import XCTest
import Arils
import ImageIO
import simd
import UniformTypeIdentifiers
@testable import ArilsEx

final class ArilsExTests: XCTestCase {
    private func admissionImage(reachesBottom: Bool = true) -> CGImage {
        var bitmap = Bitmap(width: 100, height: 100)
        let maximumY = reachesBottom ? 100 : 90
        for y in 5..<maximumY {
            for x in 20..<80 {
                bitmap.setRGBA(x: x, y: y, SIMD4(0.8, 0.7, 0.6, 1))
            }
        }
        return bitmap.cgImage()!
    }

    private func admittedPose() -> ReferencePose {
        let points: [JointKind: SIMD2<Float>] = [
            .neck: SIMD2(0.50, 0.22),
            .leftShoulder: SIMD2(0.35, 0.30),
            .rightShoulder: SIMD2(0.65, 0.30),
            .leftElbow: SIMD2(0.28, 0.48),
            .rightElbow: SIMD2(0.72, 0.48),
            .leftWrist: SIMD2(0.25, 0.68),
            .rightWrist: SIMD2(0.75, 0.68),
        ]
        return ReferencePose(
            role: .front,
            fileName: "front.png",
            joints: points.mapValues {
                JointObservation(position: $0, confidence: 0.9, source: .user)
            }
        )
    }

    func testObservationClampsInvalidAndOutOfRangeCoordinates() {
        let clamped = JointObservation(
            position: SIMD2(-0.4, 1.8),
            confidence: 2,
            source: .vision
        )
        XCTAssertEqual(clamped.position, SIMD2(0, 1))
        XCTAssertEqual(clamped.confidence, 1)

        let invalid = JointObservation(
            position: SIMD2(.nan, .infinity),
            confidence: .nan,
            source: .vision
        )
        XCTAssertEqual(invalid.position, SIMD2(0.5, 0.5))
        XCTAssertEqual(invalid.confidence, 0)
    }

    func testLegacyObservationWithoutVisibilityDecodesAsVisible() throws {
        struct LegacyObservation: Encodable {
            var position: SIMD2<Float>
            var confidence: Float
            var source: JointObservationSource
        }
        let data = try JSONEncoder().encode(LegacyObservation(
            position: SIMD2(0.3, 0.4),
            confidence: 0.8,
            source: .vision
        ))
        let decoded = try JSONDecoder().decode(JointObservation.self, from: data)
        XCTAssertEqual(decoded.visibility, .visible)
        XCTAssertEqual(decoded.visibilitySource, .legacy)
    }

    func testVisibilityReviewDoesNotInflatePositionConfidence() {
        var pose = ReferencePose(role: .right, fileName: "right.png")
        pose[.rightWrist] = JointObservation(
            position: SIMD2(0.7, 0.6),
            confidence: 0.22,
            source: .silhouetteTemplate,
            visibility: .unknown,
            visibilitySource: .topology
        )
        pose.setUserVisibility(.visible, for: .rightWrist)
        XCTAssertEqual(pose[.rightWrist]?.confidence, 0.22)
        XCTAssertEqual(pose[.rightWrist]?.source, .silhouetteTemplate)
        XCTAssertEqual(pose[.rightWrist]?.visibilitySource, .user)
    }

    func testCrossViewPositionNeedsReviewEvenWhenVisibilityIsConfirmed() {
        var pose = admittedPose()
        pose[.rightWrist] = JointObservation(
            position: SIMD2(0.75, 0.68),
            confidence: 0.55,
            source: .crossViewConsensus,
            visibility: .visible,
            visibilitySource: .user
        )
        let result = PoseAdmission.evaluate(pose: pose, image: admissionImage())
        XCTAssertTrue(result.issues.contains(.jointPositionUnverified(.rightWrist)))
    }

