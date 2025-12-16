//
//  MaskComposer.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//  Composes multiple masks using Porter-Duff operations for correct Lottie semantics.
//
//  IMPORTANT: This class is NOT thread-safe. It must be used exclusively
//  on a single queue (typically the render queue during export).
//

import CoreGraphics

// MARK: - MaskComposer

/// Composes multiple masks into a single alpha coverage buffer.
///
/// This implements the correct Lottie mask semantics using raw shape paths:
/// - **Add**: Union coverage — draw shape with `.normal` blend
/// - **Add + inverted**: Show everything except shape — fill full rect, then `.destinationOut` shape
/// - **Subtract**: Remove coverage — `.destinationOut` on shape
/// - **Subtract + inverted**: Remove everything except shape — complex case
/// - **Intersect**: Keep only intersection — `.destinationIn` via temp buffer
///
/// ## Important
/// This class works with `MaskSnapshot.shapePath` (raw path without veryLargeRect),
/// NOT with `bakedPath`. The inversion logic is handled explicitly here.
///
/// ## Usage
/// ```swift
/// let composer = MaskComposer(contextPool: pool)
/// let maskImage = composer.compose(masks: masks, width: w, height: h, offset: pt)
/// // Use maskImage with CGContext.clip(to:mask:)
/// ```
///
/// ## Thread Safety
/// This class is NOT thread-safe. Use only from a single queue.
///
public final class MaskComposer {

    // MARK: - Properties

    /// Pool for getting mask buffers
    private let contextPool: ContextPool

    // MARK: - Initialization

    /// Creates a new mask composer.
    /// - Parameter contextPool: Pool for allocating temporary buffers
    public init(contextPool: ContextPool) {
        self.contextPool = contextPool
    }

    // MARK: - Public API

    /// Composes multiple masks into a single alpha coverage image.
    ///
    /// - Parameters:
    ///   - masks: Array of MaskSnapshot with resolved paths
    ///   - width: Width of the mask buffer
    ///   - height: Height of the mask buffer
    ///   - offset: Translation offset for rendering (typically -cropRect.origin)
    /// - Returns: CGImage with alpha coverage, or nil if composition failed
    public func compose(
        masks: [MaskSnapshot],
        width: Int,
        height: Int,
        offset: CGPoint
    ) -> CGImage? {
        guard !masks.isEmpty, width > 0, height > 0 else { return nil }

        // Get accumulator buffer from pool
        guard let accCtx = contextPool.getMask(width: width, height: height) else {
            return nil
        }
        defer { contextPool.release(accCtx) }

        // Determine initial coverage based on first mask
        // - Add (non-inverted): start empty, add shape coverage
        // - Subtract / Intersect / Inverted: start full, then modify
        let firstMask = masks[0]
        let needsFullInitialCoverage = firstMask.mode == .subtract ||
                                        firstMask.mode == .darken ||
                                        firstMask.mode == .intersect ||
                                        firstMask.mode == .difference ||
                                        firstMask.inverted

        // 🔥 DEBUG: Log mask details — REMOVED for cleaner logs

        if needsFullInitialCoverage {
            // Fill accumulator with full coverage (alpha = 1)
            initializeAccumulatorFull(accCtx, width: width, height: height)
        } else {
            // Clear accumulator to transparent (0 coverage)
            ContextPool.clearMaskLuminance(accCtx, width: width, height: height)
        }

        // Apply translation offset
        accCtx.saveGState()
        accCtx.translateBy(x: offset.x, y: offset.y)

        // Compose all masks with their actual modes
        for mask in masks {
            composeMask(mask, into: accCtx, width: width, height: height, offset: offset)
        }

        accCtx.restoreGState()

        // Extract grayscale image from accumulator
        guard let fullImage = accCtx.makeImage() else { return nil }

        #if DEBUG
        // Debug: sample raw grayscale pixels
        if let provider = fullImage.dataProvider,
           let data = provider.data,
           let bytes = CFDataGetBytePtr(data) {
            let bpr = fullImage.bytesPerRow
            let cornerIdx = 10 * bpr + 10
            let centerIdx = (fullImage.height / 2) * bpr + (fullImage.width / 2)
            print("🔥 [MaskComposer] grayscale mask:")
            print("🔥   corner(10,10)=\(bytes[cornerIdx]) center=\(bytes[centerIdx])")
            print("🔥   For clip(to:mask:): white(255)=visible, black(0)=hidden")
        }
        #endif

        let cropRegion = CGRect(x: 0, y: 0, width: width, height: height)
        guard let croppedImage = fullImage.cropping(to: cropRegion) else { return nil }

        // Return grayscale CGImage directly for clip(to:mask:)
        // clip(to:mask:) semantics for grayscale images:
        // - white (255) = fully visible
        // - black (0) = fully hidden
        // This matches our "coverage = luminance" model
        return croppedImage
    }

