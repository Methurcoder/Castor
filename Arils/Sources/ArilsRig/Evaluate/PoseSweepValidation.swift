import Foundation
import simd

import ArilsCore

public struct PoseSweepSample: Hashable, Sendable {
    public var yawDegrees: Float
    public var pitchDegrees: Float

    public init(yawDegrees: Float, pitchDegrees: Float) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
    }
}

public struct RigIntegrityThresholds: Codable, Equatable, Sendable {
    public var maximumMeshInversionCount: Int
    public var maximumHoleArea: Float
    public var maximumGhostArea: Float
    public var maximumUnknownExposure: Float

    public init(
        maximumMeshInversionCount: Int = 0,
        maximumHoleArea: Float = 0.02,
        maximumGhostArea: Float = 0.05,
        maximumUnknownExposure: Float = 0.005
    ) {
        self.maximumMeshInversionCount = max(0, maximumMeshInversionCount)
        self.maximumHoleArea = max(0, maximumHoleArea)
        self.maximumGhostArea = max(0, maximumGhostArea)
        self.maximumUnknownExposure = max(0, maximumUnknownExposure)
    }

    public func accepts(_ metrics: RigIntegrityMetrics) -> Bool {
        validationPolicy.disposition(for: metrics) == .accepted
    }

    public var validationPolicy: RigValidationPolicy {
        RigValidationPolicy(
            safety: RigSafetyThresholds(
                maximumMeshInversionCount: maximumMeshInversionCount,
                maximumNonFiniteVertexCount: 0,
                maximumUnknownExposure: maximumUnknownExposure
            ),
            quality: RigQualityThresholds(
                maximumHoleArea: maximumHoleArea,
                maximumGhostArea: maximumGhostArea
            )
        )
    }
}

/// Hard failures: unsafe geometry or pixels with no source support.
public struct RigSafetyMetrics: Codable, Equatable, Sendable {
    public var meshInversionCount: Int
    public var nonFiniteVertexCount: Int
    public var unknownExposure: Float
}

/// Rest-pose comparison scores. These describe visual drift and are review
/// signals; normal articulation can move valid pixels away from their rest
/// locations, so they are not hard safety failures by themselves.
public struct RigQualityMetrics: Codable, Equatable, Sendable {
    public var holeArea: Float
    public var ghostArea: Float
}

public extension RigIntegrityMetrics {
    var safety: RigSafetyMetrics {
        RigSafetyMetrics(
            meshInversionCount: meshInversionCount,
            nonFiniteVertexCount: nonFiniteVertexCount,
            unknownExposure: unknownExposure
        )
    }

    var quality: RigQualityMetrics {
        RigQualityMetrics(holeArea: holeArea, ghostArea: ghostArea)
    }
}

public struct RigSafetyThresholds: Codable, Equatable, Sendable {
    public var maximumMeshInversionCount: Int
    public var maximumNonFiniteVertexCount: Int
    public var maximumUnknownExposure: Float

    public init(
        maximumMeshInversionCount: Int = 0,
        maximumNonFiniteVertexCount: Int = 0,
        maximumUnknownExposure: Float = 0.005
    ) {
        self.maximumMeshInversionCount = max(0, maximumMeshInversionCount)
        self.maximumNonFiniteVertexCount = max(0, maximumNonFiniteVertexCount)
        self.maximumUnknownExposure = max(0, maximumUnknownExposure)
    }

    public func accepts(_ metrics: RigIntegrityMetrics) -> Bool {
        metrics.isFinite
            && metrics.meshInversionCount <= maximumMeshInversionCount
            && metrics.nonFiniteVertexCount <= maximumNonFiniteVertexCount
            && metrics.unknownExposure <= maximumUnknownExposure
    }
}

public struct RigQualityThresholds: Codable, Equatable, Sendable {
    public var maximumHoleArea: Float
    public var maximumGhostArea: Float

    public init(
        maximumHoleArea: Float = 0.02,
        maximumGhostArea: Float = 0.05
    ) {
        self.maximumHoleArea = max(0, maximumHoleArea)
        self.maximumGhostArea = max(0, maximumGhostArea)
    }

    public func accepts(_ metrics: RigIntegrityMetrics) -> Bool {
        metrics.isFinite
            && metrics.holeArea <= maximumHoleArea
            && metrics.ghostArea <= maximumGhostArea
    }
}

public enum RigValidationDisposition: String, Codable, Equatable, Sendable {
    case accepted
    case requiresReview
    case rejected
}

public struct RigValidationPolicy: Codable, Equatable, Sendable {
    public var safety: RigSafetyThresholds
    public var quality: RigQualityThresholds

