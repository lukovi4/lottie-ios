//
//  LottieOffscreenRenderer.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//  Renders Lottie animations directly to CGContext without CALayer.render().
//
//  IMPORTANT: This class is NOT thread-safe. It must be created and used
//  exclusively on a single queue (typically the render queue during export).
//  Do not share instances between threads or with the main thread preview.
//

import CoreGraphics
import QuartzCore

// MARK: - LottieOffscreenRenderer

/// A renderer that draws Lottie animations directly to CGContext.
///
/// This is designed for video export where:
/// - Main thread availability is limited
/// - Maximum render speed is required
/// - CALayer.render(in:) overhead is unacceptable
///
/// ## Usage
/// ```swift
/// // Create on render queue
/// renderQueue.async {
///     let renderer = LottieOffscreenRenderer(
///         animation: animation,
///         imageProvider: streamingVideoProvider
///     )
///
///     for frame in 0..<totalFrames {
///         let seconds = Double(frame) / fps
///         renderer.renderFrame(seconds: CGFloat(seconds), into: context)
///     }
/// }
/// ```
///
/// ## Thread Safety
/// This class is intentionally single-thread confined. All calls (including init)
/// must happen on the same queue. This enables maximum performance without locks.
///
public final class LottieOffscreenRenderer {

    // MARK: - Properties

    /// The size of the animation canvas
    public let canvasSize: CGSize

    /// The frame rate of the animation
    public let framerate: CGFloat

    /// The animation layers tree (owned by this renderer, not shared)
    private let animationLayers: [CompositionLayer]

    /// Provider for image/video frames (owned by this renderer)
    private let layerImageProvider: LayerImageProvider

    /// Pool of reusable CGContext buffers for mask rendering
    private let contextPool = ContextPool()

    // MARK: - Metrics (for debugging/profiling)

    /// Number of frames rendered since creation
    public private(set) var framesRendered: Int = 0

    /// Total time spent rendering (seconds)
    public private(set) var totalRenderTime: TimeInterval = 0

    // MARK: - Initialization

    /// Creates a new offscreen renderer for the given animation.
    ///
    /// - Important: Call this on the render queue, not main thread.
    ///
    /// - Parameters:
    ///   - animation: The Lottie animation to render
    ///   - imageProvider: Provider for images/video frames (should be export-specific)
    ///   - textProvider: Optional text provider (defaults to empty)
    ///   - fontProvider: Optional font provider (defaults to system fonts)
    public init(
        animation: LottieAnimation,
        imageProvider: AnimationImageProvider,
        textProvider: AnimationKeypathTextProvider = DefaultTextProvider(),
        fontProvider: AnimationFontProvider = DefaultFontProvider()
    ) {
        self.canvasSize = animation.bounds.size
        self.framerate = CGFloat(animation.framerate)

        // Create our own LayerImageProvider (not shared with preview)
        // Note: We do NOT wrap with FlippedImageProvider here - that would copy pixels
        // on every video frame (expensive!). Instead, we flip via geometry in draw rect.
        self.layerImageProvider = LayerImageProvider(
            imageProvider: imageProvider,
            assets: animation.assetLibrary?.imageAssets
        )

        // Create text/font providers (local instances)
        let layerTextProvider = LayerTextProvider(textProvider: textProvider)
        let layerFontProvider = LayerFontProvider(fontProvider: fontProvider)

        // Build our own layer tree (not shared with LottieAnimationView)
        // Note: We pass nil for rootAnimationLayer since we're not using CALayer hierarchy
        let layers = animation.layers.initializeCompositionLayers(
            assetLibrary: animation.assetLibrary,
            layerImageProvider: layerImageProvider,
            layerTextProvider: layerTextProvider,
            layerFontProvider: layerFontProvider,
            textProvider: textProvider,
            fontProvider: fontProvider,
            frameRate: framerate,
            rootAnimationLayer: nil
        )

        // Process layers: set up mattes
        var processedLayers: [CompositionLayer] = []
        var mattedLayer: CompositionLayer? = nil

        for layer in layers.reversed() {
            layer.bounds = CGRect(origin: .zero, size: canvasSize)

            // Handle matte relationships
            if let matte = mattedLayer {
                matte.matteLayer = layer
                mattedLayer = nil
                continue
            }
            if let matteType = layer.matteType,
               matteType == .add || matteType == .invert {
                mattedLayer = layer
            }

            processedLayers.append(layer)
        }

        self.animationLayers = processedLayers

        // Collect image layers for provider registration (unified traversal will render them)
        var collectedImageLayers: [ImageCompositionLayer] = []
        for layer in processedLayers {
            Self.collectImageLayers(from: layer, into: &collectedImageLayers)
        }
        layerImageProvider.addImageLayers(collectedImageLayers)

        // Initial image load
        layerImageProvider.reloadImages(seconds: nil)

        print("🎬 [LottieOffscreenRenderer] Created: size=\(canvasSize), fps=\(framerate), layers=\(animationLayers.count), imageLayers=\(collectedImageLayers.count)")
        for (i, layer) in animationLayers.enumerated() {
            let typeName = String(describing: type(of: layer)).replacingOccurrences(of: "CompositionLayer", with: "")
            print("🎬 [LottieOffscreenRenderer]   [\(i)] '\(layer.keypathName ?? "?")' (\(typeName))")
        }
    }

