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

    public init(cg: CGContext, state: RenderState = .identity) {
        self.cg = cg
        self.state = state
    }

    /// Convenience: creates context with updated alpha
    public func withOpacity(_ opacity: CGFloat) -> RenderContext {
        RenderContext(cg: cg, state: state.withOpacity(opacity))
    }

    /// Applies current state to CGContext (call before drawing)
    public func applyState() {
        cg.setAlpha(state.alpha)
        // blendMode will be applied when needed for masks/mattes
    }
}