    func testConsensusFillsMissingJointWithoutReplacingUserEdit() {
        var front = ReferencePose(role: .front, fileName: "front.png")
        front.setUserPosition(SIMD2(0.42, 0.31), for: .neck)

        var left = ReferencePose(role: .left, fileName: "left.png")
        left[.neck] = JointObservation(
            position: SIMD2(0.48, 0.28),
            confidence: 0.8,
            source: .vision
        )
        var right = ReferencePose(role: .right, fileName: "right.png")
        right[.neck] = JointObservation(
            position: SIMD2(0.52, 0.30),
            confidence: 0.6,
            source: .vision
        )

        let result = ThreeViewJointConsensus.reconcile([left, front, right])
        let outputFront = try! XCTUnwrap(result.poses.first { $0.role == .front })
        let outputLeft = try! XCTUnwrap(result.poses.first { $0.role == .left })
        XCTAssertEqual(outputFront[.neck]?.position, SIMD2(0.42, 0.31))
        XCTAssertEqual(outputFront[.neck]?.source, .user)
        XCTAssertEqual(outputLeft[.neck]?.position, SIMD2(0.48, 0.28))

        // A point absent from only one view is copied conservatively from the
        // other two rather than guessed with full confidence.
        left[.pelvis] = JointObservation(position: SIMD2(0.49, 0.58), confidence: 0.8, source: .vision)
        right[.pelvis] = JointObservation(position: SIMD2(0.51, 0.60), confidence: 0.6, source: .vision)
        let completed = ThreeViewJointConsensus.reconcile([left, front, right])
        let completedFront = try! XCTUnwrap(completed.poses.first { $0.role == .front })
        XCTAssertEqual(completedFront[.pelvis]?.position.x ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(completedFront[.pelvis]?.position.y ?? 0, 0.59, accuracy: 0.0001)
        XCTAssertEqual(completedFront[.pelvis]?.source, .crossViewConsensus)
        XCTAssertLessThan(completedFront[.pelvis]?.confidence ?? 1, 0.55)
    }

    func testConsensusReportsAbsentView() {
        let result = ThreeViewJointConsensus.reconcile([
            ReferencePose(role: .front, fileName: "front.png")
        ])
        XCTAssertTrue(result.warnings.contains(.missingReference(.left)))
        XCTAssertTrue(result.warnings.contains(.missingReference(.right)))
    }

    func testBlendUsesAuthoredSideOnly() {
        XCTAssertEqual(
            ThreeViewBlend.weights(for: -0.75),
            ThreeViewBlendWeights(left: 0.75, front: 0.25, right: 0)
        )
        XCTAssertEqual(
            ThreeViewBlend.weights(for: 0.4),
            ThreeViewBlendWeights(left: 0, front: 0.6, right: 0.4)
        )
        XCTAssertEqual(
            ThreeViewBlend.weights(for: .nan),
            ThreeViewBlendWeights(left: 0, front: 1, right: 0)
        )
    }

    func testTemplateDistinguishesFrontAndSideSpread() {
        let bounds = CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)
        let front = JointProposalEngine.templatePose(role: .front, fileName: "front.png", bounds: bounds)
        let side = JointProposalEngine.templatePose(role: .left, fileName: "left.png", bounds: bounds)
        let frontSpread = abs(
            (front[.rightShoulder]?.position.x ?? 0) - (front[.leftShoulder]?.position.x ?? 0)
        )
        let sideSpread = abs(
            (side[.rightShoulder]?.position.x ?? 0) - (side[.leftShoulder]?.position.x ?? 0)
        )
        XCTAssertGreaterThan(frontSpread, sideSpread)
        XCTAssertTrue(side.joints.values.allSatisfy { $0.visibility == .unknown })
    }

    func testOcclusionTopologyInfersWeakFarArmWithoutErasingPosition() throws {
        var pose = admittedPose()
        pose.role = .right
        for joint in OcclusionTopology.armJoints(.right) {
            let point = try XCTUnwrap(pose[joint]?.position)
            pose[joint] = JointObservation(
                position: point,
                confidence: 0.82,
                source: .vision,
                visibility: .visible
            )
        }
        let originalLeftWrist = try XCTUnwrap(pose[.leftWrist]?.position)
        for joint in OcclusionTopology.armJoints(.left) {
            let point = try XCTUnwrap(pose[joint]?.position)
            pose[joint] = JointObservation(
                position: point,
                confidence: 0.22,
                source: .silhouetteTemplate,
                visibility: .unknown
            )
        }

        let result = OcclusionTopology.resolve([pose])
        let resolved = try XCTUnwrap(result.pose(for: .right))
        XCTAssertTrue(OcclusionTopology.armJoints(.left).allSatisfy {
            resolved[$0]?.visibility == .occluded
        })
        XCTAssertEqual(resolved[.leftWrist]?.position, originalLeftWrist)
        XCTAssertEqual(result.decisions.count, 1)
        XCTAssertEqual(result.decisions.first?.basis, .asymmetricVisionEvidence)

        let audit = VisibilityAuditMetrics(
            pose: resolved,
            joints: JointScope.bustUp.joints
        )
        XCTAssertEqual(audit.occludedJointCount, 3)
        XCTAssertEqual(audit.preventedTextureSeedCount, 3)
    }

