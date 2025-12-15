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

    /// All image layers extracted from the tree for fast access
    private var imageLayers: [ImageCompositionLayer] = []


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

        // Process layers: set up mattes, collect image layers
        var processedLayers: [CompositionLayer] = []
        var collectedImageLayers: [ImageCompositionLayer] = []
        var mattedLayer: CompositionLayer? = nil

        for layer in layers.reversed() {
            layer.bounds = CGRect(origin: .zero, size: canvasSize)

            // Recursively collect image layers (they may be nested in PreCompositionLayer)
            Self.collectImageLayers(from: layer, into: &collectedImageLayers)

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
        self.imageLayers = collectedImageLayers

        // Register image layers with provider
        layerImageProvider.addImageLayers(collectedImageLayers)

        // Initial image load
        layerImageProvider.reloadImages(seconds: nil)

        print("🎬 [LottieOffscreenRenderer] Created: size=\(canvasSize), fps=\(framerate), layers=\(animationLayers.count), imageLayers=\(imageLayers.count)")
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

        // CONTRACT: VideoGenerator provides context already flipped to UIKit coords (Y-down).
        // All rendering (shapes AND images) uses the same coordinate system - no per-element flips.

        // Render image layers directly to CGContext (no CALayer.render!)
        renderImageLayers(into: ctx)

        // Update metrics
        framesRendered += 1
        totalRenderTime += CACurrentMediaTime() - startTime
    }

    // MARK: - Private Rendering Methods

    /// Renders all image layers directly into the CGContext.
    /// This bypasses CALayer.render() completely for true offscreen rendering.
    ///
    /// CONTRACT: Context is already in UIKit coords (Y-down) from VideoGenerator.
    /// Both shapes and images use the same CTM - no per-element coordinate flips.
    ///
    /// IMAGE FLIP: CGImage pixel data has origin at bottom-left, but we're in UIKit coords.
    /// We use negative height rect with ACTUAL IMAGE SIZE (not CA layer bounds).
    /// This is fast (no pixel copying) and independent of CALayer internals.
    private func renderImageLayers(into ctx: CGContext) {
        for layer in imageLayers {
            guard !layer.contentsLayer.isHidden else { continue }
            guard let image = layer.image else { continue }

            ctx.saveGState()
            defer { ctx.restoreGState() }

            // Apply global transform (position, scale, rotation, anchor, parent chain)
            let transform = layer.transformNode.globalTransform.affineTransform
            ctx.concatenate(transform)

            // Hierarchical opacity
            ctx.setAlpha(ctx.alpha * CGFloat(layer.transformNode.opacity))

            // Draw image using ACTUAL IMAGE DIMENSIONS (not contentsLayer.bounds!)
            // contentsLayer.bounds is a CA detail that doesn't apply in offscreen context.
            // Using image.width/height gives correct local rect independent of CA mechanics.
            let w = CGFloat(image.width)
            let h = CGFloat(image.height)
            let flipRect = CGRect(x: 0, y: h, width: w, height: -h)
            ctx.draw(image, in: flipRect)

            // DEBUG: Log first few frames - compare bounds vs actual image size
            if framesRendered < 3 {
                let bounds = layer.contentsLayer.bounds
                print("🖼️ [Image] '\(layer.keypathName ?? "?")': bounds=\(bounds.size) vs image=\(w)x\(h), transform=\(transform)")
            }
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
