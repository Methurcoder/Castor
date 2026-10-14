import CoreGraphics
import Foundation

/// Anything that can turn a single image into a ready-to-animate avatar.
/// `AutoRigPipeline` is the built-in implementation; a future ML-based rigger
/// (or a hand-authoring tool) replaces it behind this protocol.
public protocol RiggingPipeline: Sendable {
    func makeAvatar(from image: CGImage) async throws -> RiggedAvatar
}

public enum RiggingError: Error, Equatable {
    case imageUnreadable
    case faceNotFound
    case subjectNotFound
    case textureEncodingFailed
}

/// Opaque, reusable result of image decoding, downscaling, and subject
/// segmentation. Hosts can carry this token through candidate selection, face
/// review, and final Build without repeating those expensive stages.
///
/// The reference storage deliberately keeps the large source bitmap and
/// full-resolution mask from being copied when this value is passed around.
public struct PreparedRiggingInput: @unchecked Sendable {
    fileprivate final class Storage: @unchecked Sendable {
        let source: Bitmap
        let context: AnalysisContext
        let faceContext: AnalysisContext
        let analysisSubjectMask: FloatPlane
        let extractionSubjectMask: FloatPlane
        let maskIsAuthoritative: Bool

        init(
            source: Bitmap,
            context: AnalysisContext,
            faceContext: AnalysisContext,
            analysisSubjectMask: FloatPlane,
            extractionSubjectMask: FloatPlane,
            maskIsAuthoritative: Bool
        ) {
            self.source = source
            self.context = context
            self.faceContext = faceContext
            self.analysisSubjectMask = analysisSubjectMask
            self.extractionSubjectMask = extractionSubjectMask
            self.maskIsAuthoritative = maskIsAuthoritative
        }
    }

    fileprivate let storage: Storage

    fileprivate init(storage: Storage) {
        self.storage = storage
    }
}

/// The default automatic rigging pipeline. Every stage is injected, so any
/// single algorithm — segmentation, face estimation, the whole binding rules —
/// can be swapped without touching the others:
///
///     image → subject mask → face layout → part plan → layers → rig
public struct AutoRigPipeline: RiggingPipeline {
    public struct Options: Sendable {
        /// Longest side of the analysis bitmap heuristics run on.
        public var analysisMaxDimension: Int
        /// Longest side used only for face features. Subject segmentation and
        /// connected-component work stay cheap at `analysisMaxDimension`.
        public var faceAnalysisMaxDimension: Int
        public var qualityDepthStrategy: QualityDepthStrategy
        public var qualityHeadMeshResolution: Int
        /// Build-time integrity grid used to persist per-avatar safe pose limits.
        public var poseSweepPlan: PoseSweepPlan

        public init(
            analysisMaxDimension: Int = 256,
            faceAnalysisMaxDimension: Int = 768,
            qualityDepthStrategy: QualityDepthStrategy = .faceAwareRibbon,
            qualityHeadMeshResolution: Int = 24,
            poseSweepPlan: PoseSweepPlan = .supportedHead
        ) {
            self.analysisMaxDimension = analysisMaxDimension
            self.faceAnalysisMaxDimension = max(analysisMaxDimension, faceAnalysisMaxDimension)
            self.qualityDepthStrategy = qualityDepthStrategy
            self.qualityHeadMeshResolution = min(max(qualityHeadMeshResolution, 12), 48)
            self.poseSweepPlan = poseSweepPlan
        }
    }

    public var options: Options
    /// Tried in order; the first non-nil mask wins.
    public var maskProviders: [any SubjectMaskProviding]
    public var faceEstimator: any FaceLayoutEstimating
    /// Automatic approval stays disabled until a caller injects a policy built
    /// from current out-of-fold complete-layout calibration evidence.
    public var faceApprovalPolicy: FaceLayoutApprovalPolicy
    /// Optional archive-build-time repair. Failure is deliberately non-fatal:
    /// `LayerFactory` always has a deterministic low-frequency fallback.
    public var occlusionInpainter: (any OcclusionInpaintingProviding)?

