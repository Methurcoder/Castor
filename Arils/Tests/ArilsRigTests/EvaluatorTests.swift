import CoreGraphics
import Foundation
import simd
import Testing

import ArilsCore
@testable import ArilsRig
@testable import ArilsRigPortable

private func makeRig(parts: [AvatarPart]) -> AvatarRig {
    AvatarRig(
        imageWidth: 200,
        imageHeight: 200,
        parts: parts,
        parameters: StandardParameters.all
    )
}

private func part(
    id: String,
    parentID: String? = nil,
    rect: CGRect = CGRect(x: 50, y: 50, width: 100, height: 100),
    pivot: SIMD2<Float> = SIMD2(0.5, 0.5),
    deformations: [DeformationOp]
) -> AvatarPart {
    AvatarPart(
        id: id,
        kind: .body,
        parentID: parentID,
        rect: rect,
        pivot: pivot,
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 2, rows: 2),
        deformations: deformations
    )
}

@Test func translateMovesByGainTimesDeviation() {
    let rig = makeRig(parts: [
        part(id: "a", deformations: [.translate(parameter: .bodyAngleX, gainX: 0.01, gainY: 0)])
    ])
    let evaluator = DeformationEvaluator(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])["a"]!
    let moved = evaluator.evaluate(parameters: [.bodyAngleX: 10])["a"]!
    for (before, after) in zip(rest, moved) {
        #expect(abs((after.x - before.x) - 0.01 * 100 * 10) < 0.001)
        #expect(abs(after.y - before.y) < 0.001)
    }
}

@Test func nonFiniteParametersFallBackToRestGeometry() {
    let rig = makeRig(parts: [
        part(id: "a", deformations: [
            .translate(parameter: .bodyAngleX, gainX: 0.01, gainY: 0),
            .rotate3D(
                parameter: .angleX,
                axis: .y,
                pivot: SIMD3(0.5, 1, 0),
                degreesPerUnit: 1
            ),
        ]),
    ])
    let planar = DeformationEvaluator(rig: rig)
    let depth = DeformationEvaluator3D(rig: rig)

    let planarRest = planar.evaluate(parameters: [:])["a"]!
    let planarInvalid = planar.evaluate(parameters: [.bodyAngleX: .nan])["a"]!
    #expect(planarInvalid == planarRest)

    let depthRest = depth.evaluate(parameters: [:])["a"]!
    let depthInvalid = depth.evaluate(parameters: [.angleX: .infinity])["a"]!
    #expect(depthInvalid == depthRest)
    #expect(depthInvalid.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
}

@Test func rotationIsRigidAroundPivot() {
    let rig = makeRig(parts: [
        part(id: "a", deformations: [.rotate(parameter: .angleZ, pivot: SIMD2(0.5, 1.0), degreesPerUnit: 1)])
    ])
    let evaluator = DeformationEvaluator(rig: rig)
    let pivot = SIMD2<Float>(100, 150)
    let rest = evaluator.evaluate(parameters: [:])["a"]!
    let rotated = evaluator.evaluate(parameters: [.angleZ: 20])["a"]!
    for (before, after) in zip(rest, rotated) {
        #expect(abs(simd_distance(before, pivot) - simd_distance(after, pivot)) < 0.01)
    }
    // Something actually moved.
    #expect(simd_distance(rest[0], rotated[0]) > 1)
}

@Test func scaleUsesDeviationFromDefault() {
    // eyeLeftOpen has default 1: at value 1 nothing moves, at 0 it collapses.
    let rig = makeRig(parts: [
        part(id: "eye", deformations: [.scale(parameter: .eyeLeftOpen, pivot: SIMD2(0.5, 0.5), gainX: 0, gainY: 0.92)])
    ])
    let evaluator = DeformationEvaluator(rig: rig)
    let atDefault = evaluator.evaluate(parameters: [.eyeLeftOpen: 1])["eye"]!
    let rest = evaluator.evaluate(parameters: [:])["eye"]!
    for (a, b) in zip(atDefault, rest) {
        #expect(simd_distance(a, b) < 0.001)
    }

    let closed = evaluator.evaluate(parameters: [.eyeLeftOpen: 0])["eye"]!
    func height(_ vertices: [SIMD2<Float>]) -> Float {
        vertices.map(\.y).max()! - vertices.map(\.y).min()!
    }
    #expect(abs(height(closed) / height(rest) - 0.08) < 0.001)
}

@Test func childInheritsParentAffineMotion() {
    let rig = makeRig(parts: [
        part(id: "parent", deformations: [.translate(parameter: .bodyY, gainX: 0, gainY: -0.012)]),
        part(
            id: "child",
            parentID: "parent",
            rect: CGRect(x: 70, y: 60, width: 20, height: 20),
            deformations: []
        ),
    ])
    let evaluator = DeformationEvaluator(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])["child"]!
    let lifted = evaluator.evaluate(parameters: [.bodyY: 1])["child"]!
    for (before, after) in zip(rest, lifted) {
        #expect(abs((after.y - before.y) - (-0.012 * 100)) < 0.001)
    }
}

@Test func perspectiveShiftMovesCenterNotEdges() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let rig = makeRig(parts: [
        AvatarPart(
            id: "head", kind: .head, rect: rect, pivot: SIMD2(0.5, 1),
            zOrder: 0, mesh: .grid(rect: rect, columns: 4, rows: 4),
            deformations: [.perspectiveShift(parameterX: .angleX, parameterY: .angleY, strength: 0.06)]
        )
    ])
    let evaluator = DeformationEvaluator(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])["head"]!
    let turned = evaluator.evaluate(parameters: [.angleX: 30])["head"]!

    // Corner vertex (0,0) must not move; center vertex moves right.
    #expect(simd_distance(rest[0], turned[0]) < 0.001)
    let centerIndex = 2 * 5 + 2 // row 2, column 2 of a 5x5 vertex grid
    #expect(turned[centerIndex].x - rest[centerIndex].x > 4)
}

