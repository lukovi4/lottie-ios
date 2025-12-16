//
//  ContextPool.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//  Provides reusable CGContext buffers for RGBA content rendering.
//
//  IMPORTANT: This class is NOT thread-safe. It must be used exclusively
//  on a single queue (typically the render queue during export).
//

import CoreGraphics

// MARK: - CGAffineTransform Extension

private extension CGAffineTransform {
    /// Safely inverts the transform, returning nil if not invertible.
    var invertedIfPossible: CGAffineTransform? {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return nil }
        return inverted()
    }
}

// MARK: - ContextPool

/// A pool of reusable CGContext buffers for offscreen rendering.
///
/// Used for RGBA content buffers during mask rendering.
/// MaskComposer manages its own grayscale buffers separately.
///
/// Creating CGContexts is expensive (~5-20ms each). This pool reuses buffers
/// to avoid allocation overhead during export.
///
/// ## Usage
/// ```swift
/// let pool = ContextPool()
///
/// // Get a context (creates or reuses)
/// let ctx = pool.getRGBA(width: 280, height: 280)
///
/// // ... render into ctx ...
/// let image = ctx.makeImage()
///
/// // Return to pool for reuse
/// pool.release(ctx)
/// ```
///
/// ## Thread Safety
/// This class is NOT thread-safe. Use only from a single queue.
///
public final class ContextPool {

    // MARK: - Types

    /// A pooled context with metadata
    private struct PooledContext {
        let context: CGContext
        let width: Int
        let height: Int
        var inUse: Bool
    }

    // MARK: - Properties

    /// Pool of available contexts
    private var pool: [PooledContext] = []

    /// Maximum number of contexts to keep in pool
    private let maxPoolSize: Int

    /// Statistics for debugging
    public private(set) var totalCreated: Int = 0
    public private(set) var totalReused: Int = 0
    public private(set) var peakPoolSize: Int = 0

    // MARK: - Initialization

    /// Creates a new context pool.
    /// - Parameter maxPoolSize: Maximum contexts to keep cached (default: 8)
    public init(maxPoolSize: Int = 8) {
        self.maxPoolSize = maxPoolSize
    }

    // MARK: - Public API

    /// Gets or creates an RGBA context of the specified size.
    ///
    /// The context is cleared to fully transparent before returning.
    ///
    /// - Parameters:
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    /// - Returns: A CGContext ready for drawing, or nil if creation failed
    public func getRGBA(width: Int, height: Int) -> CGContext? {
        // Try to find a reusable context of matching or larger size
        for i in pool.indices {
            let pooled = pool[i]
            if !pooled.inUse &&
               pooled.width >= width &&
               pooled.height >= height {
                // Reuse this context
                pool[i].inUse = true
                totalReused += 1

                // Clear the context before reuse
                Self.clearRGBA(pooled.context, width: pooled.width, height: pooled.height)
                return pooled.context
            }
        }

        // No suitable context found - create new one
        guard let context = createRGBAContext(width: width, height: height) else {
            return nil
        }

        totalCreated += 1

        // Add to pool if not full
        if pool.count < maxPoolSize {
            pool.append(PooledContext(
                context: context,
                width: width,
                height: height,
                inUse: true
            ))
            peakPoolSize = max(peakPoolSize, pool.count)
        }

        return context
    }

    /// Returns a context to the pool for reuse.
    ///
    /// - Parameter context: The context to release
    public func release(_ context: CGContext) {
        // Find and mark as not in use
        for i in pool.indices {
            if pool[i].context === context {
                pool[i].inUse = false
                return
            }
        }
        // Context not from this pool - ignore
    }

    /// Clears all contexts from the pool.
    /// Call this when export is complete to free memory.
    public func clear() {
        pool.removeAll()
    }

    /// Logs pool statistics.
    public func logStats() {
        print("📦 [ContextPool] Stats:")
        print("   Created: \(totalCreated)")
        print("   Reused: \(totalReused)")
        print("   Peak pool size: \(peakPoolSize)")
        print("   Current pool size: \(pool.count)")
        let reuseRate = totalCreated > 0 ? Double(totalReused) / Double(totalCreated + totalReused) * 100 : 0
        print("   Reuse rate: \(String(format: "%.1f", reuseRate))%")
    }

    // MARK: - Private

    /// Clears an RGBA context to fully transparent.
    private static func clearRGBA(_ ctx: CGContext, width: Int, height: Int) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.resetClip()
        let ctm = ctx.ctm
        if !ctm.isIdentity, let inv = ctm.invertedIfPossible {
            ctx.concatenate(inv)
        }

        ctx.setBlendMode(.copy)
        // Transparent (alpha=0) — critical for RGBA content compositing
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Creates an RGBA context for content rendering.
    private func createRGBAContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)

        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
    }
}
