import CoreGraphics
import CoreVideo
import Foundation
import Testing

@testable import ArilsRig

@Test func alphaProviderKeepsOriginalResolutionAndExactCoverage() async throws {
    var source = Bitmap(width: 64, height: 64)
    for y in 8..<56 {
        for x in 8..<56 {
            source.setRGBA(x: x, y: y, SIMD4(0.8, 0.6, 0.4, 1))
        }
    }
    source.setRGBA(x: 7, y: 32, SIMD4(0.4, 0.3, 0.2, 0.5))
    let image = try #require(source.cgImage())
    let analysis = source.downscaled(maxDimension: 8)
    let context = AnalysisContext(
        originalImage: image,
        analysis: analysis,
        originalBitmap: source
    )

    let masks = try #require(await AlphaSubjectMaskProvider().masks(for: context))

    #expect(masks.analysis.width == 8)
    #expect(masks.analysis.height == 8)
    #expect(masks.extraction.width == 64)
    #expect(masks.extraction.height == 64)
    #expect(abs(masks.extraction[7, 32] - 0.5) < 0.01)
    #expect(masks.extraction[6, 32] == 0)
    #expect(masks.extraction[8, 32] == 1)
}

@Test func alphaProviderSelectionUsesOriginalAlphaEvidence() async throws {
    var source = Bitmap(width: 100, height: 100)
    for y in 0..<source.height {
        for x in 0..<source.width {
            source.setRGBA(x: x, y: y, SIMD4(0.8, 0.6, 0.4, 1))
        }
    }
    // Exactly two percent of the original is transparent, but place the pixels
    // sparsely enough that an aggressively reduced analysis bitmap can average
    // them away. The exact source alpha must still select the alpha provider.
    for index in 0..<200 {
        let x = (index * 37) % source.width
        let y = index / 2
        source.setRGBA(x: x, y: y, .zero)
    }
    let image = try #require(source.cgImage())
    let analysis = source.downscaled(maxDimension: 4)
    let context = AnalysisContext(
        originalImage: image,
        analysis: analysis,
        originalBitmap: source
    )

    let masks = try #require(await AlphaSubjectMaskProvider().masks(for: context))

    #expect(masks.analysis.width == 4)
    #expect(masks.extraction.width == 100)
    #expect(masks.extraction.values.filter { $0 < 0.1 }.count >= 200)
}

@Test func visionMaskPlaneCanRemainAtOriginalResolution() throws {
    let width = 16
    let height = 8
    var optionalBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_OneComponent8,
        nil,
        &optionalBuffer
    )
    #expect(status == kCVReturnSuccess)
    let buffer = try #require(optionalBuffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            row[x] = x < 6 ? 0 : 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let plane = try #require(
        VisionSubjectMaskProvider.plane(
            from: buffer,
            targetWidth: width,
            targetHeight: height
        )
    )

    #expect(plane.width == width)
    #expect(plane.height == height)
    #expect(plane[5, 4] == 0)
    #expect(plane[6, 4] == 1)
}

@Test func layerFactoryCapsAuthoritativeAlphaInsteadOfSquaringIt() {
    var source = Bitmap(width: 32, height: 32)
    for y in 0..<32 {
        for x in 0..<32 {
            source.setRGBA(x: x, y: y, SIMD4(0.35, 0.25, 0.15, 0.5))
        }
    }
    let mask = source.alphaPlane()
    let plan = maskResolutionPlan(width: 32, height: 32)

    let layers = LayerFactory.extract(
        source: source,
        subjectMask: mask,
        plan: plan
    )

    // This body pixel is outside the curved moving-head ownership region.
    // Applying the same authoritative alpha multiplicatively would yield 0.25.
    #expect(abs(layers.body.alpha(x: 2, y: 28) - 0.5) < 0.02)
}

@Test func guidedUpsampleMovesTheCoarseMaskOntoTheOriginalColorEdge() {
    var fullGuide = Bitmap(width: 64, height: 32)
    for y in 0..<fullGuide.height {
        for x in 0..<fullGuide.width {
            let value: Float = x < 28 ? 0.95 : 0.05
            fullGuide.setRGBA(x: x, y: y, SIMD4(value, value, value, 1))
        }
    }
    let lowGuide = fullGuide.downscaled(maxDimension: 8)
    var lowMask = FloatPlane(width: lowGuide.width, height: lowGuide.height)
    for y in 0..<lowMask.height {
        for x in 4..<lowMask.width {
            lowMask[x, y] = 1
        }
    }

    let bilinear = lowMask.resized(width: 64, height: 32)
    let guided = SubjectMaskResampling.guidedUpsampled(
        lowMask,
        lowResolutionGuide: lowGuide,
        fullResolutionGuide: fullGuide
    )

    #expect(guided[26, 16] < 0.05)
    #expect(guided[29, 16] > bilinear[29, 16] + 0.25)
    #expect(guided[36, 16] > 0.95)
}