@Test func legacyHeadPitchTranslationKeepsEveryCropEdgeFixed() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let rig = makeRig(parts: [
        AvatarPart(
            id: "head", kind: .head, rect: rect, pivot: SIMD2(0.5, 1),
            zOrder: 0, mesh: .grid(rect: rect, columns: 4, rows: 4),
            deformations: [.translate(parameter: .angleY, gainX: 0, gainY: -0.01)]
        ),
        part(
            id: "eye",
            parentID: "head",
            rect: CGRect(x: 40, y: 40, width: 20, height: 20),
            deformations: []
        ),
    ])
    let evaluator = DeformationEvaluator(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])
    let pitched = evaluator.evaluate(parameters: [.angleY: 10])
    let head = pitched["head"]!
    let restHead = rest["head"]!

    // 5x5 grid: the complete rectangular crop boundary stays registered.
    for row in 0..<5 {
        for column in 0..<5 where row == 0 || row == 4 || column == 0 || column == 4 {
            let index = row * 5 + column
            #expect(simd_distance(head[index], restHead[index]) < 0.001)
        }
    }

    let centerIndex = 2 * 5 + 2
    #expect(abs((head[centerIndex].y - restHead[centerIndex].y) + 10) < 0.001)
    for (before, after) in zip(rest["eye"]!, pitched["eye"]!) {
        #expect(abs((after.y - before.y) + 10) < 0.001)
    }
}

@Test func regionSwayIsNotInheritedByChildren() {
    let parentRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let rig = makeRig(parts: [
        AvatarPart(
            id: "head", kind: .head, rect: parentRect, pivot: SIMD2(0.5, 1),
            zOrder: 0, mesh: .grid(rect: parentRect, columns: 2, rows: 2),
            deformations: [
                .regionSway(
                    parameter: .hairFrontSway,
                    region: CGRect(x: 0, y: 0, width: 1, height: 1),
                    axis: .horizontal, profile: .bell, gain: 0.05
                )
            ]
        ),
        // Child pivot sits mid-region where sway weight is maximal.
        part(
            id: "eye",
            parentID: "head",
            rect: CGRect(x: 40, y: 40, width: 20, height: 20),
            deformations: []
        ),
    ])
    let evaluator = DeformationEvaluator(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])
    let swaying = evaluator.evaluate(parameters: [.hairFrontSway: 1])

    // The head's own mid vertices sway...
    #expect(simd_distance(rest["head"]![4], swaying["head"]![4]) > 0.5)
    // ...but the child does not move at all.
    for (before, after) in zip(rest["eye"]!, swaying["eye"]!) {
        #expect(simd_distance(before, after) < 0.001)
    }
}

@Test func evaluationIsPure() {
    let rig = BindingSynthesizer.makeRig(plan: PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 45, y: 15, width: 110, height: 110),
            eyeLeftRect: CGRect(x: 63, y: 77, width: 24, height: 16),
            eyeRightRect: CGRect(x: 113, y: 77, width: 24, height: 16),
            mouthRect: CGRect(x: 90, y: 111, width: 20, height: 8),
            confidence: 1
        ),
        subjectMask: FloatPlane(width: 4, height: 4, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    ))
    let evaluator = DeformationEvaluator(rig: rig)
    let parameters: [ParameterID: Float] = [.angleX: 12, .angleZ: -6, .breath: 0.7, .hairFrontSway: 0.4]
    let first = evaluator.evaluate(parameters: parameters)
    let second = evaluator.evaluate(parameters: parameters)
    for (partID, vertices) in first {
        for (a, b) in zip(vertices, second[partID]!) {
            #expect(a == b)
        }
    }
}

@Test func integrityMetricsDetectsOnlyFlippedTrianglesAsMeshInversions() {
    let mesh = DeformableMesh(
        vertices: [
            SIMD2(10, 10),
            SIMD2(10, 90),
            SIMD2(90, 10),
        ],
        uvs: [
            SIMD2(0, 0),
            SIMD2(0, 1),
            SIMD2(1, 0),
        ],
        indices: [0, 1, 2]
    )
    let triangle = AvatarPart(
        id: "triangle",
        kind: .body,
        rect: CGRect(x: 10, y: 10, width: 80, height: 80),
        zOrder: 0,
        mesh: mesh
    )
    let rig = AvatarRig(
        imageWidth: 100,
        imageHeight: 100,
        parts: [triangle],
        parameters: []
    )
    let rest = ["triangle": mesh.vertices]
    let stable = RigIntegrityMetrics.measure(rig: rig, evaluatedVertices: rest)
    #expect(stable.meshInversionCount == 0)

    let flipped = [
        "triangle": [
            mesh.vertices[0],
            mesh.vertices[2],
            mesh.vertices[1],
        ],
    ]
    let metrics = RigIntegrityMetrics.measure(rig: rig, evaluatedVertices: flipped)
    #expect(metrics.meshInversionCount == 1)
}