    func testConsensusRefinesOccludedPositionButDoesNotInventTexture() throws {
        var front = admittedPose()
        var side = admittedPose()
        side.role = .right
        side.fileName = "right.png"
        for joint in OcclusionTopology.armJoints(.right) {
            var observation = try XCTUnwrap(side[joint])
            observation.source = .vision
            observation.visibility = .visible
            side[joint] = observation
        }
        for joint in OcclusionTopology.armJoints(.left) {
            var observation = try XCTUnwrap(side[joint])
            observation.position = SIMD2(0.5, 0.5)
            observation.confidence = 0.22
            observation.source = .silhouetteTemplate
            observation.visibility = .unknown
            side[joint] = observation
        }
        front.setUserPosition(SIMD2(0.23, 0.67), for: .leftWrist)

        let result = ThreeViewJointConsensus.reconcile([front, side])
        let resolved = try XCTUnwrap(result.poses.first { $0.role == .right })
        XCTAssertEqual(resolved[.leftWrist]?.position, SIMD2(0.23, 0.67))
        XCTAssertEqual(resolved[.leftWrist]?.source, .crossViewConsensus)
        XCTAssertEqual(resolved[.leftWrist]?.visibility, .occluded)
    }

    func testBustUpScopeContainsExactlyTheSevenArticulatedUpperBodyJoints() {
        XCTAssertEqual(JointScope.bustUp.joints.count, 7)
        XCTAssertTrue(JointScope.bustUp.joints.contains(.neck))
        XCTAssertTrue(JointScope.bustUp.joints.contains(.leftWrist))
        XCTAssertFalse(JointScope.bustUp.joints.contains(.head))
        XCTAssertFalse(JointScope.bustUp.joints.contains(.pelvis))
    }

    func testPoseAdmissionAcceptsVisibleUncrossedBustUpPose() {
        let result = PoseAdmission.evaluate(
            pose: admittedPose(),
            image: admissionImage()
        )
        XCTAssertTrue(result.isAdmitted)
    }

    func testPoseAdmissionRejectsCrossedArmAndMissingBottomContact() {
        var pose = admittedPose()
        pose.setUserPosition(SIMD2(0.58, 0.50), for: .leftElbow)
        pose.setUserPosition(SIMD2(0.68, 0.66), for: .leftWrist)
        let result = PoseAdmission.evaluate(
            pose: pose,
            image: admissionImage(reachesBottom: false)
        )
        XCTAssertTrue(result.issues.contains(.armIntersectsTorso(side: .left)))
        XCTAssertTrue(result.issues.contains(.subjectDoesNotReachBottom))
    }

    func testPoseAdmissionRejectsLowConfidenceRequiredJoint() {
        var pose = admittedPose()
        pose[.neck] = JointObservation(
            position: SIMD2(0.5, 0.22),
            confidence: 0.2,
            source: .vision
        )
        let result = PoseAdmission.evaluate(pose: pose, image: admissionImage())
        XCTAssertTrue(result.issues.contains(.jointPositionUnverified(.neck)))
    }

    func testSideAdmissionAllowsOccludedFarArmButFrontDoesNot() {
        var side = admittedPose()
        side.role = .right
        for joint in OcclusionTopology.armJoints(.left) {
            side.setUserVisibility(.occluded, for: joint)
        }
        let sideResult = PoseAdmission.evaluate(
            pose: side,
            image: admissionImage()
        )
        XCTAssertTrue(sideResult.isAdmitted)

        side.role = .front
        let frontResult = PoseAdmission.evaluate(
            pose: side,
            image: admissionImage()
        )
        XCTAssertFalse(frontResult.isAdmitted)
        XCTAssertTrue(frontResult.issues.contains(.jointNotVisible(.leftWrist)))
    }