    // MARK: - Rendering

    /// Renders a frame at the given time into the provided context.
    ///
    /// - Important: Call this on the same queue where init was called.
    ///
    /// - Parameters:
    ///   - seconds: The time in seconds to render
    ///   - ctx: The CGContext to render into
    public func renderFrame(seconds: CGFloat, into ctx: CGContext) {
        let startTime = CACurrentMediaTime()

        // 1. Update video/image frames for this time
        layerImageProvider.reloadImages(seconds: seconds)

        // 2. Calculate frame number
        let frame = seconds * framerate

        // 3. Update all layer states (transforms, visibility, etc.)
        for layer in animationLayers {
            layer.displayWithFrame(frame: frame, forceUpdates: true)
        }

        // 4. Render all layers in correct order (unified traversal)
        // CONTRACT: VideoGenerator provides context already flipped to UIKit coords (Y-down).
        // NOTE: We use RenderState to track alpha because CGContext.alpha getter
        // doesn't work correctly with bitmap contexts.
        let initialState = RenderState.identity
        for layer in animationLayers {
            renderCompositionLayer(layer, into: ctx, state: initialState)
        }

        // Update metrics
        framesRendered += 1
        totalRenderTime += CACurrentMediaTime() - startTime
    }

    // MARK: - Unified Layer Traversal

    /// Renders a composition layer and its contents.
    /// This is the unified traversal that handles all layer types in correct order.
    ///
    /// ## Layer Types:
    /// - ImageCompositionLayer → draws image with pixel-buffer flip
    /// - ShapeCompositionLayer → draws shapes via renderer pipeline
    /// - PreCompositionLayer → recursively renders children
    ///
    /// ## Alpha Management
    /// We use RenderState to track accumulated alpha, NOT CGContext.alpha getter
    /// (which doesn't work correctly with bitmap contexts).
    ///
    private func renderCompositionLayer(_ layer: CompositionLayer, into cg: CGContext, state: RenderState) {
        guard !layer.isHidden else { return }

        cg.saveGState()
        defer { cg.restoreGState() }

        // 1. Apply global transform (position, scale, rotation, anchor, parent chain)
        let transform = layer.transformNode.globalTransform.affineTransform
        cg.concatenate(transform)

        // 2. Calculate layer alpha from RenderState (our source of truth)
        // NEVER read from cg.alpha - it doesn't work with bitmap contexts!
        let layerOpacity = CGFloat(layer.transformNode.opacity)
        let layerState = state.withOpacity(layerOpacity)

        // 3. Set alpha ABSOLUTE from our tracked state
        cg.setAlpha(layerState.alpha)

        // 4. Create RenderContext for this layer
        let renderCtx = RenderContext(cg: cg, state: layerState)

        // 5. Check for masks - if present, use alpha-mask rendering
        if let maskContainer = layer.maskLayer {
            let masks = maskContainer.maskSnapshots()
            if !masks.isEmpty {
                renderLayerWithMask(layer, masks: masks, into: cg, state: layerState)
                return
            }
        }

        // 6. Render based on layer type (no mask)
        renderLayerContent(layer, ctx: renderCtx)
    }

