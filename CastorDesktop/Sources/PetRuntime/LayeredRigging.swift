import ArilsCore
import ArilsPlayer
import ArilsRigPortable
import Foundation

public struct PreparedPortableRig: Sendable {
    public let source: PortableRigImage
    public let bitmap: Bitmap
    public let analysisContext: AnalysisContext
    public let faceContext: AnalysisContext
    public let masks: SubjectMaskSet
    public let maskIsAuthoritative: Bool
    public let face: FaceLayoutProposal
    public let warnings: [String]

    public var preview: PortableRigImage {
        var image = source
        for index in masks.extraction.values.indices {
            let alpha = UInt8(min(max(masks.extraction.values[index], 0), 1) * 255)
            image.rgba[index * 4 + 3] = min(image.rgba[index * 4 + 3], alpha)
        }
        return image
    }
}

public enum LayeredRigging {
    public enum RigError: LocalizedError {
        case subjectNotFound, faceNotFound, selectSubject([RiggingSubjectCandidate])
        public var errorDescription: String? {
            switch self {
            case .subjectNotFound: "キャラクターを切り抜けませんでした。透過PNGまたは背景が単色の画像を選んでください。"
            case .faceNotFound: "顔を推定できませんでした。頭・目・口を補正してください。"
            case .selectSubject: "複数の被写体があります。作成するキャラクターを選んでください。"
            }
        }
    }