    public init(
        safety: RigSafetyThresholds = RigSafetyThresholds(),
        quality: RigQualityThresholds = RigQualityThresholds()
    ) {
        self.safety = safety
        self.quality = quality
    }

    public func disposition(for metrics: RigIntegrityMetrics) -> RigValidationDisposition {
        guard safety.accepts(metrics) else { return .rejected }
        return quality.accepts(metrics) ? .accepted : .requiresReview
    }
}

/// Build-time yaw/pitch grid and the integrity thresholds each pose must pass.
public struct PoseSweepPlan: Codable, Equatable, Sendable {
    public var yawDegrees: [Float]
    public var pitchDegrees: [Float]
    public var thresholds: RigIntegrityThresholds
    public var rasterResolution: Int

    public static let supportedHead = PoseSweepPlan(
        yawDegrees: [-20, -10, 0, 10, 20],
        pitchDegrees: [-6, -3, 0, 3, 6]
    )

    public init(
        yawDegrees: [Float],
        pitchDegrees: [Float],
        thresholds: RigIntegrityThresholds = RigIntegrityThresholds(),
        rasterResolution: Int = 256
    ) {
        self.yawDegrees = Self.sanitizedAngles(yawDegrees)
        self.pitchDegrees = Self.sanitizedAngles(pitchDegrees)
        self.thresholds = thresholds
        self.rasterResolution = max(16, rasterResolution)
    }

    public var samples: [PoseSweepSample] {
        yawDegrees.flatMap { yaw in
            pitchDegrees.map { pitch in
                PoseSweepSample(yawDegrees: yaw, pitchDegrees: pitch)
            }
        }
    }

    private static func sanitizedAngles(_ values: [Float]) -> [Float] {
        let finite = values.filter(\.isFinite)
        return Array(Set(finite + [0])).sorted()
    }
}

public struct PoseSweepValidationResult: Sendable {
    /// Range that passes both hard safety and soft quality thresholds. This is
    /// the legacy persisted behavior and remains backward compatible.
    public var validatedPoseLimits: ValidatedPoseLimits
    /// Range that passes hard safety even when visual quality needs review.
    public var safetyPoseLimits: ValidatedPoseLimits
    public var metricsByPose: [PoseSweepSample: RigIntegrityMetrics]
    public var dispositionsByPose: [PoseSweepSample: RigValidationDisposition]

    public init(
        validatedPoseLimits: ValidatedPoseLimits,
        safetyPoseLimits: ValidatedPoseLimits? = nil,
        metricsByPose: [PoseSweepSample: RigIntegrityMetrics],
        dispositionsByPose: [PoseSweepSample: RigValidationDisposition] = [:]
    ) {
        self.validatedPoseLimits = validatedPoseLimits
        self.safetyPoseLimits = safetyPoseLimits ?? validatedPoseLimits
        self.metricsByPose = metricsByPose
        self.dispositionsByPose = dispositionsByPose
    }
}

public enum PoseSweepValidator {
    public static func validate(
        rig: AvatarRig,
        plan: PoseSweepPlan = .supportedHead,
        alphaCoverageByPartID: [String: FloatPlane] = [:],
        unknownCoverageByPartID: [String: FloatPlane] = [:]
    ) -> PoseSweepValidationResult {
        let evaluator = DeformationEvaluator3D(rig: rig)
        let reference = evaluator.evaluate(parameters: [:])
        var metricsByPose: [PoseSweepSample: RigIntegrityMetrics] = [:]
        metricsByPose.reserveCapacity(plan.samples.count)

        for sample in plan.samples {
            let evaluated = evaluator.evaluate(parameters: [
                .angleX: sample.yawDegrees,
                .angleY: sample.pitchDegrees,
            ])
            metricsByPose[sample] = RigIntegrityMetrics.measure(
                rig: rig,
                evaluatedVertices: evaluated,
                referenceVertices: reference,
                alphaCoverageByPartID: alphaCoverageByPartID,
                unknownCoverageByPartID: unknownCoverageByPartID,
                rasterResolution: plan.rasterResolution
            )
        }

        let policy = plan.thresholds.validationPolicy
        let dispositionsByPose = metricsByPose.mapValues {
            policy.disposition(for: $0)
        }
        let disposition: (Float, Float) -> RigValidationDisposition? = { yaw, pitch in
            dispositionsByPose[PoseSweepSample(yawDegrees: yaw, pitchDegrees: pitch)]
        }
        let acceptedLimits = validatedLimits(plan: plan) { yaw, pitch in
            disposition(yaw, pitch) == .accepted
        }
        let safetyLimits = validatedLimits(plan: plan) { yaw, pitch in
            guard let value = disposition(yaw, pitch) else { return false }
            return value != .rejected
        }

        return PoseSweepValidationResult(
            validatedPoseLimits: acceptedLimits,
            safetyPoseLimits: safetyLimits,
            metricsByPose: metricsByPose,
            dispositionsByPose: dispositionsByPose
        )
    }

