//
//  GradientStrokeRenderer.swift
//  lottie-swift
//
//  Created by Brandon Withrow on 1/30/19.
//

import QuartzCore

// MARK: - Renderer

final class GradientStrokeRenderer: PassThroughOutputNode, Renderable {

  // MARK: Lifecycle

  override init(parent: NodeOutput?) {
    strokeRender = StrokeRenderer(parent: nil)
    gradientRender = LegacyGradientFillRenderer(parent: nil)
    strokeRender.color = .rgb(1, 1, 1)
    super.init(parent: parent)
  }

  // MARK: Internal

  var shouldRenderInContext = true

  let strokeRender: StrokeRenderer
  let gradientRender: LegacyGradientFillRenderer

  override func hasOutputUpdates(_ forFrame: CGFloat) -> Bool {
    let updates = super.hasOutputUpdates(forFrame)
    return updates || strokeRender.hasUpdate || gradientRender.hasUpdate
  }

  func updateShapeLayer(layer _: CAShapeLayer) {
    /// Not Applicable
  }

  func setupSublayers(layer _: CAShapeLayer) {
    /// Not Applicable
  }

  func render(_ ctx: CGContext) {
    guard let cgPath = outputPath else { return }
    if cgPath.boundingBoxOfPath.isNull { return }

    strokeRender.hasUpdate = false
    hasUpdate = false
    gradientRender.hasUpdate = false

    ctx.saveGState()
    defer { ctx.restoreGState() }

    ctx.addPath(cgPath)
    strokeRender.setupForStroke(ctx)
    ctx.replacePathWithStrokedPath()

    /// Now draw the gradient.
    gradientRender.render(ctx)
  }

  func renderBoundsFor(_ boundingBox: CGRect) -> CGRect {
    strokeRender.renderBoundsFor(boundingBox)
  }

}
