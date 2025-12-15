//
//  FillRenderer.swift
//  lottie-swift
//
//  Created by Brandon Withrow on 1/30/19.
//

import QuartzCore

extension FillRule {
  var cgFillRule: CGPathFillRule {
    switch self {
    case .evenOdd:
      .evenOdd
    default:
      .winding
    }
  }

  var caFillRule: CAShapeLayerFillRule {
    switch self {
    case .evenOdd:
      CAShapeLayerFillRule.evenOdd
    default:
      CAShapeLayerFillRule.nonZero
    }
  }
}

// MARK: - FillRenderer

/// A rendered for a Path Fill
final class FillRenderer: PassThroughOutputNode, Renderable {
  var shouldRenderInContext = false

  var color: CGColor? {
    didSet {
      hasUpdate = true
    }
  }

  var opacity: CGFloat = 0 {
    didSet {
      hasUpdate = true
    }
  }

  var fillRule = FillRule.none {
    didSet {
      hasUpdate = true
    }
  }

  func render(_ ctx: CGContext) {
    guard let cgPath = outputPath else { return }
    guard let fillColor = color else { return }
    if cgPath.boundingBoxOfPath.isNull { return }

    hasUpdate = false

    ctx.saveGState()
    ctx.addPath(cgPath)
    ctx.setFillColor(fillColor)
    ctx.setAlpha(ctx.alpha * opacity)
    ctx.fillPath(using: fillRule.cgFillRule)
    ctx.restoreGState()
  }

  func setupSublayers(layer _: CAShapeLayer) {
    // do nothing
  }

  func updateShapeLayer(layer: CAShapeLayer) {
    layer.fillColor = color
    layer.opacity = Float(opacity)
    layer.fillRule = fillRule.caFillRule
    hasUpdate = false
  }

}

// MARK: - OffscreenRenderable

extension FillRenderer: OffscreenRenderable {
  /// Renders fill using explicit alpha from RenderContext.
  /// Uses ctx.state.alpha (layer-level) * self.opacity (paint-level).
  func renderOffscreen(_ ctx: RenderContext) {
    guard let cgPath = outputPath else { return }
    guard let fillColor = color else { return }
    if cgPath.boundingBoxOfPath.isNull { return }

    hasUpdate = false

    ctx.cg.saveGState()
    defer { ctx.cg.restoreGState() }

    ctx.cg.addPath(cgPath)
    ctx.cg.setFillColor(fillColor)
    // Key difference: use ctx.state.alpha instead of ctx.cg.alpha
    ctx.cg.setAlpha(ctx.state.alpha * opacity)
    ctx.cg.fillPath(using: fillRule.cgFillRule)
  }
}
