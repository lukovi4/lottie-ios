//
//  LayerImageProvider.swift
//  lottie-swift
//
//  Created by Brandon Withrow on 1/25/19.
//

import Foundation
import UIKit

/// Connects a LottieImageProvider to a group of image layers
final class LayerImageProvider {

  // MARK: Lifecycle

  init(imageProvider: AnimationImageProvider, assets: [String: ImageAsset]?) {
    self.imageProvider = imageProvider
    imageLayers = [ImageCompositionLayer]()
    if let assets {
      imageAssets = assets
    } else {
      imageAssets = [:]
    }
    reloadImages(seconds: nil)
  }

  // MARK: Internal

  private(set) var imageLayers: [ImageCompositionLayer]
  let imageAssets: [String: ImageAsset]

  var imageProvider: AnimationImageProvider {
    didSet {
      reloadImages(seconds: nil)
    }
  }

  func addImageLayers(_ layers: [ImageCompositionLayer]) {
    for layer in layers {
      if imageAssets[layer.imageReferenceID] != nil {
        /// Found a linking asset in our asset library. Add layer
        imageLayers.append(layer)
      }
    }
  }

  func reloadImages(seconds: CGFloat?) {
    for imageLayer in imageLayers {
      if let asset = imageAssets[imageLayer.imageReferenceID] {
        imageLayer.image = imageProvider.imageForAsset(asset: asset, seconds: seconds)
        imageLayer.imageContentsGravity = imageProvider.contentsGravity(for: asset)
      }
    }
  }
}
