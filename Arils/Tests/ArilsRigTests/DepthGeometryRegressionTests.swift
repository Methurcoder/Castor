import CoreGraphics
import Foundation
import simd
import Testing

import ArilsCore
@testable import ArilsRig

private func depthGeometryRig(parts: [AvatarPart]) -> AvatarRig {
    AvatarRig(
        imageWidth: 200,
        imageHeight: 200,
        parts: parts,
        parameters: StandardParameters.all
    )
}

@Test func depthYawPreservesSilhouetteWidthWithoutFlatteningDepthParallax() throws {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
    var head = AvatarPart(
        id: "head",
        kind: .head,
        rect: rect,
        pivot: SIMD2(0.5, 0.98),
        zOrder: 0,
        mesh: .grid(rect: rect, columns: 2, rows: 4),
        deformations: [
            .rotate3D(
                parameter: .angleX,
                axis: .y,
                pivot: SIMD3(0.5, 0.98, 0),
                degreesPerUnit: 1
            ),
        ]
    )
    // The two outer samples model the zero-depth silhouette ribbon. The
    // centre remains in front so the test also fixes the intended parallax
    // instead of allowing a solution that simply disables yaw.
    head.mesh.depths = (0...4).flatMap { _ in [Float(0), 60, 0] }

    let evaluator = DeformationEvaluator3D(rig: depthGeometryRig(parts: [head]))
    let rest = try #require(evaluator.evaluate(parameters: [:])[head.id])
    let leftIndex = 0
    let faceIndex = 1
    let rightIndex = 2
    let restWidth = rest[rightIndex].x - rest[leftIndex].x

    for yaw in [-20 as Float, -10, 10, 20] {
        let turned = try #require(
            evaluator.evaluate(parameters: [.angleX: yaw])[head.id]
        )
        let turnedWidth = turned[rightIndex].x - turned[leftIndex].x
        #expect(abs(turnedWidth - restWidth) < 0.001)

        let radians = yaw * .pi / 180
        let expectedParallax = sin(radians)
            * head.mesh.depths[faceIndex]
            * SupportedHeadPose.rotationParallaxStrength
        #expect(abs((turned[faceIndex].x - rest[faceIndex].x) - expectedParallax) < 0.001)
    }
}

@Test func faceAwareDepthUsesCurvedHeadOwnershipAtTheRectBoundary() {
    let width = 80
    let height = 80
    let mask = FloatPlane(width: width, height: height, fill: 1)
    var source = Bitmap(width: width, height: height)
    for y in 0..<height {
        for x in 0..<width {
            source.setRGBA(x: x, y: y, SIMD4(0.88, 0.72, 0.64, 1))
        }
    }
    let plan = PartPlan(
        imageWidth: width,
        imageHeight: height,
        subjectRect: CGRect(x: 0, y: 0, width: width, height: height),
        headRect: CGRect(x: 16, y: 8, width: 48, height: 56),
        eyeLeftRect: CGRect(x: 27, y: 28, width: 8, height: 6),
        eyeRightRect: CGRect(x: 45, y: 28, width: 8, height: 6),
        mouthRect: CGRect(x: 36, y: 48, width: 8, height: 4),
        collarHeight: 8
    )
    let thickness = ThicknessProfile(rows: [Float](repeating: 1, count: height))
    let baseline = SilhouetteDepthEstimator()
        .estimate(frontMask: mask, sideThickness: thickness)
    let depth = FaceAwareRibbonDepthEstimator()
        .estimate(frontMask: mask, sideThickness: thickness, plan: plan, source: source)
    let profile = HeadRegionProfile(plan: plan)
    let y = 42
    let edgeX = Int(plan.headRect.minX)
    let transitionX = edgeX + 1
    let interiorX = edgeX + 2

    #expect(profile.ownershipWeight(x: CGFloat(edgeX), y: CGFloat(y)) == 0)
    let transitionOwnership = profile.ownershipWeight(
        x: CGFloat(transitionX),
        y: CGFloat(y)
    )
    #expect(transitionOwnership > 0 && transitionOwnership < 1)
    // A zero-owned pixel stays on the row-ellipse body surface. One pixel
    // inward is a genuine blend, and only the fully owned interior reaches
    // the semantic face depth. This prevents a Z step on the rectangular edge.
    #expect(abs(depth[edgeX, y] - baseline[edgeX, y]) < 0.000_001)
    #expect(depth[transitionX, y] < baseline[transitionX, y] - 0.01)
    #expect(depth[transitionX, y] > depth[interiorX, y] + 0.01)

    let centerX = Int(plan.headRect.midX)
    let lowerOutsideY = Int(profile.lowerBoundaryY(at: CGFloat(centerX)))
    let lowerTransitionY = lowerOutsideY - 1
    let lowerInteriorY = lowerOutsideY - 2
    let lowerOwnership = profile.ownershipWeight(
        x: CGFloat(centerX),
        y: CGFloat(lowerTransitionY)
    )
    #expect(lowerOwnership > 0 && lowerOwnership < 1)
    #expect(abs(depth[centerX, lowerOutsideY] - baseline[centerX, lowerOutsideY]) < 0.000_001)
    #expect(depth[centerX, lowerTransitionY] < baseline[centerX, lowerTransitionY] - 0.01)
    #expect(depth[centerX, lowerTransitionY] > depth[centerX, lowerInteriorY] + 0.01)
}

