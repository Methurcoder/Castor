import Foundation
import NaturalLanguage
import Observation
import os
import CastorCore

struct PetVoiceProfile: Equatable {
    static let defaultProfile = PetVoiceProfile(
        speaker: "Ono_Anna",
        displayName: "Anna",
        characterDirection: "A gentle, slightly hesitant Japanese desktop companion.",
        speakingRateMultiplier: 1
    )

    let speaker: String
    let displayName: String
    let characterDirection: String
    let speakingRateMultiplier: Double

    static func resolvedProfile() -> PetVoiceProfile {
        PetVoiceSelectionStore.selectedPreset().profile(
            speakingRateMultiplier: PetVoiceSelectionStore.speakingRate()
        )
    }

    func instruction(for speech: OllamaSpeechMetadata) -> String {
        let emotionDirection: String
        switch speech.emotion {
        case .neutral:
            emotionDirection = "自然で会話らしい抑揚で話してください。"
        case .happy:
            emotionDirection = "嬉しさと温かさを、明るすぎない自然な抑揚で表現してください。"
        case .sad:
            emotionDirection = "芝居がかりすぎず、静かでやさしい寂しさを表現してください。"
        case .angry:
            emotionDirection = "叫ばず、抑制された不満を明瞭に表現してください。"
        case .surprised:
            emotionDirection = "吸気音や息を入れず、声の抑揚だけで軽い驚きを表現してください。"
        case .thoughtful:
            emotionDirection = "短い間を取りながら、考え深く丁寧に話してください。"
        case .embarrassed:
            emotionDirection = "やさしいためらいを含め、少し照れて戸惑った様子で話してください。"
        }

        let intensityPercent = Int((speech.intensity * 100).rounded())
        let paceDirection: String
        if speech.speakingRate < 0.9 {
            paceDirection = "少しゆっくり、言葉を丁寧に区切ってください。"
        } else if speech.speakingRate > 1.1 {
            paceDirection = "聞き取りやすさを保ちながら、軽快に話してください。"
        } else {
            paceDirection = "自然な会話速度で話してください。"
        }
        let cleanDelivery = """
        発声以外の音を加えないでください。吐息、ため息、吸気音、呼気音、ささやき、 \
        リップノイズ、口の音を一切入れず、最初の言葉から直接読み始めてください。
        """
        let note = safePerformanceNote(speech.performanceNote)
            .map { " 追加の演技指示: \($0)" } ?? ""
        return "\(irodoriVoiceDirection) \(emotionDirection) \(paceDirection) \(cleanDelivery) 感情の強さは\(intensityPercent)パーセントです。\(note)"
    }

    func qwenInstruction(for speech: OllamaSpeechMetadata) -> String {
        let emotionDirection: String
        switch speech.emotion {
        case .neutral:
            emotionDirection = "Speak naturally and conversationally."
        case .happy:
            emotionDirection = "Sound genuinely happy, warm, and lightly animated."
        case .sad:
            emotionDirection = "Sound subdued and tender without becoming theatrical."
        case .angry:
            emotionDirection = "Sound controlled but clearly frustrated. Do not shout."
        case .surprised:
            emotionDirection = "Express mild surprise through intonation only."
        case .thoughtful:
            emotionDirection = "Sound reflective, with small pauses and careful phrasing."
        case .embarrassed:
            emotionDirection = "Sound shy and slightly flustered, with gentle hesitation."
        }

        let paceDirection: String
        if speech.speakingRate < 0.9 {
            paceDirection = "Use a slower, deliberate conversational pace."
        } else if speech.speakingRate > 1.1 {
            paceDirection = "Use a brisk pace while staying clear."
        } else {
            paceDirection = "Use a natural conversational pace."
        }

        let note = safePerformanceNote(speech.performanceNote)
            .map { " Additional direction: \($0)" } ?? ""
        return """
        \(characterDirection) \(emotionDirection) \(paceDirection) Use clean voiced speech only. \
        Do not add audible breaths, sighs, gasps, inhalations, exhalations, whispering, lip sounds, \
        or mouth noises. Begin directly with the first word.\(note)
        """
    }

    private var irodoriVoiceDirection: String {
        switch speaker {
        case "Uncle_Fu":
            "落ち着いた低めの声で、静かに寄り添うように話してください。"
        case "Serena":
            "柔らかくやさしい声で、温かさを控えめに表現してください。"
        case "Vivian":
            "明るく軽やかな声で、親しみのある反応をしてください。"
        case "Ryan":
            "好奇心を感じる快活な声で、抑揚は自然に制御してください。"
        default:
            "癖の少ない自然な声で、明瞭かつ会話らしく話してください。"
        }
    }