    /// Fills the accumulator with full coverage (alpha = 1).
    /// Used when first mask is subtract/intersect/inverted.
    private func initializeAccumulatorFull(_ ctx: CGContext, width: Int, height: Int) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Reset any transforms
        ctx.resetClip()
        let ctm = ctx.ctm
        if !ctm.isIdentity {
            let det = ctm.a * ctm.d - ctm.b * ctm.c
            if abs(det) > 1e-12 {
                ctx.concatenate(ctm.inverted())
            }
        }

        // Fill with full coverage
        ctx.setBlendMode(.copy)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: - Private

    /// Composes a single mask into the accumulator context.
    ///
    /// Uses raw `shapePath` and applies mode/inverted logic explicitly.
    /// Accumulator must be pre-initialized (empty or full) based on first mask.
    private func composeMask(
        _ mask: MaskSnapshot,
        into accCtx: CGContext,
        width: Int,
        height: Int,
        offset: CGPoint
    ) {
        switch mask.mode {
        case .add, .lighten:
            if mask.inverted {
                // Inverted Add: show everything EXCEPT the shape
                // Fill full coverage, then cut out shape
                composeInvertedAdd(mask, into: accCtx, width: width, height: height, offset: offset)
            } else {
                // Normal Add: draw shape coverage (union)
                drawShapePath(mask, into: accCtx, blendMode: .normal)
            }

        case .subtract, .darken:
            if mask.inverted {
                // Inverted Subtract: keep only the shape area
                // This is equivalent to intersect with shape
                composeIntersect(mask, into: accCtx, width: width, height: height, offset: offset)
            } else {
                // Normal Subtract: remove shape from coverage
                // destinationOut: dst = dst * (1 - src.alpha)
                drawShapePath(mask, into: accCtx, blendMode: .destinationOut)
            }

        case .intersect, .difference:
            if mask.inverted {
                // Inverted Intersect: keep only where shape is NOT
                // This is subtract semantics
                drawShapePath(mask, into: accCtx, blendMode: .destinationOut)
            } else {
                // Normal Intersect: keep only where both have coverage
                composeIntersect(mask, into: accCtx, width: width, height: height, offset: offset)
            }

        case .none:
            // Skip masks with mode .none
            break
        }
    }

    /// Draws the raw shape path into the context with specified blend mode.
    ///
    /// Uses `shapePath` (raw path without veryLargeRect inversion).
    ///
    /// We use "coverage = luminance" model:
    /// - clip(to:mask:) reads gray channel for coverage
    /// - gray=0 (black) = fully hidden
    /// - gray=1 (white) = fully visible
    /// - gray=opacity encodes partial coverage
    private func drawShapePath(
        _ mask: MaskSnapshot,
        into ctx: CGContext,
        blendMode: CGBlendMode
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setBlendMode(blendMode)

        // Coverage = luminance model:
        // gray = mask.opacity encodes coverage (0 = hidden, 1 = visible)
        // alpha = 1 ensures the fill actually applies
        ctx.setFillColor(CGColor(gray: mask.opacity, alpha: 1))
        ctx.addPath(mask.shapePath)
        ctx.fillPath(using: mask.fillRule)
    }