@Test func integrityCoverageRasterizerHasStableSyntheticBaseline() {
    let imageRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let halfRect = CGRect(x: 0, y: 0, width: 50, height: 100)
    let body = AvatarPart(
        id: "body",
        kind: .body,
        rect: imageRect,
        zOrder: 0,
        mesh: .grid(rect: imageRect, columns: 1, rows: 1)
    )
    let foreground = AvatarPart(
        id: "foreground",
        kind: .accessory,
        rect: halfRect,
        zOrder: 1,
        mesh: .grid(rect: halfRect, columns: 1, rows: 1)
    )
    let rig = AvatarRig(
        imageWidth: 100,
        imageHeight: 100,
        parts: [body, foreground],
        parameters: []
    )
    let movedForeground = foreground.mesh.vertices.map { $0 + SIMD2<Float>(50, 0) }
    let unknown = FloatPlane(width: 2, height: 2, fill: 1)
    let metrics = RigIntegrityMetrics.measure(
        rig: rig,
        evaluatedVertices: [
            body.id: body.mesh.vertices,
            foreground.id: movedForeground,
        ],
        unknownCoverageByPartID: [foreground.id: unknown]
    )

    #expect(metrics.meshInversionCount == 0)
    #expect(abs(metrics.holeArea) < 0.000_001)
    #expect(abs(metrics.ghostArea - 0.5) < 0.000_001)
    #expect(abs(metrics.unknownExposure - 0.5) < 0.000_001)
}

@Test func integrityCoverageRasterizerMeasuresVacatedRestAreaAsHole() {
    let leftRect = CGRect(x: 0, y: 0, width: 50, height: 100)
    let part = AvatarPart(
        id: "part",
        kind: .body,
        rect: leftRect,
        zOrder: 0,
        mesh: .grid(rect: leftRect, columns: 1, rows: 1)
    )
    let rig = AvatarRig(
        imageWidth: 100,
        imageHeight: 100,
        parts: [part],
        parameters: []
    )
    let moved = part.mesh.vertices.map { $0 + SIMD2<Float>(50, 0) }
    let metrics = RigIntegrityMetrics.measure(
        rig: rig,
        evaluatedVertices: [part.id: moved]
    )

    #expect(abs(metrics.holeArea - 0.5) < 0.000_001)
    #expect(abs(metrics.ghostArea - 0.5) < 0.000_001)
    #expect(metrics.unknownExposure == 0)
}

@Test func threeDimensionalIntegrityUsesRendererPerspectiveAndRejectsNonFiniteVertices() {
    let rect = CGRect(x: 55, y: 30, width: 30, height: 40)
    let part = AvatarPart(
        id: "depth",
        kind: .head,
        rect: rect,
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 1, rows: 1)
    )
    let rig = AvatarRig(
        imageWidth: 100,
        imageHeight: 100,
        parts: [part],
        parameters: []
    )
    let reference = [
        part.id: part.mesh.vertices.map { SIMD3<Float>($0.x, $0.y, 0) },
    ]
    let forward = [
        part.id: part.mesh.vertices.map { SIMD3<Float>($0.x, $0.y, 100) },
    ]
    let projected = RigIntegrityMetrics.measure(
        rig: rig,
        evaluatedVertices: forward,
        referenceVertices: reference,
        rasterResolution: 100
    )
    #expect(projected.holeArea > 0)
    #expect(projected.ghostArea > 0)
    #expect(projected.nonFiniteVertexCount == 0)

    var invalid = forward
    invalid[part.id]?[0].x = .nan
    let nonFinite = RigIntegrityMetrics.measure(
        rig: rig,
        evaluatedVertices: invalid,
        referenceVertices: reference,
        rasterResolution: 100
    )
    #expect(nonFinite.nonFiniteVertexCount == 1)
}

@Test func legacyIntegrityMetricsDecodeWithZeroNonFiniteVertices() throws {
    let legacy = Data(
        #"{"meshInversionCount":1,"holeArea":0.1,"ghostArea":0.2,"unknownExposure":0.3}"#.utf8
    )
    let decoded = try JSONDecoder().decode(RigIntegrityMetrics.self, from: legacy)
    #expect(decoded.meshInversionCount == 1)
    #expect(decoded.nonFiniteVertexCount == 0)
}

@Test func validationPolicyRejectsSafetyFailuresAndReviewsQualityFailures() {
    let policy = RigValidationPolicy(
        safety: RigSafetyThresholds(maximumUnknownExposure: 0.1),
        quality: RigQualityThresholds(maximumHoleArea: 0.1, maximumGhostArea: 0.1)
    )
    #expect(policy.disposition(for: RigIntegrityMetrics()) == .accepted)
    #expect(
        policy.disposition(for: RigIntegrityMetrics(holeArea: 0.2))
            == .requiresReview
    )
    #expect(
        policy.disposition(for: RigIntegrityMetrics(unknownExposure: 0.2))
            == .rejected
    )
    #expect(
        policy.disposition(for: RigIntegrityMetrics(nonFiniteVertexCount: 1))
            == .rejected
    )
}

@Test func poseSweepKeepsASeparateHardSafetyRangeForReviewableQuality() {
    let rect = CGRect(x: 20, y: 20, width: 40, height: 40)
    let moving = AvatarPart(
        id: "moving",
        kind: .head,
        rect: rect,
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 1, rows: 1),
        deformations: [
            .translate(parameter: .angleX, gainX: 0.01, gainY: 0),
        ]
    )
    let rig = AvatarRig(
        imageWidth: 100,
        imageHeight: 100,
        parts: [moving],
        parameters: StandardParameters.all
    )
    let plan = PoseSweepPlan(
        yawDegrees: [0, 10],
        pitchDegrees: [0],
        thresholds: RigIntegrityThresholds(
            maximumMeshInversionCount: 0,
            maximumHoleArea: 0,
            maximumGhostArea: 0,
            maximumUnknownExposure: 0
        ),
        rasterResolution: 100
    )
    let result = PoseSweepValidator.validate(rig: rig, plan: plan)
    let moved = PoseSweepSample(yawDegrees: 10, pitchDegrees: 0)

    #expect(result.dispositionsByPose[moved] == .requiresReview)
    #expect(result.validatedPoseLimits.maximumYawDegrees == 0)
    #expect(result.safetyPoseLimits.maximumYawDegrees == 10)
}

