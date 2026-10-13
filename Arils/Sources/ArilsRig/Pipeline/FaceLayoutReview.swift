import CoreGraphics
import Foundation

/// Reasons an automatically estimated face layout deserves a human check.
/// These are deliberately data-only so the host app can localize the message.
public enum FaceLayoutReviewIssue: String, Sendable, Equatable, CaseIterable {
    case lowEstimatorConfidence
    case headExtendsTooLow
    case headIsTooLarge
    case eyesOutsideHead
    case eyesMisaligned
    case eyesTooCloseOrFar
    case mouthOutsideHead
    case mouthNotBelowEyes
    case mouthFarFromFaceAxis
}

/// Selective-prediction gate derived from out-of-fold complete-layout results.
/// A missing/invalid calibration deliberately means manual review only.
public struct FaceLayoutApprovalPolicy: Sendable, Equatable {
    public static let minimumCalibrationSampleCount = 30
    public static let maximumFalseAcceptRateUpper95: Float = 0.05

    public var minimumConfidence: Float?
    public var datasetFingerprint: String?
    public var calibrationSampleCount: Int
    public var falseAcceptRateUpper95: Float?

    public init(
        minimumConfidence: Float?,
        datasetFingerprint: String? = nil,
        calibrationSampleCount: Int = 0,
        falseAcceptRateUpper95: Float? = nil
    ) {
        self.minimumConfidence = minimumConfidence
        self.datasetFingerprint = datasetFingerprint
        self.calibrationSampleCount = max(0, calibrationSampleCount)
        self.falseAcceptRateUpper95 = falseAcceptRateUpper95
    }

    public static let manualOnly = FaceLayoutApprovalPolicy(minimumConfidence: nil)

    public var automaticApprovalEnabled: Bool {
        guard let minimumConfidence,
              minimumConfidence.isFinite,
              minimumConfidence >= FaceLayoutReview.minimumAutomaticConfidence,
              let datasetFingerprint,
              !datasetFingerprint.isEmpty,
              calibrationSampleCount >= Self.minimumCalibrationSampleCount,
              let falseAcceptRateUpper95,
              falseAcceptRateUpper95.isFinite,
              falseAcceptRateUpper95 >= 0,
              falseAcceptRateUpper95 <= Self.maximumFalseAcceptRateUpper95 else {
            return false
        }
        return true
    }

    /// Constructs an enabled policy only from a sufficiently large calibration
    /// set whose Wilson upper bound meets the caller's risk ceiling.
    public static func calibrated(
        minimumConfidence: Float,
        datasetFingerprint: String,
        sampleCount: Int,
        falseAcceptRateUpper95: Float,
        minimumSampleCount: Int = Self.minimumCalibrationSampleCount,
        maximumFalseAcceptRateUpper95: Float = Self.maximumFalseAcceptRateUpper95
    ) -> FaceLayoutApprovalPolicy {
        let requiredSampleCount = max(Self.minimumCalibrationSampleCount, minimumSampleCount)
        let allowedFalseAcceptRate = min(
            Self.maximumFalseAcceptRateUpper95,
            maximumFalseAcceptRateUpper95
        )
        guard minimumConfidence.isFinite,
              minimumConfidence >= FaceLayoutReview.minimumAutomaticConfidence,
              !datasetFingerprint.isEmpty,
              sampleCount >= requiredSampleCount,
              falseAcceptRateUpper95.isFinite,
              falseAcceptRateUpper95 >= 0,
              falseAcceptRateUpper95 <= allowedFalseAcceptRate else {
            return .manualOnly
        }
        return FaceLayoutApprovalPolicy(
            minimumConfidence: minimumConfidence,
            datasetFingerprint: datasetFingerprint,
            calibrationSampleCount: sampleCount,
            falseAcceptRateUpper95: falseAcceptRateUpper95
        )
    }
}

/// Geometry validation performed before an estimated layout is turned into a
/// destructive layer cut. `confidence` combines the estimator's own score with
/// independent anatomical checks; it is advisory, not a claim of probability.
public struct FaceLayoutReview: Sendable, Equatable {
    /// Conservative automatic-use gate. The pilot corpus currently contains
    /// visually plausible but badly localized Anime estimates around 0.47, so
    /// values below 0.50 must remain in the manual confirmation path until the
    /// heuristic confidence is calibrated on a larger held-out set.
    public static let minimumAutomaticConfidence: Float = 0.50

    public var confidence: Float
    public var issues: [FaceLayoutReviewIssue]
    public var approvalPolicy: FaceLayoutApprovalPolicy

    public init(
        confidence: Float,
        issues: [FaceLayoutReviewIssue],
        approvalPolicy: FaceLayoutApprovalPolicy = .manualOnly
    ) {
        self.confidence = min(max(confidence, 0), 1)
        self.issues = issues
        self.approvalPolicy = approvalPolicy
    }