    /// Default configuration: alpha channel first (character PNGs), Vision
    /// segmentation for opaque images, then a flat-background flood fill for
    /// illustration exports. A full-frame mask is deliberately not a default:
    /// it erases the silhouette information the head/neck estimator requires.
    /// Anime heuristics lead face estimation with Vision as the photo fallback.
    public init(
        options: Options = Options(),
        maskProviders: [any SubjectMaskProviding] = [
            AlphaSubjectMaskProvider(),
            VisionSubjectMaskProvider(),
            BorderBackgroundSubjectMaskProvider(),
        ],
        faceEstimator: any FaceLayoutEstimating = CompositeFaceEstimator(estimators: [
            AnimeFaceEstimator(),
            VisionFaceEstimator(),
        ]),
        faceApprovalPolicy: FaceLayoutApprovalPolicy = .manualOnly,
        occlusionInpainter: (any OcclusionInpaintingProviding)? = nil
    ) {
        self.options = options
        self.maskProviders = maskProviders
        self.faceEstimator = faceEstimator
        self.faceApprovalPolicy = faceApprovalPolicy
        self.occlusionInpainter = occlusionInpainter
    }

    public func makeAvatar(from image: CGImage) async throws -> RiggedAvatar {
        let prepared = try await prepare(image: image)
        return try await makeAvatar(from: prepared)
    }

    public func makeAvatar(from prepared: PreparedRiggingInput) async throws -> RiggedAvatar {
        let masks = PreparedMasks(
            analysis: prepared.storage.analysisSubjectMask,
            extraction: prepared.storage.extractionSubjectMask
        )
        return try await buildAvatar(prepared: prepared, masks: masks).avatar
    }

    /// Estimates and independently reviews the face layout before layer cuts
    /// are made. Hosts should use this for confirmation/manual-correction UI.
    public func faceLayoutProposal(
        from image: CGImage,
        selecting candidate: RiggingSubjectCandidate? = nil
    ) async throws -> FaceLayoutProposal {
        let prepared = try await prepare(image: image)
        return try await faceLayoutProposal(from: prepared, selecting: candidate)
    }

    public func faceLayoutProposal(
        from prepared: PreparedRiggingInput,
        selecting candidate: RiggingSubjectCandidate? = nil
    ) async throws -> FaceLayoutProposal {
        let mask = try selectedAnalysisMask(for: candidate, in: prepared)
        return try await faceLayoutProposal(
            prepared: prepared,
            subjectMask: mask
        )
    }

    /// Builds from a user-confirmed layout. The selected subject mask is still
    /// honored, so manual face correction does not reintroduce other figures.
    public func makeAvatar(
        from image: CGImage,
        selecting candidate: RiggingSubjectCandidate? = nil,
        faceLayout: FaceLayout
    ) async throws -> RiggedAvatar {
        let prepared = try await prepare(image: image)
        return try await makeAvatar(
            from: prepared,
            selecting: candidate,
            faceLayout: faceLayout
        )
    }

    public func makeAvatar(
        from prepared: PreparedRiggingInput,
        selecting candidate: RiggingSubjectCandidate? = nil,
        faceLayout: FaceLayout
    ) async throws -> RiggedAvatar {
        let masks = try selectedMasks(for: candidate, in: prepared)
        return try await buildAvatar(
            prepared: prepared,
            masks: masks,
            faceLayout: faceLayout
        ).avatar
    }

    /// Returns separately selectable foreground regions. Touching or overlapping
    /// figures intentionally remain one candidate; this API never guesses a
    /// separation that is not present in the mask.
    public func subjectCandidates(from image: CGImage) async throws -> [RiggingSubjectCandidate] {
        let prepared = try await prepare(image: image)
        return subjectCandidates(from: prepared)
    }

    public func subjectCandidates(
        from prepared: PreparedRiggingInput
    ) -> [RiggingSubjectCandidate] {
        SubjectCandidates.candidates(in: prepared.storage.analysisSubjectMask)
    }