    /// Renders layer content based on its type.
    /// Extracted for reuse in both masked and non-masked paths.
    private func renderLayerContent(_ layer: CompositionLayer, ctx: RenderContext) {
        if let shapeLayer = layer as? ShapeCompositionLayer {
            renderShapeLayer(shapeLayer, ctx: ctx)
        } else if let imageLayer = layer as? ImageCompositionLayer {
            renderImageLayer(imageLayer, ctx: ctx)
        } else if let precompLayer = layer as? PreCompositionLayer {
            renderPrecompLayer(precompLayer, ctx: ctx)
        }
        // Other layer types (Text, Solid, etc.) can be added later
    }

    // MARK: - Mask Rendering

    /// Renders a layer with alpha mask applied.
    ///
    /// ## Algorithm:
    /// 1. Calculate cropRect = intersection of content bounds and mask bounds
    /// 2. Render content into RGBA offscreen buffer (cropRect size)
    /// 3. Render masks into grayscale buffer (white * opacity)
    /// 4. Composite: clip(to: cropRect, mask: grayImage) + draw(rgbaImage)
    ///
    /// ## Performance:
    /// - Uses ContextPool to reuse buffers
    /// - Bounds cropping avoids rendering full canvas for small masks
    ///
    /// ## Important:
    /// This method is called AFTER globalTransform is already applied to main context.
    /// Content and mask are rendered in layer's LOCAL coordinate space (before transform).
    /// The final composite is drawn into the already-transformed main context.
    ///
    private func renderLayerWithMask(
        _ layer: CompositionLayer,
        masks: [MaskSnapshot],
        into cg: CGContext,
        state: RenderState
    ) {
        // 1. Calculate crop bounds in layer's LOCAL space (content ∩ masks)
        // contentBounds and mask paths are in local coords
        let contentBounds = layer.contentsLayer.bounds
        let maskBounds = calculateMaskBounds(masks)
        var cropRect = contentBounds.intersection(maskBounds)

        // Guard against empty or invalid rect
        if cropRect.isNull || cropRect.isEmpty || cropRect.width < 1 || cropRect.height < 1 {
            // Mask doesn't intersect content - nothing to render
            return
        }

        // Add small padding for anti-aliasing
        cropRect = cropRect.insetBy(dx: -2, dy: -2)

        let width = Int(ceil(cropRect.width))
        let height = Int(ceil(cropRect.height))

        // 2. Get buffers from pool
        guard let contentCtx = contextPool.getRGBA(width: width, height: height),
              let maskCtx = contextPool.getGrayscale(width: width, height: height) else {
            // Fallback: render without mask if we can't get buffers
            print("⚠️ [LottieOffscreenRenderer] Failed to get context buffers for mask, rendering without mask")
            let renderCtx = RenderContext(cg: cg, state: state)
            renderLayerContent(layer, ctx: renderCtx)
            return
        }

        defer {
            contextPool.release(contentCtx)
            contextPool.release(maskCtx)
        }

        // 3. Setup content context with offset for crop
        // We render in layer's local space, offset by cropRect origin
        contentCtx.translateBy(x: -cropRect.origin.x, y: -cropRect.origin.y)

        // 4. Render layer content into RGBA buffer
        // Create RenderContext with alpha=1.0 for offscreen, we'll apply layer alpha when compositing
        let offscreenState = RenderState(alpha: 1.0)
        let contentRenderCtx = RenderContext(cg: contentCtx, state: offscreenState)
        renderLayerContent(layer, ctx: contentRenderCtx)

        // 5. Render masks into grayscale buffer
        maskCtx.translateBy(x: -cropRect.origin.x, y: -cropRect.origin.y)
        renderMasksToGrayscale(masks, into: maskCtx)

        // 6. Get images from buffers
        guard let contentImage = contentCtx.makeImage(),
              let maskImage = maskCtx.makeImage() else {
            print("⚠️ [LottieOffscreenRenderer] Failed to create images from mask buffers")
            return
        }

        // 7. Composite onto main context
        // Main context already has globalTransform applied, so we draw at cropRect origin
        // in local coords. clip(to:mask:) uses mask alpha to determine visibility.
        // Apply layer alpha when drawing the composited result.
        cg.saveGState()
        cg.setAlpha(state.alpha)
        let destRect = CGRect(x: cropRect.origin.x, y: cropRect.origin.y, width: CGFloat(width), height: CGFloat(height))
        cg.clip(to: destRect, mask: maskImage)
        cg.draw(contentImage, in: destRect)
        cg.restoreGState()
    }

