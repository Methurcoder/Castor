import CoreGraphics
import Foundation
import simd

@testable import ArilsRig
@testable import ArilsRigPortable

/// Draws a minimal anime-ish character on a transparent background: a round
/// skin-colored head with a neck pinch, wider shoulders, two dark eyes, and a
/// dark mouth. Enough structure for the silhouette + contrast heuristics.
enum SyntheticCharacter {
    static let size = (width: 200, height: 260)
    static let headCenter = SIMD2<Float>(100, 70)
    static let headRadius: Float = 55
    static let eyeLeftCenter = SIMD2<Float>(75, 85)
    static let eyeRightCenter = SIMD2<Float>(125, 85)
    static let mouthCenter = SIMD2<Float>(100, 115)

    static func bitmap() -> Bitmap {
        var bitmap = Bitmap(width: size.width, height: size.height)
        let skin = SIMD4<Float>(0.98, 0.86, 0.76, 1)
        let shirt = SIMD4<Float>(0.55, 0.65, 0.9, 1)
        let eyeColor = SIMD4<Float>(0.15, 0.2, 0.45, 1)
        let mouthColor = SIMD4<Float>(0.6, 0.2, 0.2, 1)

        func fillEllipse(center: SIMD2<Float>, radiusX: Float, radiusY: Float, color: SIMD4<Float>) {
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let dx = (Float(x) - center.x) / radiusX
                    let dy = (Float(y) - center.y) / radiusY
                    if dx * dx + dy * dy <= 1 {
                        bitmap.setRGBA(x: x, y: y, color)
                    }
                }
            }
        }

        func fillRect(_ rect: CGRect, color: SIMD4<Float>) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    bitmap.setRGBA(x: x, y: y, color)
                }
            }
        }

        // Shoulders/torso, neck, head, features — painter's order.
        fillRect(CGRect(x: 30, y: 140, width: 140, height: 110), color: shirt)
        fillRect(CGRect(x: 85, y: 120, width: 30, height: 25), color: skin)
        fillEllipse(center: headCenter, radiusX: headRadius, radiusY: headRadius, color: skin)
        fillEllipse(center: eyeLeftCenter, radiusX: 12, radiusY: 8, color: eyeColor)
        fillEllipse(center: eyeRightCenter, radiusX: 12, radiusY: 8, color: eyeColor)
        fillEllipse(center: mouthCenter, radiusX: 10, radiusY: 4, color: mouthColor)
        return bitmap
    }

    static func cgImage() -> CGImage {
        bitmap().cgImage()!
    }

    static func bitmapOnOpaqueBackground() -> Bitmap {
        let foreground = bitmap()
        var result = Bitmap(width: size.width, height: size.height)
        let background = SIMD4<Float>(0.12, 0.045, 0.06, 1)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let pixel = foreground.rgba(x: x, y: y)
                result.setRGBA(x: x, y: y, pixel.w > 0.01 ? pixel : background)
            }
        }
        return result
    }

    /// Full-body opaque export with long side hair that hides the real neck.
    /// The old silhouette-only neck search followed the hair toward the torso
    /// and treated much of the upper body as the head.
    static func tallLongHairedBitmapOnOpaqueBackground() -> Bitmap {
        let width = size.width
        let height = 500
        let background = SIMD4<Float>(0.12, 0.045, 0.06, 1)
        let hair = SIMD4<Float>(0.25, 0.20, 0.31, 1)
        let hairShine = SIMD4<Float>(0.52, 0.46, 0.62, 1)
        let shirt = SIMD4<Float>(0.55, 0.65, 0.9, 1)
        var result = Bitmap(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { result.setRGBA(x: x, y: y, background) }
        }
        // Hair behind the face stays wide well below the actual neck.
        for y in 25..<250 {
            for x in 25..<60 { result.setRGBA(x: x, y: y, hair) }
            for x in 140..<175 { result.setRGBA(x: x, y: y, hair) }
        }
        for y in 55..<115 {
            for x in 157..<164 { result.setRGBA(x: x, y: y, hairShine) }
        }
        // Extend the torso/legs so the subject is unmistakably full-body.
        for y in 140..<485 {
            for x in 35..<165 { result.setRGBA(x: x, y: y, shirt) }
        }
        let foreground = bitmap()
        for y in 0..<foreground.height {
            for x in 0..<foreground.width {
                let pixel = foreground.rgba(x: x, y: y)
                if pixel.w > 0.01 { result.setRGBA(x: x, y: y, pixel) }
            }
        }
        return result
    }

    /// Compact character with a tall hat extending the head rect upward. The
    /// real eyes sit below 70% of the resulting head height, so non-full-body
    /// inputs must retain the wider legacy eye-search band.
    static func bitmapWithTallHat() -> Bitmap {
        let foreground = bitmap()
        var result = Bitmap(width: size.width, height: 300)
        let hat = SIMD4<Float>(0.18, 0.12, 0.28, 1)
        for y in 0..<48 {
            for x in 72..<128 { result.setRGBA(x: x, y: y, hat) }
        }
        for y in 38..<52 {
            for x in 50..<150 { result.setRGBA(x: x, y: y, hat) }
        }
        for y in 0..<foreground.height {
            for x in 0..<foreground.width {
                let pixel = foreground.rgba(x: x, y: y)
                if pixel.w > 0.01 { result.setRGBA(x: x, y: y + 25, pixel) }
            }
        }
        return result
    }

    /// A small real mouth above a broad, high-contrast choker/collar. This is
    /// the failure shape from opaque anime exports: a whole-band centroid is
    /// pulled down to the garment edge and cuts the neck out as the mouth.
    static func bitmapWithStrongCollarDecoy() -> Bitmap {
        var result = bitmap()
        let collar = SIMD4<Float>(0.08, 0.06, 0.10, 1)
        let trim = SIMD4<Float>(0.95, 0.40, 0.62, 1)
        for y in 120..<126 {
            for x in 62..<138 { result.setRGBA(x: x, y: y, collar) }
        }
        for y in 122..<124 {
            for x in 68..<132 { result.setRGBA(x: x, y: y, trim) }
        }
        return result
    }
}