    func testAdmissionUsesSubjectMaskInsteadOfOpaqueBackgroundAlpha() {
        var pose = admittedPose()
        pose.setUserPosition(SIMD2(0.95, 0.68), for: .leftWrist)
        var subjectMask = FloatPlane(width: 100, height: 100)
        for y in 5..<100 {
            for x in 20..<80 {
                subjectMask[x, y] = 1
            }
        }
        let result = PoseAdmission.evaluate(
            pose: pose,
            subjectMask: subjectMask
        )
        XCTAssertTrue(result.issues.contains(.jointNotVisible(.leftWrist)))
    }

    func testSynchronousAdmissionRejectsFullyOpaqueAlphaAsVisibilityEvidence() {
        var opaque = Bitmap(width: 100, height: 100)
        for y in 0..<100 {
            for x in 0..<100 {
                opaque.setRGBA(x: x, y: y, SIMD4(1, 1, 1, 1))
            }
        }
        let result = PoseAdmission.evaluate(
            pose: admittedPose(),
            image: opaque.cgImage()!
        )
        XCTAssertFalse(result.isAdmitted)
        XCTAssertTrue(result.issues.contains(.jointVisibilityUnresolved(.neck)))
    }

    func testArticulationCompilerProducesFourMaskedPartsAndTwoBoneWeights() async throws {
        let compiler = ArticulationCompiler(
            maskProviders: [AlphaSubjectMaskProvider()],
            integrityThresholds: RigIntegrityThresholds(
                maximumMeshInversionCount: 100,
                maximumHoleArea: 1,
                maximumGhostArea: 1,
                maximumUnknownExposure: 1
            )
        )
        let archive = try await compiler.compile(
            image: admissionImage(),
            pose: admittedPose()
        )

        XCTAssertEqual(archive.parts.count, 4)
        XCTAssertTrue(archive.integrityAccepted)
        XCTAssertFalse(archive.baseTexturePNG.isEmpty)
        for part in archive.parts {
            XCTAssertEqual(part.mesh.vertexCount, part.weights.count)
            XCTAssertTrue(part.weights.contains { $0.secondaryWeight > 0 })
            XCTAssertFalse(part.texturePNG.isEmpty)
        }
    }

    func testArticulationCompilerOmitsOccludedArmInsteadOfCuttingFalseTexture() async throws {
        var pose = admittedPose()
        pose.role = .right
        for joint in OcclusionTopology.armJoints(.left) {
            pose.setUserVisibility(.occluded, for: joint)
        }
        let compiler = ArticulationCompiler(
            maskProviders: [AlphaSubjectMaskProvider()],
            integrityThresholds: RigIntegrityThresholds(
                maximumMeshInversionCount: 100,
                maximumHoleArea: 1,
                maximumGhostArea: 1,
                maximumUnknownExposure: 1
            )
        )
        let archive = try await compiler.compile(
            image: admissionImage(),
            pose: pose
        )

        XCTAssertEqual(Set(archive.parts.map(\.id)), Set([
            ArticulationPartID.rightUpperArm,
            ArticulationPartID.rightForearm,
        ]))
        XCTAssertEqual(archive.omittedParts?[.leftUpperArm], .occluded)
        XCTAssertEqual(archive.omittedParts?[.leftForearm], .occluded)
    }

    func testArticulationEvaluatorBendsForearmAroundElbow() async throws {
        let compiler = ArticulationCompiler(
            maskProviders: [AlphaSubjectMaskProvider()],
            integrityThresholds: RigIntegrityThresholds(
                maximumMeshInversionCount: 100,
                maximumHoleArea: 1,
                maximumGhostArea: 1,
                maximumUnknownExposure: 1
            )
        )
        let archive = try await compiler.compile(
            image: admissionImage(),
            pose: admittedPose()
        )
        let evaluator = ArticulationEvaluator(rig: archive)
        let rest = evaluator.evaluate(parameters: ArticulationPoseParameters())
        let bent = evaluator.evaluate(parameters: ArticulationPoseParameters(
            jointRotations: [.leftElbow: 30]
        ))
        let forearm = try XCTUnwrap(
            archive.parts.first { $0.id == .leftForearm }
        )
        let restVertices = try XCTUnwrap(rest[.leftForearm])
        let bentVertices = try XCTUnwrap(bent[.leftForearm])
        let wrist = admittedPose()[.leftWrist]!.position * SIMD2<Float>(100, 100)
        let wristIndex = forearm.mesh.vertices.indices.min {
            simd_distance_squared(forearm.mesh.vertices[$0], wrist)
                < simd_distance_squared(forearm.mesh.vertices[$1], wrist)
        }!
        XCTAssertGreaterThan(
            simd_distance(restVertices[wristIndex], bentVertices[wristIndex]),
            3
        )
    }