    public var requiresReview: Bool {
        guard approvalPolicy.automaticApprovalEnabled,
              let threshold = approvalPolicy.minimumConfidence else { return true }
        return confidence < max(Self.minimumAutomaticConfidence, threshold) || !issues.isEmpty
    }
}

public struct FaceLayoutAlternative: Sendable, Equatable, Identifiable {
    public var id: String
    public var sourceLabel: String
    public var layout: FaceLayout
    public var review: FaceLayoutReview

    public init(
        id: String,
        sourceLabel: String,
        layout: FaceLayout,
        review: FaceLayoutReview
    ) {
        self.id = id
        self.sourceLabel = sourceLabel
        self.layout = layout
        self.review = review
    }
}

/// An estimated layout together with validation evidence for confirmation UI.
public struct FaceLayoutProposal: Sendable, Equatable {
    public var layout: FaceLayout
    public var review: FaceLayoutReview
    public var sourceID: String
    public var sourceLabel: String
    public var alternatives: [FaceLayoutAlternative]

    public init(
        layout: FaceLayout,
        review: FaceLayoutReview,
        sourceID: String = "automatic",
        sourceLabel: String = "Automatic",
        alternatives: [FaceLayoutAlternative] = []
    ) {
        self.layout = layout
        self.review = review
        self.sourceID = sourceID
        self.sourceLabel = sourceLabel
        self.alternatives = alternatives
    }
}

public enum FaceLayoutReviewer {
    /// Reviews original-image pixel coordinates against the selected subject.
    public static func review(
        layout: FaceLayout,
        subjectMask: FloatPlane,
        imageWidth: Int,
        imageHeight: Int,
        approvalPolicy: FaceLayoutApprovalPolicy = .manualOnly
    ) -> FaceLayoutReview {
        let imageRect = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let subjectRect = subjectBounds(
            subjectMask,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        ) ?? imageRect
        var issues: [FaceLayoutReviewIssue] = []

        if layout.confidence < 0.35 {
            issues.append(.lowEstimatorConfidence)
        }

        let head = layout.headRect
        let headH = max(1, head.height)
        let headW = max(1, head.width)
        let subjectH = max(1, subjectRect.height)
        let subjectW = max(1, subjectRect.width)

        if head.maxY > subjectRect.minY + subjectH * 0.48 {
            issues.append(.headExtendsTooLow)
        }
        if head.height > subjectH * 0.52 || head.width > subjectW * 0.92 {
            issues.append(.headIsTooLarge)
        }

        let leftEye = layout.eyeLeftRect
        let rightEye = layout.eyeRightRect
        let featureBounds = head.insetBy(dx: -headW * 0.02, dy: -headH * 0.02)
        if !featureBounds.contains(CGPoint(x: leftEye.midX, y: leftEye.midY))
            || !featureBounds.contains(CGPoint(x: rightEye.midX, y: rightEye.midY)) {
            issues.append(.eyesOutsideHead)
        }
        if abs(leftEye.midY - rightEye.midY) > headH * 0.14 {
            issues.append(.eyesMisaligned)
        }
        let eyeSeparation = rightEye.midX - leftEye.midX
        if eyeSeparation < headW * 0.12 || eyeSeparation > headW * 0.65 {
            issues.append(.eyesTooCloseOrFar)
        }

        let mouth = layout.mouthRect
        if !featureBounds.contains(CGPoint(x: mouth.midX, y: mouth.midY)) {
            issues.append(.mouthOutsideHead)
        }
        let eyesMidY = (leftEye.midY + rightEye.midY) / 2
        if mouth.midY <= eyesMidY + headH * 0.04 {
            issues.append(.mouthNotBelowEyes)
        }
        let faceAxisX = (leftEye.midX + rightEye.midX) / 2
        if abs(mouth.midX - faceAxisX) > max(headW * 0.15, abs(eyeSeparation) * 0.55) {
            issues.append(.mouthFarFromFaceAxis)
        }

        // Geometry penalties are intentionally stronger than the estimator's
        // self-confidence. A confident but anatomically impossible layout must
        // still surface as uncertain instead of silently cutting wrong layers.
        let geometryMultiplier = pow(0.78, Float(issues.filter { $0 != .lowEstimatorConfidence }.count))
        let confidence = min(max(layout.confidence * geometryMultiplier, 0), 1)
        return FaceLayoutReview(
            confidence: confidence,
            issues: issues,
            approvalPolicy: approvalPolicy
        )
    }

    private static func subjectBounds(
        _ mask: FloatPlane,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect? {
        var minX = mask.width
        var minY = mask.height
        var maxX = -1
        var maxY = -1
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask[x, y] > 0.5 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let scaleX = CGFloat(imageWidth) / CGFloat(max(1, mask.width))
        let scaleY = CGFloat(imageHeight) / CGFloat(max(1, mask.height))
        return CGRect(
            x: CGFloat(minX) * scaleX,
            y: CGFloat(minY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        )
    }
}
