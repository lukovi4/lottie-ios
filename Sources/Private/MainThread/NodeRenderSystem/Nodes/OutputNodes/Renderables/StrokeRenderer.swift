//
//  StrokeRenderer.swift
//  lottie-swift
//
//  Created by Brandon Withrow on 1/30/19.
//

import QuartzCore

extension LineJoin {
  var cgLineJoin: CGLineJoin {
    switch self {
    case .bevel:
      .bevel
    case .none:
      .miter
    case .miter:
      .miter
    case .round:
      .round
    }
  }

  var caLineJoin: CAShapeLayerLineJoin {
    switch self {
    case .none:
      CAShapeLayerLineJoin.miter
    case .miter:
      CAShapeLayerLineJoin.miter
    case .round:
      CAShapeLayerLineJoin.round
    case .bevel:
      CAShapeLayerLineJoin.bevel
    }
  }
}

extension LineCap {
  var cgLineCap: CGLineCap {
    switch self {
    case .none:
      .butt
    case .butt:
      .butt
    case .round:
      .round
    case .square:
      .square
    }
  }

  var caLineCap: CAShapeLayerLineCap {
    switch self {
    case .none:
      CAShapeLayerLineCap.butt
    case .butt:
      CAShapeLayerLineCap.butt
    case .round:
      CAShapeLayerLineCap.round
    case .square:
      CAShapeLayerLineCap.square
    }
  }
}

// MARK: - StrokeRenderer

/// A rendered that renders a stroke on a path.
final class StrokeRenderer: PassThroughOutputNode, Renderable {

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

  var width: CGFloat = 0 {
    didSet {
      hasUpdate = true
    }
  }

  var miterLimit: CGFloat = 0 {
    didSet {
      hasUpdate = true
    }
  }

  var lineCap = LineCap.none {
    didSet {
      hasUpdate = true
    }
  }

  var lineJoin = LineJoin.none {
    didSet {
      hasUpdate = true
    }
  }

  var dashPhase: CGFloat? {
    didSet {
      hasUpdate = true
    }
  }

  var dashLengths: [CGFloat]? {
    didSet {
      hasUpdate = true
    }
  }

  func setupSublayers(layer _: CAShapeLayer) {
    // empty
  }

  func renderBoundsFor(_ boundingBox: CGRect) -> CGRect {
    boundingBox.insetBy(dx: -width, dy: -width)
  }

  func setupForStroke(_ inContext: CGContext) {
    inContext.setLineWidth(width)
    inContext.setMiterLimit(miterLimit)
    inContext.setLineCap(lineCap.cgLineCap)
    inContext.setLineJoin(lineJoin.cgLineJoin)
    if let dashPhase, let lengths = dashLengths {
      inContext.setLineDash(phase: dashPhase, lengths: lengths)
    } else {
      inContext.setLineDash(phase: 0, lengths: [])
    }
  }

  func render(_ ctx: CGContext) {
    guard let cgPath = outputPath else { return }
    guard let strokeColor = color else { return }
    if cgPath.boundingBoxOfPath.isNull { return }

    hasUpdate = false

    ctx.saveGState()
    defer { ctx.restoreGState() }

    ctx.addPath(cgPath)
    setupForStroke(ctx)

    ctx.setAlpha(ctx.alpha * opacity)
    ctx.setStrokeColor(strokeColor)
    ctx.strokePath()
  }

  func updateShapeLayer(layer: CAShapeLayer) {
    layer.strokeColor = color
    layer.opacity = Float(opacity)
    layer.lineWidth = width
    layer.lineJoin = lineJoin.caLineJoin
    layer.lineCap = lineCap.caLineCap
    layer.lineDashPhase = dashPhase ?? 0
    layer.fillColor = nil
    if let dashPattern = dashLengths {
      layer.lineDashPattern = dashPattern.map { NSNumber(value: Double($0)) }
    }
  }
}

// MARK: - OffscreenRenderable

extension StrokeRenderer: OffscreenRenderable {
  /// Renders stroke using explicit alpha from RenderContext.
  /// Uses ctx.state.alpha (layer-level) * self.opacity (paint-level).
  func renderOffscreen(_ ctx: RenderContext) {
    guard let cgPath = outputPath else { return }
    guard let strokeColor = color else { return }
    if cgPath.boundingBoxOfPath.isNull { return }

    hasUpdate = false

    ctx.cg.saveGState()
    defer { ctx.cg.restoreGState() }

    ctx.cg.addPath(cgPath)
    setupForStroke(ctx.cg)

    // Key difference: use ctx.state.alpha instead of ctx.cg.alpha
    ctx.cg.setAlpha(ctx.state.alpha * opacity)
    ctx.cg.setStrokeColor(strokeColor)
    ctx.cg.strokePath()
  }
}
