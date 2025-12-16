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
/// This implements the correct Lottie mask semantics:
/// - **Add / Lighten**: Union coverage (sourceOver)
/// - **Subtract / Darken**: Remove coverage (destinationOut)
/// - **Intersect / Difference**: Intersect coverage (destinationIn via temp buffer)
///
/// ## Usage
/// ```swift
/// let composer = MaskComposer(contextPool: pool)
/// let maskImage = composer.compose(masks: masks, cropRect: rect)
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

        // Clear accumulator to transparent (0 coverage = fully masked)
        ContextPool.clearContextToTransparent(accCtx, width: width, height: height)

        // Apply translation offset
        accCtx.saveGState()
        accCtx.translateBy(x: offset.x, y: offset.y)

        // Compose all masks
        for mask in masks {
            composeMask(mask, into: accCtx, width: width, height: height, offset: offset)
        }

        accCtx.restoreGState()

        // Extract image from accumulator
        // IMPORTANT: Crop to requested size since pooled context may be larger
        guard let fullImage = accCtx.makeImage() else { return nil }

        let cropRegion = CGRect(x: 0, y: 0, width: width, height: height)
        return fullImage.cropping(to: cropRegion)
    }

    // MARK: - Private

    /// Composes a single mask into the accumulator context.
    private func composeMask(
        _ mask: MaskSnapshot,
        into accCtx: CGContext,
        width: Int,
        height: Int,
        offset: CGPoint
    ) {
        switch mask.mode {
        case .add, .lighten:
            // Add: draw coverage with normal blend (union)
            drawMaskShape(mask, into: accCtx, blendMode: .normal)

        case .subtract, .darken:
            // Subtract: remove coverage using destinationOut
            // destinationOut: dst = dst * (1 - src.alpha)
            drawMaskShape(mask, into: accCtx, blendMode: .destinationOut)

        case .intersect, .difference:
            // Intersect: requires temp buffer for AND operation
            composeIntersect(mask, into: accCtx, width: width, height: height, offset: offset)

        case .none:
            // Skip masks with mode .none
            break
        }
    }

    /// Draws a mask shape into the context with specified blend mode.
    ///
    /// For alpha-only contexts:
    /// - We draw with white (gray=1) and let alpha control coverage
    /// - opacity is encoded in the fill alpha
    private func drawMaskShape(
        _ mask: MaskSnapshot,
        into ctx: CGContext,
        blendMode: CGBlendMode
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setBlendMode(blendMode)

        // In alpha-only context, we draw white with alpha = opacity
        // This gives us coverage = opacity where the path is filled
        ctx.setFillColor(CGColor(gray: 1, alpha: mask.opacity))
        ctx.addPath(mask.path)
        ctx.fillPath(using: mask.fillRule)
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
            drawMaskShape(mask, into: accCtx, blendMode: .normal)
            return
        }
        defer { contextPool.release(tmpCtx) }

        // Clear temp to transparent
        ContextPool.clearContextToTransparent(tmpCtx, width: width, height: height)

        // Draw mask shape into temp buffer
        tmpCtx.saveGState()
        tmpCtx.translateBy(x: offset.x, y: offset.y)
        drawMaskShape(mask, into: tmpCtx, blendMode: .normal)
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
