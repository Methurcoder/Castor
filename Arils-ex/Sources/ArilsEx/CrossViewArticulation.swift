import Arils
import CoreGraphics
import Foundation
import ImageIO
import simd

/// Arm segments are compared independently. A costume may be symmetric at the
/// sleeve while carrying a deliberately asymmetric cuff or hand decoration.
public enum ArmSegment: String, Codable, CaseIterable, Sendable {
    case upperArm
    case forearm

    public func part(on side: ArmSide) -> ArticulationPartID {
        switch (side, self) {
        case (.left, .upperArm): .leftUpperArm
        case (.left, .forearm): .leftForearm
        case (.right, .upperArm): .rightUpperArm
        case (.right, .forearm): .rightForearm
        }
    }
}

public struct ArmSymmetryScore: Codable, Equatable, Sendable {
    public var segment: ArmSegment
    public var score: Float
    public var silhouetteScore: Float
    public var appearanceScore: Float
    public var geometryScore: Float
    public var substitutionAllowed: Bool

    public init(
        segment: ArmSegment,
        score: Float,
        silhouetteScore: Float,
        appearanceScore: Float,
        geometryScore: Float,
        substitutionAllowed: Bool
    ) {
        self.segment = segment
        self.score = Self.unit(score)
        self.silhouetteScore = Self.unit(silhouetteScore)
        self.appearanceScore = Self.unit(appearanceScore)
        self.geometryScore = Self.unit(geometryScore)
        self.substitutionAllowed = substitutionAllowed
    }