    func testOwnershipBrushCorrectionChangesOnlyTheSelectedPartProposal() async throws {
        let compiler = ArticulationCompiler(maskProviders: [AlphaSubjectMaskProvider()])
        let image = admissionImage()
        let pose = admittedPose()
        let original = try await compiler.proposeOwnership(image: image, pose: pose)
        let corrected = try await compiler.proposeOwnership(
            image: image,
            pose: pose,
            corrections: [
                .leftUpperArm: [
                    OwnershipBrushStroke(
                        points: [SIMD2(0.35, 0.30), SIMD2(0.28, 0.48)],
                        radius: 0.08,
                        mode: .remove
                    ),
                ],
            ]
        )
        let originalLeft = original.masks[.leftUpperArm]!.values.reduce(0, +)
        let correctedLeft = corrected.masks[.leftUpperArm]!.values.reduce(0, +)
        XCTAssertLessThan(correctedLeft, originalLeft)
        XCTAssertGreaterThan(
            corrected.masks[.rightUpperArm]!.values.reduce(0, +),
            0
        )
    }

    func testCrossViewAnalyzerUsesFrontSymmetryAndMarksMissingSideArmHidden() throws {
        let pale = SIMD4<Float>(0.72, 0.78, 0.92, 1)
        let front = try articulationFixture(
            role: .front,
            visibleSides: [.left, .right],
            colors: [.left: pale, .right: pale]
        )
        let right = try articulationFixture(
            role: .right,
            visibleSides: [.right],
            colors: [.right: pale]
        )
        let profile = try XCTUnwrap(CrossViewArticulationAnalyzer.analyze(
            articulationByRole: [.front: front, .right: right]
        ))

        XCTAssertTrue(profile.frontSymmetry.allSatisfy { $0.score > 0.95 })
        XCTAssertTrue(profile.frontSymmetry.allSatisfy(\.substitutionAllowed))
        let side = try XCTUnwrap(profile.sideView(for: .right))
        XCTAssertEqual(side.hiddenFrontSides, [.left])
        let correspondence = try XCTUnwrap(side.correspondence(forSideViewSide: .right))
        XCTAssertEqual(correspondence.frontSide, .right)
        XCTAssertEqual(correspondence.basis, .symmetricAmbiguity)
    }

    func testCrossViewAnalyzerCanCorrectSideLabelFromAsymmetricAppearance() throws {
        let red = SIMD4<Float>(0.9, 0.05, 0.05, 1)
        let blue = SIMD4<Float>(0.05, 0.1, 0.9, 1)
        let front = try articulationFixture(
            role: .front,
            visibleSides: [.left, .right],
            colors: [.left: red, .right: blue]
        )
        // Vision called this the right arm, but its authored red decoration
        // matches the front left arm decisively.
        let right = try articulationFixture(
            role: .right,
            visibleSides: [.right],
            colors: [.right: red]
        )
        let profile = try XCTUnwrap(CrossViewArticulationAnalyzer.analyze(
            articulationByRole: [.front: front, .right: right]
        ))
        let correspondence = try XCTUnwrap(
            profile.sideView(for: .right)?.correspondence(forSideViewSide: .right)
        )

        XCTAssertEqual(correspondence.frontSide, .left)
        XCTAssertEqual(correspondence.basis, .appearance)
        XCTAssertGreaterThan(correspondence.confidence, 0.7)
        XCTAssertEqual(profile.sideView(for: .right)?.hiddenFrontSides, [.right])

        let mapped = CrossViewArticulationParameterMapper.parameters(
            ArticulationPoseParameters(jointRotations: [
                .leftShoulder: 12,
                .leftElbow: 24,
                .rightShoulder: -7,
                .rightElbow: -14,
            ]),
            for: .right,
            profile: profile
        )
        XCTAssertEqual(mapped[.rightShoulder], 12)
        XCTAssertEqual(mapped[.rightElbow], 24)
    }

