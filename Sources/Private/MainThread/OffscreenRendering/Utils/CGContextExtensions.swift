//
//  CGContextExtensions.swift
//  lottie-ios
//
//  Created for Animi offscreen rendering support.
//

import CoreGraphics
import QuartzCore

// MARK: - CGContext Extensions for Offscreen Rendering

extension CGContext {

    // MARK: - Coordinate System

    /// Flips the coordinate system from CoreGraphics (origin bottom-left)
    /// to UIKit/CALayer (origin top-left).
    /// Call this once at the beginning of frame rendering.
    ///
    /// - Parameter height: The height of the canvas to flip around
    func flipCoordinateSystem(height: CGFloat) {
        translateBy(x: 0, y: height)
        scaleBy(x: 1, y: -1)
    }

    // MARK: - Clearing

    /// Clears the context using .copy blend mode.
    /// This is safer than CGContext.clear() which can leave artifacts
    /// depending on bitmapInfo configuration.
    ///
    /// - Parameter rect: The rect to clear
    func clearWithCopyBlendMode(_ rect: CGRect) {
        saveGState()
        setBlendMode(.copy)
        setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        fill(rect)
        restoreGState()
    }

    // MARK: - Transform Helpers

    /// Applies a CATransform3D to the context by converting it to CGAffineTransform.
    /// Only the 2D components are used (3D projection is ignored).
    ///
    /// - Parameter transform3D: The CATransform3D to apply
    func concatenate(_ transform3D: CATransform3D) {
        let affine = CATransform3DGetAffineTransform(transform3D)
        concatenate(affine)
    }
}

// MARK: - CATransform3D Extensions

extension CATransform3D {

    /// Converts CATransform3D to CGAffineTransform.
    /// This extracts only the 2D transformation components.
    var affineTransform: CGAffineTransform {
        CATransform3DGetAffineTransform(self)
    }

    /// Checks if the transform is 2D-only (no 3D rotation or perspective).
    var isAffine: Bool {
        CATransform3DIsAffine(self)
    }
}