    public static func bitmap(from image: PortableRigImage) -> Bitmap {
        var pixels = image.rgba
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = UInt32(pixels[i + 3])
            for c in 0..<3 { pixels[i + c] = UInt8((UInt32(pixels[i + c]) * alpha + 127) / 255) }
        }
        return Bitmap(width: image.width, height: image.height, pixels: pixels)
    }

    public static func png(from bitmap: Bitmap) throws -> Data {
        var pixels = bitmap.pixels
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = UInt32(pixels[i + 3])
            for c in 0..<3 {
                pixels[i + c] = alpha == 0 ? 0 : UInt8(min(255, (UInt32(pixels[i + c]) * 255 + alpha / 2) / alpha))
            }
        }
        return try PortableRigImage(width: bitmap.width, height: bitmap.height, rgba: pixels).pngData()
    }

    public static func prepare(_ source: PortableRigImage, selecting candidateID: Int? = nil) async throws -> PreparedPortableRig {
        try Task.checkCancellation()
        let bitmap = bitmap(from: source)
        guard let context = AnalysisContext(bitmap: bitmap),
              let faceContext = AnalysisContext(bitmap: bitmap, analysisMaxDimension: 768) else { throw RigError.subjectNotFound }
        var chosen: SubjectMaskSet?
        var authoritative = true
        for provider: any SubjectMaskProviding in [AlphaSubjectMaskProvider(), BorderBackgroundSubjectMaskProvider()] {
            if let masks = await provider.masks(for: context) {
                chosen = masks; authoritative = provider.isAuthoritativeAlpha; break
            }
        }
        guard var masks = chosen else { throw RigError.subjectNotFound }
        let candidates = SubjectCandidates.candidates(in: masks.analysis)
        if candidates.count > 1, candidateID == nil { throw RigError.selectSubject(candidates) }
        if let candidateID {
            guard let selected = SubjectCandidates.mask(in: masks.analysis, selecting: candidateID) else { throw RigError.subjectNotFound }
            masks = SubjectMaskSet(analysis: selected, extraction: SubjectCandidates.extractionMask(masks.extraction, supportedBy: selected))
        }
        let faceMask = masks.analysis.resized(width: faceContext.analysis.width, height: faceContext.analysis.height)
        let estimate = await AnimeFaceEstimator().estimateLayout(context: faceContext, subjectMask: faceMask)
        let layout: FaceLayout
        let label: String
        var warnings = ["顔の推定結果は自動承認しません。頭・目・口の範囲を確認してください。",
                        "WindowsのVision/Core ML代替モデルは未接続です。現在は共有のイラスト推定器を使用します。"]
        if let estimate {
            layout = estimate; label = "Illustration heuristic"
        } else {
            // An explicit editable template fallback, never a confirmed AI result.
            let draft = try PortableRigBuilder.prepare(source)
            layout = faceLayout(draft.layout, confidence: 0)
            label = "Template (manual review)"
            warnings.append("顔推定に失敗したためテンプレートを表示しています。補正が必要です。")
        }
        let review = FaceLayoutReviewer.review(layout: layout, subjectMask: masks.analysis,
            imageWidth: source.width, imageHeight: source.height, approvalPolicy: .manualOnly)
        try Task.checkCancellation()
        return PreparedPortableRig(source: source, bitmap: bitmap, analysisContext: context, faceContext: faceContext,
            masks: masks, maskIsAuthoritative: authoritative,
            face: FaceLayoutProposal(layout: layout, review: review, sourceLabel: label), warnings: warnings)
    }

    public static func markers(_ layout: FaceLayout) -> PortableFaceLayout {
        PortableFaceLayout(head: layout.headRect, eyeLeft: layout.eyeLeftRect, eyeRight: layout.eyeRightRect, mouth: layout.mouthRect)
    }
    public static func faceLayout(_ layout: PortableFaceLayout, confidence: Float = 0) -> FaceLayout {
        FaceLayout(headRect: layout.head, eyeLeftRect: layout.eyeLeft, eyeRightRect: layout.eyeRight,
                   mouthRect: layout.mouth, confidence: confidence)
    }

    private static func layers(_ prepared: PreparedPortableRig, markers: PortableFaceLayout) throws -> RigLayerBuild {
        try markers.validate(width: prepared.source.width, height: prepared.source.height)
        return RigLayerBuilder.build(source: prepared.bitmap, analysisMask: prepared.masks.analysis,
            extractionMask: prepared.masks.extraction, layout: faceLayout(markers), maskIsAuthoritative: prepared.maskIsAuthoritative)
    }

    public static func build(_ prepared: PreparedPortableRig, markers: PortableFaceLayout) throws -> AvatarArchive {
        try Task.checkCancellation()
        let archive = try layers(prepared, markers: markers).archive(encoding: png)
        try Task.checkCancellation()
        return archive
    }

    public static func buildQuality(front: PreparedPortableRig, side: PreparedPortableRig,
                                    frontMarkers: PortableFaceLayout, sideMarkers: PortableFaceLayout,
                                    direction: QualitySideDirection, sideFileName: String) async throws -> QualityAvatarArchive {
        try Task.checkCancellation()
        let assessment = await QualityPairInspector.assess(front: (front.analysisContext, front.masks.analysis),
            side: (side.analysisContext, side.masks.analysis), faceEstimator: AnimeFaceEstimator(), sideFileName: sideFileName)
        let frontBuild = try layers(front, markers: frontMarkers)
        let sideBuild = try layers(side, markers: sideMarkers)
        let depth = RigLayerBuilder.addQualityDepth(front: frontBuild, side: sideBuild,
            frontSource: front.bitmap, sideSource: side.bitmap, frontMask: front.masks.analysis, sideMask: side.masks.analysis)
        try Task.checkCancellation()
        return try QualityAvatarArchive(front: depth.front.archive(encoding: png), side: sideBuild.archive(encoding: png),
                                        sideDirection: direction, registration: depth.registration, assessment: assessment)
    }

    public static func savedPetData(source: PortableRigImage, asset: PetAsset) throws -> Data {
        struct Saved: Encodable { let imageData: Data; let arilsArchiveData: Data?; let qualityArchiveData: Data? }
        switch asset {
        case let .manual(pet): return try pet.data()
        case let .standard(archive):
            return try JSONEncoder().encode(Saved(imageData: source.pngData(), arilsArchiveData: archive.data(), qualityArchiveData: nil))
        case let .quality(archive):
            return try JSONEncoder().encode(Saved(imageData: source.pngData(), arilsArchiveData: nil, qualityArchiveData: archive.data()))
        }
    }
}