    private static func validatedLimits(
        plan: PoseSweepPlan,
        safe: (Float, Float) -> Bool
    ) -> ValidatedPoseLimits {
        let negativeYaw = contiguousLimit(
            plan.yawDegrees.filter { $0 <= 0 }.sorted(by: >),
            other: 0,
            isYaw: true,
            safe: safe
        )
        let positiveYaw = contiguousLimit(
            plan.yawDegrees.filter { $0 >= 0 }.sorted(),
            other: 0,
            isYaw: true,
            safe: safe
        )
        let negativePitch = contiguousLimit(
            plan.pitchDegrees.filter { $0 <= 0 }.sorted(by: >),
            other: 0,
            isYaw: false,
            safe: safe
        )
        let positivePitch = contiguousLimit(
            plan.pitchDegrees.filter { $0 >= 0 }.sorted(),
            other: 0,
            isYaw: false,
            safe: safe
        )

        let yawMinimumCandidates = plan.yawDegrees.filter { $0 <= 0 && $0 >= negativeYaw }
        let yawMaximumCandidates = plan.yawDegrees.filter { $0 >= 0 && $0 <= positiveYaw }
        let pitchMinimumCandidates = plan.pitchDegrees.filter { $0 <= 0 && $0 >= negativePitch }
        let pitchMaximumCandidates = plan.pitchDegrees.filter { $0 >= 0 && $0 <= positivePitch }

        var best = ValidatedPoseLimits(
            minimumYawDegrees: 0,
            maximumYawDegrees: 0,
            minimumPitchDegrees: 0,
            maximumPitchDegrees: 0
        )
        var bestScore = RectangleScore.zero
        for minYaw in yawMinimumCandidates {
            for maxYaw in yawMaximumCandidates {
                for minPitch in pitchMinimumCandidates {
                    for maxPitch in pitchMaximumCandidates {
                        let allSafe = plan.samples
                            .filter {
                                $0.yawDegrees >= minYaw && $0.yawDegrees <= maxYaw
                                    && $0.pitchDegrees >= minPitch && $0.pitchDegrees <= maxPitch
                            }
                            .allSatisfy { safe($0.yawDegrees, $0.pitchDegrees) }
                        guard allSafe else { continue }
                        let score = RectangleScore(
                            minYaw: minYaw,
                            maxYaw: maxYaw,
                            minPitch: minPitch,
                            maxPitch: maxPitch,
                            plan: plan
                        )
                        if score > bestScore {
                            bestScore = score
                            best = ValidatedPoseLimits(
                                minimumYawDegrees: minYaw,
                                maximumYawDegrees: maxYaw,
                                minimumPitchDegrees: minPitch,
                                maximumPitchDegrees: maxPitch
                            )
                        }
                    }
                }
            }
        }
        return best
    }

    private static func contiguousLimit(
        _ values: [Float],
        other: Float,
        isYaw: Bool,
        safe: (Float, Float) -> Bool
    ) -> Float {
        var result: Float = 0
        for value in values {
            let accepted = isYaw ? safe(value, other) : safe(other, value)
            guard accepted else { break }
            result = value
        }
        return result
    }

    private struct RectangleScore: Comparable {
        var balancedCoverage: Float
        var totalCoverage: Float

        static let zero = RectangleScore(balancedCoverage: -1, totalCoverage: -1)

        init(
            minYaw: Float,
            maxYaw: Float,
            minPitch: Float,
            maxPitch: Float,
            plan: PoseSweepPlan
        ) {
            let yawRange = maxYaw - minYaw
            let pitchRange = maxPitch - minPitch
            let availableYaw = max(0.0001, (plan.yawDegrees.max() ?? 0) - (plan.yawDegrees.min() ?? 0))
            let availablePitch = max(
                0.0001,
                (plan.pitchDegrees.max() ?? 0) - (plan.pitchDegrees.min() ?? 0)
            )
            let yawCoverage = yawRange / availableYaw
            let pitchCoverage = pitchRange / availablePitch
            balancedCoverage = min(yawCoverage, pitchCoverage)
            totalCoverage = yawCoverage + pitchCoverage
        }

        private init(balancedCoverage: Float, totalCoverage: Float) {
            self.balancedCoverage = balancedCoverage
            self.totalCoverage = totalCoverage
        }

        static func < (lhs: RectangleScore, rhs: RectangleScore) -> Bool {
            if lhs.balancedCoverage != rhs.balancedCoverage {
                return lhs.balancedCoverage < rhs.balancedCoverage
            }
            return lhs.totalCoverage < rhs.totalCoverage
        }
    }
}
