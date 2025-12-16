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

// MARK: - MaskComposer

/// Composes multiple masks into a single coverage buffer using pixel math.
///
/// ## Key Principle: Coverage = Luminance
/// We use DeviceGray (1 byte per pixel, no alpha) for masks.
/// - 0 (black) = fully hidden
/// - 255 (white) = fully visible
/// - opacity is encoded in gray value, NOT alpha
///
/// ## Mask Mode Math (equivalent to After Effects)
/// - **Add**: `dst = max(dst, src)`
/// - **Subtract**: `dst = dst * (1 - src) / 255`
/// - **Intersect**: `dst = min(dst, src)`
/// - **Inverted**: `src = 255 - src` (applied before mode)
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

    /// Accumulator buffer (dst) - reused between compose() calls
    private var accBuffer: [UInt8] = []

    /// Source buffer for single mask - reused between masks
    private var srcBuffer: [UInt8] = []

    /// CGContext that draws into srcBuffer - reused
    private var srcContext: CGContext?

    /// Current buffer dimensions
    private var bufferWidth: Int = 0
    private var bufferHeight: Int = 0

    // MARK: - Initialization

    public init() {}

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

        // Determine initial coverage based on first mask
        let first = masks[0]
        let needsFullInitial = first.mode == .subtract ||
                               first.mode == .darken ||
                               first.mode == .intersect ||
                               first.mode == .difference ||
                               first.inverted

        // Initialize accumulator
        if needsFullInitial {
            // Start with full coverage (white)
            accBuffer.withUnsafeMutableBytes { ptr in
                memset(ptr.baseAddress, 255, width * height)
            }
        } else {
            // Start with zero coverage (black)
            accBuffer.withUnsafeMutableBytes { ptr in
                memset(ptr.baseAddress, 0, width * height)
            }
        }

        // Compose each mask
        for mask in masks {
            renderMaskToSrcBuffer(mask, offset: offset)
            composeCoverage(mode: mask.mode, inverted: mask.inverted)
        }

        // Create CGImage from accumulator
        return createImageFromAccumulator(width: width, height: height)
    }

    /// Clears cached buffers. Call after export to free memory.
    public func clearCaches() {
        accBuffer = []
        srcBuffer = []
        srcContext = nil
        bufferWidth = 0
        bufferHeight = 0
    }

    // MARK: - Private: Buffer Management

    /// Ensures buffers are allocated with correct size.
    private func ensureBuffers(width: Int, height: Int) {
        let size = width * height

        // Reallocate if size changed
        if bufferWidth != width || bufferHeight != height {
            accBuffer = [UInt8](repeating: 0, count: size)
            srcBuffer = [UInt8](repeating: 0, count: size)
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

        // Apply offset (typically -cropRect.origin)
        ctx.translateBy(x: offset.x, y: offset.y)

        // Draw shape with opacity encoded as gray value
        // gray = opacity means: 0 = transparent, 1 = opaque coverage
        ctx.setFillColor(CGColor(gray: mask.opacity, alpha: 1))
        ctx.addPath(mask.shapePath)
        ctx.fillPath(using: mask.fillRule)
    }

    // MARK: - Private: Pixel Math Composition

    /// Composes srcBuffer into accBuffer using pixel math.
    ///
    /// This is the core of mask composition - exact AE semantics:
    /// - Add: max(dst, src)
    /// - Subtract: dst * (1 - src) / 255
    /// - Intersect: min(dst, src)
    private func composeCoverage(mode: MaskMode, inverted: Bool) {
        let count = bufferWidth * bufferHeight

        for i in 0..<count {
            var s = Int(srcBuffer[i])

            // Apply inversion first
            if inverted {
                s = 255 - s
            }

            let d = Int(accBuffer[i])

            let result: Int
            switch mode {
            case .add, .lighten:
                // Union: max(dst, src)
                result = max(d, s)

            case .subtract, .darken:
                // Remove: dst * (1 - src/255) = dst * (255 - src) / 255
                result = (d * (255 - s)) / 255

            case .intersect, .difference:
                // Intersection: min(dst, src)
                result = min(d, s)

            case .none:
                // Skip this mask
                result = d
            }

            accBuffer[i] = UInt8(clamping: result)
        }
    }

    // MARK: - Private: Image Creation

    /// Creates a CGImage from the accumulator buffer.
    private func createImageFromAccumulator(width: Int, height: Int) -> CGImage? {
        // Create data provider from accumulator
        guard let provider = CGDataProvider(data: Data(accBuffer) as CFData) else {
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
