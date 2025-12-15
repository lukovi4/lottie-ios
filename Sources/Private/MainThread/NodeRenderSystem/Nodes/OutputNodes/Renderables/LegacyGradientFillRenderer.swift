//
//  LegacyGradientFillRenderer.swift
//  lottie-swift
//
//  Created by Brandon Withrow on 1/30/19.
//

import QuartzCore

/// A rendered for a Path Fill
final class LegacyGradientFillRenderer: PassThroughOutputNode, Renderable {

  var shouldRenderInContext = true

  var start = CGPoint.zero {
    didSet {
      hasUpdate = true
    }
  }

  var numberOfColors = 0 {
    didSet {
      hasUpdate = true
    }
  }

  var colors: [CGFloat] = [] {
    didSet {
      hasUpdate = true
    }
  }

  var end = CGPoint.zero {
    didSet {
      hasUpdate = true
    }
  }

  var opacity: CGFloat = 0 {
    didSet {
      hasUpdate = true
    }
  }

  var type = GradientType.none {
    didSet {
      hasUpdate = true
    }
  }

  func updateShapeLayer(layer _: CAShapeLayer) {
    // Not applicable
  }

  func setupSublayers(layer _: CAShapeLayer) {
    // Not applicable
  }

  func render(_ inContext: CGContext) {
    guard inContext.path != nil, inContext.path!.isEmpty == false else {
      return
    }
    hasUpdate = false
    var alphaColors = [CGColor]()
    var alphaLocations = [CGFloat]()

    var gradientColors = [CGColor]()
    var colorLocations = [CGFloat]()
    let maskColorSpace = CGColorSpaceCreateDeviceGray()
    for i in 0..<numberOfColors {
      let ix = i * 4
      if colors.count > ix {
        let color = CGColor.rgb(colors[ix + 1], colors[ix + 2], colors[ix + 3])
        gradientColors.append(color)
        colorLocations.append(colors[ix])
      }
    }

    var drawMask = false
    for i in stride(from: numberOfColors * 4, to: colors.endIndex, by: 2) {
      let alpha = colors[i + 1]
      if alpha < 1 {
        drawMask = true
      }
      alphaLocations.append(colors[i])
      alphaColors.append(.gray(alpha))
    }

    inContext.setAlpha(inContext.alpha * opacity)
    inContext.clip()

    /// First draw a mask is necessary.
    if drawMask {
      guard
        let maskGradient = CGGradient(
          colorsSpace: maskColorSpace,
          colors: alphaColors as CFArray,
          locations: alphaLocations),
        let maskContext = CGContext(
          data: nil,
          width: inContext.width,
          height: inContext.height,
          bitsPerComponent: 8,
          bytesPerRow: inContext.width,
          space: maskColorSpace,
          bitmapInfo: 0)
      else { return }
      let flipVertical = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(maskContext.height))
      maskContext.concatenate(flipVertical)
      maskContext.concatenate(inContext.ctm)
      if type == .linear {
        maskContext.drawLinearGradient(
          maskGradient,
          start: start,
          end: end,
          options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
      } else {
        maskContext.drawRadialGradient(
          maskGradient,
          startCenter: start,
          startRadius: 0,
          endCenter: start,
          endRadius: start.distanceTo(end),
          options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
      }
      /// Clips the gradient
      if let alphaMask = maskContext.makeImage() {
        inContext.clip(to: inContext.boundingBoxOfClipPath, mask: alphaMask)
      }
    }

    /// Now draw the gradient
    guard
      let gradient = CGGradient(
        colorsSpace: LottieConfiguration.shared.colorSpace,
        colors: gradientColors as CFArray,
        locations: colorLocations)
    else { return }

    if type == .linear {
      inContext.drawLinearGradient(gradient, start: start, end: end, options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    } else {
      inContext.drawRadialGradient(
        gradient,
        startCenter: start,
        startRadius: 0,
        endCenter: start,
        endRadius: start.distanceTo(end),
        options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    }
  }
}

// MARK: - OffscreenRenderable

extension LegacyGradientFillRenderer: OffscreenRenderable {
  /// Renders legacy gradient fill using explicit alpha from RenderContext.
  /// Uses ctx.state.alpha (layer-level) * self.opacity (paint-level).
  ///
  /// NOTE: This renderer expects path to be already added to context before calling.
  func renderOffscreen(_ ctx: RenderContext) {
    guard ctx.cg.path != nil, ctx.cg.path!.isEmpty == false else {
      return
    }
    hasUpdate = false
    var alphaColors = [CGColor]()
    var alphaLocations = [CGFloat]()

    var gradientColors = [CGColor]()
    var colorLocations = [CGFloat]()
    let maskColorSpace = CGColorSpaceCreateDeviceGray()
    for i in 0..<numberOfColors {
      let ix = i * 4
      if colors.count > ix {
        let color = CGColor.rgb(colors[ix + 1], colors[ix + 2], colors[ix + 3])
        gradientColors.append(color)
        colorLocations.append(colors[ix])
      }
    }

    var drawMask = false
    for i in stride(from: numberOfColors * 4, to: colors.endIndex, by: 2) {
      let alpha = colors[i + 1]
      if alpha < 1 {
        drawMask = true
      }
      alphaLocations.append(colors[i])
      alphaColors.append(.gray(alpha))
    }

    // Key difference: use ctx.state.alpha instead of ctx.cg.alpha
    ctx.cg.setAlpha(ctx.state.alpha * opacity)
    ctx.cg.clip()

    /// First draw a mask is necessary.
    if drawMask {
      guard
        let maskGradient = CGGradient(
          colorsSpace: maskColorSpace,
          colors: alphaColors as CFArray,
          locations: alphaLocations),
        let maskContext = CGContext(
          data: nil,
          width: ctx.cg.width,
          height: ctx.cg.height,
          bitsPerComponent: 8,
          bytesPerRow: ctx.cg.width,
          space: maskColorSpace,
          bitmapInfo: 0)
      else { return }
      let flipVertical = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(maskContext.height))
      maskContext.concatenate(flipVertical)
      maskContext.concatenate(ctx.cg.ctm)
      if type == .linear {
        maskContext.drawLinearGradient(
          maskGradient,
          start: start,
          end: end,
          options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
      } else {
        maskContext.drawRadialGradient(
          maskGradient,
          startCenter: start,
          startRadius: 0,
          endCenter: start,
          endRadius: start.distanceTo(end),
          options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
      }
      /// Clips the gradient
      if let alphaMask = maskContext.makeImage() {
        ctx.cg.clip(to: ctx.cg.boundingBoxOfClipPath, mask: alphaMask)
      }
    }

    /// Now draw the gradient
    guard
      let gradient = CGGradient(
        colorsSpace: LottieConfiguration.shared.colorSpace,
        colors: gradientColors as CFArray,
        locations: colorLocations)
    else { return }

    if type == .linear {
      ctx.cg.drawLinearGradient(gradient, start: start, end: end, options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    } else {
      ctx.cg.drawRadialGradient(
        gradient,
        startCenter: start,
        startRadius: 0,
        endCenter: start,
        endRadius: start.distanceTo(end),
        options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    }
  }
}