    private static func unit(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public enum ArmCorrespondenceBasis: String, Codable, Sendable {
    /// Appearance provides enough evidence to choose between direct and
    /// swapped anatomical labels.
    case appearance
    /// The front artwork is too symmetric to distinguish identities safely;
    /// preserve the reviewed joint labels but keep confidence low.
    case symmetricAmbiguity
    /// A usable appearance descriptor was unavailable.
    case reviewedJointLabel
}

/// Maps the side-view compiler's arm label to the corresponding anatomical arm
/// in the front drawing. `sideViewSide` and `frontSide` may differ when Vision
/// assigned a side-profile limb to the wrong anatomical side.
public struct ArmSideCorrespondence: Codable, Equatable, Sendable {
    public var sideViewSide: ArmSide
    public var frontSide: ArmSide
    public var confidence: Float
    public var basis: ArmCorrespondenceBasis

    public init(
        sideViewSide: ArmSide,
        frontSide: ArmSide,
        confidence: Float,
        basis: ArmCorrespondenceBasis
    ) {
        self.sideViewSide = sideViewSide
        self.frontSide = frontSide
        self.confidence = confidence.isFinite ? min(max(confidence, 0), 1) : 0
        self.basis = basis
    }
}

public struct SideArticulationProfile: Codable, Equatable, Sendable {
    public var role: ReferenceRole
    public var correspondences: [ArmSideCorrespondence]
    /// Anatomical front arms that have no authored texture in this side view.
    /// They may retain their front texture during the turn, but must move
    /// behind the body and disappear before the exact profile is reached.
    public var hiddenFrontSides: [ArmSide]

    public init(
        role: ReferenceRole,
        correspondences: [ArmSideCorrespondence],
        hiddenFrontSides: [ArmSide]
    ) {
        self.role = role
        self.correspondences = correspondences
        self.hiddenFrontSides = hiddenFrontSides
    }

    public func correspondence(forSideViewSide side: ArmSide) -> ArmSideCorrespondence? {
        correspondences.first { $0.sideViewSide == side }
    }
}

/// Build-time result used by the runtime to transition arms independently from
/// the whole-image cross-fade. Optional in archives for backward compatibility.
public struct CrossViewArticulationProfile: Codable, Equatable, Sendable {
    public var frontSymmetry: [ArmSymmetryScore]
    public var sideViews: [SideArticulationProfile]

    public init(
        frontSymmetry: [ArmSymmetryScore],
        sideViews: [SideArticulationProfile]
    ) {
        self.frontSymmetry = frontSymmetry
        self.sideViews = sideViews
    }

    public func symmetry(for segment: ArmSegment) -> ArmSymmetryScore? {
        frontSymmetry.first { $0.segment == segment }
    }

    public func sideView(for role: ReferenceRole) -> SideArticulationProfile? {
        sideViews.first { $0.role == role }
    }
}

/// Compares compiled, original-resolution arm cut-outs. This is intentionally
/// deterministic and local-only: it uses alpha silhouette, a compact color
/// histogram and reviewed bone geometry, not an external embedding service.
public enum CrossViewArticulationAnalyzer {
    public static func analyze(
        articulationByRole: [ReferenceRole: ArticulationRigArchive]
    ) -> CrossViewArticulationProfile? {
        guard let front = articulationByRole[.front] else { return nil }

        let symmetry = ArmSegment.allCases.map { segment in
            symmetryScore(segment: segment, front: front)
        }
        let averageSymmetry = symmetry.isEmpty
            ? 0
            : symmetry.map(\.score).reduce(0, +) / Float(symmetry.count)
        let sideViews = [ReferenceRole.left, .right].compactMap { role -> SideArticulationProfile? in
            guard let side = articulationByRole[role] else { return nil }
            return sideProfile(
                role: role,
                side: side,
                front: front,
                averageFrontSymmetry: averageSymmetry
            )
        }
        return CrossViewArticulationProfile(
            frontSymmetry: symmetry,
            sideViews: sideViews
        )
    }

    private struct TextureDescriptor {
        var alpha: [Float]
        var histogram: [Float]
        var coverage: Float
        var aspect: Float
    }

    private static func symmetryScore(
        segment: ArmSegment,
        front: ArticulationRigArchive
    ) -> ArmSymmetryScore {
        let leftID = segment.part(on: .left)
        let rightID = segment.part(on: .right)
        let leftPart = front.parts.first { $0.id == leftID }
        let rightPart = front.parts.first { $0.id == rightID }
        let leftDescriptor = leftPart.flatMap { descriptor(for: $0.texturePNG) }
        let rightDescriptor = rightPart.flatMap { descriptor(for: $0.texturePNG) }

        let silhouette: Float
        let appearance: Float
        if let leftDescriptor, let rightDescriptor {
            silhouette = alphaSimilarity(
                leftDescriptor.alpha,
                rightDescriptor.alpha,
                mirrorSecond: true
            )
            appearance = histogramIntersection(
                leftDescriptor.histogram,
                rightDescriptor.histogram
            )
        } else {
            silhouette = 0
            appearance = 0
        }
        let bone = boneLengthSimilarity(
            segment.part(on: .left),
            segment.part(on: .right),
            rig: front
        )
        let area: Float
        if let leftPart, let rightPart {
            area = ratioSimilarity(
                Float(leftPart.rect.width * leftPart.rect.height),
                Float(rightPart.rect.width * rightPart.rect.height)
            )
        } else {
            area = 0
        }
        let geometry = bone * 0.65 + area * 0.35
        let score = silhouette * 0.35
            + appearance * 0.25
            + geometry * 0.40
        return ArmSymmetryScore(
            segment: segment,
            score: score,
            silhouetteScore: silhouette,
            appearanceScore: appearance,
            geometryScore: geometry,
            substitutionAllowed: score >= 0.72
        )
    }

    private static func sideProfile(
        role: ReferenceRole,
        side: ArticulationRigArchive,
        front: ArticulationRigArchive,
        averageFrontSymmetry: Float
    ) -> SideArticulationProfile {
        let visibleSides = [ArmSide.left, .right].filter { armSide in
            ArmSegment.allCases.contains { segment in
                side.parts.contains { $0.id == segment.part(on: armSide) }
            }
        }
        guard !visibleSides.isEmpty else {
            return SideArticulationProfile(
                role: role,
                correspondences: [],
                hiddenFrontSides: [.left, .right]
            )
        }

        let direct = assignmentScore(
            sideRig: side,
            frontRig: front,
            mapping: Dictionary(uniqueKeysWithValues: visibleSides.map { ($0, $0) })
        )
        let swappedMapping = Dictionary(uniqueKeysWithValues: visibleSides.map {
            ($0, opposite($0))
        })
        let swapped = assignmentScore(
            sideRig: side,
            frontRig: front,
            mapping: swappedMapping
        )
        let hasAppearance = direct.sampleCount > 0 || swapped.sampleCount > 0
        let difference = abs(direct.score - swapped.score)
        let isAppearanceDecisive = hasAppearance
            && averageFrontSymmetry < 0.86
            && difference >= 0.08
        let useSwapped = isAppearanceDecisive && swapped.score > direct.score
        let chosen = useSwapped ? swappedMapping : Dictionary(
            uniqueKeysWithValues: visibleSides.map { ($0, $0) }
        )
        let basis: ArmCorrespondenceBasis
        if !hasAppearance {
            basis = .reviewedJointLabel
        } else if isAppearanceDecisive {
            basis = .appearance
        } else {
            basis = .symmetricAmbiguity
        }
        let confidence: Float
        switch basis {
        case .appearance:
            confidence = min(0.95, 0.62 + difference * 1.8)
        case .symmetricAmbiguity:
            confidence = 0.50
        case .reviewedJointLabel:
            confidence = 0.42
        }
        let correspondences = visibleSides.compactMap { sideViewSide -> ArmSideCorrespondence? in
            guard let frontSide = chosen[sideViewSide] else { return nil }
            return ArmSideCorrespondence(
                sideViewSide: sideViewSide,
                frontSide: frontSide,
                confidence: confidence,
                basis: basis
            )
        }
        let mapped = Set(correspondences.map(\.frontSide))
        let hidden = [ArmSide.left, .right].filter { !mapped.contains($0) }
        return SideArticulationProfile(
            role: role,
            correspondences: correspondences,
            hiddenFrontSides: hidden
        )
    }

    private struct AssignmentScore {
        var score: Float
        var sampleCount: Int
    }

    private static func assignmentScore(
        sideRig: ArticulationRigArchive,
        frontRig: ArticulationRigArchive,
        mapping: [ArmSide: ArmSide]
    ) -> AssignmentScore {
        var scores: [Float] = []
        for (sideViewSide, frontSide) in mapping {
            for segment in ArmSegment.allCases {
                let sideID = segment.part(on: sideViewSide)
                let frontID = segment.part(on: frontSide)
                guard let sidePart = sideRig.parts.first(where: { $0.id == sideID }),
                      let frontPart = frontRig.parts.first(where: { $0.id == frontID }),
                      let sideDescriptor = descriptor(for: sidePart.texturePNG),
                      let frontDescriptor = descriptor(for: frontPart.texturePNG) else {
                    continue
                }
                let color = histogramIntersection(
                    sideDescriptor.histogram,
                    frontDescriptor.histogram
                )
                let coverage = ratioSimilarity(
                    sideDescriptor.coverage,
                    frontDescriptor.coverage
                )
                let aspect = ratioSimilarity(
                    sideDescriptor.aspect,
                    frontDescriptor.aspect
                )
                let geometry = boneLengthSimilarity(sideID, frontID, lhs: sideRig, rhs: frontRig)
                scores.append(color * 0.55 + coverage * 0.15 + aspect * 0.10 + geometry * 0.20)
            }
        }
        guard !scores.isEmpty else { return AssignmentScore(score: 0, sampleCount: 0) }
        return AssignmentScore(
            score: scores.reduce(0, +) / Float(scores.count),
            sampleCount: scores.count
        )
    }

    private static func descriptor(for data: Data) -> TextureDescriptor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let bitmap = Bitmap(image: image),
              bitmap.width > 0,
              bitmap.height > 0 else { return nil }

        let sampleWidth = 24
        let sampleHeight = 32
        var alpha = [Float](repeating: 0, count: sampleWidth * sampleHeight)
        var histogram = [Float](repeating: 0, count: 4 * 4 * 4)
        var alphaSum: Float = 0
        var covered = 0
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let pixel = bitmap.rgba(x: x, y: y)
                guard pixel.w > 0.01 else { continue }
                covered += 1
                alphaSum += pixel.w
                let rgb = SIMD3(pixel.x, pixel.y, pixel.z) / max(pixel.w, 0.001)
                let r = min(3, max(0, Int(rgb.x * 3.999)))
                let g = min(3, max(0, Int(rgb.y * 3.999)))
                let b = min(3, max(0, Int(rgb.z * 3.999)))
                histogram[(r * 4 + g) * 4 + b] += pixel.w
            }
        }
        if alphaSum > 0 {
            histogram = histogram.map { $0 / alphaSum }
        }
        for sampleY in 0..<sampleHeight {
            let sourceY = min(
                bitmap.height - 1,
                Int((Float(sampleY) + 0.5) / Float(sampleHeight) * Float(bitmap.height))
            )
            for sampleX in 0..<sampleWidth {
                let sourceX = min(
                    bitmap.width - 1,
                    Int((Float(sampleX) + 0.5) / Float(sampleWidth) * Float(bitmap.width))
                )
                alpha[sampleY * sampleWidth + sampleX] = bitmap.rgba(
                    x: sourceX,
                    y: sourceY
                ).w
            }
        }
        return TextureDescriptor(
            alpha: alpha,
            histogram: histogram,
            coverage: Float(covered) / Float(bitmap.width * bitmap.height),
            aspect: Float(bitmap.width) / Float(bitmap.height)
        )
    }

    private static func alphaSimilarity(
        _ lhs: [Float],
        _ rhs: [Float],
        mirrorSecond: Bool
    ) -> Float {
        guard lhs.count == rhs.count, lhs.count == 24 * 32 else { return 0 }
        var difference: Float = 0
        var union: Float = 0
        for y in 0..<32 {
            for x in 0..<24 {
                let a = lhs[y * 24 + x]
                let rhsX = mirrorSecond ? 23 - x : x
                let b = rhs[y * 24 + rhsX]
                difference += abs(a - b)
                union += max(a, b)
            }
        }
        guard union > 0.001 else { return 0 }
        return min(max(1 - difference / union, 0), 1)
    }

    private static func histogramIntersection(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        return min(max(zip(lhs, rhs).reduce(Float.zero) { $0 + min($1.0, $1.1) }, 0), 1)
    }

    private static func boneLengthSimilarity(
        _ lhsID: ArticulationPartID,
        _ rhsID: ArticulationPartID,
        rig: ArticulationRigArchive
    ) -> Float {
        boneLengthSimilarity(lhsID, rhsID, lhs: rig, rhs: rig)
    }

    private static func boneLengthSimilarity(
        _ lhsID: ArticulationPartID,
        _ rhsID: ArticulationPartID,
        lhs: ArticulationRigArchive,
        rhs: ArticulationRigArchive
    ) -> Float {
        guard let lhsLength = boneLength(lhsID, rig: lhs),
              let rhsLength = boneLength(rhsID, rig: rhs) else { return 0 }
        return ratioSimilarity(lhsLength, rhsLength)
    }

    private static func boneLength(
        _ partID: ArticulationPartID,
        rig: ArticulationRigArchive
    ) -> Float? {
        let endpoints = partID.joints
        guard let start = rig.restPose[endpoints.start]?.position,
              let end = rig.restPose[endpoints.end]?.position else { return nil }
        let scale = SIMD2(Float(rig.imageWidth), Float(rig.imageHeight))
        return simd_distance(start * scale, end * scale)
    }

    private static func ratioSimilarity(_ lhs: Float, _ rhs: Float) -> Float {
        guard lhs.isFinite, rhs.isFinite, lhs > 0, rhs > 0 else { return 0 }
        return min(lhs, rhs) / max(lhs, rhs)
    }

    private static func opposite(_ side: ArmSide) -> ArmSide {
        side == .left ? .right : .left
    }
}