/// The same character drawn at a slight three-quarter turn: the facial
/// features sit left of the head-mask centroid because the hair mass (the
/// back of the head) bulges out to the right, and the far eye is smaller
/// than the near one. This is the geometry that breaks frontal-only
/// heuristics — the mask centroid is not the face axis anymore.
enum SyntheticTurnedCharacter {
    static let size = (width: 200, height: 260)
    static let eyeLeftCenter = SIMD2<Float>(66, 85)
    static let eyeRightCenter = SIMD2<Float>(104, 85)
    static let mouthCenter = SIMD2<Float>(84, 115)

    static func bitmap() -> Bitmap {
        var bitmap = Bitmap(width: size.width, height: size.height)
        let skin = SIMD4<Float>(0.98, 0.86, 0.76, 1)
        let shirt = SIMD4<Float>(0.55, 0.65, 0.9, 1)
        let hair = SIMD4<Float>(0.24, 0.19, 0.3, 1)
        let hairShine = SIMD4<Float>(0.5, 0.44, 0.6, 1)
        let eyeColor = SIMD4<Float>(0.15, 0.2, 0.45, 1)
        let mouthColor = SIMD4<Float>(0.6, 0.2, 0.2, 1)

        func fillEllipse(center: SIMD2<Float>, radiusX: Float, radiusY: Float, color: SIMD4<Float>) {
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let dx = (Float(x) - center.x) / radiusX
                    let dy = (Float(y) - center.y) / radiusY
                    if dx * dx + dy * dy <= 1 {
                        bitmap.setRGBA(x: x, y: y, color)
                    }
                }
            }
        }

        func fillRect(_ rect: CGRect, color: SIMD4<Float>) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    bitmap.setRGBA(x: x, y: y, color)
                }
            }
        }

        // Painter's order: torso, neck, skull, hair volume trailing right
        // (the turned-away back of the head), then the face opening carved
        // back in with skin, features shifted toward the viewer's left.
        fillRect(CGRect(x: 30, y: 140, width: 140, height: 110), color: shirt)
        fillRect(CGRect(x: 85, y: 120, width: 30, height: 25), color: skin)
        fillEllipse(center: SIMD2(100, 70), radiusX: 55, radiusY: 55, color: skin)
        fillEllipse(center: SIMD2(112, 58), radiusX: 58, radiusY: 52, color: hair)
        // A hair highlight inside the eye band: a decoy contrast feature on
        // the hair side, like specular streaks in real artwork.
        fillEllipse(center: SIMD2(146, 84), radiusX: 6, radiusY: 16, color: hairShine)
        fillEllipse(center: SIMD2(86, 80), radiusX: 40, radiusY: 42, color: skin)
        // Near (viewer-left) eye slightly larger than the far eye.
        fillEllipse(center: eyeLeftCenter, radiusX: 12, radiusY: 8, color: eyeColor)
        fillEllipse(center: eyeRightCenter, radiusX: 9, radiusY: 7, color: eyeColor)
        fillEllipse(center: mouthCenter, radiusX: 9, radiusY: 4, color: mouthColor)
        return bitmap
    }

    static func cgImage() -> CGImage {
        bitmap().cgImage()!
    }
}
