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
        for layer in animationLayers {
            renderCompositionLayer(layer, into: ctx)
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
    private func renderCompositionLayer(_ layer: CompositionLayer, into ctx: CGContext) {
        guard !layer.isHidden else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 1. Apply global transform (position, scale, rotation, anchor, parent chain)
        let transform = layer.transformNode.globalTransform.affineTransform
        ctx.concatenate(transform)

        // 2. Hierarchical opacity (MULTIPLY, not replace!)
        ctx.setAlpha(ctx.alpha * CGFloat(layer.transformNode.opacity))

        // 3. TODO: masks/mattes will be applied here later

        // 4. Render based on layer type
        if let shapeLayer = layer as? ShapeCompositionLayer {
            renderShapeLayer(shapeLayer, into: ctx)
        } else if let imageLayer = layer as? ImageCompositionLayer {
            renderImageLayer(imageLayer, into: ctx)
        } else if let precompLayer = layer as? PreCompositionLayer {
            renderPrecompLayer(precompLayer, into: ctx)
        }
        // Other layer types (Text, Solid, etc.) can be added later

        // DEBUG: Log first few frames
        if framesRendered < 3 {
            let typeName = String(describing: type(of: layer)).replacingOccurrences(of: "CompositionLayer", with: "")
            print("🎬 [Layer] '\(layer.keypathName ?? "?")' (\(typeName))")
        }
    }

    // MARK: - Shape Rendering

    /// Renders a ShapeCompositionLayer by traversing its renderContainer.
    private func renderShapeLayer(_ layer: ShapeCompositionLayer, into ctx: CGContext) {
        guard let container = layer.renderContainer else { return }
        renderShapeContainer(container, into: ctx)
    }

    /// Recursively renders a ShapeContainerLayer and its children.
    /// Each ShapeRenderLayer.draw(in:) adds path and calls renderer.render(ctx).
    private func renderShapeContainer(_ container: ShapeContainerLayer, into ctx: CGContext) {
        // Render in correct order (renderLayers are in Lottie's layer order)
        for renderLayer in container.renderLayers {
            guard !renderLayer.isHidden else { continue }

            ctx.saveGState()

            // Apply layer's own transform if any
            if !renderLayer.affineTransform().isIdentity {
                ctx.concatenate(renderLayer.affineTransform())
            }

            // ShapeRenderLayer.draw(in:) adds outputPath and calls renderer.render(ctx)
            if let shapeRenderLayer = renderLayer as? ShapeRenderLayer {
                shapeRenderLayer.draw(in: ctx)
            }

            ctx.restoreGState()

            // Recurse into nested containers
            renderShapeContainer(renderLayer, into: ctx)
        }
    }

    // MARK: - Image Rendering

    /// Renders an ImageCompositionLayer with correct pixel-buffer orientation.
    ///
    /// ## Coordinate System Policy
    /// - Context is in UIKit coords (Y-down) from VideoGenerator
    /// - globalTransform places the "slot" in world space (already applied)
    /// - Inside the slot, we flip Y for pixel-buffer images (origin bottom-left)
    ///
    private func renderImageLayer(_ layer: ImageCompositionLayer, into ctx: CGContext) {
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
    /// - Note: If mask/matte applies to slot content, clip should be inside this flip.
    ///
    private func drawPixelBufferImage(_ image: CGImage, inSlot bounds: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
    }

    // MARK: - Precomp Rendering

    /// Renders a PreCompositionLayer by recursively rendering its children.
    private func renderPrecompLayer(_ layer: PreCompositionLayer, into ctx: CGContext) {
        // PreCompositionLayer has its own animationLayers
        for childLayer in layer.animationLayers {
            renderCompositionLayer(childLayer, into: ctx)
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
