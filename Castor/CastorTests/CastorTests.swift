import AppKit
import Arils
import CoreGraphics
import Foundation
import NaturalLanguage
import Testing
@testable import Castor
import CastorCore

@MainActor
struct CastorTests {
    @Test func savedPetReadsLegacyLocationAndPrefersCastorWithoutChangingLegacyFile() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("castor-pet-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        let legacy = base.appendingPathComponent("Pomegranate/PomegranatePet.json")
        try manager.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldData = try JSONEncoder().encode(SavedPetCharacter(arilsArchiveData: Data("legacy".utf8)))
        try oldData.write(to: legacy)
        #expect(PetCharacterStore.load(in: base)?.arilsArchiveData == Data("legacy".utf8))

        let current = PetCharacterStore.fileURL(in: base)
        #expect(current.lastPathComponent == "CastorPet.json")
        #expect(current.deletingLastPathComponent().lastPathComponent == "Castor")
        try manager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(SavedPetCharacter(arilsArchiveData: Data("current".utf8))).write(to: current)
        #expect(PetCharacterStore.load(in: base)?.arilsArchiveData == Data("current".utf8))
        #expect(try Data(contentsOf: legacy) == oldData)

        // A damaged new file must not silently resurrect a different old pet.
        try Data("invalid json".utf8).write(to: current)
        #expect(PetCharacterStore.load(in: base) == nil)
    }


    // MARK: - Anime face landmarks beta

    @Test func animeFaceLandmarksLeadFaceEstimationOnlyWhenEnabled() throws {
        #expect(AnimeFaceLandmarksSettingsStore.defaultEnabled)

        let key = AnimeFaceLandmarksSettingsStore.enabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        AnimeFaceLandmarksSettingsStore.isEnabled = true
        let enabled = try #require(
            ArilsRiggingPipelines.make().faceEstimator as? CompositeFaceEstimator
        )
        #expect(enabled.estimators.first is AnimeFaceCoreMLEstimator)
        #expect(enabled.estimators.contains { $0 is AnimeFaceEstimator })
        #expect(enabled.estimators.contains { $0 is VisionFaceEstimator })
        #expect(!enabled.estimators.contains { $0 is AnimeFaceServiceEstimator })

