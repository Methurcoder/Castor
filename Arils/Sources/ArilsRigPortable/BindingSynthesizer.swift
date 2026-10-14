#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Turns a `PartPlan` into a complete `AvatarRig`: meshes, parenting, pivots,
/// deformation bindings, and physics channels.
///
/// This is the "puppet knowledge" of the automatic pipeline — every gain here
/// is a fraction of the part's own size, so the same rules work at any image
/// resolution. Tune here, not in the evaluator.
public enum BindingSynthesizer {
    public static func makeRig(plan: PartPlan) -> AvatarRig {
        // Sub-rects of the body used by sway regions, normalized within body rect.
        let bodyRect = plan.subjectRect
        let neckV = bodyRect.height > 0
            ? Float((plan.neckY - bodyRect.minY) / bodyRect.height)
            : 0.4
        let shoulderBandTop = Interpolation.clamp(neckV - 0.02, 0...0.9)
        let hairStripTop = Interpolation.clamp(neckV - 0.05, 0...0.9)
        let armStripTop = Interpolation.clamp(neckV + 0.22, 0...0.95)

        func region(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> CGRect {
            CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        }

        let body = AvatarPart(
            id: "body",
            kind: .body,
            parentID: nil,
            rect: bodyRect,
            pivot: SIMD2(0.5, 1.0),
            zOrder: 0,
            mesh: .grid(rect: bodyRect, columns: 12, rows: 16),
            deformations: [
                // Breath lifts the whole upper body from the base; the head
                // inherits the rise through the parent chain.
                .scale(parameter: .breath, pivot: SIMD2(0.5, 1.0), gainX: 0.004, gainY: 0.011),
                .rotate(parameter: .bodyAngleZ, pivot: SIMD2(0.5, 1.0), degreesPerUnit: 0.35),
                // A head tilt is shared with the whole body. The head inherits
                // this 22%, then adds the remaining 78% around the neck below;
                // total visual tilt stays unchanged while the shoulder/neck
                // seam no longer has to absorb the full relative rotation.
                .rotate(parameter: .angleZ, pivot: SIMD2(0.5, 1.0), degreesPerUnit: 0.22),
                .translate(parameter: .bodyAngleX, gainX: 0.004, gainY: 0),
                // bodyY positive lifts; image y grows downward.
                .translate(parameter: .bodyY, gainX: 0, gainY: -0.012),
                .regionSway(
                    parameter: .shoulderY,
                    region: region(0.05, shoulderBandTop, 0.9, 0.18),
                    axis: .vertical, profile: .bell, gain: -0.012
                ),
                // Long back/side hair approximated as side strips of the body
                // silhouette (see PartKind.hairBack for the design note).
                .regionSway(
                    parameter: .hairBackSway,
                    region: region(0, hairStripTop, 0.30, 1 - hairStripTop),
                    axis: .horizontal, profile: .rampDown, gain: 0.012
                ),
                .regionSway(
                    parameter: .hairBackSway,
                    region: region(0.70, hairStripTop, 0.30, 1 - hairStripTop),
                    axis: .horizontal, profile: .rampDown, gain: 0.012
                ),
                .regionSway(
                    parameter: .armLeftSway,
                    region: region(0, armStripTop, 0.28, 1 - armStripTop),
                    axis: .horizontal, profile: .rampDown, gain: 0.008
                ),
                .regionSway(
                    parameter: .armRightSway,
                    region: region(0.72, armStripTop, 0.28, 1 - armStripTop),
                    axis: .horizontal, profile: .rampDown, gain: 0.008
                ),
            ]
        )

        let head = AvatarPart(
            id: "head",
            kind: .head,
            parentID: "body",
            rect: plan.headRect,
            pivot: SIMD2(0.5, 0.98), // the neck
            zOrder: 10,
            mesh: .grid(rect: plan.headRect, columns: 12, rows: 12),
            deformations: [
                .rotate(parameter: .angleZ, pivot: SIMD2(0.5, 0.98), degreesPerUnit: 0.78),
                // Lateral/vertical shift accompanies the fake 3D turn so the
                // whole head participates, not just the interior features.
                .translate(parameter: .angleX, gainX: 0.0032, gainY: 0),
                .translate(parameter: .angleY, gainX: 0, gainY: -0.0028),
                .perspectiveShift(parameterX: .angleX, parameterY: .angleY, strength: 0.06),
                // Head-pat: squash down onto the neck, spread slightly.
                .scale(parameter: .touchSquash, pivot: SIMD2(0.5, 1.0), gainX: 0.05, gainY: -0.09),
                // The fringe sways as a warp region inside the head layer —
                // no cut, no seam (see PartKind.hairFront).
                .regionSway(
                    parameter: .hairFrontSway,
                    region: region(0.05, 0.02, 0.9, 0.55),
                    axis: .horizontal, profile: .bell, gain: 0.012
                ),
            ]
        )

        let neckSeamRect = plan.neckSeamRect
        let seamHeight = Float(max(1, neckSeamRect.height))
        let headHeight = Float(max(1, plan.headRect.height))
        let seamNeckV = Interpolation.clamp(
            Float((plan.neckY - neckSeamRect.minY) / max(1, neckSeamRect.height)),
            0.1...0.9
        )
        let neckSeam = AvatarPart(
            id: "neckSeam",
            kind: .accessory,
            parentID: "body",
            rect: neckSeamRect,
            pivot: SIMD2(0.5, seamNeckV),
            zOrder: 9,
            mesh: .grid(rect: neckSeamRect, columns: 16, rows: 8),
            deformations: [
                // Only the pixels above the true neck row follow pitch. The
                // lower half remains identical to the fixed body, and the
                // region op's horizontal fade keeps both side edges attached.
                .regionSway(
                    parameter: .angleY,
                    region: region(0, 0, 1, seamNeckV),
                    axis: .vertical,
                    profile: .rampUp,
                    gain: -0.0024 * headHeight / seamHeight
                ),
            ]
        )

        func eyePart(id: String, kind: PartKind, rect: CGRect, openParameter: ParameterID, z: Int) -> AvatarPart {
            AvatarPart(
                id: id,
                kind: kind,
                parentID: "head",
                rect: rect,
                pivot: SIMD2(0.5, 0.5),
                zOrder: z,
                mesh: .grid(rect: rect, columns: 4, rows: 4),
                deformations: [
                    // openness 1 -> rest, 0 -> collapsed to a near-line.
                    .scale(parameter: openParameter, pivot: SIMD2(0.5, 0.55), gainX: 0.06, gainY: 0.92),
                    .translate(parameter: .eyeBallX, gainX: 0.045, gainY: 0),
                    .translate(parameter: .eyeBallY, gainX: 0, gainY: -0.035),
                ]
            )
        }

        let mouthMesh = DeformableMesh.grid(rect: plan.mouthRect, columns: 4, rows: 4)
        let mouth = AvatarPart(
            id: "mouth",
            kind: .mouth,
            parentID: "head",
            rect: plan.mouthRect,
            pivot: SIMD2(0.5, 0.3),
            zOrder: 20,
            mesh: mouthMesh,
            deformations: [
                .warpKeyform(
                    parameterX: .mouthOpen,
                    parameterY: .mouthForm,
                    keys: LayerFactory.mouthWarpKeyforms(mesh: mouthMesh)
                ),
            ]
        )

        let physics = PhysicsRig(channels: [
            SwayChannel(output: .hairFrontSway, frequency: 1.7, dampingRatio: 0.25, headDrive: 0.9, breeze: 0.25),
            SwayChannel(output: .hairBackSway, frequency: 1.0, dampingRatio: 0.30, headDrive: 1.2, breeze: 0.35),
        ])

        return AvatarRig(
            formatVersion: AvatarRig.currentFormatVersion,
            imageWidth: plan.imageWidth,
            imageHeight: plan.imageHeight,
            parts: [
                body,
                neckSeam,
                head,
                mouth,
                eyePart(id: "eyeLeft", kind: .eyeLeft, rect: plan.eyeLeftRect, openParameter: .eyeLeftOpen, z: 30),
                eyePart(id: "eyeRight", kind: .eyeRight, rect: plan.eyeRightRect, openParameter: .eyeRightOpen, z: 31),
            ],
            parameters: StandardParameters.all,
            physics: physics
        )
    }

    /// Produces a v2 rig whose body/head meshes carry estimated depth and use
    /// real yaw/pitch operations. Feature layers remain children of the head
    /// and inherit those rotations.
    public static func makeDepthRig(
        plan: PartPlan,
        depthMap: DepthMap,
        depthScalePixels: Float? = nil,
        maximumHeadDepthPixels: Float? = nil,
        headMeshResolution: Int = 12
    ) -> AvatarRig {
        var rig = makeRig(plan: plan)
        rig.formatVersion = AvatarRig.currentFormatVersion
        let depthScalePixels = depthScalePixels ?? Float(plan.imageWidth)
        let headDepthCap = maximumHeadDepthPixels.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        for index in rig.parts.indices {
            var part = rig.parts[index]
            if part.kind == .head, headMeshResolution > 12 {
                let resolution = min(max(headMeshResolution, 12), 48)
                part.mesh = .grid(rect: part.rect, columns: resolution, rows: resolution)
            }
            let capsHeadSurface = switch part.kind {
            case .head, .eyeLeft, .eyeRight, .mouth:
                true
            case .body, .hairBack, .hairFront, .accessory:
                false
            }
            part.mesh.depths = part.mesh.vertices.map { vertex in
                let u = vertex.x / Float(max(1, plan.imageWidth))
                let v = vertex.y / Float(max(1, plan.imageHeight))
                let sampled = depthMap.sample(u: u, v: v) * depthScalePixels
                if capsHeadSurface, let headDepthCap {
                    return min(sampled, headDepthCap)
                }
                return sampled
            }
            if part.kind == .head {
                part.deformations.removeAll { operation in
                    switch operation {
                    case .perspectiveShift:
                        return true
                    case let .translate(parameter, _, _):
                        return parameter == .angleX || parameter == .angleY
                    default:
                        return false
                    }
                }
                part.deformations.insert(
                    .rotate3D(parameter: .angleX, axis: .y, pivot: SIMD3(0.5, 0.98, 0), degreesPerUnit: 1),
                    at: 1
                )
                part.deformations.insert(
                    .rotate3D(parameter: .angleY, axis: .x, pivot: SIMD3(0.5, 0.98, 0), degreesPerUnit: 1),
                    at: 2
                )
            }
            rig.parts[index] = part
        }
        return rig
    }

    /// A face-scale upper bound for depth reconstructed from the side image.
    ///
    /// `ThicknessProfile` sees the complete subject silhouette. With long
    /// twin-tails or a wide veil, using that width directly makes the face as
    /// deep as the hair is wide. Eye spacing and the front head cut are much
    /// better skull-size signals, so keep facial layers within this bound.
    /// The body depth remains uncapped because broad clothing is real body
    /// geometry and does not participate in the head pitch operation.
    static func recommendedHeadDepthCap(plan: PartPlan) -> Float {
        let headWidth = Float(plan.headRect.width)
        guard headWidth.isFinite, headWidth > 0 else { return 0 }

        let eyeSpan = abs(Float(plan.eyeRightRect.midX - plan.eyeLeftRect.midX))
        let faceScale = eyeSpan.isFinite && eyeSpan > headWidth * 0.15
            ? eyeSpan
            : headWidth * 0.34
        return min(headWidth * 0.40, max(headWidth * 0.22, faceScale))
    }
}