    func testCrossViewBlendMovesHiddenFrontArmBehindBodyThenRemovesIt() throws {
        let color = SIMD4<Float>(0.7, 0.8, 0.9, 1)
        let front = try articulationFixture(
            role: .front,
            visibleSides: [.left, .right],
            colors: [.left: color, .right: color]
        )
        let right = try articulationFixture(
            role: .right,
            visibleSides: [.right],
            colors: [.right: color]
        )
        let rigs: [ReferenceRole: ArticulationRigArchive] = [
            .front: front,
            .right: right,
        ]
        let profile = try XCTUnwrap(CrossViewArticulationAnalyzer.analyze(
            articulationByRole: rigs
        ))

        let frontState = CrossViewArticulationBlend.state(
            viewTurn: 0,
            profile: profile,
            articulationByRole: rigs
        )
        XCTAssertEqual(frontState[.front, .leftForearm].inFrontOfBody, 1, accuracy: 0.001)

        let middle = CrossViewArticulationBlend.state(
            viewTurn: 0.5,
            profile: profile,
            articulationByRole: rigs
        )
        XCTAssertGreaterThan(
            middle[.front, .leftForearm].behindBody,
            middle[.front, .leftForearm].inFrontOfBody
        )
        XCTAssertEqual(middle[.right, .rightForearm].total, 0.5, accuracy: 0.001)

        let profileState = CrossViewArticulationBlend.state(
            viewTurn: 1,
            profile: profile,
            articulationByRole: rigs
        )
        XCTAssertEqual(profileState[.front, .leftForearm].total, 0, accuracy: 0.001)
        XCTAssertEqual(profileState[.right, .rightForearm].total, 1, accuracy: 0.001)
        XCTAssertEqual(profileState[.right, .leftForearm].total, 0, accuracy: 0.001)
    }

    func testCrossViewBlendTreatsMissingSegmentAsHiddenEvenWhenUpperArmExists() throws {
        let color = SIMD4<Float>(0.7, 0.8, 0.9, 1)
        let front = try articulationFixture(
            role: .front,
            visibleSides: [.left, .right],
            colors: [.left: color, .right: color]
        )
        var right = try articulationFixture(
            role: .right,
            visibleSides: [.right],
            colors: [.right: color]
        )
        right.parts.removeAll { $0.id == .rightForearm }
        right.omittedParts?[.rightForearm] = .occluded
        let rigs: [ReferenceRole: ArticulationRigArchive] = [
            .front: front,
            .right: right,
        ]
        let profile = try XCTUnwrap(CrossViewArticulationAnalyzer.analyze(
            articulationByRole: rigs
        ))
        let middle = CrossViewArticulationBlend.state(
            viewTurn: 0.5,
            profile: profile,
            articulationByRole: rigs
        )

        XCTAssertGreaterThan(
            middle[.front, .rightForearm].behindBody,
            middle[.front, .rightForearm].inFrontOfBody
        )
        XCTAssertEqual(middle[.right, .rightForearm].total, 0, accuracy: 0.001)
    }

    @MainActor
    func testArticulationRuntimeCreatesMetalAndUnderpaintSurfaces() throws {
        let color = SIMD4<Float>(0.7, 0.8, 0.9, 1)
        let rig = try articulationFixture(
            role: .front,
            visibleSides: [.left, .right],
            colors: [.left: color, .right: color]
        )
        let metalView = ArticulationMetalView(rig: rig)
        XCTAssertTrue(
            metalView.rendererIsAvailable,
            metalView.rendererErrorDescription ?? "unknown renderer failure"
        )
        XCTAssertNotNil(ArticulationUnderpaintPatchView(rig: rig))
        metalView.update(
            parameters: ArticulationPoseParameters(
                jointRotations: [.leftElbow: 15]
            ),
            opacities: [.leftForearm: 1]
        )
        XCTAssertFalse(metalView.isHidden)
    }