    /// Composes an inverted Add mask.
    ///
    /// Algorithm:
    /// 1. Fill entire bounds with coverage
    /// 2. Cut out the shape using destinationOut
    /// Result: coverage everywhere EXCEPT the shape
    private func composeInvertedAdd(
        _ mask: MaskSnapshot,
        into accCtx: CGContext,
        width: Int,
        height: Int,
        offset: CGPoint
    ) {
        accCtx.saveGState()
        defer { accCtx.restoreGState() }

        // First: fill full rect with coverage (using normal blend to add to existing)
        // Coverage = luminance: gray=opacity for partial coverage
        accCtx.setBlendMode(.normal)
        accCtx.setFillColor(CGColor(gray: mask.opacity, alpha: 1))

        // We need to fill the shape bounds in layer coordinates
        // The context already has offset applied, so fill the shapeBounds
        let boundsRect = mask.shapeBounds
        accCtx.fill(boundsRect)

        // Second: cut out the shape
        // Coverage = luminance: gray=1 (white) for full removal
        accCtx.setBlendMode(.destinationOut)
        accCtx.setFillColor(CGColor(gray: 1, alpha: 1))
        accCtx.addPath(mask.shapePath)
        accCtx.fillPath(using: mask.fillRule)
    }

    /// Composes an intersect mask using a temporary buffer.
    ///
    /// Algorithm:
    /// 1. Render mask shape into temp buffer
    /// 2. Draw temp buffer onto accumulator with destinationIn blend
    /// 3. Result: acc = acc AND temp (intersection)
    private func composeIntersect(
        _ mask: MaskSnapshot,
        into accCtx: CGContext,
        width: Int,
        height: Int,
        offset: CGPoint
    ) {
        // Get temp buffer for this mask
        guard let tmpCtx = contextPool.getMask(width: width, height: height) else {
            #if DEBUG
            print("⚠️ [MaskComposer] Failed to get temp buffer for intersect, falling back to add")
            #endif
            // Fallback to add if we can't get temp buffer
            drawShapePath(mask, into: accCtx, blendMode: .normal)
            return
        }
        defer { contextPool.release(tmpCtx) }

        // Clear temp to transparent
        ContextPool.clearMaskLuminance(tmpCtx, width: width, height: height)

        // Draw mask shape into temp buffer
        tmpCtx.saveGState()
        tmpCtx.translateBy(x: offset.x, y: offset.y)
        drawShapePath(mask, into: tmpCtx, blendMode: .normal)
        tmpCtx.restoreGState()

        // Get image from temp buffer
        guard let fullTmpImage = tmpCtx.makeImage() else {
            #if DEBUG
            print("⚠️ [MaskComposer] Failed to create temp image for intersect")
            #endif
            return
        }

        let cropRegion = CGRect(x: 0, y: 0, width: width, height: height)
        guard let tmpImage = fullTmpImage.cropping(to: cropRegion) else { return }

        // Draw temp onto accumulator with destinationIn
        // destinationIn: dst = dst * src.alpha (keeps only where both have coverage)
        accCtx.saveGState()

        // Reset translation for drawing the composited image
        let ctm = accCtx.ctm
        if !ctm.isIdentity {
            let det = ctm.a * ctm.d - ctm.b * ctm.c
            if abs(det) > 1e-12 {
                accCtx.concatenate(ctm.inverted())
            }
        }

        accCtx.setBlendMode(.destinationIn)
        accCtx.draw(tmpImage, in: cropRegion)
        accCtx.restoreGState()
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension MaskComposer {
    /// Logs mask composition details for debugging.
    public static func logMasks(_ masks: [MaskSnapshot], label: String = "Masks") {
        print("🎭 [\(label)] count=\(masks.count)")
        for (i, mask) in masks.enumerated() {
            print("🎭   [\(i)] mode=\(mask.mode) opacity=\(String(format: "%.2f", mask.opacity)) inverted=\(mask.inverted)")
            print("🎭   [\(i)] shapeBounds=\(mask.shapeBounds)")
        }
    }
}
#endif