    private func safePerformanceNote(_ note: String?) -> String? {
        guard let note else {
            return nil
        }

        let normalized = note.lowercased()
        let disallowedTerms = [
            "breath", "breathe", "sigh", "gasp", "inhale", "exhale",
            "whisper", "mouth noise", "lip sound", "吐息", "ため息", "吸い込"
        ]
        guard !disallowedTerms.contains(where: normalized.contains) else {
            return nil
        }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PetVoicePreset: String, CaseIterable, Codable, Identifiable {
    case calm
    case gentle
    case standard
    case bright
    case curious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calm:
            "Calm"
        case .gentle:
            "Gentle"
        case .standard:
            "Castor Standard"
        case .bright:
            "Bright"
        case .curious:
            "Curious"
        }
    }

    var subtitle: String {
        switch self {
        case .calm:
            "落ち着いた低めの声"
        case .gentle:
            "やさしく柔らかな声"
        case .standard:
            "自然でバランスのよい声"
        case .bright:
            "明るく軽やかな声"
        case .curious:
            "好奇心のある快活な声"
        }
    }

    var detail: String {
        switch self {
        case .calm:
            "間を急がず、静かに寄り添う話し方です。長めの回答にも向いています。"
        case .gentle:
            "角のない柔らかな響きで、少し控えめに話します。"
        case .standard:
            "感情と聞き取りやすさのバランスを重視した標準の声です。"
        case .bright:
            "反応が明るく、短い会話をテンポよく返す声です。"
        case .curious:
            "語尾に自然な動きがあり、一緒に考える会話に向いた声です。"
        }
    }

    var speaker: String {
        switch self {
        case .calm:
            "Uncle_Fu"
        case .gentle:
            "Serena"
        case .standard:
            "Ono_Anna"
        case .bright:
            "Vivian"
        case .curious:
            "Ryan"
        }
    }

    var characterDirection: String {
        switch self {
        case .calm:
            "Use a calm, grounded voice with unhurried phrasing."
        case .gentle:
            "Use a soft, kind voice with restrained warmth."
        case .standard:
            "Use a balanced, natural voice that stays clear and conversational."
        case .bright:
            "Use a bright, open voice with light energy."
        case .curious:
            "Use an attentive, curious voice with lively but controlled intonation."
        }
    }

    var accent: PetVoiceAccent {
        switch self {
        case .calm:
            PetVoiceAccent(red: 0.20, green: 0.67, blue: 0.90)
        case .gentle:
            PetVoiceAccent(red: 0.32, green: 0.78, blue: 0.64)
        case .standard:
            PetVoiceAccent(red: 0.91, green: 0.52, blue: 0.80)
        case .bright:
            PetVoiceAccent(red: 0.96, green: 0.64, blue: 0.22)
        case .curious:
            PetVoiceAccent(red: 0.46, green: 0.40, blue: 0.94)
        }
    }

    static let recommended: PetVoicePreset = .standard

    func profile(speakingRateMultiplier: Double) -> PetVoiceProfile {
        PetVoiceProfile(
            speaker: speaker,
            displayName: title,
            characterDirection: "\(PetVoiceProfile.defaultProfile.characterDirection) \(characterDirection)",
            speakingRateMultiplier: speakingRateMultiplier
        )
    }
}

struct PetVoiceAccent: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

enum PetVoiceSelectionStore {
    private static let presetKeyPrefix = "Pomegranate.Voice.Preset."
    private static let rateKeyPrefix = "Pomegranate.Voice.Rate."
    /// Kept from the era when official characters had their own keys, so existing voice
    /// selections for imported characters carry over.
    private static let storageID = "imported"

    static func selectedPreset() -> PetVoicePreset {
        guard let rawValue = UserDefaults.standard.string(forKey: presetKeyPrefix + storageID),
              let preset = PetVoicePreset(rawValue: rawValue) else {
            return .recommended
        }
        return preset
    }

    static func speakingRate() -> Double {
        let key = rateKeyPrefix + storageID
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return 1
        }
        return min(max(UserDefaults.standard.double(forKey: key), 0.8), 1.2)
    }

    static func save(preset: PetVoicePreset, speakingRate: Double) {
        UserDefaults.standard.set(preset.rawValue, forKey: presetKeyPrefix + storageID)
        UserDefaults.standard.set(
            min(max(speakingRate, 0.8), 1.2),
            forKey: rateKeyPrefix + storageID
        )
    }
}