    func testV3ArchiveDecodesWithoutCrossViewArticulationProfile() throws {
        struct LegacyArchiveV3: Codable {
            var formatVersion = 3
            var references: [ReferenceViewArchive] = []
            var registration = ThreeViewRegistration(views: [:])
            var consensus = ThreeViewConsensusResult(
                poses: [],
                confidence: 0,
                warnings: []
            )
            var articulationByRole: [ReferenceRole: ArticulationRigArchive]? = nil
        }
        let data = try PropertyListEncoder().encode(LegacyArchiveV3())
        let decoded = try ThreeViewRigArchive(data: data)

        XCTAssertEqual(decoded.formatVersion, 3)
        XCTAssertNil(decoded.crossViewArticulation)
    }

    func testV4ArchivePersistsCrossViewArticulationProfile() throws {
        let profile = CrossViewArticulationProfile(
            frontSymmetry: [
                ArmSymmetryScore(
                    segment: .forearm,
                    score: 0.9,
                    silhouetteScore: 0.9,
                    appearanceScore: 0.9,
                    geometryScore: 0.9,
                    substitutionAllowed: true
                ),
            ],
            sideViews: [
                SideArticulationProfile(
                    role: .right,
                    correspondences: [
                        ArmSideCorrespondence(
                            sideViewSide: .right,
                            frontSide: .right,
                            confidence: 0.5,
                            basis: .symmetricAmbiguity
                        ),
                    ],
                    hiddenFrontSides: [.left]
                ),
            ]
        )
        let archive = ThreeViewRigArchive(
            references: [],
            registration: ThreeViewRegistration(views: [:]),
            consensus: ThreeViewConsensusResult(
                poses: [],
                confidence: 0,
                warnings: []
            ),
            articulationByRole: [:],
            crossViewArticulation: profile
        )
        let decoded = try ThreeViewRigArchive(data: archive.data())

        XCTAssertEqual(decoded.formatVersion, 4)
        XCTAssertEqual(decoded.crossViewArticulation, profile)
    }

    private func articulationFixture(
        role: ReferenceRole,
        visibleSides: Set<ArmSide>,
        colors: [ArmSide: SIMD4<Float>]
    ) throws -> ArticulationRigArchive {
        var pose = admittedPose()
        pose.role = role
        pose.fileName = "\(role.rawValue).png"
        for side in ArmSide.allCases where !visibleSides.contains(side) {
            for joint in OcclusionTopology.armJoints(side) {
                pose.setUserVisibility(.occluded, for: joint)
            }
        }
        let parts = visibleSides.flatMap { side in
            ArmSegment.allCases.map { segment -> ArticulatedPartArchive in
                let partID = segment.part(on: side)
                let rect = CGRect(x: 20, y: 20, width: 12, height: 24)
                let mesh = DeformableMesh.grid(rect: rect, columns: 1, rows: 2)
                let bone = articulationBone(for: partID)
                return ArticulatedPartArchive(
                    id: partID,
                    rect: rect,
                    mesh: mesh,
                    weights: mesh.vertices.map { _ in
                        LBSVertexWeight(
                            primaryBone: bone,
                            secondaryBone: bone,
                            secondaryWeight: 0
                        )
                    },
                    texturePNG: try! solidPNG(colors[side] ?? SIMD4(1, 1, 1, 1)),
                    layerOrder: .inFrontOfBody
                )
            }
        }
        let omitted = Dictionary(uniqueKeysWithValues: ArmSide.allCases
            .filter { !visibleSides.contains($0) }
            .flatMap { side in
                ArmSegment.allCases.map { ($0.part(on: side), JointVisibility.occluded) }
            })
        return ArticulationRigArchive(
            imageWidth: 100,
            imageHeight: 100,
            restPose: pose,
            baseTexturePNG: try solidPNG(SIMD4(0, 0, 0, 0)),
            unknownUnderpaintMaskPNG: try solidPNG(SIMD4(1, 1, 1, 1)),
            parts: parts,
            omittedParts: omitted,
            corrections: [:],
            integrityMetrics: RigIntegrityMetrics(),
            integrityAccepted: true
        )
    }

    private func articulationBone(for part: ArticulationPartID) -> ArticulationBoneID {
        switch part {
        case .leftUpperArm: .leftUpperArm
        case .leftForearm: .leftForearm
        case .rightUpperArm: .rightUpperArm
        case .rightForearm: .rightForearm
        }
    }

    private func solidPNG(_ color: SIMD4<Float>) throws -> Data {
        var bitmap = Bitmap(width: 12, height: 24)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                bitmap.setRGBA(x: x, y: y, color)
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, bitmap.cgImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
