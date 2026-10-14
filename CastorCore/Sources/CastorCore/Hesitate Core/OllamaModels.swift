import Foundation

public nonisolated struct OllamaModel: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    /// Parameter count reported by the provider; absent in older saved data.
    public let parameterSize: String?

    public var id: String { name }

    public init(name: String, parameterSize: String? = nil) {
        self.name = name
        self.parameterSize = parameterSize
    }

    public var parameterSizeLabel: String? {
        if let parameterSize, Self.parameterScale(in: parameterSize) != nil {
            return parameterSize.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.parameterScale(in: name).map { "\($0.label) (estimated)" }
    }

    public var parameterCountBillions: Double? {
        if let parameterSize, let scale = Self.parameterScale(in: parameterSize) {
            return scale.billions
        }
        return Self.parameterScale(in: name)?.billions
    }

    /// A rough guidance threshold, not a measure of a model's accuracy.
    public var isSmallModel: Bool {
        parameterCountBillions.map { $0 < 7 } ?? false
    }

    private static func parameterScale(in text: String) -> (label: String, billions: Double)? {
        // Token boundaries keep version numbers, quantization (4bit), and MoE active
        // counts (A3B after a total count) from being mistaken for a model's size.
        let pattern = #"(?i)(?<![a-z0-9.])([0-9]+(?:\.[0-9]+)?)\s*([bmt])(?=$|[^a-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange]), number.isFinite, number > 0 else {
            return nil
        }
        let unit = text[unitRange].uppercased()
        let multiplier = unit == "M" ? 0.001 : (unit == "T" ? 1_000.0 : 1.0)
        return ("\(text[numberRange])\(unit)", number * multiplier)
    }
}

public nonisolated struct OllamaChatMessage: Codable, Equatable, Sendable {
    public nonisolated enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String
    /// Ollama vision models accept base64-encoded images on a user message.
    /// Ordinary chat leaves this nil, so its existing wire format is unchanged.
    public var images: [String]? = nil

    public init(role: Role, content: String, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.images = images
    }
}

public nonisolated struct OllamaReply: Equatable, Sendable {
    public let text: String
    public let motionState: MotionState
    public let speech: OllamaSpeechMetadata

    public init(text: String, motionState: MotionState, speech: OllamaSpeechMetadata) {
        self.text = text
        self.motionState = motionState
        self.speech = speech
    }
}

public nonisolated enum OllamaSpeechEmotion: String, Codable, CaseIterable, Equatable, Sendable {
    case neutral
    case happy
    case sad
    case angry
    case surprised
    case thoughtful
    case embarrassed
}

public nonisolated struct OllamaSpeechMetadata: Equatable, Sendable {
    public static let fallback = OllamaSpeechMetadata(
        emotion: .neutral,
        intensity: 0.5,
        speakingRate: 1.0,
        performanceNote: nil
    )

    public let emotion: OllamaSpeechEmotion
    public let intensity: Double
    public let speakingRate: Double
    public let performanceNote: String?

    public init(
        emotion: OllamaSpeechEmotion,
        intensity: Double,
        speakingRate: Double,
        performanceNote: String?
    ) {
        self.emotion = emotion
        self.intensity = intensity
        self.speakingRate = speakingRate
        self.performanceNote = performanceNote
    }
}

public nonisolated enum OllamaResponseParser: Sendable {
    private nonisolated struct SpeechPayload: Decodable {
        let emotion: String?
        let intensity: Double?
        let speakingRate: Double?
        let performanceNote: String?

        enum CodingKeys: String, CodingKey {
            case emotion
            case intensity
            case speakingRate = "speaking_rate"
            case performanceNote = "performance_note"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            emotion = try? container.decodeIfPresent(String.self, forKey: .emotion)
            intensity = try? container.decodeIfPresent(Double.self, forKey: .intensity)
            speakingRate = try? container.decodeIfPresent(Double.self, forKey: .speakingRate)
            performanceNote = try? container.decodeIfPresent(String.self, forKey: .performanceNote)
        }
    }

    private nonisolated struct Payload: Decodable {
        let response: String?
        let message: String?
        let motionState: String?
        let speech: SpeechPayload?

        enum CodingKeys: String, CodingKey {
            case response
            case message
            case motionState = "motion_state"
            case speech = "tts"
        }
    }

    public static func parse(_ content: String, fallback: MotionState = .idle) -> OllamaReply {
        guard let payload = decodePayload(from: content) else {
            return OllamaReply(
                text: content.trimmingCharacters(in: .whitespacesAndNewlines),
                motionState: fallback,
                speech: .fallback
            )
        }

        let text = payload.response ?? payload.message ?? content
        return OllamaReply(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            motionState: motionState(from: payload.motionState) ?? fallback,
            speech: speechMetadata(from: payload.speech)
        )
    }

    public static func motionState(from value: String?) -> MotionState? {
        guard let value else {
            return nil
        }

        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "idle", "neutral", "calm":
            return .idle
        case "thinking", "think", "pondering":
            return .thinking
        case "listening", "listen", "attentive":
            return .listening
        case "surprised", "surprise", "startled":
            return .surprised
        default:
            return nil
        }
    }

    private static func speechMetadata(from payload: SpeechPayload?) -> OllamaSpeechMetadata {
        guard let payload else {
            return .fallback
        }

        let note = payload.performanceNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return OllamaSpeechMetadata(
            emotion: speechEmotion(from: payload.emotion) ?? .neutral,
            intensity: clamp(payload.intensity ?? OllamaSpeechMetadata.fallback.intensity, to: 0...1),
            speakingRate: clamp(payload.speakingRate ?? OllamaSpeechMetadata.fallback.speakingRate, to: 0.5...1.5),
            performanceNote: note?.isEmpty == false ? note : nil
        )
    }

    private static func speechEmotion(from value: String?) -> OllamaSpeechEmotion? {
        guard let value else {
            return nil
        }

        return OllamaSpeechEmotion(
            rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func decodePayload(from content: String) -> Payload? {
        let decoder = JSONDecoder()
        if let data = content.data(using: .utf8),
           let payload = try? decoder.decode(Payload.self, from: data),
           payloadScore(payload) > 0 {
            return payload
        }

        var bestMatch: (payload: Payload, score: Int)?
        for candidate in jsonObjectCandidates(in: content) {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? decoder.decode(Payload.self, from: data) else {
                continue
            }

            let score = payloadScore(payload)
            if score > (bestMatch?.score ?? 0) {
                bestMatch = (payload, score)
            }
        }

        return bestMatch?.payload
    }

    private static func payloadScore(_ payload: Payload) -> Int {
        var score = 0
        if payload.response != nil {
            score += 100
        }
        if payload.message != nil {
            score += 90
        }
        if payload.motionState != nil {
            score += 10
        }
        if payload.speech != nil {
            score += 5
        }
        return score
    }

    private static func jsonObjectCandidates(in content: String) -> [String] {
        var candidates: [String] = []
        var objectStart: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        for index in content.indices {
            let character = content[index]

            if depth == 0 {
                if character == "{" {
                    objectStart = index
                    depth = 1
                    isInsideString = false
                    isEscaping = false
                }
                continue
            }

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let startIndex = objectStart {
                    candidates.append(String(content[startIndex...index]))
                    objectStart = nil
                }
            }
        }

        return candidates
    }
}