    /// Auto-rigs just one previously discovered candidate, making every other
    /// disconnected foreground component transparent before layer extraction.
    public func makeAvatar(from image: CGImage, selecting candidate: RiggingSubjectCandidate) async throws -> RiggedAvatar {
        let prepared = try await prepare(image: image)
        return try await makeAvatar(from: prepared, selecting: candidate)
    }

    public func makeAvatar(
        from prepared: PreparedRiggingInput,
        selecting candidate: RiggingSubjectCandidate
    ) async throws -> RiggedAvatar {
        let masks = try selectedMasks(for: candidate, in: prepared)
        return try await buildAvatar(prepared: prepared, masks: masks).avatar
    }

    /// Assesses whether two references are usable as a front/profile quality
    /// pair. The result is advisory and intentionally preserves uncertainty.
    public func assessQualityPair(
        front: CGImage,
        side: CGImage,
        sideFileName: String,
        frontCandidate: RiggingSubjectCandidate? = nil,
        sideCandidate: RiggingSubjectCandidate? = nil
    ) async throws -> QualityPairAssessment {
        let frontInput = try await prepare(image: front)
        let sideInput = try await prepare(image: side)
        return try await assessQualityPair(
            front: frontInput,
            side: sideInput,
            sideFileName: sideFileName,
            frontCandidate: frontCandidate,
            sideCandidate: sideCandidate
        )
    }

    public func assessQualityPair(
        front: PreparedRiggingInput,
        side: PreparedRiggingInput,
        sideFileName: String,
        frontCandidate: RiggingSubjectCandidate? = nil,
        sideCandidate: RiggingSubjectCandidate? = nil
    ) async throws -> QualityPairAssessment {
        let frontMask = try selectedAnalysisMask(for: frontCandidate, in: front)
        let sideMask = try selectedAnalysisMask(for: sideCandidate, in: side)
        return await QualityPairInspector.assess(
            front: (front.storage.context, frontMask),
            side: (side.storage.context, sideMask),
            faceEstimator: faceEstimator,
            sideFileName: sideFileName
        )
    }

    /// Builds and archives both independently rigged views after reporting
    /// confidence. The caller decides whether warnings require confirmation.
    public func makeQualityArchive(
        front: CGImage,
        side: CGImage,
        sideDirection: QualitySideDirection,
        sideFileName: String,
        frontCandidate: RiggingSubjectCandidate? = nil,
        sideCandidate: RiggingSubjectCandidate? = nil,
        frontFaceLayout: FaceLayout? = nil,
        sideFaceLayout: FaceLayout? = nil
    ) async throws -> QualityAvatarArchive {
        let frontInput = try await prepare(image: front)
        let sideInput = try await prepare(image: side)
        return try await makeQualityArchive(
            front: frontInput,
            side: sideInput,
            sideDirection: sideDirection,
            sideFileName: sideFileName,
            frontCandidate: frontCandidate,
            sideCandidate: sideCandidate,
            frontFaceLayout: frontFaceLayout,
            sideFaceLayout: sideFaceLayout
        )
    }

    public func makeQualityArchive(
        front: PreparedRiggingInput,
        side: PreparedRiggingInput,
        sideDirection: QualitySideDirection,
        sideFileName: String,
        frontCandidate: RiggingSubjectCandidate? = nil,
        sideCandidate: RiggingSubjectCandidate? = nil,
        frontFaceLayout: FaceLayout? = nil,
        sideFaceLayout: FaceLayout? = nil
    ) async throws -> QualityAvatarArchive {
        let frontMasks = try selectedMasks(for: frontCandidate, in: front)
        let sideMasks = try selectedMasks(for: sideCandidate, in: side)
        let assessment = await QualityPairInspector.assess(
            front: (front.storage.context, frontMasks.analysis),
            side: (side.storage.context, sideMasks.analysis),
            faceEstimator: faceEstimator,
            sideFileName: sideFileName
        )
        var frontBuild = try await buildAvatar(
            prepared: front,
            masks: frontMasks,
            faceLayout: frontFaceLayout
        )
        let sideBuild = try await buildAvatar(
            prepared: side,
            masks: sideMasks,
            faceLayout: sideFaceLayout
        )
        let sideAvatar = sideBuild.avatar
        let depthBuild = RigLayerBuilder.addQualityDepth(
            front: frontBuild.shared, side: sideBuild.shared,
            frontSource: front.storage.source, sideSource: side.storage.source,
            frontMask: frontMasks.analysis, sideMask: sideMasks.analysis,
            strategy: options.qualityDepthStrategy,
            headMeshResolution: options.qualityHeadMeshResolution,
            poseSweep: options.poseSweepPlan)
        frontBuild.avatar.rig = depthBuild.front.rig
        let registration = depthBuild.registration
        return try QualityAvatarArchive(
            front: AvatarArchive(avatar: frontBuild.avatar),
            side: AvatarArchive(avatar: sideAvatar),
            sideDirection: sideDirection,
            registration: registration,
            assessment: assessment
        )
    }