    /// Calculates the bounding box of all masks combined.
    private func calculateMaskBounds(_ masks: [MaskSnapshot]) -> CGRect {
        var bounds = CGRect.null
        for mask in masks {
            let pathBounds = mask.path.boundingBox
            if !pathBounds.isNull {
                bounds = bounds.union(pathBounds)
            }
        }
        return bounds
    }

    /// Renders masks into a grayscale context.
    /// White (1.0) = fully visible, Black (0.0) = fully masked.
    ///
    /// For Add mode: fill path with white * opacity
    /// Multiple Add masks are combined (union).
    ///
    private func renderMasksToGrayscale(_ masks: [MaskSnapshot], into ctx: CGContext) {
        // Start with black (fully masked)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: -10_000_000, y: -10_000_000, width: 20_000_000, height: 20_000_000))

        // Render each mask
        for mask in masks {
            switch mask.mode {
            case .add:
                // Add mode: fill with white * opacity
                ctx.setFillColor(gray: 1, alpha: mask.opacity)
                ctx.addPath(mask.path)
                ctx.fillPath(using: .evenOdd)

            case .subtract:
                // Subtract: path already contains veryLargeRect with evenOdd
                // Fill with black to subtract
                ctx.setFillColor(gray: 0, alpha: mask.opacity)
                ctx.addPath(mask.path)
                ctx.fillPath(using: .evenOdd)

            case .intersect:
                // Intersect: more complex, would need separate buffer
                // For now, treat as add (covers most cases in MinCircles)
                ctx.setFillColor(gray: 1, alpha: mask.opacity)
                ctx.addPath(mask.path)
                ctx.fillPath(using: .evenOdd)

            default:
                // Other modes (lighten, darken, difference, none) - skip
                break
            }
        }
    }

    // MARK: - Shape Rendering

    /// Renders a ShapeCompositionLayer by traversing its renderContainer.
    ///
    /// Uses OffscreenRenderable protocol on shape renderers for proper alpha handling.
    /// Renderers receive RenderContext with explicit alpha state instead of relying
    /// on CGContext.alpha getter (which doesn't work with bitmap contexts).
    ///
    private func renderShapeLayer(_ layer: ShapeCompositionLayer, ctx: RenderContext) {
        guard let container = layer.renderContainer else { return }
        renderShapeContainer(container, ctx: ctx)
    }