/// The neural voice engine choice. This is a global, language-independent switch: `.qwen` routes
/// every language (including Japanese) through the multilingual Qwen3-TTS model, while `.system`
/// routes every language through the macOS `AVSpeechSynthesizer`. Irodori-TTS is Japanese-only and
/// is intentionally never selected by this switch (see `NeuralSpeechClient.modelName(engine:)`);
/// its model constant and `PetVoiceProfile.instruction(for:)` are kept so the routing can be
/// reintroduced later without re-deriving them.
enum NeuralVoiceEngine: String, CaseIterable, Identifiable {
    case system
    case qwen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            "macOS"
        case .qwen:
            "Qwen 0.6B"
        }
    }

    var detail: String {
        switch self {
        case .system:
            "Fast. Uses the macOS system voice for every language."
        case .qwen:
            "More natural and multilingual, but slower and without detailed style control."
        }
    }
}

enum NeuralVoiceEngineStore {
    // Preserves the pre-rename UserDefaults key so existing users keep their saved preference.
    private static let key = "Pomegranate.Voice.EnglishEngine"

    static var selected: NeuralVoiceEngine {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: key) else {
                return .system
            }
            return NeuralVoiceEngine(rawValue: rawValue) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

@MainActor
@Observable
final class NeuralSpeechSettings {
    var voiceEngine: NeuralVoiceEngine {
        didSet {
            NeuralVoiceEngineStore.selected = voiceEngine
            if voiceEngine == .qwen {
                preloadQwen()
            }
        }
    }
    private(set) var isPreparingQwen = false
    private(set) var preparationError: String?

    init() {
        voiceEngine = NeuralVoiceEngineStore.selected
        if voiceEngine == .qwen {
            preloadQwen()
        }
    }

    func refresh() {
        voiceEngine = NeuralVoiceEngineStore.selected
    }

    private func preloadQwen() {
        guard !isPreparingQwen else {
            return
        }
        isPreparingQwen = true
        preparationError = nil

        Task {
            do {
                try await NeuralSpeechClient.preloadQwen()
            } catch {
                preparationError = "Could not prepare Qwen: \(error.localizedDescription)"
            }
            isPreparingQwen = false
        }
    }
}

typealias NeuralSpeechRequest = NeuralSpeechPayload

struct NeuralSpeechClient {
    static let defaultEndpoint = URL(string: "http://127.0.0.1:8000/v1/audio/speech")!
    static let irodoriModel = "mlx-community/Irodori-TTS-600M-v3-VoiceDesign-8bit"
    static let qwenEnglishModel = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
    private static let logger = Logger(subsystem: "dev.pomegranate.prototype", category: "NeuralSpeech")

    let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL = NeuralSpeechClient.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    func audio(
        for text: String,
        profile: PetVoiceProfile,
        speech: OllamaSpeechMetadata,
        languageCode: String
    ) async throws -> Data {
        let engine = NeuralVoiceEngineStore.selected
        guard let model = Self.modelName(engine: engine) else {
            throw NeuralSpeechError.unsupportedLanguage
        }
        let startedAt = Date()
        guard try await isModelReady(model) else {
            preload(model: model)
            Self.logger.notice(
                "Neural voice model not ready; falling back. model=\(model, privacy: .public) chars=\(text.count)"
            )
            throw NeuralSpeechError.modelNotReady
        }
        // The instruction style follows the model being used, not the text's language: Irodori is
        // Japanese-only and always uses the Japanese-language instruction, while Qwen is
        // multilingual and always uses the English-language instruction regardless of what
        // language it is speaking.
        let instruction = model == Self.irodoriModel
            ? profile.instruction(for: speech)
            : profile.qwenInstruction(for: speech)

        let payload = NeuralSpeechRequest(
            model: model,
            input: text,
            instruct: instruction,
            voice: profile.speaker,
            speed: min(max(speech.speakingRate * profile.speakingRateMultiplier, 0.7), 1.35),
            langCode: languageCode,
            responseFormat: "wav",
            stream: false
        )

        let transport = try NeuralSpeechTransport(endpoint:endpoint,session:session)
        let (data,httpResponse) = try await transport.response(for:payload,
            timeout:model == Self.qwenEnglishModel ? 120:20)
        let elapsed = Date().timeIntervalSince(startedAt)
        let serverTiming = httpResponse.value(forHTTPHeaderField: "Server-Timing") ?? "missing"
        Self.logger.info(
            "Neural voice audio ready in \(elapsed, format: .fixed(precision: 2))s; chars=\(text.count) bytes=\(data.count) timing=\(serverTiming, privacy: .public)"
        )
        return data
    }

    private func isModelReady(_ model: String) async throws -> Bool {
        var request = URLRequest(url: statusEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.45

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return false
        }

        let status = try? JSONDecoder().decode(NeuralSpeechStatus.self, from: data)
        return status?.model == model
    }