@Test func poseSweepStopsAtTheFirstInvertingYawAndKeepsTheSafeDirection() {
    let rect = CGRect(x: 10, y: 10, width: 80, height: 80)
    let scalable = AvatarPart(
        id: "scalable",
        kind: .head,
        rect: rect,
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 1, rows: 1),
        deformations: [
            .scale(
                parameter: .angleX,
                pivot: SIMD2(0.5, 0.5),
                gainX: -0.06,
                gainY: 0
            ),
        ]
    )
    let rig = AvatarRig(
        imageWidth: 100,
        imageHeight: 100,
        parts: [scalable],
        parameters: StandardParameters.all
    )
    let plan = PoseSweepPlan(
        yawDegrees: [-20, -10, 0, 10, 20],
        pitchDegrees: [0],
        thresholds: RigIntegrityThresholds(
            maximumMeshInversionCount: 0,
            maximumHoleArea: 1,
            maximumGhostArea: 1,
            maximumUnknownExposure: 1
        ),
        rasterResolution: 64
    )
    let result = PoseSweepValidator.validate(rig: rig, plan: plan)

    #expect(result.validatedPoseLimits.minimumYawDegrees == -20)
    #expect(result.validatedPoseLimits.maximumYawDegrees == 10)
    #expect(
        result.metricsByPose[
            PoseSweepSample(yawDegrees: 20, pitchDegrees: 0)
        ]?.meshInversionCount == 2
    )
}

@Test func twoDimensionalWarpKeyformUsesExactCorrectivesAndBilinearCorners() {
    let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
    let mesh = DeformableMesh.grid(rect: rect, columns: 1, rows: 1)
    func key(_ x: Float, _ y: Float, _ offset: SIMD2<Float>) -> WarpKeyformKey {
        WarpKeyformKey(
            parameterXValue: x,
            parameterYValue: y,
            vertexOffsets: [SIMD2<Float>](repeating: offset, count: mesh.vertexCount)
        )
    }
    let keys = [
        key(0, -1, SIMD2(0, 0)),
        key(1, -1, SIMD2(10, 0)),
        key(0, 1, SIMD2(0, 20)),
        key(1, 1, SIMD2(10, 20)),
        key(0.5, 0, SIMD2(7, 12)),
    ]
    let part = AvatarPart(
        id: "keyed",
        kind: .mouth,
        rect: rect,
        zOrder: 0,
        mesh: mesh,
        deformations: [
            .warpKeyform(
                parameterX: .mouthOpen,
                parameterY: .mouthForm,
                keys: keys
            ),
        ]
    )
    let rig = AvatarRig(
        imageWidth: 10,
        imageHeight: 10,
        parts: [part],
        parameters: StandardParameters.all
    )
    let evaluator = DeformationEvaluator(rig: rig)
    let exact = evaluator.evaluate(parameters: [.mouthOpen: 0.5, .mouthForm: 0])["keyed"]!
    #expect(simd_distance(exact[0], mesh.vertices[0] + SIMD2(7, 12)) < 0.001)

    let interpolated = evaluator.evaluate(
        parameters: [.mouthOpen: 0.25, .mouthForm: 0]
    )["keyed"]!
    #expect(simd_distance(interpolated[0], mesh.vertices[0] + SIMD2(2.5, 10)) < 0.001)

    let defaults = evaluator.evaluate(parameters: [:])["keyed"]!
    let nonFinite = evaluator.evaluate(
        parameters: [.mouthOpen: .nan, .mouthForm: .infinity]
    )["keyed"]!
    #expect(nonFinite == defaults)
    #expect(nonFinite.allSatisfy { $0.x.isFinite && $0.y.isFinite })
}

@Test func legacyProceduralDeformationDocumentStillDecodesWithoutKeyforms() throws {
    let legacyPart = part(
        id: "legacy",
        deformations: [
            .scale(
                parameter: .mouthOpen,
                pivot: SIMD2(0.5, 0.5),
                gainX: -0.1,
                gainY: 0.9
            ),
        ]
    )
    let legacyRig = makeRig(parts: [legacyPart])
    let restored = try JSONDecoder().decode(
        AvatarRig.self,
        from: JSONEncoder().encode(legacyRig)
    )
    #expect(restored == legacyRig)
}

@Test func headTiltIsSharedWithTheBodyWithoutChangingTheTotalAngle() {
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 45, y: 15, width: 110, height: 110),
            eyeLeftRect: CGRect(x: 63, y: 77, width: 24, height: 16),
            eyeRightRect: CGRect(x: 113, y: 77, width: 24, height: 16),
            mouthRect: CGRect(x: 90, y: 111, width: 20, height: 8),
            confidence: 1
        ),
        subjectMask: FloatPlane(width: 4, height: 4, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    )
    let rig = BindingSynthesizer.makeRig(plan: plan)
    let evaluator = DeformationEvaluator(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])
    let tilted = evaluator.evaluate(parameters: [.angleZ: 10])

    let body = rig.firstPart(ofKind: .body)!
    let head = rig.firstPart(ofKind: .head)!
    let bodyColumns = 13 // BindingSynthesizer body grid: 12 columns.
    let headColumns = 13 // BindingSynthesizer head grid: 12 columns.

    func edgeAngle(_ vertices: [SIMD2<Float>], start: Int, end: Int) -> Float {
        let edge = vertices[end] - vertices[start]
        return atan2(edge.y, edge.x) * 180 / .pi
    }

    let bodyRestAngle = edgeAngle(rest[body.id]!, start: 0, end: bodyColumns - 1)
    let bodyTiltAngle = edgeAngle(tilted[body.id]!, start: 0, end: bodyColumns - 1)
    let headRestAngle = edgeAngle(rest[head.id]!, start: 0, end: headColumns - 1)
    let headTiltAngle = edgeAngle(tilted[head.id]!, start: 0, end: headColumns - 1)

    // The torso follows 22% of the requested lean, while the child head adds
    // the remaining 78%; visually the head still reaches the requested 10°.
    #expect(abs((bodyTiltAngle - bodyRestAngle) - 2.2) < 0.05)
    #expect(abs((headTiltAngle - headRestAngle) - 10) < 0.05)
}