@Test func preparedTokenReusesSegmentationAndCutsWithTheExtractionMask() async throws {
    var source = Bitmap(width: 64, height: 64)
    for y in 0..<source.height {
        for x in 0..<source.width {
            source.setRGBA(x: x, y: y, SIMD4(0.7, 0.5, 0.3, 1))
        }
    }
    let image = try #require(source.cgImage())
    let analysisMask = FloatPlane(width: 16, height: 16, fill: 1)
    var extractionMask = FloatPlane(width: 64, height: 64, fill: 1)
    extractionMask[2, 55] = 0.5
    let counter = MaskResolutionProviderCounter()
    let pipeline = AutoRigPipeline(
        options: .init(analysisMaxDimension: 16, faceAnalysisMaxDimension: 32),
        maskProviders: [
            SplitResolutionMaskProvider(
                result: SubjectMaskSet(
                    analysis: analysisMask,
                    extraction: extractionMask
                ),
                counter: counter
            ),
        ],
        faceEstimator: MaskResolutionFaceEstimator()
    )

    let prepared = try await pipeline.prepare(image: image)
    let candidates = pipeline.subjectCandidates(from: prepared)
    let proposal = try await pipeline.faceLayoutProposal(from: prepared)
    let avatar = try await pipeline.makeAvatar(
        from: prepared,
        faceLayout: proposal.layout
    )
    _ = try await pipeline.assessQualityPair(
        front: prepared,
        side: prepared,
        sideFileName: "prepared-side.png"
    )
    _ = try await pipeline.makeQualityArchive(
        front: prepared,
        side: prepared,
        sideDirection: .right,
        sideFileName: "prepared-side.png",
        frontFaceLayout: proposal.layout,
        sideFaceLayout: proposal.layout
    )
    let calls = await counter.read()

    #expect(candidates.count == 1)
    #expect(calls.set == 1)
    #expect(calls.legacy == 0)
    let bodyImage = try #require(avatar.textures["body"])
    let body = try #require(Bitmap(image: bodyImage))
    #expect(abs(body.alpha(x: 2, y: 55) - 0.5) < 0.02)
}

@Test func selectedCandidateGatesTheFullMaskWithoutLosingItsThinTip() {
    var selectedAnalysis = FloatPlane(width: 8, height: 4)
    for y in 1...2 {
        for x in 1...2 {
            selectedAnalysis[x, y] = 1
        }
    }
    var extraction = FloatPlane(width: 64, height: 32)
    for y in 8..<24 {
        for x in 8..<23 {
            extraction[x, y] = 1
        }
        for x in 48..<57 {
            extraction[x, y] = 1
        }
    }
    // Full-resolution detail just outside the coarse component is preserved by
    // the one-analysis-cell support dilation.
    extraction[28, 16] = 0.4

    let selected = AutoRigPipeline.candidateExtractionMask(
        extraction,
        supportedBy: selectedAnalysis
    )

    #expect(selected[12, 16] == 1)
    #expect(abs(selected[28, 16] - 0.4) < 0.001)
    #expect(selected[52, 16] == 0)
}

@Test func precomputedUnderpaintEnvelopeMatchesTheCompatibilityEntryPoint() {
    let plan = maskResolutionPlan(width: 96, height: 128)
    let envelope = LayerFactory.underpaintEnvelope(for: plan)
    let points = [(24, 18), (48, 50), (70, 72), (48, 92), (3, 120)]

    for (x, y) in points {
        let legacy = LayerFactory.underpaintWeights(x: x, y: y, plan: plan)
        let precomputed = LayerFactory.underpaintWeights(
            x: x,
            y: y,
            plan: plan,
            envelope: envelope
        )
        #expect(abs(legacy.collar - precomputed.collar) < 0.000_001)
        #expect(abs(legacy.side - precomputed.side) < 0.000_001)
    }
}

private actor MaskResolutionProviderCounter {
    private var setCalls = 0
    private var legacyCalls = 0

    func recordSet() {
        setCalls += 1
    }

    func recordLegacy() {
        legacyCalls += 1
    }

    func read() -> (set: Int, legacy: Int) {
        (setCalls, legacyCalls)
    }
}

private struct SplitResolutionMaskProvider: SubjectMaskProviding {
    let result: SubjectMaskSet
    let counter: MaskResolutionProviderCounter
    let isAuthoritativeAlpha = true

    func mask(for context: AnalysisContext) async -> FloatPlane? {
        await counter.recordLegacy()
        return result.analysis
    }

    func masks(for context: AnalysisContext) async -> SubjectMaskSet? {
        await counter.recordSet()
        return result
    }
}

private struct MaskResolutionFaceEstimator: FaceLayoutEstimating {
    func estimateLayout(
        context: AnalysisContext,
        subjectMask: FloatPlane
    ) async -> FaceLayout? {
        maskResolutionLayout(width: context.originalImage.width, height: context.originalImage.height)
    }
}

private func maskResolutionLayout(width: Int, height: Int) -> FaceLayout {
    let width = CGFloat(width)
    let height = CGFloat(height)
    return FaceLayout(
        headRect: CGRect(
            x: width * 0.25,
            y: height * 0.05,
            width: width * 0.5,
            height: height * 0.45
        ),
        eyeLeftRect: CGRect(
            x: width * 0.34,
            y: height * 0.22,
            width: width * 0.12,
            height: height * 0.08
        ),
        eyeRightRect: CGRect(
            x: width * 0.54,
            y: height * 0.22,
            width: width * 0.12,
            height: height * 0.08
        ),
        mouthRect: CGRect(
            x: width * 0.43,
            y: height * 0.39,
            width: width * 0.14,
            height: height * 0.06
        ),
        confidence: 1
    )
}

private func maskResolutionPlan(width: Int, height: Int) -> PartPlan {
    let layout = maskResolutionLayout(width: width, height: height)
    return PartPlan(
        imageWidth: width,
        imageHeight: height,
        subjectRect: CGRect(x: 0, y: 0, width: width, height: height),
        headRect: layout.headRect,
        eyeLeftRect: layout.eyeLeftRect,
        eyeRightRect: layout.eyeRightRect,
        mouthRect: layout.mouthRect,
        collarHeight: layout.headRect.height * 0.14
    )
}