    private struct PreparedMasks {
        var analysis: FloatPlane
        var extraction: FloatPlane
    }

    private struct AvatarBuild {
        var avatar: RiggedAvatar
        var shared: RigLayerBuild
        var plan: PartPlan { shared.plan }
        var alphaCoverageByPartID: [String: FloatPlane] { shared.alphaCoverage }
    }

    /// Decodes and segments an image once for reuse by the token overloads.
    public func prepare(image: CGImage) async throws -> PreparedRiggingInput {
        guard let source = Bitmap(image: image) else {
            throw RiggingError.imageUnreadable
        }
        let analysis = source.downscaled(maxDimension: options.analysisMaxDimension)
        let context = AnalysisContext(
            originalImage: image,
            analysis: analysis,
            originalBitmap: source
        )
        let faceAnalysis = source.downscaled(maxDimension: options.faceAnalysisMaxDimension)
        let faceContext = AnalysisContext(
            originalImage: image,
            analysis: faceAnalysis,
            originalBitmap: source
        )

        var subjectMasks: SubjectMaskSet?
        var maskIsAuthoritative = true
        for provider in maskProviders {
            if let masks = await provider.masks(for: context) {
                subjectMasks = SubjectMaskSet(
                    analysis: masks.analysis.resized(
                        width: analysis.width,
                        height: analysis.height
                    ),
                    extraction: masks.extraction.resized(
                        width: source.width,
                        height: source.height
                    )
                )
                maskIsAuthoritative = provider.isAuthoritativeAlpha
                break
            }
        }
        guard let masks = subjectMasks else { throw RiggingError.subjectNotFound }

        return PreparedRiggingInput(
            storage: .init(
                source: source,
                context: context,
                faceContext: faceContext,
                analysisSubjectMask: masks.analysis,
                extractionSubjectMask: masks.extraction,
                maskIsAuthoritative: maskIsAuthoritative
            )
        )
    }

    private func buildAvatar(
        prepared: PreparedRiggingInput,
        masks: PreparedMasks,
        faceLayout: FaceLayout? = nil
    ) async throws -> AvatarBuild {
        let storage = prepared.storage
        let layout: FaceLayout
        if let faceLayout {
            layout = faceLayout
        } else {
            layout = try await faceLayoutProposal(
                prepared: prepared,
                subjectMask: masks.analysis
            ).layout
        }

        let plan = PartPlanner.plan(
            layout: layout,
            subjectMask: masks.analysis,
            imageWidth: storage.source.width,
            imageHeight: storage.source.height
        )
        var inpaintedSource: Bitmap?
        if let occlusionInpainter,
           let request = LayerFactory.occlusionInpaintingRequest(
               source: storage.source,
               subjectMask: masks.extraction,
               plan: plan,
               sharpenMaskEdges: !storage.maskIsAuthoritative
           ),
           let result = try? await occlusionInpainter.inpaint(request),
           result.width == storage.source.width,
           result.height == storage.source.height {
            inpaintedSource = Bitmap(image: result)
        }
        let shared = RigLayerBuilder.build(
            source: storage.source, extractionMask: masks.extraction, plan: plan,
            maskIsAuthoritative: storage.maskIsAuthoritative,
            inpaintedSource: inpaintedSource, poseSweep: options.poseSweepPlan)
        var textures: [String: CGImage] = [:]
        for (partID, bitmap) in shared.layers {
            guard let image = bitmap.cgImage() else { throw RiggingError.textureEncodingFailed }
            textures[partID] = image
        }
        return AvatarBuild(avatar: RiggedAvatar(rig: shared.rig, textures: textures), shared: shared)
    }