    /// Recursively renders a ShapeContainerLayer and its children.
    ///
    /// ## Alpha Management
    /// Each renderer receives RenderContext with accumulated layer-level alpha.
    /// Renderers multiply their paint-level opacity on top: `ctx.state.alpha * self.opacity`
    ///
    /// ## Renderer Types (all must conform to OffscreenRenderable)
    /// - FillRenderer, StrokeRenderer: Simple path operations
    /// - GradientFillRenderer, GradientStrokeRenderer: Complex gradient rendering
    /// - LegacyGradientFillRenderer: Used internally by GradientStrokeRenderer
    ///
    /// ## No Fallback Policy
    /// We do NOT fall back to shapeRenderLayer.draw(in:) because:
    /// 1. It uses ctx.alpha which doesn't work in bitmap contexts
    /// 2. Mixing render paths would cause inconsistent alpha behavior
    /// Non-migrated renderers are logged and skipped (fail-fast for debugging).
    ///
    private func renderShapeContainer(_ container: ShapeContainerLayer, ctx: RenderContext) {
        // Render in correct order (renderLayers are in Lottie's layer order)
        for renderLayer in container.renderLayers {
            guard !renderLayer.isHidden else { continue }

            ctx.cg.saveGState()

            // Apply layer's own transform if any
            if !renderLayer.affineTransform().isIdentity {
                ctx.cg.concatenate(renderLayer.affineTransform())
            }

            // Call renderOffscreen directly on renderer for proper alpha handling
            if let shapeRenderLayer = renderLayer as? ShapeRenderLayer {
                if let offscreenRenderer = shapeRenderLayer.renderer as? OffscreenRenderable {
                    // Use OffscreenRenderable path - proper alpha from RenderState
                    offscreenRenderer.renderOffscreen(ctx)
                } else {
                    // NO FALLBACK: Log and skip non-migrated renderer
                    // This makes migration gaps immediately visible during testing
                    let rendererType = String(describing: type(of: shapeRenderLayer.renderer))
                    logNonMigratedRenderer(rendererType)
                    #if DEBUG
                    assertionFailure("⚠️ [LottieOffscreenRenderer] Renderer '\(rendererType)' does not conform to OffscreenRenderable. Export will be incorrect.")
                    #endif
                }
            }

            ctx.cg.restoreGState()

            // Recurse into nested containers (safe type check)
            if let childContainer = renderLayer as? ShapeContainerLayer {
                renderShapeContainer(childContainer, ctx: ctx)
            }
        }
    }

    // MARK: - Migration Audit

    /// Tracks non-migrated renderer types encountered during export.
    /// Reset at the start of each export, logged at the end.
    private var nonMigratedRendererCounts: [String: Int] = [:]

    /// Logs a non-migrated renderer type (called during render).
    private func logNonMigratedRenderer(_ type: String) {
        nonMigratedRendererCounts[type, default: 0] += 1
    }

    /// Resets the migration audit counters. Call at start of export.
    public func resetMigrationAudit() {
        nonMigratedRendererCounts.removeAll()
    }

    /// Logs migration audit results. Call at end of export.
    public func logMigrationAudit() {
        guard !nonMigratedRendererCounts.isEmpty else {
            print("✅ [LottieOffscreenRenderer] All renderers migrated to OffscreenRenderable")
            return
        }

        print("⚠️ [LottieOffscreenRenderer] Non-migrated renderers detected:")
        for (type, count) in nonMigratedRendererCounts.sorted(by: { $0.value > $1.value }) {
            print("   - \(type): \(count) occurrences")
        }
        print("   These renderers were SKIPPED and will cause incorrect export!")
    }

    // MARK: - Image Rendering

    /// Renders an ImageCompositionLayer with correct pixel-buffer orientation.
    ///
    /// ## Coordinate System Policy
    /// - Context is in UIKit coords (Y-down) from VideoGenerator
    /// - globalTransform places the "slot" in world space (already applied)
    /// - Inside the slot, we flip Y for pixel-buffer images (origin bottom-left)
    ///
    /// ## Alpha
    /// Alpha is already set in renderCompositionLayer via cg.setAlpha(layerState.alpha).
    /// Images don't have their own opacity property, so we just use the inherited alpha.
    ///
    private func renderImageLayer(_ layer: ImageCompositionLayer, ctx: RenderContext) {
        guard let image = layer.image else { return }

        let bounds = layer.contentsLayer.bounds
        drawPixelBufferImage(image, inSlot: bounds, ctx: ctx)
    }

