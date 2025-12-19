//
//  MaskComposer.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//  Composes multiple masks using pixel math for correct Lottie/AE semantics.
//
//  IMPORTANT: This class is NOT thread-safe. It must be used exclusively
//  on a single queue (typically the render queue during export).
//

import CoreGraphics
import ImageIO

// MARK: - MaskComposer

/// Composes multiple masks into a single coverage buffer using pixel math.
///
/// ## Key Principle: clip(to:mask:) semantics
/// We use DeviceGray (1 byte per pixel, no alpha) for masks.
/// Apple's clip(to:mask:) uses mask sample value as alpha:
/// - 255 (white) = fully VISIBLE
/// - 0 (black) = fully HIDDEN
/// - opacity is encoded in gray value, NOT alpha
///
/// ## Mask Mode Math (equivalent to After Effects)
/// - **Add**: `dst = max(dst, src)` - union, reveal shape area
/// - **Subtract**: `dst = dst * (255 - src) / 255` - hide shape area
/// - **Intersect**: `dst = min(dst, src)` - keep only intersection
/// - **Inverted**: `src = 255 - src` (applied before mode)
///
/// ## Initial Accumulator Value
/// - Add mode: start with 0 (all hidden), Add reveals shapes
/// - Subtract/Intersect: start with 255 (all visible), then reduce
///
/// ## Why Pixel Math Instead of CGBlendMode
/// - CGBlendMode behavior with grayscale contexts is undefined/inconsistent
/// - Pixel math gives exact AE semantics
/// - Easy to debug (can dump buffers)
/// - No CoreGraphics quirks
///
/// ## Thread Safety
/// This class is NOT thread-safe. Use only from a single queue.
///
public final class MaskComposer {

    // MARK: - Properties

    /// Accumulator buffer (dst) - stable pointer for no-copy CGDataProvider
    /// P0-2: Using UnsafeMutablePointer instead of [UInt8] to avoid Data copy
    private var accPtr: UnsafeMutablePointer<UInt8>?
    private var accCapacity: Int = 0

    /// Source buffer for single mask - reused between masks
    private var srcBuffer: [UInt8] = []

    /// CGContext that draws into srcBuffer - reused
    private var srcContext: CGContext?

    /// Current buffer dimensions
    private var bufferWidth: Int = 0
    private var bufferHeight: Int = 0

    // MARK: - Initialization

    public init() {}

    deinit {
        accPtr?.deallocate()
    }

    // MARK: - Public API

    /// Composes multiple masks into a single grayscale coverage image.
    ///
    /// - Parameters:
    ///   - masks: Array of MaskSnapshot with resolved paths
    ///   - width: Width of the mask buffer
    ///   - height: Height of the mask buffer
    ///   - offset: Translation offset for rendering (typically -cropRect.origin)
    /// - Returns: CGImage with grayscale coverage, or nil if composition failed
    public func compose(
        masks: [MaskSnapshot],
        width: Int,
        height: Int,
        offset: CGPoint
    ) -> CGImage? {
        guard !masks.isEmpty, width > 0, height > 0 else { return nil }

        // Ensure buffers are allocated/resized
        ensureBuffers(width: width, height: height)

        // clip(to:mask:) semantics (Apple docs):
        // - WHITE (255) = VISIBLE (mask sample used as alpha)
        // - BLACK (0) = HIDDEN (clipped)
        //
        // So our coverage buffer: 255 = show content, 0 = hide content

        // Initialize accumulator (P0-2: using stable pointer)
        guard let acc = accPtr else { return nil }
        let size = width * height

        // Neutral element depends ONLY on the first operation
        // - add/lighten: start from 0 (empty coverage), then max(0, s) = s
        // - subtract/darken/intersect/difference: start from 255 (full coverage)
        // - none: start from 255 (same as "no mask")
        let first = masks[0]
        let initial: UInt8
        switch first.mode {
        case .add, .lighten:
            initial = 0
        case .subtract, .darken, .intersect, .difference, .none:
            initial = 255
        }
        memset(acc, Int32(initial), size)

        // Compose each mask
        for mask in masks {
            renderMaskToSrcBuffer(mask, offset: offset)
            composeCoverage(mode: mask.mode, inverted: mask.inverted, opacity: mask.opacity)
        }

        // Create CGImage from accumulator
        return createImageFromAccumulator(width: width, height: height)
    }

    /// Clears cached buffers. Call after export to free memory.
    public func clearCaches() {
        accPtr?.deallocate()
        accPtr = nil
        accCapacity = 0
        srcBuffer = []
        srcContext = nil
        bufferWidth = 0
        bufferHeight = 0
    }

    // MARK: - Private: Buffer Management