@Test func legacyMeshWithoutDepthDecodesFlatAndKeepsPerspectiveShift() throws {
    let mesh = DeformableMesh.grid(rect: CGRect(x: 0, y: 0, width: 10, height: 10), columns: 1, rows: 1)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(mesh)) as? [String: Any])
    object.removeValue(forKey: "depths")
    let restored = try JSONDecoder().decode(
        DeformableMesh.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(restored.depths == [0, 0, 0, 0])
}

@Test func depthRigUsesRigidYawAndMovesChildrenInThreeDimensions() {
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 40, y: 20, width: 120, height: 120),
            eyeLeftRect: CGRect(x: 65, y: 75, width: 20, height: 12),
            eyeRightRect: CGRect(x: 115, y: 75, width: 20, height: 12),
            mouthRect: CGRect(x: 90, y: 110, width: 20, height: 10),
            confidence: 1
        ),
        subjectMask: FloatPlane(width: 10, height: 13, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    )
    let depth = DepthMap(width: 10, height: 13, fill: 0.2)
    let rig = BindingSynthesizer.makeDepthRig(plan: plan, depthMap: depth)
    #expect(rig.formatVersion == AvatarRig.currentFormatVersion)
    #expect(rig.firstPart(ofKind: .head)?.deformations.contains {
        if case .rotate3D(parameter: .angleX, axis: .y, _, _) = $0 { return true }
        return false
    } == true)
    #expect(rig.firstPart(ofKind: .head)?.deformations.contains {
        if case .perspectiveShift = $0 { return true }
        return false
    } == false)

    let evaluator = DeformationEvaluator3D(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])
    let turned = evaluator.evaluate(parameters: [.angleX: 20])
    let eyeID = try? #require(rig.firstPart(ofKind: .eyeLeft)?.id)
    if let eyeID, let before = rest[eyeID], let after = turned[eyeID] {
        #expect(zip(before, after).contains { abs($0.0.z - $0.1.z) > 0.1 })
    }
}

@Test func depthYawUsesTheBodyTransformedNeckAxisAtZeroDepth() {
    let body = part(
        id: "body",
        rect: CGRect(x: 0, y: 0, width: 100, height: 100),
        deformations: [.translate(parameter: .bodyY, gainX: 0, gainY: -0.1)]
    )
    var head = part(
        id: "head",
        parentID: "body",
        rect: CGRect(x: 25, y: 0, width: 50, height: 50),
        pivot: SIMD2(0.5, 1),
        deformations: [.rotate3D(parameter: .angleX, axis: .y, pivot: SIMD3(0.5, 1, 0), degreesPerUnit: 1)]
    )
    head.kind = .head
    head.mesh.depths = [Float](repeating: 10, count: head.mesh.vertexCount)
    let rig = makeRig(parts: [body, head])
    let evaluator = DeformationEvaluator3D(rig: rig)
    let movedOnly = evaluator.evaluate(parameters: [.bodyY: 1, .angleX: 0])["head"]!
    let movedAndTurned = evaluator.evaluate(parameters: [.bodyY: 1, .angleX: 20])["head"]!
    // The pivot-row vertex is anchored (the rotation tapers to zero at its
    // own row), so the neck seam stays closed through body translation. Away
    // from the taper band the rotation turns with the full angle around an
    // axis whose X/Y rides with the translated body but whose Z remains at
    // the central plane.
    let neckIndex = 7 // 3x3 grid: bottom row, center column
    #expect(simd_distance(movedOnly[neckIndex], movedAndTurned[neckIndex]) < 0.001)
    let topIndex = 1 // 3x3 grid: top row, center column — above the taper band
    let expectedXShift = sin(Float(20) * .pi / 180) * 10 * 0.5 // half parallax strength
    #expect(abs((movedAndTurned[topIndex].x - movedOnly[topIndex].x) - expectedXShift) < 0.001)
    #expect(abs(movedAndTurned[topIndex].y - movedOnly[topIndex].y) < 0.001)
}

@Test func depthRotationTapersToZeroAtThePivotRowSoTheNeckSeamStaysClosed() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
    var head = AvatarPart(
        id: "head",
        kind: .head,
        rect: rect,
        pivot: SIMD2(0.5, 1),
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 2, rows: 8),
        deformations: [
            .rotate3D(
                parameter: .angleX,
                axis: .y,
                pivot: SIMD3(0.5, 1, 0),
                degreesPerUnit: 1
            )
        ]
    )
    // Deep front surface everywhere — the worst case for seam shear.
    head.mesh.depths = [Float](repeating: 75, count: head.mesh.vertexCount)
    let evaluator = DeformationEvaluator3D(rig: makeRig(parts: [head]))
    let rest = evaluator.evaluate(parameters: [:])[head.id]!
    let turned = evaluator.evaluate(parameters: [.angleX: 20])[head.id]!

    // 3 columns x 9 rows, row-major. Center column of the bottom row (y=200,
    // the seam), the row half a band above it (y=150), and the top row.
    let seamCenter = 8 * 3 + 1
    let halfBandCenter = 6 * 3 + 1 // y=150: half of the 100 px (0.5 * height) band
    let topCenter = 1
    #expect(simd_distance(rest[seamCenter], turned[seamCenter]) < 0.001)
    let halfShift = sin(Float(10) * .pi / 180) * 75 * 0.5 // smoothstep(0.5) -> 10 deg, half strength
    #expect(abs((turned[halfBandCenter].x - rest[halfBandCenter].x) - halfShift) < 0.001)
    let fullShift = sin(Float(20) * .pi / 180) * 75 * 0.5 // half parallax strength
    #expect(abs((turned[topCenter].x - rest[topCenter].x) - fullShift) < 0.001)
}

