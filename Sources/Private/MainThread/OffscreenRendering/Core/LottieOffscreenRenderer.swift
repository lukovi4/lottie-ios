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
            renderCompositionLayer(layer, frame: frame, into: ctx, state: initialState)
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
    private func renderCompositionLayer(
        _ layer: CompositionLayer,
        frame: CGFloat,
        into cg: CGContext,
        state: RenderState
    ) {
        // 0) IP/OP gating — don't render layers outside their visibility range
        let ip = layer.inFrame
        let op = layer.outFrame
        if op > ip {
            let eps: CGFloat = 0.0001
            if frame + eps < ip || frame >= op - eps { return }
        } else {
            // Broken timing data, skip layer
            return
        }

        // 1) Runtime hidden check
        guard !layer.contentsLayer.isHidden else { return }

        cg.saveGState()
        defer { cg.restoreGState() }

        // 2. Apply global transform (position, scale, rotation, anchor, parent chain)
        let transform = layer.transformNode.globalTransform.affineTransform
        cg.concatenate(transform)

        // 2. Calculate layer alpha from RenderState (our source of truth)
        // NEVER read from cg.alpha - it doesn't work with bitmap contexts!
        let layerOpacity = CGFloat(layer.transformNode.opacity)
        let layerState = state.withOpacity(layerOpacity)

        // 3. Set alpha ABSOLUTE from our tracked state
        cg.setAlpha(layerState.alpha)

        // 4. Create RenderContext for this layer
        let renderCtx = RenderContext(cg: cg, state: layerState, frame: frame)

        // 5. Check for masks - if present, use alpha-mask rendering
        if let maskContainer = layer.maskLayer {
            let masks = maskContainer.maskSnapshots()
            #if DEBUG
            if !masks.isEmpty {
                print("🎭 [Mask] layer='\(layer.keypathName ?? "?")' masks=\(masks.count) modes=\(masks.map { "\($0.mode)" })")
            } else {
                print("⚠️ [Mask] layer='\(layer.keypathName ?? "?")' has maskContainer but masks.isEmpty!")
            }
            #endif
            if !masks.isEmpty {
                renderLayerWithMask(layer, masks: masks, frame: frame, into: cg, state: layerState)
                return
            }
        }

        // 6. Render based on layer type (no mask)
        #if DEBUG
        if layer.keypathName.contains("Media") {
            print("🔴 [NO MASK] rendering '\(layer.keypathName)' WITHOUT mask!")
        }
        #endif
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

    // MARK: - Bounds Calculation

    /// Computes the actual content bounds for a layer in its LOCAL coordinate space.
    ///
    /// This is critical for correct mask cropping. Using `contentsLayer.bounds` directly
    /// can be incorrect because:
    /// - Shape layers: real bounds = union of outputPath.boundingBoxOfPath
    /// - Precomp: bounds = union of children (with their transforms)
    /// - Image: slot bounds (usually matches contentsLayer.bounds)
    ///
    /// Called during render (after displayWithFrame), not at init time.
    ///
    private func computeLayerLocalContentBounds(_ layer: CompositionLayer) -> CGRect {
        if let imageLayer = layer as? ImageCompositionLayer {
            return computeImageLocalBounds(imageLayer)
        }
        if let shapeLayer = layer as? ShapeCompositionLayer {
            return computeShapeLocalBounds(shapeLayer)
        }
        if let precompLayer = layer as? PreCompositionLayer {
            return computePrecompLocalBounds(precompLayer)
        }

        // Fallback for other layer types
        let b = layer.contentsLayer.bounds
        return b.isEmpty ? layer.bounds : b
    }

    /// Image layer bounds = slot bounds (not actual image size).
    /// Transforms are calculated relative to slot, not image dimensions.
    private func computeImageLocalBounds(_ layer: ImageCompositionLayer) -> CGRect {
        let b = layer.contentsLayer.bounds
        if !b.isEmpty { return b }
        return layer.bounds
    }

    /// Shape layer bounds = union of all outputPath.boundingBoxOfPath with transforms applied.
    /// This gives the actual rendered area, matching how shapes are drawn in renderShapeContainer.
    private func computeShapeLocalBounds(_ layer: ShapeCompositionLayer) -> CGRect {
        var unionBounds = CGRect.null
        accumulateShapeBounds(layer.renderContainer, into: &unionBounds)

        // If we got valid bounds, use them; otherwise fall back to contentsLayer
        if !unionBounds.isNull && !unionBounds.isEmpty {
            return unionBounds
        }
        let b = layer.contentsLayer.bounds
        return b.isEmpty ? layer.bounds : b
    }

    // MARK: - Shape Bounds (transform-aware)

    /// Entry point for shape bounds accumulation.
    /// Starts with identity transform and recursively accumulates all shape bounds.
    private func accumulateShapeBounds(_ container: ShapeContainerLayer?, into rect: inout CGRect) {
        guard let container else { return }
        accumulateShapeBounds(container, parentTransform: .identity, into: &rect)
    }

    /// Recursively accumulates bounds from all shape renderers in the container,
    /// applying transforms as we go (matching renderShapeContainer traversal).
    ///
    /// This is critical for correct bounds calculation because:
    /// - renderShapeContainer applies renderLayer.affineTransform() before drawing
    /// - Without this, bounds would be in local renderer coords, not layer coords
    /// - Result: cropRect too small/offset → clipped or misaligned masks
    ///
    private func accumulateShapeBounds(
        _ container: ShapeContainerLayer,
        parentTransform: CGAffineTransform,
        into rect: inout CGRect
    ) {
        for renderLayer in container.renderLayers {
            // This must match rendering traversal:
            // you concatenate renderLayer.affineTransform() before drawing.
            let currentTransform = parentTransform.concatenating(renderLayer.affineTransform())

            if let shapeRenderLayer = renderLayer as? ShapeRenderLayer,
               let path = shapeRenderLayer.renderer.outputPath {
                let pathBounds = path.boundingBoxOfPath
                if !pathBounds.isNull && !pathBounds.isEmpty {
                    // Apply accumulated transform to bounds (same as rendering CTM).
                    let transformedBounds = pathBounds.applying(currentTransform)
                    if !transformedBounds.isNull && !transformedBounds.isEmpty {
                        rect = rect.isNull ? transformedBounds : rect.union(transformedBounds)
                    }
                }
            }

            // Recurse into nested containers with accumulated transform
            if let childContainer = renderLayer as? ShapeContainerLayer {
                accumulateShapeBounds(childContainer, parentTransform: currentTransform, into: &rect)
            }
        }
    }

    /// Precomp bounds = slot bounds (conservative).
    /// Computing union of children with transforms is complex; for now use slot bounds.
    /// This is safe because precomps are typically not huge, and the main perf concern
    /// is masks on image/shape layers which we handle correctly.
    private func computePrecompLocalBounds(_ layer: PreCompositionLayer) -> CGRect {
        let b = layer.contentsLayer.bounds
        return b.isEmpty ? layer.bounds : b
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
        frame: CGFloat,
        into cg: CGContext,
        state: RenderState
    ) {
        // 1. Calculate crop bounds in layer's LOCAL space (content ∩ masks)
        let contentBounds = computeLayerLocalContentBounds(layer)
        let maskBounds = calculateMaskBounds(masks)
        var cropRect = contentBounds.intersection(maskBounds)

        // Guard against empty or invalid rect
        if cropRect.isNull || cropRect.isEmpty || cropRect.width < 1 || cropRect.height < 1 {
            // Mask doesn't intersect content - nothing to render
            #if DEBUG
            print("   ⚠️ SKIP render - cropRect invalid for '\(layer.keypathName ?? "?")'")
            print("      contentBounds: \(contentBounds)")
            print("      maskBounds: \(maskBounds)")
            #endif
            return
        }

        // Add padding for anti-aliasing and make pixel-aligned
        cropRect = cropRect.insetBy(dx: -2, dy: -2).integral

        let width = Int(cropRect.width)
        let height = Int(cropRect.height)

        #if DEBUG
        print("   final cropRect: \(cropRect) (\(width)x\(height))")
        #endif

        // 2. Get buffers from pool
        guard let contentCtx = contextPool.getRGBA(width: width, height: height),
              let maskCtx = contextPool.getGrayscale(width: width, height: height) else {
            // Fallback: render without mask if we can't get buffers
            print("⚠️ [LottieOffscreenRenderer] Failed to get context buffers for mask, rendering without mask")
            let renderCtx = RenderContext(cg: cg, state: state, frame: frame)
            renderLayerContent(layer, ctx: renderCtx)
            return
        }

        defer {
            contextPool.release(contentCtx)
            contextPool.release(maskCtx)
        }

        // 3. Render layer content into RGBA buffer
        // IMPORTANT: Wrap translateBy in saveGState/restoreGState to not pollute pooled context
        contentCtx.saveGState()
        contentCtx.translateBy(x: -cropRect.origin.x, y: -cropRect.origin.y)
        let offscreenState = RenderState(alpha: 1.0)
        let contentRenderCtx = RenderContext(cg: contentCtx, state: offscreenState, frame: frame)
        renderLayerContent(layer, ctx: contentRenderCtx)
        contentCtx.restoreGState()

        // 4. Render masks into grayscale buffer
        // IMPORTANT: Wrap translateBy in saveGState/restoreGState to not pollute pooled context
        maskCtx.saveGState()
        maskCtx.translateBy(x: -cropRect.origin.x, y: -cropRect.origin.y)
        renderMasksToGrayscale(masks, into: maskCtx, bufferSize: CGSize(width: width, height: height))
        maskCtx.restoreGState()

        // 5. Get images from buffers and crop to requested size
        // IMPORTANT: Pooled context may be larger than requested (width×height).
        // makeImage() returns full pooled size, so we must crop to the actual
        // rendered area to avoid mask/content being scaled incorrectly.
        let cropRegion = CGRect(x: 0, y: 0, width: width, height: height)

        guard let fullContent = contentCtx.makeImage(),
              let fullMask = maskCtx.makeImage(),
              let contentImage = fullContent.cropping(to: cropRegion),
              let maskImage = fullMask.cropping(to: cropRegion) else {
            print("⚠️ [LottieOffscreenRenderer] Failed to create/crop images from mask buffers")
            return
        }

        // 6. Composite onto main context
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
    /// Uses boundingBoxOfPath (actual curve bbox) instead of boundingBox (control points bbox)
    /// for more accurate cropping.
    private func calculateMaskBounds(_ masks: [MaskSnapshot]) -> CGRect {
        var bounds = CGRect.null
        for mask in masks {
            let pathBounds = mask.path.boundingBoxOfPath
            if !pathBounds.isNull && !pathBounds.isEmpty {
                bounds = bounds.isNull ? pathBounds : bounds.union(pathBounds)
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
    /// - Parameters:
    ///   - masks: Array of MaskSnapshot with resolved paths
    ///   - ctx: Grayscale CGContext to render into
    ///   - bufferSize: Size of the buffer (for initial black fill)
    ///
    private func renderMasksToGrayscale(_ masks: [MaskSnapshot], into ctx: CGContext, bufferSize: CGSize) {
        // Start with black (fully masked) - fill only the buffer area
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: bufferSize))

        // Render each mask
        // IMPORTANT: Grayscale context has no alpha channel (CGImageAlphaInfo.none),
        // so we encode opacity directly into the gray value (0=masked, 1=visible).
        // clip(to:mask:) uses pixel brightness as alpha.
        for mask in masks {
            #if DEBUG
            print("   🎨 mask.opacity=\(mask.opacity) mode=\(mask.mode)")
            #endif
            switch mask.mode {
            case .add:
                // Add mode: gray = opacity (0% opacity → black, 100% → white)
                ctx.setFillColor(gray: mask.opacity, alpha: 1)
                ctx.addPath(mask.path)
                ctx.fillPath(using: .evenOdd)

            case .subtract:
                // Subtract: path already contains veryLargeRect with evenOdd
                // Fill with black to subtract (inverse of opacity)
                ctx.setFillColor(gray: 1.0 - mask.opacity, alpha: 1)
                ctx.addPath(mask.path)
                ctx.fillPath(using: .evenOdd)

            case .intersect:
                // Intersect: more complex, would need separate buffer
                // For now, treat as add (covers most cases in MinCircles)
                #if DEBUG
                print("⚠️ [LottieOffscreenRenderer] Intersect mask mode not fully implemented, treating as Add")
                #endif
                ctx.setFillColor(gray: mask.opacity, alpha: 1)
                ctx.addPath(mask.path)
                ctx.fillPath(using: .evenOdd)

            default:
                // Other modes (lighten, darken, difference, none) - skip
                #if DEBUG
                print("⚠️ [LottieOffscreenRenderer] Unsupported mask mode: \(mask.mode)")
                #endif
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
        // Pass frame for ip/op gating on nested layers
        for childLayer in layer.animationLayers {
            renderCompositionLayer(childLayer, frame: ctx.frame, into: ctx.cg, state: ctx.state)
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