public struct ArticulationLayerOpacity: Equatable, Sendable {
    public var behindBody: Float
    public var inFrontOfBody: Float

    public init(behindBody: Float = 0, inFrontOfBody: Float = 0) {
        self.behindBody = Self.unit(behindBody)
        self.inFrontOfBody = Self.unit(inFrontOfBody)
    }

    public var total: Float { behindBody + inFrontOfBody }

    private static func unit(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

public struct CrossViewArticulationRenderState: Equatable, Sendable {
    public var byRole: [ReferenceRole: [ArticulationPartID: ArticulationLayerOpacity]]

    public init(
        byRole: [ReferenceRole: [ArticulationPartID: ArticulationLayerOpacity]] = [:]
    ) {
        self.byRole = byRole
    }

    public subscript(
        role: ReferenceRole,
        part: ArticulationPartID
    ) -> ArticulationLayerOpacity {
        byRole[role]?[part] ?? ArticulationLayerOpacity()
    }
}

/// Converts view turn into independent arm render weights. A front arm that
/// has no side-view counterpart changes layer before fading, which makes it
/// disappear behind the body instead of dissolving over the torso as a ghost.
public enum CrossViewArticulationBlend {
    public static func state(
        viewTurn: Float,
        profile: CrossViewArticulationProfile?,
        articulationByRole: [ReferenceRole: ArticulationRigArchive]
    ) -> CrossViewArticulationRenderState {
        let turn = viewTurn.isFinite ? min(max(viewTurn, -1), 1) : 0
        let progress = abs(turn)
        let activeSideRole: ReferenceRole = turn < 0 ? .left : .right
        var values: [ReferenceRole: [ArticulationPartID: ArticulationLayerOpacity]] = [:]

        guard let profile,
              let sideProfile = profile.sideView(for: activeSideRole) else {
            let bodyWeights = ThreeViewBlend.weights(for: turn)
            let roleWeights: [ReferenceRole: Float] = [
                .left: bodyWeights.left,
                .front: bodyWeights.front,
                .right: bodyWeights.right,
            ]
            for (role, rig) in articulationByRole {
                let opacity = roleWeights[role] ?? 0
                values[role] = Dictionary(uniqueKeysWithValues: rig.parts.map { part in
                    let layer = part.layerOrder == .behindBody
                        ? ArticulationLayerOpacity(behindBody: opacity)
                        : ArticulationLayerOpacity(inFrontOfBody: opacity)
                    return (part.id, layer)
                })
            }
            return CrossViewArticulationRenderState(byRole: values)
        }

        if let front = articulationByRole[.front] {
            let sideRig = articulationByRole[activeSideRole]
            values[.front] = Dictionary(uniqueKeysWithValues: front.parts.map { part in
                let segment = segment(for: part.id)
                let hasSideCounterpart = sideProfile.correspondences.contains { correspondence in
                    guard correspondence.frontSide == part.id.side else { return false }
                    let counterpart = segment.part(on: correspondence.sideViewSide)
                    return sideRig?.parts.contains { $0.id == counterpart } == true
                }
                let isHiddenAtProfile = !hasSideCounterpart
                if isHiddenAtProfile {
                    let total = 1 - smoothstep(0.35, 0.92, progress)
                    let behindMix = smoothstep(0.16, 0.60, progress)
                    return (
                        part.id,
                        ArticulationLayerOpacity(
                            behindBody: total * behindMix,
                            inFrontOfBody: total * (1 - behindMix)
                        )
                    )
                }
                let total = 1 - progress
                let layer = part.layerOrder == .behindBody
                    ? ArticulationLayerOpacity(behindBody: total)
                    : ArticulationLayerOpacity(inFrontOfBody: total)
                return (part.id, layer)
            })
        }

        if let side = articulationByRole[activeSideRole] {
            values[activeSideRole] = Dictionary(uniqueKeysWithValues: side.parts.map { part in
                let layer = part.layerOrder == .behindBody
                    ? ArticulationLayerOpacity(behindBody: progress)
                    : ArticulationLayerOpacity(inFrontOfBody: progress)
                return (part.id, layer)
            })
        }
        return CrossViewArticulationRenderState(byRole: values)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func segment(for part: ArticulationPartID) -> ArmSegment {
        switch part {
        case .leftUpperArm, .rightUpperArm: .upperArm
        case .leftForearm, .rightForearm: .forearm
        }
    }
}

/// Keeps motion identity consistent when the appearance comparison concludes
/// that a side-view limb was assigned the opposite anatomical label.
public enum CrossViewArticulationParameterMapper {
    public static func parameters(
        _ parameters: ArticulationPoseParameters,
        for role: ReferenceRole,
        profile: CrossViewArticulationProfile?
    ) -> ArticulationPoseParameters {
        guard role != .front,
              let sideProfile = profile?.sideView(for: role) else {
            return parameters
        }
        var rotations = parameters.jointRotations
        for correspondence in sideProfile.correspondences {
            let sourceShoulder: JointKind = correspondence.frontSide == .left
                ? .leftShoulder
                : .rightShoulder
            let sourceElbow: JointKind = correspondence.frontSide == .left
                ? .leftElbow
                : .rightElbow
            let destinationShoulder: JointKind = correspondence.sideViewSide == .left
                ? .leftShoulder
                : .rightShoulder
            let destinationElbow: JointKind = correspondence.sideViewSide == .left
                ? .leftElbow
                : .rightElbow
            rotations[destinationShoulder] = parameters[sourceShoulder]
            rotations[destinationElbow] = parameters[sourceElbow]
        }
        return ArticulationPoseParameters(jointRotations: rotations)
    }
}
