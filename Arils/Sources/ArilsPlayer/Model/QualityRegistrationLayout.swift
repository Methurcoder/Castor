#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

import ArilsCore

/// Pure geometry for placing the front/side views of an Arils-2D-Quality
/// character inside one shared container. Kept separate from
/// `QualityCharacterEngine` (and free of AppKit) so the math is unit-testable.
///
/// The container this feeds is Y-down (top-left origin, matching image
/// coordinates and `isFlipped == true`), and every rect below is expressed in
/// that same Y-down space.
public enum QualityRegistrationLayout {
    /// Centers `imageSize` inside `bounds`, scaled uniformly to fit
    /// (letterboxed, matching `AvatarMetalView`'s own aspect-fit draw).
    public static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }

    /// Frame for the side view, in the container's Y-down coordinate space,
    /// such that:
    /// - the side view's frame has the side image's own aspect ratio, so the
    ///   side view's internal aspect-fit exactly fills its frame (no
    ///   letterboxing inside the side view itself), and
    /// - the front and side neck points (both normalized image coordinates,
    ///   Y down) land on the same container point.
    public static func sideFrame(
        bounds: CGRect,
        frontImageSize: CGSize,
        sideImageSize: CGSize,
        registration: QualityViewRegistration
    ) -> CGRect {
        let frontFit = aspectFitRect(imageSize: frontImageSize, in: bounds)
        let frontScale = frontImageSize.width > 0 ? frontFit.width / frontImageSize.width : 0
        let sideScale = frontScale * CGFloat(registration.sideScale)
        let sideSize = CGSize(width: sideImageSize.width * sideScale, height: sideImageSize.height * sideScale)

        let frontNeck = CGPoint(
            x: frontFit.origin.x + CGFloat(registration.frontNeck.x) * frontFit.width,
            y: frontFit.origin.y + CGFloat(registration.frontNeck.y) * frontFit.height
        )
        let origin = CGPoint(
            x: frontNeck.x - CGFloat(registration.sideNeck.x) * sideSize.width,
            y: frontNeck.y - CGFloat(registration.sideNeck.y) * sideSize.height
        )
        return CGRect(origin: origin, size: sideSize)
    }
}