    /// Ensures buffers are allocated with correct size.
    /// P0-2: accPtr uses stable UnsafeMutablePointer for no-copy CGDataProvider
    private func ensureBuffers(width: Int, height: Int) {
        let needed = width * height

        // Reallocate accPtr if capacity insufficient
        if needed > accCapacity {
            accPtr?.deallocate()
            accPtr = .allocate(capacity: needed)
            accCapacity = needed
        }

        // Reallocate srcBuffer and srcContext if dimensions changed
        if bufferWidth != width || bufferHeight != height {
            srcBuffer = [UInt8](repeating: 0, count: needed)
            srcContext = nil // Force recreation
            bufferWidth = width
            bufferHeight = height
        }

        // Create srcContext if needed (draws directly into srcBuffer)
        if srcContext == nil {
            srcBuffer.withUnsafeMutableBytes { ptr in
                srcContext = CGContext(
                    data: ptr.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            }
            // Enable antialiasing for smooth mask edges
            srcContext?.setShouldAntialias(true)
            srcContext?.setAllowsAntialiasing(true)
        }
    }

    // MARK: - Private: Mask Rendering

    /// Renders a single mask shape into srcBuffer.
    private func renderMaskToSrcBuffer(_ mask: MaskSnapshot, offset: CGPoint) {
        guard let ctx = srcContext else { return }

        // Clear srcBuffer to black (0 coverage)
        srcBuffer.withUnsafeMutableBytes { ptr in
            memset(ptr.baseAddress, 0, bufferWidth * bufferHeight)
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Offscreen = Quartz coordinates (Y-up), only offset needed
        // Must match contentCtx transform order in renderLayerWithMask
        ctx.translateBy(x: offset.x, y: offset.y)

        // Draw shape as full white (opacity applied in composeCoverage)
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.addPath(mask.shapePath)
        ctx.fillPath(using: mask.fillRule)
    }

    // MARK: - Private: Pixel Math Composition

    /// Composes srcBuffer into accBuffer using pixel math.
    ///
    /// clip(to:mask:) semantics (Apple docs):
    /// - 255 (white) = VISIBLE
    /// - 0 (black) = HIDDEN
    ///
    /// srcBuffer contains shape coverage: 255 inside shape, 0 outside
    /// accPtr is our accumulated mask: 255 = visible, 0 = hidden
    ///
    /// After Effects mask modes:
    /// - Add: union - reveal shape area (increase coverage)
    /// - Subtract: difference - hide shape area (decrease coverage)
    /// - Intersect: intersection - keep only where both are visible
    private func composeCoverage(mode: MaskMode, inverted: Bool, opacity: CGFloat) {
        guard let acc = accPtr else { return }
        let count = bufferWidth * bufferHeight

        // Clamp and convert opacity to 0-255 range
        let o = Int((max(0, min(1, opacity)) * 255.0).rounded())

        for i in 0..<count {
            var s = Int(srcBuffer[i])  // src = shape coverage (255 inside, 0 outside)

            // Apply inversion first (in shape space)
            if inverted {
                s = 255 - s
            }

            // Apply mask opacity as multiplier
            s = (s * o) / 255

            let d = Int(acc[i])  // dst = accumulated coverage (255=visible, 0=hidden)

            let result: Int
            switch mode {
            case .add, .lighten:
                // Add: union of masks - take maximum coverage
                // Inside shape (s=255): max(d, 255) = 255 (visible)
                // Outside shape (s=0): max(d, 0) = d (unchanged)
                result = max(d, s)

            case .subtract, .darken:
                // Subtract: multiplicatively cut out shape from accumulated coverage
                // Standard coverage compositing formula (Lottie/AE-like model)
                // Inside shape (s=255): d * (255 - 255) / 255 = 0 (hidden)
                // Outside shape (s=0): d * (255 - 0) / 255 = d (unchanged)
                // Works correctly with antialiasing and opacity
                result = (d * (255 - s)) / 255

            case .intersect:
                // Intersect: keep only where BOTH are visible
                // min(dst, src)
                // Inside shape (s=255): min(d, 255) = d
                // Outside shape (s=0): min(d, 0) = 0 (hidden)
                result = min(d, s)

            case .difference:
                // Difference: XOR-like coverage (where one but not both are visible)
                // abs(dst - src)
                result = abs(d - s)

            case .none:
                result = d
            }

            acc[i] = UInt8(clamping: result)
        }
    }

    // MARK: - Private: Image Creation

    /// Creates a CGImage from the accumulator buffer.
    /// Uses a copy of the data to avoid lifetime issues when compose() is called again.
    private func createImageFromAccumulator(width: Int, height: Int) -> CGImage? {
        guard let acc = accPtr else { return nil }
        let size = width * height

        // Create a copy of accumulator data for CGImage
        // This ensures the CGImage remains valid even if compose() is called again
        // (which would overwrite accPtr with new data)
        let data = Data(bytes: acc, count: size) as CFData
        guard let provider = CGDataProvider(data: data) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension MaskComposer {
    /// Saves the current accumulator as PNG for debugging.
    public func saveAccumulatorDebugImage(to url: URL, width: Int, height: Int) {
        guard let image = createImageFromAccumulator(width: width, height: height),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            print("⚠️ [MaskComposer] Failed to create debug image destination")
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("✅ [MaskComposer] Saved debug mask to \(url.path)")
    }

    /// Logs mask composition details.
    public static func logMasks(_ masks: [MaskSnapshot], label: String = "Masks") {
        print("🎭 [\(label)] count=\(masks.count)")
        for (i, mask) in masks.enumerated() {
            print("🎭   [\(i)] mode=\(mask.mode) opacity=\(String(format: "%.2f", mask.opacity)) inverted=\(mask.inverted)")
            print("🎭   [\(i)] shapeBounds=\(mask.shapeBounds)")
        }
    }
}
#endif