@Test func depthYawDoesNotSlideAZeroDepthSilhouetteWithTheSurfacePivot() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
    var head = AvatarPart(
        id: "head",
        kind: .head,
        rect: rect,
        pivot: SIMD2(0.5, 1),
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 2, rows: 2),
        deformations: [
            .rotate3D(
                parameter: .angleX,
                axis: .y,
                pivot: SIMD3(0.5, 1, 0),
                degreesPerUnit: 1
            )
        ]
    )
    // Reproduce the problematic geometry: the nearest neck surface sample is
    // 60 px in front of the central axis, while the silhouette sample at the
    // same X is Z=0. The old evaluator used Z=60 as the pivot and shifted that
    // silhouette by sin(20°) * -60 = -20.5 px.
    head.mesh.depths = [
        0, 0, 0,
        0, 75, 0,
        0, 60, 0,
    ]
    let evaluator = DeformationEvaluator3D(rig: makeRig(parts: [head]))
    let rest = evaluator.evaluate(parameters: [:])[head.id]!
    let turned = evaluator.evaluate(parameters: [.angleX: 20])[head.id]!

    let topCenter = 1
    #expect(abs(turned[topCenter].x - rest[topCenter].x) < 0.001)

    // The actual front surface still rotates around Z=0; this prevents a fix
    // that merely disables depth motion altogether.
    let faceCenter = 4
    let expectedFaceShift = sin(Float(20) * .pi / 180) * 75 * 0.5 // half parallax strength
    #expect(abs((turned[faceCenter].x - rest[faceCenter].x) - expectedFaceShift) < 0.001)
}

@Test func depthPitchDoesNotSlideAZeroDepthNeckEdgeWithTheSurfacePivot() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
    var head = AvatarPart(
        id: "head",
        kind: .head,
        rect: rect,
        pivot: SIMD2(0.5, 1),
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 2, rows: 2),
        deformations: [
            .rotate3D(
                parameter: .angleY,
                axis: .x,
                pivot: SIMD3(0.5, 1, 0),
                degreesPerUnit: 1
            )
        ]
    )
    head.mesh.depths = [
        0, 0, 0,
        0, 75, 0,
        0, 60, 0,
    ]
    let evaluator = DeformationEvaluator3D(rig: makeRig(parts: [head]))
    let rest = evaluator.evaluate(parameters: [:])[head.id]!
    let pitched = evaluator.evaluate(parameters: [.angleY: 20])[head.id]!

    // Bottom-left lies on the central Z plane at the pivot's Y. A surface-Z
    // pivot would move it vertically by about 20.5 px; the central axis does not.
    let neckEdge = 6
    #expect(abs(pitched[neckEdge].y - rest[neckEdge].y) < 0.001)
}

@Test func depthRigUsesTheExplicitSideWidthScale() {
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 20, y: 10, width: 60, height: 60),
            eyeLeftRect: .zero, eyeRightRect: .zero, mouthRect: .zero, confidence: 1
        ),
        subjectMask: FloatPlane(width: 10, height: 10, fill: 1),
        imageWidth: 100,
        imageHeight: 100
    )
    let rig = BindingSynthesizer.makeDepthRig(
        plan: plan,
        depthMap: DepthMap(width: 10, height: 10, fill: 0.25),
        depthScalePixels: 200
    )
    let depths = rig.firstPart(ofKind: .head)!.mesh.depths
    #expect(depths.allSatisfy { abs($0 - 50) < 0.001 })
}

@Test func depthRigCapsFacialDepthAtFaceScaleWithoutFlatteningTheBody() throws {
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 20, y: 10, width: 160, height: 160),
            eyeLeftRect: CGRect(x: 55, y: 70, width: 24, height: 14),
            eyeRightRect: CGRect(x: 121, y: 70, width: 24, height: 14),
            mouthRect: CGRect(x: 88, y: 125, width: 24, height: 12),
            confidence: 1
        ),
        subjectMask: FloatPlane(width: 10, height: 13, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    )
    let cap = BindingSynthesizer.recommendedHeadDepthCap(plan: plan)
    let rig = BindingSynthesizer.makeDepthRig(
        plan: plan,
        depthMap: DepthMap(width: 10, height: 13, fill: 0.25),
        depthScalePixels: 500,
        maximumHeadDepthPixels: cap
    )

    #expect(abs(cap - 64) < 0.001)
    for kind in [PartKind.head, .eyeLeft, .eyeRight, .mouth] {
        let depths = try #require(rig.firstPart(ofKind: kind)).mesh.depths
        #expect(depths.allSatisfy { abs($0 - cap) < 0.001 })
    }
    let bodyDepths = try #require(rig.firstPart(ofKind: .body)).mesh.depths
    #expect(bodyDepths.allSatisfy { abs($0 - 125) < 0.001 })
}