    private func faceLayoutProposal(
        prepared: PreparedRiggingInput,
        subjectMask: FloatPlane
    ) async throws -> FaceLayoutProposal {
        let storage = prepared.storage
        let faceMask = subjectMask.resized(
            width: storage.faceContext.analysis.width,
            height: storage.faceContext.analysis.height
        )
        func review(_ layout: FaceLayout) -> FaceLayoutReview {
            FaceLayoutReviewer.review(
                layout: layout,
                subjectMask: subjectMask,
                imageWidth: storage.source.width,
                imageHeight: storage.source.height,
                approvalPolicy: faceApprovalPolicy
            )
        }

        if let candidateEstimator = faceEstimator as? any FaceLayoutCandidatesEstimating {
            let candidates = await candidateEstimator.estimateCandidates(
                context: storage.faceContext,
                subjectMask: faceMask
            )
            guard let preferred = candidateEstimator.preferredCandidate(from: candidates) else {
                throw RiggingError.faceNotFound
            }
            let alternatives = candidates.compactMap { candidate -> FaceLayoutAlternative? in
                guard candidate.id != preferred.id else { return nil }
                return FaceLayoutAlternative(
                    id: candidate.id,
                    sourceLabel: candidate.sourceLabel,
                    layout: candidate.layout,
                    review: review(candidate.layout)
                )
            }
            return FaceLayoutProposal(
                layout: preferred.layout,
                review: review(preferred.layout),
                sourceID: preferred.id,
                sourceLabel: preferred.sourceLabel,
                alternatives: alternatives
            )
        }

        guard let layout = await faceEstimator.estimateLayout(
            context: storage.faceContext,
            subjectMask: faceMask
        ) else {
            throw RiggingError.faceNotFound
        }
        return FaceLayoutProposal(layout: layout, review: review(layout))
    }

    private func selectedMasks(
        for candidate: RiggingSubjectCandidate?,
        in prepared: PreparedRiggingInput
    ) throws -> PreparedMasks {
        let storage = prepared.storage
        guard let candidate else {
            return PreparedMasks(
                analysis: storage.analysisSubjectMask,
                extraction: storage.extractionSubjectMask
            )
        }
        let selected = try selectedAnalysisMask(for: candidate, in: prepared)
        return PreparedMasks(
            analysis: selected,
            extraction: Self.candidateExtractionMask(
                storage.extractionSubjectMask,
                supportedBy: selected
            )
        )
    }

    private func selectedAnalysisMask(
        for candidate: RiggingSubjectCandidate?,
        in prepared: PreparedRiggingInput
    ) throws -> FloatPlane {
        guard let candidate else {
            return prepared.storage.analysisSubjectMask
        }
        guard let selected = SubjectCandidates.mask(
            in: prepared.storage.analysisSubjectMask,
            selecting: candidate.id
        ) else {
            throw RiggingError.subjectNotFound
        }
        return selected
    }

    /// Candidate ids belong to analysis components. Instead of assuming the
    /// full-resolution connected components have identical ids/topology,
    /// expand the selected analysis support by one cell and use it only as a
    /// gate over the exact extraction mask. The dilation preserves full-size
    /// antialiasing and thin tips at the selected component's boundary.
    static func candidateExtractionMask(_ extraction: FloatPlane, supportedBy selectedAnalysis: FloatPlane) -> FloatPlane {
        SubjectCandidates.extractionMask(extraction, supportedBy: selectedAnalysis)
    }
}
