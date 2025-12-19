//
//  FilepathImageProvider.swift
//  lottie-swift
//
//  Created by Brandon Withrow on 2/1/19.
//

import Foundation
#if canImport(UIKit)
import UIKit

/// Provides an image for a lottie animation from a provided Bundle.
public class FilepathImageProvider: AnimationImageProvider {

  // MARK: Lifecycle

  /// Initializes an image provider with a specific filepath.
  ///
  /// - Parameter filepath: The absolute filepath containing the images.
  /// - Parameter contentsGravity: The contents gravity to use when rendering the images.
  ///
  public init(filepath: String, contentsGravity: CALayerContentsGravity = .resize) {
    self.filepath = URL(fileURLWithPath: filepath)
    self.contentsGravity = contentsGravity
  }

  /// Initializes an image provider with a specific filepath.
  ///
  /// - Parameter filepath: The absolute filepath containing the images.
  /// - Parameter contentsGravity: The contents gravity to use when rendering the images.
  ///
  public init(filepath: URL, contentsGravity: CALayerContentsGravity = .resize) {
    self.filepath = filepath
    self.contentsGravity = contentsGravity
  }

  // MARK: Public

  public func imageForAsset(asset: ImageAsset, seconds: CGFloat?) -> CGImage? {

    if
      asset.name.hasPrefix("data:"),
      let url = URL(string: asset.name),
      let data = try? Data(contentsOf: url),
      let image = UIImage(data: data)
    {
      return normalizedCGImage(from: image)
    }

    let directPath = filepath.appendingPathComponent(asset.name).path
    if FileManager.default.fileExists(atPath: directPath),
       let uiImage = UIImage(contentsOfFile: directPath) {
      return normalizedCGImage(from: uiImage)
    }

    let pathWithDirectory = filepath.appendingPathComponent(asset.directory).appendingPathComponent(asset.name).path
    if FileManager.default.fileExists(atPath: pathWithDirectory),
       let uiImage = UIImage(contentsOfFile: pathWithDirectory) {
      return normalizedCGImage(from: uiImage)
    }

    LottieLogger.shared.warn("Could not find image \"\(asset.name)\" in bundle")
    return nil
  }

  // MARK: Private

  /// Normalizes UIImage orientation by rendering through UIGraphics context.
  /// UIImage.cgImage returns raw pixels without applying imageOrientation.
  /// This ensures the CGImage has correct pixel orientation for direct drawing.
  private func normalizedCGImage(from uiImage: UIImage) -> CGImage? {
    let size = uiImage.size
    UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
    defer { UIGraphicsEndImageContext() }

    uiImage.draw(in: CGRect(origin: .zero, size: size))

    return UIGraphicsGetImageFromCurrentImageContext()?.cgImage
  }

  public func contentsGravity(for _: ImageAsset) -> CALayerContentsGravity {
    contentsGravity
  }

  // MARK: Internal

  let filepath: URL
  let contentsGravity: CALayerContentsGravity
}

extension FilepathImageProvider: Equatable {
  public static func ==(_ lhs: FilepathImageProvider, _ rhs: FilepathImageProvider) -> Bool {
    lhs.filepath == rhs.filepath
  }
}
#endif