        AnimeFaceLandmarksSettingsStore.isEnabled = false
        let disabled = try #require(
            ArilsRiggingPipelines.make().faceEstimator as? CompositeFaceEstimator
        )
        #expect(!disabled.estimators.contains { $0 is AnimeFaceCoreMLEstimator })
    }

    @Test func faceReviewExplainsWhenTheLandmarkModelWasNotUsed() {
        let landmark = AnimeFaceCoreMLEstimator.sourceLabel
        #expect(AnimeFaceLandmarksSettingsStore.landmarkModelWasMissing(
            enabled: true, candidateSources: ["Illustration heuristic"]
        ))
        #expect(!AnimeFaceLandmarksSettingsStore.landmarkModelWasMissing(
            enabled: true, candidateSources: [landmark, "Illustration heuristic"]
        ))
        // Turned off on purpose: nothing to explain.
        #expect(!AnimeFaceLandmarksSettingsStore.landmarkModelWasMissing(
            enabled: false, candidateSources: ["Illustration heuristic"]
        ))
    }

    // MARK: - LaMa underpaint beta

    @Test func laMaUnderpaintDefaultsOffAndRejectsRemoteEndpoints() {
        #expect(!LaMaInpaintingSettingsStore.defaultEnabled)
        #expect(LaMaInpaintingClient.isAllowedEndpoint(
            URL(string: "http://127.0.0.1:8123/v1/inpaint")!
        ))
        #expect(LaMaInpaintingClient.isAllowedEndpoint(
            URL(string: "http://localhost:8123/v1/inpaint")!
        ))
        #expect(!LaMaInpaintingClient.isAllowedEndpoint(
            URL(string: "https://127.0.0.1:8123/v1/inpaint")!
        ))
        #expect(!LaMaInpaintingClient.isAllowedEndpoint(
            URL(string: "http://example.com/v1/inpaint")!
        ))
        #expect(
            LaMaInpaintingError.server(status: 503, message: "warming up").localizedDescription
                == "LaMa server error 503: warming up"
        )
    }

    @Test func laMaUnavailableGuidanceIncludesTheRealErrorAndSetupCommands() {
        #expect(
            LaMaInpaintingSetupGuidance.unavailableStatus(
                errorDescription: "Could not connect to the server."
            ) == "Unavailable: Could not connect to the server."
        )
        #expect(
            LaMaInpaintingSetupGuidance.bootstrapCommand
                == "scripts/bootstrap-lama-inpainting.sh"
        )
        #expect(
            LaMaInpaintingSetupGuidance.startCommand
                == "scripts/start-lama-inpainting.sh"
        )
    }

    @Test func laMaClientSendsPNGInputsAndAcceptsSameSizePNGOutput() async throws {
        let endpoint = URL(string: "http://127.0.0.1:18124/v1/inpaint")!
        let source = try Self.makeTinyCGImage(red: 0.8, green: 0.1, blue: 0.2)
        let output = try Self.makeTinyCGImage(red: 0.1, green: 0.8, blue: 0.2)
        let outputPNG = try #require(
            NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
        )
        LaMaClientURLProtocol.reset(responseData: outputPNG)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaMaClientURLProtocol.self]
        let client = LaMaInpaintingClient(
            endpoint: endpoint,
            session: URLSession(configuration: configuration)
        )

        let result = try await client.inpaint(
            OcclusionInpaintingRequest(sourceImage: source, maskImage: source)
        )
        #expect(result.width == source.width)
        #expect(result.height == source.height)
        #expect(client.report == LaMaInpaintingReport(attempts: 1, successes: 1, failures: 0))

        let request = try #require(LaMaClientURLProtocol.recordedRequest())
        let body = try Self.jsonBody(from: request)
        #expect((body["image"] as? String)?.isEmpty == false)
        #expect((body["mask"] as? String)?.isEmpty == false)
    }

    private static func makeTinyCGImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try #require(context.makeImage())
    }

    // MARK: - Pet evasion

    @Test func petEvasionProfilesAreDataDriven() {
        let profiles = EvasionStyle.allCases.map(EvasionProfiles.profile(for:))
        #expect(profiles.count == 5)
        #expect(EvasionProfiles.profile(for: .cute).bodyCue == .startledHop)
        #expect(EvasionProfiles.profile(for: .robot).soundEffect == .systemBeep)
        #expect(SavedPetCharacter(evasionStyle: .robot).resolvedEvasionStyle == .robot)
        #expect(SavedPetCharacter().resolvedEvasionStyle == .calm)
    }

    @Test func trilobiteOwnsConversationCaptureNotificationsWithoutContentView() {
        let notificationCenter = NotificationCenter()
        let trilobite = TrilobiteEngine(notificationCenter: notificationCenter)

        #expect(!trilobite.conversationAudioCaptureActive)

        notificationCenter.post(name: .castorSpeechCaptureWillStart, object: nil)
        #expect(trilobite.conversationAudioCaptureActive)
        #expect(trilobite.snapshot.audioLevel == 0)

        notificationCenter.post(name: .castorSpeechCaptureDidStop, object: nil)
        #expect(!trilobite.conversationAudioCaptureActive)
    }

    // MARK: - Cherry Connection: cross-fade transitions (A)

    // MARK: - Cherry Connection: unified deterministic blinking (B)

    // MARK: - Cherry Connection: motion context integration (D)

    @Test func cherryConnectionContextFreeOverloadsStayIdenticalAndSkipTheOverlay() async throws {
        // ContentView's preview path never passes a `MotionContext` — it must keep producing
        // exactly the pre-D output (no ambient touch/speaking overlay folded in), which is why
        // the context-free overloads route through `coreParameters` directly rather than through
        // the context-aware entry point with a `.preview` context.
        let core = HesitateCore()
        core.request(.thinking)
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(3.7)

        let legacy = connection.parameters(from: core.snapshot, at: date)
        let viaTrilobiteOverload = connection.parameters(from: core.snapshot, trilobite: .inactive, at: date)

        #expect(legacy.bodyLift == viaTrilobiteOverload.bodyLift)
        #expect(legacy.headTilt == viaTrilobiteOverload.headTilt)
        #expect(legacy.headBob == viaTrilobiteOverload.headBob)
        #expect(legacy.eyeScale == viaTrilobiteOverload.eyeScale)
        #expect(legacy.mouthSlant == viaTrilobiteOverload.mouthSlant)
        #expect(legacy.browLift == viaTrilobiteOverload.browLift)
        #expect(legacy.cheekWarmth == viaTrilobiteOverload.cheekWarmth)
        #expect(legacy.mouthOpen == viaTrilobiteOverload.mouthOpen)
        #expect(legacy.eyeOpen == viaTrilobiteOverload.eyeOpen)
    }

    @Test func cherryConnectionTouchedContextAppliesHappyBounceAndWiderEyes() async throws {
        // Touched context should reproduce the old PetFloatingView touched overlay: a wider-eyed
        // look (eyeScale >= 1.08) and extra cheek warmth (>= 0.72), ported verbatim from the old
        // `petParameters(at:touched:)`.
        let core = HesitateCore()
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(5.0)

        let touchedParameters = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: MotionContext(touched: true),
            at: date
        )
        let untouchedParameters = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: .preview,
            at: date
        )

        #expect(touchedParameters.eyeScale >= 1.08 - 0.0001)
        #expect(touchedParameters.cheekWarmth >= 0.72 - 0.0001)
        #expect(touchedParameters.eyeScale >= untouchedParameters.eyeScale)
    }

    // MARK: - Phase E: real-audio-driven mouth flap

    @Test func systemVoicePseudoEnergyRisesThenDecaysWithinThePulse() {
        let duration = 0.4
        let start = PetSpeechOutput.systemVoicePseudoEnergy(elapsed: 0, pulseDuration: duration)
        let peak = PetSpeechOutput.systemVoicePseudoEnergy(elapsed: duration * 0.15, pulseDuration: duration)
        let end = PetSpeechOutput.systemVoicePseudoEnergy(elapsed: duration, pulseDuration: duration)

        #expect(peak > start)
        #expect(peak > end)
    }

    // MARK: - Cherry Connection: saccadic gaze model (C)

    // MARK: - Arils AI alignment

    @Test func arilsAIAlignmentParserReadsFencedJSONAndConvertsNormalizedCoordinates() throws {
        let response = """
        Proposed alignment:
        ```json
        {
          "operation": "POME_ARILS_FACE_LAYOUT_V1",
          "head": {"x": 0.20, "y": 0.10, "width": 0.60, "height": 0.70},
          "eye_left": {"x": 0.34, "y": 0.30, "width": 0.10, "height": 0.08},
          "eye_right": {"x": 0.56, "y": 0.30, "width": 0.10, "height": 0.08},
          "mouth": {"x": 0.43, "y": 0.50, "width": 0.14, "height": 0.08},
          "confidence": 0.82,
          "explanation": "Moved the head boundary above the torso."
        }
        ```
        """

        let result = try ArilsAIAdjustmentParser.parse(
            response,
            imageSize: CGSize(width: 1_000, height: 800),
            provider: .claudeCode
        )

        #expect(result.provider == .claudeCode)
        #expect(result.layout.headRect == CGRect(x: 200, y: 80, width: 600, height: 560))
        #expect(result.layout.eyeLeftRect == CGRect(x: 340, y: 240, width: 100, height: 64))
        #expect(result.layout.mouthRect == CGRect(x: 430, y: 400, width: 140, height: 64))
        #expect(abs(result.confidence - 0.82) < 0.0001)
    }

    @Test func arilsAIAlignmentParserRejectsMouthAboveEyes() {
        let response = """
        {
          "operation": "POME_ARILS_FACE_LAYOUT_V1",
          "head": {"x": 0.20, "y": 0.10, "width": 0.60, "height": 0.70},
          "eye_left": {"x": 0.34, "y": 0.30, "width": 0.10, "height": 0.08},
          "eye_right": {"x": 0.56, "y": 0.30, "width": 0.10, "height": 0.08},
          "mouth": {"x": 0.43, "y": 0.20, "width": 0.14, "height": 0.08},
          "confidence": 0.99,
          "explanation": "Invalid on purpose."
        }
        """

        do {
            _ = try ArilsAIAdjustmentParser.parse(
                response,
                imageSize: CGSize(width: 1_000, height: 800),
                provider: .ollama
            )
            Issue.record("A mouth above the eyes must never reach the preview.")
        } catch let error as ArilsAIAdjustmentError {
            #expect(error == .invalidGeometry("the mouth must be below the eyes."))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func voicePresetsStayDistinctAndRecommendTheDefaultVoice() {
        #expect(PetVoicePreset.allCases.count == 5)
        #expect(Set(PetVoicePreset.allCases.map(\.speaker)).count == 5)
        #expect(PetVoicePreset.recommended.speaker == PetVoiceProfile.defaultProfile.speaker)
    }

    @Test func voicePresetProfileCarriesUserSpeakingRate() {
        let profile = PetVoicePreset.bright.profile(speakingRateMultiplier: 1.15)

        #expect(profile.speaker == "Vivian")
        #expect(profile.speakingRateMultiplier == 1.15)
        #expect(profile.characterDirection.contains("bright"))
    }

    @Test func neuralVoiceInstructionCarriesEmotionWithoutChangingSpokenText() {
        let speech = OllamaSpeechMetadata(
            emotion: .embarrassed,
            intensity: 0.72,
            speakingRate: 0.9,
            performanceNote: "Pause briefly before the final phrase."
        )
        let instruction = PetVoiceProfile.defaultProfile.instruction(for: speech)

        #expect(instruction.contains("照れて戸惑った"))
        #expect(instruction.contains("自然な会話速度"))
        #expect(instruction.contains("吐息"))
        #expect(instruction.contains("72パーセント"))
        #expect(instruction.contains("Pause briefly"))
    }

    @Test func neuralVoiceInstructionDropsBreathingPerformanceNotes() {
        let speech = OllamaSpeechMetadata(
            emotion: .surprised,
            intensity: 0.8,
            speakingRate: 1.0,
            performanceNote: "Take a quick audible breath before speaking."
        )
        let instruction = PetVoiceProfile.defaultProfile.instruction(for: speech)

        #expect(!instruction.contains("Take a quick audible breath"))
        #expect(instruction.contains("最初の言葉から直接"))
    }

    @Test func qwenEnglishInstructionSuppressesBreathingSounds() {
        let speech = OllamaSpeechMetadata(
            emotion: .happy,
            intensity: 0.5,
            speakingRate: 1.0,
            performanceNote: "Take a breath before answering."
        )
        let instruction = PetVoiceProfile.defaultProfile.qwenInstruction(for: speech)

        #expect(instruction.contains("Do not add audible breaths"))
        #expect(instruction.contains("Begin directly with the first word"))
        #expect(!instruction.contains("Take a breath before answering"))
    }

    @Test func neuralSpeechRoutesAllLanguagesByEngineChoice() {
        // `modelName(engine:)` no longer takes the text being spoken: routing is purely by the
        // engine preference, so it is the same for every language (Japanese, English, Chinese,
        // etc.) — Irodori is no longer auto-selected for Japanese.
        #expect(NeuralSpeechClient.modelName(engine: .system) == nil)
        #expect(
            NeuralSpeechClient.modelName(engine: .qwen)
                == NeuralSpeechClient.qwenEnglishModel
        )
    }

    @Test func neuralSpeechLanguageCodeReturnsKnownLanguagesWithHighConfidence() {
        #expect(NeuralSpeechClient.languageCode(for: "こんにちは、元気ですか？") == "Japanese")
        #expect(NeuralSpeechClient.languageCode(for: "Hello, how are you today?") == "English")
        #expect(NeuralSpeechClient.languageCode(for: "你好，最近怎么样？") == "Chinese")
        #expect(NeuralSpeechClient.languageCode(for: "안녕하세요, 잘 지내세요?") == "Korean")
        #expect(NeuralSpeechClient.languageCode(for: "Bonjour, comment ça va aujourd'hui ?") == "French")
        #expect(NeuralSpeechClient.languageCode(for: "Hallo, wie geht es dir heute?") == "German")
        #expect(NeuralSpeechClient.languageCode(for: "Hola, ¿cómo estás hoy?") == "Spanish")
    }

    @Test func neuralSpeechLanguageCodeFallsBackToAutoWhenUnsure() {
        // Empty/whitespace-only text has no dominant language, so the server/model's own
        // auto-detection should be used instead of guessing.
        #expect(NeuralSpeechClient.languageCode(for: "") == "auto")
        #expect(NeuralSpeechClient.languageCode(for: "   ") == "auto")
        #expect(NeuralSpeechClient.languageCode(for: "Hello") == "auto")
        #expect(NeuralSpeechClient.languageCode(for: "承知。準備完了。") == "auto")
    }

    @Test func systemVoiceLanguageMapsMajorLanguagesToBCP47Locales() {
        #expect(PetSpeechOutput.voiceLanguage(for: "こんにちは、元気ですか？") == "ja-JP")
        #expect(PetSpeechOutput.voiceLanguage(for: "Hello, how are you today?") == "en-US")
        #expect(PetSpeechOutput.voiceLanguage(for: "你好，最近怎么样？") == "zh-CN")
        #expect(PetSpeechOutput.voiceLanguage(for: "안녕하세요, 잘 지내세요?") == "ko-KR")
        #expect(PetSpeechOutput.voiceLanguage(for: "Bonjour, comment ça va aujourd'hui ?") == "fr-FR")
        #expect(PetSpeechOutput.voiceLanguage(for: "Hallo, wie geht es dir heute?") == "de-DE")
        #expect(PetSpeechOutput.voiceLanguage(for: "Hola, ¿cómo estás hoy?") == "es-ES")
    }

    @Test func systemVoiceLanguageUsesSafeFallbackWhenUnsure() {
        #expect(PetSpeechOutput.voiceLanguage(for: "") == "en-US")
        #expect(PetSpeechOutput.voiceLanguage(for: "   ") == "en-US")
        #expect(PetSpeechOutput.voiceLanguage(for: "承知。準備完了。") == "ja-JP")
    }

    @Test func speechLanguageContextUsesWholeReplyAndLatchesHighConfidenceLanguage() {
        var context = PetSpeechLanguageContext()
        context.observe("承知。準備完了。")
        #expect(context.detectedLanguage == nil)
        #expect(context.neuralLanguageCode == "auto")
        #expect(context.systemVoiceLanguage == "ja-JP")

        context.observe("このまま続けます。")
        #expect(context.detectedLanguage == .japanese)
        #expect(context.neuralLanguageCode == "Japanese")
        #expect(context.systemVoiceLanguage == "ja-JP")

        context.observe("This later segment must not change the reply voice.")
        #expect(context.detectedLanguage == .japanese)
        #expect(context.neuralLanguageCode == "Japanese")
        #expect(context.systemVoiceLanguage == "ja-JP")
    }

    @Test func systemEngineSkipsNeuralSpeechAttempt() {
        #expect(!PetSpeechOutput.shouldAttemptNeuralVoice(engine: .system))
        #expect(PetSpeechOutput.shouldAttemptNeuralVoice(engine: .qwen))
    }

    @Test func rigDocumentRoundTripsAsJSON() throws {
        let document = RigDocument.starter(
            imageName: "awkward.png",
            imageSize: CGSize(width: 640, height: 960)
        )

        let encoded = try document.encodedJSON()
        let decoded = try RigDocument.decodeJSON(encoded)

        #expect(decoded == document)
        #expect(decoded.parts.map(\.kind) == [.body, .head, .hair, .leftEye, .rightEye, .mouth])
    }

    // MARK: - Rigged character pivot alignment

    @Test func headAnchoredRotationPreservesDistanceFromThePivot() {
        // Rotating a point around a pivot must be a rigid transform: the distance between the
        // point and the pivot stays constant regardless of the rotation angle. This is the core
        // invariant that keeps a head-attached part (eye/mouth/hair) riding along the same
        // circular arc as the head outline instead of drifting away from it as headTilt grows.
        let pivot = CGPoint(x: 100, y: 200)
        let point = CGPoint(x: 130, y: 210)
        let restingDistance = hypot(point.x - pivot.x, point.y - pivot.y)

        for degrees in stride(from: -20.0, through: 20.0, by: 2.5) {
            let rotated = RiggedCharacterRenderer.headAnchoredRotation(point: point, pivot: pivot, degrees: degrees)
            let rotatedDistance = hypot(rotated.x - pivot.x, rotated.y - pivot.y)
            #expect(abs(rotatedDistance - restingDistance) < 0.0001)
        }
    }

    @Test func headAnchoredRotationIsIdentityAtZeroDegrees() {
        let pivot = CGPoint(x: 50, y: 60)
        let point = CGPoint(x: 70, y: 40)

        let rotated = RiggedCharacterRenderer.headAnchoredRotation(point: point, pivot: pivot, degrees: 0)

        #expect(abs(rotated.x - point.x) < 0.0001)
        #expect(abs(rotated.y - point.y) < 0.0001)
    }

    @Test func headAnchoredRotationKeepsEyeAndMouthOffsetsFromHeadConstantAcrossTilt() {
        // Regression test for the rigged-character "ずれ" bug: before this fix, each head-attached
        // part rotated around its own independent anchorPoint, so the vector from (say) the left
        // eye to the head pivot changed length/direction as headTilt grew — the eye visibly
        // separated from the head. After the fix, every head-attached part's *pivot-relative*
        // offset is rotated by the exact same rigid transform as the head, so the offset from any
        // head-attached part to the head pivot, measured in the pivot's rotated frame, stays
        // constant across tilt angles.
        let pivot = CGPoint(x: 195, y: 300)
        let restingEyePoint = CGPoint(x: 160, y: 270)
        let restingMouthPoint = CGPoint(x: 195, y: 340)

        let restingEyeVector = (dx: restingEyePoint.x - pivot.x, dy: restingEyePoint.y - pivot.y)
        let restingMouthVector = (dx: restingMouthPoint.x - pivot.x, dy: restingMouthPoint.y - pivot.y)
        let restingEyeDistance = hypot(restingEyeVector.dx, restingEyeVector.dy)
        let restingMouthDistance = hypot(restingMouthVector.dx, restingMouthVector.dy)

        for degrees in [-8.0, -4.0, 0.0, 4.0, 8.0] {
            let rotatedEye = RiggedCharacterRenderer.headAnchoredRotation(point: restingEyePoint, pivot: pivot, degrees: degrees)
            let rotatedMouth = RiggedCharacterRenderer.headAnchoredRotation(point: restingMouthPoint, pivot: pivot, degrees: degrees)

            let rotatedEyeDistance = hypot(rotatedEye.x - pivot.x, rotatedEye.y - pivot.y)
            let rotatedMouthDistance = hypot(rotatedMouth.x - pivot.x, rotatedMouth.y - pivot.y)

            #expect(abs(rotatedEyeDistance - restingEyeDistance) < 0.0001)
            #expect(abs(rotatedMouthDistance - restingMouthDistance) < 0.0001)
        }
    }

    @Test func layerExtractorUsesTopOriginLikeOverlay() {
        let normalized = CGRect(x: 0.25, y: 0.30, width: 0.50, height: 0.20)
        let pixelRect = LayerExtractor.pixelRect(
            for: normalized,
            pixelWidth: 800,
            pixelHeight: 1_000
        )

        #expect(pixelRect == CGRect(x: 200, y: 300, width: 400, height: 200))
    }

    @Test func layerExtractorCropsTopOriginImageContent() throws {
        let image = try makeTopRedBottomBlueImage()
        let part = RigPart(
            kind: .head,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.5),
            shape: .rectangle,
            anchorPoint: CGPoint(x: 0.5, y: 0.5),
            zIndex: 0
        )

        let layer = try #require(LayerExtractor.layerImage(from: image, part: part))
        let color = try #require(sampleCenterPixel(from: layer))

        #expect(color.red > 0.8)
        #expect(color.blue < 0.2)
    }

    @Test func layerExtractorErasesMovingPartsAtTopOriginCoordinates() throws {
        let image = try makeEraserCoordinateImage()
        let body = RigPart(
            kind: .body,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            shape: .rectangle,
            anchorPoint: CGPoint(x: 0.5, y: 0.5),
            zIndex: 0
        )
        let eye = RigPart(
            kind: .leftEye,
            normalizedRect: CGRect(x: 4.0 / 12.0, y: 2.0 / 12.0, width: 4.0 / 12.0, height: 2.0 / 12.0),
            shape: .rectangle,
            anchorPoint: CGPoint(x: 0.5, y: 0.5),
            zIndex: 1
        )
        let document = RigDocument(
            version: 1,
            imageName: "coordinates.png",
            imageSize: CGSize(width: 12, height: 12),
            parts: [body, eye]
        )

        let layer = try #require(LayerExtractor.layerImage(from: image, part: body, document: document))
        let topPixel = try #require(sampleTopOriginPixel(from: layer, x: 6, y: 2))
        let bottomPixel = try #require(sampleTopOriginPixel(from: layer, x: 6, y: 9))

        #expect(topPixel.red > 0.7)
        #expect(bottomPixel.red < 0.3)
    }

    // MARK: - Voice latency tracking

    // MARK: - Streaming sentence extraction (LLM -> TTS pipelining)

    // MARK: - Speech segmentation: minimized first segment

    @Test func petSpeechOutputResplitsStreamedSentencesBeforeQueueing() {
        let output = PetSpeechOutput()
        var completed = false
        output.beginStreaming { completed = true }

        // First streamed sentence: shrunk lead plus the remainder.
        output.appendStreamedSentence("はい、今日はとても天気が良いですね。")
        #expect(output.segments.first == "はい、")
        #expect(output.segments.count >= 2)

        // A later long sentence is re-split too, and is not shrunk at its head.
        let countAfterFirst = output.segments.count
        output.appendStreamedSentence("今日は天気がとても良くて、公園には人がたくさん集まっていました。")
        #expect(output.segments.count >= countAfterFirst + 2)
        #expect(output.segments[countAfterFirst] == "今日は天気がとても良くて、")

        output.stop()
        #expect(!completed)
        #expect(output.segments.isEmpty)
    }

    @Test func petSpeechOutputTreatsURLSessionCancellationAsCancellation() {
        let cancellation = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled
        )

        #expect(PetSpeechOutput.isCancellationError(cancellation))
        #expect(PetSpeechOutput.isCancellationError(CancellationError()))
        #expect(!PetSpeechOutput.isCancellationError(URLError(.timedOut)))
    }

    private func makeTopRedBottomBlueImage() throws -> NSImage {
        let width = 4
        let height = 4
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if y < height / 2 {
                    bytes[offset] = 255
                    bytes[offset + 3] = 255
                } else {
                    bytes[offset + 2] = 255
                    bytes[offset + 3] = 255
                }
            }
        }

        let data = Data(bytes)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgImage = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }

    private func makeEraserCoordinateImage() throws -> NSImage {
        let width = 12
        let height = 12
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let isBorder = x == 0 || y == 0 || x == width - 1 || y == height - 1
                if !isBorder {
                    bytes[offset + 1] = 100
                }
                if (4..<8).contains(x), (2..<4).contains(y) {
                    bytes[offset] = 255
                    bytes[offset + 1] = 255
                    bytes[offset + 2] = 255
                }
                bytes[offset + 3] = 255
            }
        }

        let data = Data(bytes)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgImage = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        return NSImage(cgImage: cgImage, size: CGSize(width: width, height: height))
    }

    private func sampleCenterPixel(from image: NSImage) -> (red: Double, green: Double, blue: Double)? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let offset = ((cgImage.height / 2) * cgImage.width + cgImage.width / 2) * 4
        return (
            red: Double(bytes[offset]) / 255,
            green: Double(bytes[offset + 1]) / 255,
            blue: Double(bytes[offset + 2]) / 255
        )
    }

    private func sampleTopOriginPixel(
        from image: NSImage,
        x: Int,
        y: Int
    ) -> (red: Double, green: Double, blue: Double)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixel = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (
            red: Double(bytes[0]) / 255,
            green: Double(bytes[1]) / 255,
            blue: Double(bytes[2]) / 255
        )
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try #require(Self.httpBodyData(from: request))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func httpBodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class LaMaClientURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestValue: URLRequest?
    nonisolated(unsafe) private static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.record(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(responseData: Data) {
        lock.lock()
        defer { lock.unlock() }
        requestValue = nil
        self.responseData = responseData
    }

    static func recordedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requestValue
    }

    private static func record(_ request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        requestValue = request
        return responseData
    }
}

