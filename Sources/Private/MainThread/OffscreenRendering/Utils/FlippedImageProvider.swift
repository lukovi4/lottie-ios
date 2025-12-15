//
//  FlippedImageProvider.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//
//  This provider wraps another AnimationImageProvider and flips images vertically.
//  Used for offscreen CGContext rendering where context is in UIKit coords (Y-down)
//  but CGImage stores pixels with origin at bottom-left.
//
//  Flipping at source (not per-draw) maintains a SINGLE coordinate system
//  for both shapes AND images, which is critical for masks/mattes compatibility.
//

import QuartzCore

// MARK: - FlippedImageProvider

/// An image provider wrapper that flips images vertically for UIKit-coords CGContext rendering.
///
/// ## Why This Exists
/// - CGImage stores pixels with origin at bottom-left (Y-up)
/// - VideoGenerator flips CGContext to UIKit coords (origin top-left, Y-down)
/// - When drawing CGImage with ctx.draw() in flipped context, image appears upside-down
///
/// ## The Solution
/// Flip images at source, not per-draw. This maintains ONE coordinate system for everything:
/// - Shapes render correctly (their paths are in UIKit coords)
/// - Images render correctly (pre-flipped to match UIKit coords)
/// - Masks/mattes work correctly (same coordinate system)
///
/// ## Usage
/// ```swift
/// let flippedProvider = FlippedImageProvider(wrapping: originalProvider)
/// let renderer = LottieOffscreenRenderer(animation: animation, imageProvider: flippedProvider)
/// ```
public final class FlippedImageProvider: AnimationImageProvider {

    // MARK: - Properties

    private let wrapped: AnimationImageProvider

    // Cache flipped images to avoid re-flipping every frame for static images
    private var cache: [String: CGImage] = [:]

    // MARK: - Initialization

    /// Creates a flipped image provider wrapping another provider.
    ///
    /// - Parameter provider: The original provider to wrap
    public init(wrapping provider: AnimationImageProvider) {
        self.wrapped = provider
    }

    // MARK: - AnimationImageProvider

    public var cacheEligible: Bool {
        // Don't use Lottie's internal cache since we have our own
        // (and the flipped image is different from the original)
        false
    }

    public func imageForAsset(asset: ImageAsset, seconds: CGFloat?) -> CGImage? {
        // Get original image from wrapped provider
        guard let original = wrapped.imageForAsset(asset: asset, seconds: seconds) else {
            return nil
        }

        // For video frames (seconds != nil), flip every frame (can't cache)
        if seconds != nil {
            return original.flippedVertically()
        }

        // For static images, use cache
        let key = asset.id
        if let cached = cache[key] {
            return cached
        }

        // Flip and cache
        if let flipped = original.flippedVertically() {
            cache[key] = flipped
            return flipped
        }

        return original
    }

    public func contentsGravity(for asset: ImageAsset) -> CALayerContentsGravity {
        wrapped.contentsGravity(for: asset)
    }

    // MARK: - Cache Management

    /// Clears the flipped image cache.
    /// Call this when animation changes or memory pressure occurs.
    public func clearCache() {
        cache.removeAll()
    }
}
