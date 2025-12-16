//
//  ContextPool.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//  Provides reusable CGContext buffers for mask and content rendering.
//
//  IMPORTANT: This class is NOT thread-safe. It must be used exclusively
//  on a single queue (typically the render queue during export).
//

import CoreGraphics

// MARK: - ContextPool

/// A pool of reusable CGContext buffers for offscreen rendering.
///
/// During mask rendering, we need temporary buffers for:
/// - RGBA content (layer content before masking)
/// - Grayscale mask (mask alpha channel)
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

    /// Type of context buffer
    public enum ContextType {
        case rgba       // 4 bytes per pixel, for content
        case grayscale  // 1 byte per pixel, for masks
    }

    /// A pooled context with metadata
    private struct PooledContext {
        let context: CGContext
        let width: Int
        let height: Int
        let type: ContextType
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
    /// - Parameters:
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    /// - Returns: A CGContext ready for drawing, or nil if creation failed
    public func getRGBA(width: Int, height: Int) -> CGContext? {
        getContext(width: width, height: height, type: .rgba)
    }

    /// Gets or creates a grayscale context of the specified size.
    ///
    /// - Parameters:
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    /// - Returns: A CGContext ready for drawing, or nil if creation failed
    public func getGrayscale(width: Int, height: Int) -> CGContext? {
        getContext(width: width, height: height, type: .grayscale)
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

    private func getContext(width: Int, height: Int, type: ContextType) -> CGContext? {
        // Try to find a reusable context of matching or larger size
        for i in pool.indices {
            let pooled = pool[i]
            if !pooled.inUse &&
               pooled.type == type &&
               pooled.width >= width &&
               pooled.height >= height {
                // Reuse this context
                pool[i].inUse = true
                totalReused += 1

                // Clear the context before reuse
                // IMPORTANT: Reset CTM to identity before clearing to ensure we clear
                // the entire backing store regardless of any leftover transforms
                let ctx = pooled.context
                ctx.saveGState()

                // Reset CTM to identity by applying inverse of current transform
                let currentCTM = ctx.ctm
                if !currentCTM.isIdentity {
                    let inverse = currentCTM.inverted()
                    ctx.concatenate(inverse)
                }

                // Clear using .copy blend mode to guarantee full overwrite
                ctx.setBlendMode(.copy)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0))
                ctx.fill(CGRect(x: 0, y: 0, width: pooled.width, height: pooled.height))

                ctx.restoreGState()

                // Reset to normal state for next user
                ctx.setBlendMode(.normal)
                ctx.setAlpha(1)

                return ctx
            }
        }

        // No suitable context found - create new one
        guard let context = createContext(width: width, height: height, type: type) else {
            return nil
        }

        totalCreated += 1

        // Add to pool if not full
        if pool.count < maxPoolSize {
            pool.append(PooledContext(
                context: context,
                width: width,
                height: height,
                type: type,
                inUse: true
            ))
            peakPoolSize = max(peakPoolSize, pool.count)
        }

        return context
    }

    private func createContext(width: Int, height: Int, type: ContextType) -> CGContext? {
        switch type {
        case .rgba:
            return createRGBAContext(width: width, height: height)
        case .grayscale:
            return createGrayscaleContext(width: width, height: height)
        }
    }

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

    private func createGrayscaleContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceGray()

        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }
}