    private var statusEndpoint: URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.query = nil
        return components?.url ?? endpoint
    }

    private var preloadEndpoint: URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/v1/audio/preload"
        components?.query = nil
        return components?.url ?? endpoint
    }

    /// Fire-and-forget warmup for the start of a voice conversation (called when listening
    /// begins), so the neural TTS model is already loaded by the time the first reply is ready
    /// to speak. Safe to call even if the local TTS server isn't running: the request simply
    /// fails silently and the existing `AVSpeechSynthesizer` fallback in `PetSpeechOutput` is
    /// unaffected either way. Warms up whichever model the current engine selection would
    /// actually route to (Qwen, since Irodori is no longer selected by default); no-ops when
    /// `.system` is selected, since there is no neural model to warm up in that case.
    func warmUp() {
        guard let model = Self.modelName(engine: NeuralVoiceEngineStore.selected) else {
            return
        }
        preload(model: model)
    }

    private func preload(model: String) {
        let endpoint = preloadEndpoint
        let session = session
        Task {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 600
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["model": model])
                _ = try await session.data(for: request)
            } catch {
                Self.logger.debug("Background voice preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func preloadQwen(session: URLSession = .shared) async throws {
        let endpoint = URL(string: "http://127.0.0.1:8000/v1/audio/preload")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": qwenEnglishModel])

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NeuralSpeechError.invalidResponse
        }
    }

    /// Routes every language to a single model chosen by the user's global engine preference:
    /// `.qwen` speaks all text (Japanese included) with the multilingual Qwen model, `.system`
    /// returns `nil` so the caller falls back to `AVSpeechSynthesizer` for all text. Irodori-TTS
    /// (Japanese-only) is intentionally never selected here; the model constant and its
    /// Japanese-language `instruction(for:)` are kept for a possible future per-language routing
    /// option, but the default routing no longer picks it automatically.
    static func modelName(engine: NeuralVoiceEngine) -> String? {
        engine == .qwen ? qwenEnglishModel : nil
    }

    /// Maps to the `lang_code` value sent to the local Qwen TTS server. Only languages with a
    /// well-established name in mlx-audio's Qwen3-TTS documentation are returned explicitly;
    /// everything else (including cases where `NLLanguageRecognizer` is unsure) returns "auto" so
    /// the server/model's own language auto-detection (`lang_code=payload.get("lang_code",
    /// "auto")` in `scripts/neural_tts_server.py`) takes over instead of risking an incorrect
    /// hint. This package isn't installed in this environment, so its accepted vocabulary for
    /// languages beyond Japanese/English can't be verified here — being conservative is safer
    /// than guessing a string the model doesn't recognize.
    static func languageCode(for text: String) -> String {
        languageCode(for: dominantLanguage(for: text))
    }

    static func languageCode(for language: NLLanguage?) -> String {
        guard let language else {
            return "auto"
        }

        switch language {
        case .japanese:
            return "Japanese"
        case .english:
            return "English"
        case .simplifiedChinese, .traditionalChinese:
            return "Chinese"
        case .korean:
            return "Korean"
        case .french:
            return "French"
        case .german:
            return "German"
        case .spanish:
            return "Spanish"
        default:
            return "auto"
        }
    }

    /// Shared high-confidence language detection used by both Qwen's `lang_code` hint and the
    /// `AVSpeechSynthesizer` locale. A top hypothesis is accepted only above a confidence floor.
    /// Han-only text needs a higher confidence to be treated as Chinese because short Japanese
    /// phrases such as "承知。準備完了。" otherwise skew strongly toward `zh-Hant`.
    static func dominantLanguage(for text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 3)
            .max(by: { $0.value < $1.value }) else {
            return nil
        }

        let isChinese = hypothesis.key == .simplifiedChinese
            || hypothesis.key == .traditionalChinese
        let isAmbiguousHanText = isChinese
            && containsHanCharacters(trimmed)
            && !containsKanaCharacters(trimmed)
        let minimumConfidence = isAmbiguousHanText ? 0.95 : 0.60
        guard hypothesis.value >= minimumConfidence else {
            return nil
        }
        return hypothesis.key
    }

    static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func containsKanaCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x31F0...0x31FF).contains(scalar.value)
                || (0xFF66...0xFF9D).contains(scalar.value)
        }
    }
}

private struct NeuralSpeechStatus: Decodable {
    let model: String?
}

enum NeuralSpeechError: LocalizedError {
    case invalidResponse
    case modelNotReady
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The local neural voice server returned an invalid response."
        case .modelNotReady:
            "The local neural voice model is still preparing."
        case .unsupportedLanguage:
            "No neural voice model is selected; the macOS system voice will be used instead."
        }
    }
}