    /// Draws a CGImage from pixel buffer into a slot with correct orientation.
    ///
    /// Pixel-buffer images (video frames, photos from CVPixelBuffer) have origin
    /// at bottom-left. This helper applies local Y-flip to draw correctly in
    /// UIKit coordinate context without copying pixels.
    ///
    /// - Note: Alpha is already set in CGContext from RenderState before this call.
    /// - Note: If mask/matte applies to slot content, clip should be inside this flip.
    ///
    private func drawPixelBufferImage(_ image: CGImage, inSlot bounds: CGRect, ctx: RenderContext) {
        ctx.cg.saveGState()
        defer { ctx.cg.restoreGState() }

        // Alpha is already set from RenderState in renderCompositionLayer
        // No need to set it again here

        // Apply local Y-flip for pixel-buffer images
        ctx.cg.translateBy(x: 0, y: bounds.height)
        ctx.cg.scaleBy(x: 1, y: -1)
        ctx.cg.draw(image, in: CGRect(origin: .zero, size: bounds.size))
    }

    // MARK: - Precomp Rendering

    /// Renders a PreCompositionLayer by recursively rendering its children.
    ///
    /// ## Alpha Inheritance
    /// Children receive the PreComp's accumulated alpha via RenderState.
    /// This is the key mechanism for hierarchical opacity to work correctly.
    ///
    /// Example: If PreComp has opacity=0.5 and child Image has opacity=1.0,
    /// the child will be rendered with alpha = 0.5 * 1.0 = 0.5
    ///
    private func renderPrecompLayer(_ layer: PreCompositionLayer, ctx: RenderContext) {
        // PreCompositionLayer has its own animationLayers
        // Pass current RenderState.state so children inherit accumulated alpha
        for childLayer in layer.animationLayers {
            renderCompositionLayer(childLayer, into: ctx.cg, state: ctx.state)
        }
    }

    // MARK: - Layer Collection

    /// Recursively collects all ImageCompositionLayer instances from the layer tree.
    /// Image layers may be nested inside PreCompositionLayer or other container layers.
    private static func collectImageLayers(from layer: CALayer, into result: inout [ImageCompositionLayer]) {
        if let imageLayer = layer as? ImageCompositionLayer {
            result.append(imageLayer)
        }

        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                collectImageLayers(from: sublayer, into: &result)
            }
        }
    }

    // MARK: - Metrics

    /// Average time per frame in milliseconds
    public var averageFrameTimeMs: Double {
        guard framesRendered > 0 else { return 0 }
        return (totalRenderTime / Double(framesRendered)) * 1000
    }

    /// Logs render statistics
    public func logMetrics() {
        print("🎬 [LottieOffscreenRenderer] Metrics:")
        print("   Frames rendered: \(framesRendered)")
        print("   Total time: \(String(format: "%.2f", totalRenderTime))s")
        print("   Avg frame time: \(String(format: "%.2f", averageFrameTimeMs))ms")
        contextPool.logStats()
    }

    /// Clears cached resources. Call after export completes.
    public func clearCaches() {
        contextPool.clear()
    }
}

// MARK: - Factory Method

extension LottieOffscreenRenderer {

    /// Creates an offscreen renderer from a LottieAnimationView.
    /// Useful for creating an export renderer from an existing preview view.
    ///
    /// - Parameters:
    ///   - animationView: The animation view (only uses its animation data, not layer tree)
    ///   - exportImageProvider: The image provider to use for export (should be different from preview)
    /// - Returns: A new offscreen renderer, or nil if animation is not available
    public static func forExport(
        from animationView: LottieAnimationView,
        imageProvider: AnimationImageProvider
    ) -> LottieOffscreenRenderer? {
        guard let animation = animationView.animation else {
            print("⚠️ [LottieOffscreenRenderer] Cannot create: animation is nil")
            return nil
        }
        return LottieOffscreenRenderer(animation: animation, imageProvider: imageProvider)
    }
}