@Test func depthPitchPinsCrownAndSideEdgesWhileMovingTheFaceAsOneShallowPlate() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
    var head = AvatarPart(
        id: "head",
        kind: .head,
        rect: rect,
        pivot: SIMD2(0.5, 1),
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 2, rows: 2),
        deformations: [
            .rotate3D(
                parameter: .angleY,
                axis: .x,
                pivot: SIMD3(0.5, 1, 0),
                degreesPerUnit: 1
            )
        ]
    )
    // Reconstruct the long-hair failure mode: silhouette vertices have Z=0,
    // while the face center is implausibly deep. Pitch should use one bounded
    // plate displacement; yaw intentionally continues using these raw depths.
    head.mesh.depths = [
        0, 150, 0,
        0, 150, 0,
        0, 150, 0,
    ]
    let evaluator = DeformationEvaluator3D(rig: makeRig(parts: [head]))
    let rest = evaluator.evaluate(parameters: [:])[head.id]!
    let pitched = evaluator.evaluate(parameters: [.angleY: 6])[head.id]!
    let crownCenterShift = pitched[1].y - rest[1].y
    let sideCenterShift = pitched[3].y - rest[3].y
    let faceCenterShift = pitched[4].y - rest[4].y

    #expect(abs(crownCenterShift) < 0.001)
    #expect(abs(sideCenterShift) < 0.001)
    #expect(abs(faceCenterShift) > 2)
}

@Test func productionDepthRigPositivePitchMovesTheFaceUp() {
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 20, y: 10, width: 160, height: 160),
            eyeLeftRect: CGRect(x: 55, y: 70, width: 24, height: 14),
            eyeRightRect: CGRect(x: 121, y: 70, width: 24, height: 14),
            mouthRect: CGRect(x: 88, y: 125, width: 24, height: 12),
            confidence: 1
        ),
        subjectMask: FloatPlane(width: 10, height: 13, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    )
    let rig = BindingSynthesizer.makeDepthRig(
        plan: plan,
        depthMap: DepthMap(width: 10, height: 13, fill: 0.25),
        depthScalePixels: 200
    )
    let head = rig.firstPart(ofKind: .head)!
    #expect(head.deformations.contains {
        if case .rotate3D(parameter: .angleY, axis: .x, _, degreesPerUnit: 1) = $0 { return true }
        return false
    })
    let evaluator = DeformationEvaluator3D(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])[head.id]!
    let pitched = evaluator.evaluate(parameters: [.angleY: 16])[head.id]!
    let target = SIMD2(Float(head.rect.midX), Float(head.rect.minY + head.rect.height * 0.25))
    let index = head.mesh.vertices.indices.min {
        simd_distance_squared(head.mesh.vertices[$0], target)
            < simd_distance_squared(head.mesh.vertices[$1], target)
    }!
    #expect(pitched[index].y < rest[index].y)
}

@Test func productionDepthPitchPreservesFaceFeatureSpacing() throws {
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 20, y: 10, width: 160, height: 160),
            eyeLeftRect: CGRect(x: 55, y: 70, width: 24, height: 14),
            eyeRightRect: CGRect(x: 121, y: 70, width: 24, height: 14),
            mouthRect: CGRect(x: 88, y: 125, width: 24, height: 12),
            confidence: 1
        ),
        subjectMask: FloatPlane(width: 10, height: 13, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    )
    let rig = BindingSynthesizer.makeDepthRig(
        plan: plan,
        depthMap: DepthMap(width: 10, height: 13, fill: 0.25),
        depthScalePixels: 200
    )
    let leftEye = try #require(rig.firstPart(ofKind: .eyeLeft))
    let rightEye = try #require(rig.firstPart(ofKind: .eyeRight))
    let mouth = try #require(rig.firstPart(ofKind: .mouth))
    let evaluator = DeformationEvaluator3D(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])
    let lookingDown = evaluator.evaluate(parameters: [.angleY: -6])

    func centerY(_ vertices: [SIMD3<Float>]) -> Float {
        vertices.map(\.y).reduce(0, +) / Float(vertices.count)
    }
    func eyeLine(in frame: [String: [SIMD3<Float>]]) -> Float {
        (centerY(frame[leftEye.id]!) + centerY(frame[rightEye.id]!)) * 0.5
    }

    let restEyeY = eyeLine(in: rest)
    let restMouthY = centerY(rest[mouth.id]!)
    let pitchedEyeY = eyeLine(in: lookingDown)
    let pitchedMouthY = centerY(lookingDown[mouth.id]!)
    let restSpacing = restMouthY - restEyeY
    let pitchedSpacing = pitchedMouthY - pitchedEyeY

    // The depth cue must remain visible, but the face must move as a coherent
    // band. A height-dependent angle across the eyes and mouth reads as the
    // face being vertically squashed rather than nodding.
    #expect(pitchedEyeY - restEyeY > 2)
    #expect(abs(pitchedSpacing / restSpacing - 1) < 0.01)
}