// MARK: - Aril Bridge persistence

struct ArilBridgePersistenceTests {
    @Test func faceLandmarkAspectRatioIsScaleInvariant() {
        let small = TrilobiteFaceMetrics.aspectRatio(points: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 2, y: 0),
            CGPoint(x: 2, y: 1),
            CGPoint(x: 0, y: 1),
        ])
        let large = TrilobiteFaceMetrics.aspectRatio(points: [
            CGPoint(x: 10, y: 20),
            CGPoint(x: 30, y: 20),
            CGPoint(x: 30, y: 30),
            CGPoint(x: 10, y: 30),
        ])
        #expect(abs(small - 0.5) < 0.0001)
        #expect(abs(large - small) < 0.0001)
    }

    @Test func arilsFaceBridgeStaysInsideTheCameraPermissionGate() {
        var snapshot = TrilobiteInputSnapshot.inactive
        snapshot.cameraEnabled = true
        snapshot.faceDetected = true
        snapshot.faceLandmarksAvailable = true
        snapshot.gazeX = 14
        snapshot.gazeY = -9
        snapshot.faceYawDegrees = 12
        snapshot.leftEyeAspectRatio = 0.2
        snapshot.rightEyeAspectRatio = 0.22
        snapshot.mouthAspectRatio = 0.4
        snapshot.faceTrackingConfidence = 0.9

        let denied = TrilobiteArilsFaceBridge.input(from: snapshot)
        #expect(denied.gazeTarget == nil)
        #expect(denied.faceTracking == nil)

        snapshot.cameraPermission = .granted
        let granted = TrilobiteArilsFaceBridge.input(from: snapshot)
        #expect(granted.gazeTarget == SIMD2<Float>(1, -1))
        #expect(granted.faceTracking?.yawDegrees == 12)
        #expect(granted.faceTracking?.confidence == 0.9)
    }

    @Test func savedPetCharacterRoundTripsArilsArchiveData() throws {
        let payload = SavedPetCharacter(
            document: nil,
            imageData: nil,
            arilsArchiveData: Data([1, 2, 3, 4])
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SavedPetCharacter.self, from: data)
        #expect(decoded.arilsArchiveData == Data([1, 2, 3, 4]))
    }

    @Test func petSaveRequiresArilsRigUnlessManualRiggingIsEnabled() {
        #expect(!ManualRiggingSettingsStore.canSavePet(
            hasImage: true, hasDocument: true, hasArilsRig: false, manualRiggingEnabled: false
        ))
        #expect(ManualRiggingSettingsStore.canSavePet(
            hasImage: true, hasDocument: true, hasArilsRig: true, manualRiggingEnabled: false
        ))
        #expect(ManualRiggingSettingsStore.canSavePet(
            hasImage: true, hasDocument: true, hasArilsRig: false, manualRiggingEnabled: true
        ))
        #expect(!ManualRiggingSettingsStore.canSavePet(
            hasImage: false, hasDocument: true, hasArilsRig: true, manualRiggingEnabled: true
        ))
        #expect(!ManualRiggingSettingsStore.defaultEnabled)
    }

    @Test func savedPetCharacterDecodesLegacyOfficialPetAsNoCharacter() throws {
        // Pets saved while official characters existed carry only these keys. They must keep
        // decoding (not throw) and resolve to "nothing to show" so the pet stays hidden.
        let legacy = Data(#"{"officialCharacterID":"pome-soda","officialExpression":"happy"}"#.utf8)
        let decoded = try JSONDecoder().decode(SavedPetCharacter.self, from: legacy)
        #expect(decoded.image == nil)
        #expect(decoded.document == nil)
        #expect(decoded.arilsArchiveData == nil)
        #expect(decoded.qualityArchiveData == nil)
    }

    @Test func savedPetCharacterRoundTripsQualityArchiveData() throws {
        let payload = SavedPetCharacter(
            document: nil,
            imageData: nil,
            arilsArchiveData: Data([1, 2]),
            qualityArchiveData: Data([9, 8, 7])
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(SavedPetCharacter.self, from: data)
        // Both archives survive independently; the pet prefers quality.
        #expect(decoded.arilsArchiveData == Data([1, 2]))
        #expect(decoded.qualityArchiveData == Data([9, 8, 7]))
    }
}
