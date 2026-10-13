import CoreGraphics
import Foundation
import Vision
import simd

/// Local-only joint proposal. Vision is tried first; missing points are filled
/// with a conservative template fitted to the non-transparent image bounds.
/// Illustration pose detection is not treated as certain, so every point is
/// editable in `JointSelectionEditor`.
public struct JointProposalEngine: Sendable {
    public init() {}

    public func propose(
        for image: CGImage,
        role: ReferenceRole,
        fileName: String
    ) async -> ReferencePose {
        let fallback = Self.templatePose(
            role: role,
            fileName: fileName,
            bounds: AlphaBoundsDetector.normalizedBounds(in: image)
        )

        guard let vision = Self.visionPose(for: image) else { return fallback }
        var merged = fallback
        for (kind, observation) in vision.joints where observation.confidence >= 0.18 {
            merged.joints[kind] = observation
        }
        return merged
    }

    private static func visionPose(for image: CGImage) -> ReferencePose? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let body = request.results?.max(by: { lhs, rhs in
                (try? lhs.recognizedPoint(.neck).confidence) ?? 0
                    < ((try? rhs.recognizedPoint(.neck).confidence) ?? 0)
            }) else { return nil }

            var joints: [JointKind: JointObservation] = [:]
            func add(_ kind: JointKind, _ name: VNHumanBodyPoseObservation.JointName) {
                guard let point = try? body.recognizedPoint(name), point.confidence > 0 else { return }
                joints[kind] = JointObservation(
                    position: SIMD2(Float(point.location.x), Float(1 - point.location.y)),
                    confidence: point.confidence,
                    source: .vision,
                    visibility: .visible,
                    visibilitySource: .vision
                )
            }

            add(.head, .nose)
            add(.neck, .neck)
            add(.leftShoulder, .leftShoulder)
            add(.rightShoulder, .rightShoulder)
            add(.leftElbow, .leftElbow)
            add(.rightElbow, .rightElbow)
            add(.leftWrist, .leftWrist)
            add(.rightWrist, .rightWrist)
            add(.pelvis, .root)
            add(.leftKnee, .leftKnee)
            add(.rightKnee, .rightKnee)
            add(.leftAnkle, .leftAnkle)
            add(.rightAnkle, .rightAnkle)
            return ReferencePose(role: .front, fileName: "", joints: joints)
        } catch {
            return nil
        }
    }

    static func templatePose(
        role: ReferenceRole,
        fileName: String,
        bounds: CGRect
    ) -> ReferencePose {
        let x = Float(bounds.minX)
        let y = Float(bounds.minY)
        let width = Float(bounds.width)
        let height = Float(bounds.height)
        func point(_ px: Float, _ py: Float) -> SIMD2<Float> {
            SIMD2(x + width * px, y + height * py)
        }

        // In side views, keep both limbs selectable but bring the far side
        // closer to the body axis. The user can separate crossed limbs.
        let sideCompression: Float = role == .front ? 1 : 0.42
        let shoulderOffset = 0.18 * sideCompression
        let hipOffset = 0.10 * sideCompression
        let confidence: Float = 0.22
        let values: [JointKind: SIMD2<Float>] = [
            .head: point(0.50, 0.10),
            .neck: point(0.50, 0.22),
            .leftShoulder: point(0.50 - shoulderOffset, 0.27),
            .rightShoulder: point(0.50 + shoulderOffset, 0.27),
            .leftElbow: point(0.50 - shoulderOffset * 1.35, 0.43),
            .rightElbow: point(0.50 + shoulderOffset * 1.35, 0.43),
            .leftWrist: point(0.50 - shoulderOffset * 1.45, 0.58),
            .rightWrist: point(0.50 + shoulderOffset * 1.45, 0.58),
            .pelvis: point(0.50, 0.55),
            .leftKnee: point(0.50 - hipOffset, 0.75),
            .rightKnee: point(0.50 + hipOffset, 0.75),
            .leftAnkle: point(0.50 - hipOffset, 0.94),
            .rightAnkle: point(0.50 + hipOffset, 0.94),
        ]
        return ReferencePose(
            role: role,
            fileName: fileName,
            joints: values.mapValues {
                JointObservation(
                    position: $0,
                    confidence: confidence,
                    source: .silhouetteTemplate,
                    // A fitted point is an anatomical prior, not evidence
                    // that the source drawing contains texture at that joint.
                    visibility: .unknown,
                    visibilitySource: .topology
                )
            }
        )
    }
}

private enum AlphaBoundsDetector {
    static func normalizedBounds(in image: CGImage) -> CGRect {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var foundTransparentPixel = false
        for row in 0..<height {
            for column in 0..<width {
                let alpha = bytes[row * bytesPerRow + column * 4 + 3]
                if alpha < 250 { foundTransparentPixel = true }
                guard alpha > 12 else { continue }
                minX = min(minX, column)
                minY = min(minY, row)
                maxX = max(maxX, column)
                maxY = max(maxY, row)
            }
        }
        guard foundTransparentPixel, maxX >= minX, maxY >= minY else {
            return CGRect(x: 0.08, y: 0.03, width: 0.84, height: 0.94)
        }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }
}