@Test func depthOwnershipFeatherSurvivesA4KSourceOnA256PixelGrid() {
    let sourceWidth = 4096
    let sourceHeight = 4096
    let depthWidth = 256
    let depthHeight = 256
    let plan = PartPlan(
        imageWidth: sourceWidth,
        imageHeight: sourceHeight,
        subjectRect: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
        // Deliberately keep the edge off the analysis-grid sample positions.
        headRect: CGRect(x: 517.3, y: 401.7, width: 2_600, height: 2_700),
        eyeLeftRect: CGRect(x: 1_220, y: 1_250, width: 220, height: 150),
        eyeRightRect: CGRect(x: 2_050, y: 1_250, width: 220, height: 150),
        mouthRect: CGRect(x: 1_570, y: 2_050, width: 310, height: 130),
        collarHeight: 180
    )
    let profile = FaceAwareRibbonDepthEstimator.depthOwnershipProfile(
        plan: plan,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        depthWidth: depthWidth,
        depthHeight: depthHeight
    )
    let sampleStepX = CGFloat(sourceWidth - 1) / CGFloat(depthWidth - 1)
    let sampleStepY = CGFloat(sourceHeight - 1) / CGFloat(depthHeight - 1)

    #expect(profile.horizontalFeather >= sampleStepX * 2)
    #expect(profile.lowerFeather >= sampleStepY * 2)

    let interiorY = plan.headRect.midY
    let horizontalSamples = (0..<depthWidth).map { x in
        profile.ownershipWeight(x: CGFloat(x) * sampleStepX, y: interiorY)
    }
    #expect(horizontalSamples.filter { $0 > 0 && $0 < 1 }.count >= 2)

    let centerX = plan.headRect.midX
    let verticalSamples = (0..<depthHeight).map { y in
        profile.ownershipWeight(x: centerX, y: CGFloat(y) * sampleStepY)
    }
    #expect(verticalSamples.filter { $0 > 0 && $0 < 1 }.count >= 2)

    // Exact grid alignment is the worst case: it can reduce a two-interval
    // transition to one fractional sample per boundary, but must never return
    // to the old all-zero/all-one switch.
    var alignedPlan = plan
    alignedPlan.headRect = CGRect(
        x: sampleStepX * 32,
        y: sampleStepY * 25,
        width: sampleStepX * 160,
        height: sampleStepY * 165
    )
    let alignedProfile = FaceAwareRibbonDepthEstimator.depthOwnershipProfile(
        plan: alignedPlan,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        depthWidth: depthWidth,
        depthHeight: depthHeight
    )
    let alignedHorizontal = (0..<depthWidth).map { x in
        alignedProfile.ownershipWeight(
            x: CGFloat(x) * sampleStepX,
            y: alignedPlan.headRect.midY
        )
    }
    #expect(alignedHorizontal.filter { $0 > 0 && $0 < 1 }.count >= 2)
    let alignedVertical = (0..<depthHeight).map { y in
        alignedProfile.ownershipWeight(
            x: alignedPlan.headRect.midX,
            y: CGFloat(y) * sampleStepY
        )
    }
    #expect(alignedVertical.contains { $0 > 0 && $0 < 1 })
}
