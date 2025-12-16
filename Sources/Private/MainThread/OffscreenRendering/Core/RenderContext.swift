//
//  RenderContext.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//  Provides explicit state management for hierarchical opacity and blend modes.
//
//  IMPORTANT: This replaces reliance on CGContext.alpha getter which doesn't
//  work correctly with bitmap contexts. All alpha calculations go through
//  RenderState, never read from CGContext.
//

import CoreGraphics

// MARK: - RenderState

/// Accumulated render state passed through the layer hierarchy.
///
/// ## Design Principles
/// 1. `alpha` is "layer-level accumulated alpha" - product of all transformNode.opacity in chain
/// 2. "Paint-level" opacity (fill/stroke/gradient) is multiplied inside renderers on top of this
/// 3. We NEVER read from CGContext - this is our single source of truth
///
/// ## Usage
/// ```swift
/// // In traversal:
/// let childState = RenderState(
///     alpha: parentState.alpha * CGFloat(layer.transformNode.opacity),
///     blendMode: parentState.blendMode
/// )
/// ```
public struct RenderState {

    /// Accumulated alpha from all parent layers (0.0 - 1.0)
    public var alpha: CGFloat

    /// Current blend mode
    public var blendMode: CGBlendMode

    /// Default state (fully opaque, normal blend)
    public static let identity = RenderState(alpha: 1.0, blendMode: .normal)

    public init(alpha: CGFloat = 1.0, blendMode: CGBlendMode = .normal) {
        self.alpha = alpha
        self.blendMode = blendMode
    }

    /// Creates a new state with alpha multiplied by layer opacity
    public func withOpacity(_ opacity: CGFloat) -> RenderState {
        RenderState(alpha: alpha * opacity, blendMode: blendMode)
    }
}

// MARK: - RenderContext

/// Context passed to renderers containing both CGContext and accumulated state.
///
/// ## Design Principles
/// 1. `cg` is the actual CGContext for drawing operations
/// 2. `state` contains our tracked alpha/blend (source of truth)
/// 3. Renderers use `state.alpha * self.opacity` for final alpha
///
/// ## Usage in Renderers
/// ```swift
/// func render(_ ctx: RenderContext) {
///     ctx.cg.saveGState()
///     defer { ctx.cg.restoreGState() }
///
///     ctx.cg.setAlpha(ctx.state.alpha * self.opacity)
///     // ... draw operations
/// }
/// ```
public struct RenderContext {

    /// The CGContext for drawing operations
    public let cg: CGContext

    /// Accumulated render state (alpha, blend mode)
    public let state: RenderState

    /// Current animation frame (for ip/op gating in nested layers)
    public let frame: CGFloat

    public init(cg: CGContext, state: RenderState = .identity, frame: CGFloat = 0) {
        self.cg = cg
        self.state = state
        self.frame = frame
    }

    /// Convenience: creates context with updated alpha
    public func withOpacity(_ opacity: CGFloat) -> RenderContext {
        RenderContext(cg: cg, state: state.withOpacity(opacity), frame: frame)
    }

    /// Applies current state to CGContext (call before drawing)
    public func applyState() {
        cg.setAlpha(state.alpha)
        // blendMode will be applied when needed for masks/mattes
    }
}

// MARK: - OffscreenRenderable

/// Protocol for renderers that support offscreen (export) rendering with explicit alpha management.
///
/// ## Why a Separate Protocol?
/// The existing `Renderable.render(_ ctx: CGContext)` method relies on `ctx.alpha` getter
/// which doesn't work correctly with bitmap contexts. This protocol provides an alternative
/// entry point that receives `RenderContext` with explicit alpha tracking.
///
/// ## Implementation Pattern
/// ```swift
/// extension FillRenderer: OffscreenRenderable {
///     func renderOffscreen(_ ctx: RenderContext) {
///         guard let path = outputPath, let color = color else { return }
///
///         ctx.cg.saveGState()
///         defer { ctx.cg.restoreGState() }
///
///         ctx.cg.addPath(path)
///         ctx.cg.setFillColor(color)
///         // Use ctx.state.alpha (layer-level) * self.opacity (paint-level)
///         ctx.cg.setAlpha(ctx.state.alpha * opacity)
///         ctx.cg.fillPath(using: fillRule.cgFillRule)
///     }
/// }
/// ```
///
/// ## Key Difference from render(_ ctx: CGContext)
/// - `render()` may call `ctx.alpha` which returns incorrect value (always 1.0)
/// - `renderOffscreen()` uses `ctx.state.alpha` which is our tracked source of truth
///
public protocol OffscreenRenderable {
    /// Renders content using explicit alpha from RenderContext.
    /// - Parameter ctx: The render context with tracked alpha state
    func renderOffscreen(_ ctx: RenderContext)
}