@Test func depthFeatureCardsStayBoundToTheEvaluatedHeadSurface() throws {
    let headRect = CGRect(x: 0, y: 0, width: 200, height: 200)
    var head = AvatarPart(
        id: "head",
        kind: .head,
        rect: headRect,
        pivot: SIMD2(0.5, 1),
        zOrder: 0,
        mesh: .grid(rect: headRect, columns: 2, rows: 2),
        deformations: [
            .rotate3D(
                parameter: .angleX,
                axis: .y,
                pivot: SIMD3(0.5, 1, 0),
                degreesPerUnit: 1
            ),
            .rotate3D(
                parameter: .angleY,
                axis: .x,
                pivot: SIMD3(0.5, 1, 0),
                degreesPerUnit: 1
            ),
        ]
    )
    head.mesh.depths = [
        0, 80, 0,
        0, 80, 0,
        0, 0, 0,
    ]
    var eye = AvatarPart(
        id: "eye",
        kind: .eyeLeft,
        parentID: head.id,
        rect: CGRect(x: 40, y: 70, width: 40, height: 20),
        pivot: SIMD2(0.5, 0.5),
        zOrder: 1,
        mesh: .grid(rect: CGRect(x: 40, y: 70, width: 40, height: 20), columns: 2, rows: 2),
        deformations: []
    )
    // Reproduce an independently sampled feature card disagreeing with the
    // coarser head grid. The evaluator must not rotate this depth separately.
    eye.mesh.depths = [Float](repeating: 180, count: eye.mesh.vertexCount)
    let rig = makeRig(parts: [head, eye])
    let evaluated = DeformationEvaluator3D(rig: rig).evaluate(parameters: [
        .angleX: 20,
        .angleY: 6,
    ])
    let headVertices = try #require(evaluated[head.id])
    let eyeVertices = try #require(evaluated[eye.id])

    func sampleHead(at point: SIMD2<Float>) -> SIMD3<Float> {
        let gridX = point.x / 100
        let gridY = point.y / 100
        let column0 = min(1, Int(gridX.rounded(.down)))
        let row0 = min(1, Int(gridY.rounded(.down)))
        let tx = gridX - Float(column0)
        let ty = gridY - Float(row0)
        let stride = 3
        let topLeft = headVertices[row0 * stride + column0]
        let topRight = headVertices[row0 * stride + column0 + 1]
        let bottomLeft = headVertices[(row0 + 1) * stride + column0]
        let bottomRight = headVertices[(row0 + 1) * stride + column0 + 1]
        let top = topLeft + (topRight - topLeft) * tx
        let bottom = bottomLeft + (bottomRight - bottomLeft) * tx
        return top + (bottom - top) * ty
    }

    for (rest, featureVertex) in zip(eye.mesh.vertices, eyeVertices) {
        #expect(simd_distance(featureVertex, sampleHead(at: rest)) < 0.001)
    }
}

@Test func productionDepthRigCombinedTurnKeepsFiniteVerticesAndAClosedNeckSeam() {
    let plan = PartPlanner.plan(
        layout: FaceLayout(
            headRect: CGRect(x: 20, y: 10, width: 160, height: 160),
            eyeLeftRect: CGRect(x: 55, y: 70, width: 24, height: 14),
            eyeRightRect: CGRect(x: 121, y: 70, width: 24, height: 14),
            mouthRect: CGRect(x: 88, y: 125, width: 24, height: 12),
            confidence: 1
        ),
        subjectMask: FloatPlane(width: 10, height: 13, fill: 1),
        imageWidth: 200,
        imageHeight: 260
    )
    let rig = BindingSynthesizer.makeDepthRig(
        plan: plan,
        depthMap: DepthMap(width: 10, height: 13, fill: 0.25),
        depthScalePixels: 200
    )
    let head = rig.firstPart(ofKind: .head)!
    let evaluator = DeformationEvaluator3D(rig: rig)
    let rest = evaluator.evaluate(parameters: [:])[head.id]!

    for yaw in [-20 as Float, 20] {
        for pitch in [-16 as Float, 16] {
            let evaluated = evaluator.evaluate(parameters: [.angleX: yaw, .angleY: pitch])
            #expect(evaluated.values.flatMap { $0 }.allSatisfy {
                $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
            })

            // The last mesh row sits below the 98%-height rotation pivot. Both
            // axes therefore have zero taper weight there, keeping the head/body
            // seam exactly at its rest position even at stress-test angles
            // beyond the public Quality pitch range.
            for index in head.mesh.vertices.indices where
                abs(head.mesh.vertices[index].y - Float(head.rect.maxY)) < 0.001
            {
                #expect(simd_distance(evaluated[head.id]![index], rest[index]) < 0.001)
            }
        }
    }
}

@Test func warpKeyformsKeepSparseFallbacksForShortOffsetArraysAndAdditiveOperations() {
    let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
    let mesh = DeformableMesh.grid(rect: rect, columns: 1, rows: 1)
    func key(_ x: Float, _ y: Float, _ offset: SIMD2<Float>, count: Int = 4) -> WarpKeyformKey {
        WarpKeyformKey(parameterXValue: x, parameterYValue: y,
                       vertexOffsets: Array(repeating: offset, count: count))
    }
    let part = AvatarPart(id: "ragged", kind: .mouth, rect: rect, zOrder: 0, mesh: mesh,
        deformations: [
            .warpKeyform(parameterX: .mouthOpen, parameterY: .mouthForm, keys: [
                key(0, -1, .zero), key(1, -1, SIMD2(10, 0), count: 2),
                key(0, 1, SIMD2(0, 20)), key(1, 1, SIMD2(10, 20)),
                key(0.5, 0, SIMD2(99, 99), count: 0),
            ]),
            .warpKeyform(parameterX: .mouthOpen, parameterY: .mouthForm,
                         keys: [key(0, 0, SIMD2(2, -3))]),
        ])
    let evaluator = DeformationEvaluator(rig: AvatarRig(imageWidth: 10, imageHeight: 10,
        parts: [part], parameters: StandardParameters.all))
    let result = evaluator.evaluate(parameters: [.mouthOpen: 0.5, .mouthForm: 0])["ragged"]!
    // The complete corners interpolate normally. Later vertices lack one
    // corner, so the existing nearest-key fallback supplies that corner.
    for index in mesh.vertices.indices {
        let expected = index < 2 ? SIMD2<Float>(7, 7) : SIMD2<Float>(4.5, 7)
        #expect(simd_distance(result[index], mesh.vertices[index] + expected) < 0.0001)
    }
}
