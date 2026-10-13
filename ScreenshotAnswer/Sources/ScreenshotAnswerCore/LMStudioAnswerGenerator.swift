import AppKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol ScreenshotAnswerGenerating: Sendable {
    func availableModels() async throws -> [String]
    func answer(
        recognizedText: String,
        model: String,
        options: LMStudioGenerationOptions
    ) async throws -> String
}

public struct LMStudioModelInfo: Sendable, Equatable, Decodable {
    public let type: String
    public let key: String
    public let displayName: String?
    public let sizeBytes: Int64?
    public let paramsString: String?
    public let supportsVision: Bool

    private enum CodingKeys: String, CodingKey {
        case type
        case key
        case displayName = "display_name"
        case sizeBytes = "size_bytes"
        case paramsString = "params_string"
        case capabilities
    }

    private struct Capabilities: Decodable {
        let vision: Bool?
    }

    public init(
        type: String = "llm",
        key: String,
        displayName: String? = nil,
        sizeBytes: Int64? = nil,
        paramsString: String? = nil,
        supportsVision: Bool = false
    ) {
        self.type = type
        self.key = key
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.paramsString = paramsString
        self.supportsVision = supportsVision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        key = try container.decode(String.self, forKey: .key)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        paramsString = try container.decodeIfPresent(String.self, forKey: .paramsString)
        supportsVision = try container
            .decodeIfPresent(Capabilities.self, forKey: .capabilities)?
            .vision ?? false
    }

    public var parameterCount: Double? {
        guard let paramsString else { return nil }
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*([KMBT])"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(paramsString.startIndex..., in: paramsString)
        guard let match = expression.firstMatch(in: paramsString, range: range),
              let numberRange = Range(match.range(at: 1), in: paramsString),
              let unitRange = Range(match.range(at: 2), in: paramsString),
              let number = Double(paramsString[numberRange]) else { return nil }
        let multiplier: Double = switch paramsString[unitRange].uppercased() {
        case "K": 1_000
        case "M": 1_000_000
        case "B": 1_000_000_000
        case "T": 1_000_000_000_000
        default: 1
        }
        return number * multiplier
    }
}

public enum LMStudioVisionModelSelector {
    public static func closestVisionModel(
        to selectedModel: String,
        among models: [LMStudioModelInfo]
    ) -> LMStudioModelInfo? {
        let visionModels = models.filter { $0.type == "llm" && $0.supportsVision }
        guard !visionModels.isEmpty else { return nil }
        guard let reference = models.first(where: { $0.key == selectedModel }) else {
            return visionModels.sorted { $0.key < $1.key }.first
        }

        return visionModels.min { lhs, rhs in
            let lhsDistance = distance(from: reference, to: lhs)
            let rhsDistance = distance(from: reference, to: rhs)
            if lhsDistance == rhsDistance { return lhs.key < rhs.key }
            return lhsDistance < rhsDistance
        }
    }

    private static func distance(
        from reference: LMStudioModelInfo,
        to candidate: LMStudioModelInfo
    ) -> Double {
        if let referenceCount = reference.parameterCount,
           let candidateCount = candidate.parameterCount,
           referenceCount > 0,
           candidateCount > 0 {
            return abs(log(candidateCount / referenceCount))
        }
        if let referenceSize = reference.sizeBytes,
           let candidateSize = candidate.sizeBytes,
           referenceSize > 0,
           candidateSize > 0 {
            return abs(log(Double(candidateSize) / Double(referenceSize))) + 100
        }
        return candidate.key == reference.key ? 0 : Double.greatestFiniteMagnitude
    }
}

public extension ScreenshotAnswerGenerating {
    func answer(recognizedText: String, model: String) async throws -> String {
        try await answer(
            recognizedText: recognizedText,
            model: model,
            options: LMStudioGenerationOptions()
        )
    }
}

public struct LMStudioGenerationOptions: Sendable, Equatable {
    public var draftModel: String?

    public init(draftModel: String? = nil) {
        self.draftModel = draftModel
    }

    func resolvedDraftModel(for model: String) -> String? {
        guard let draftModel else { return nil }
        let trimmed = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != model else { return nil }
        return trimmed
    }
}

/// Local-only client for LM Studio's OpenAI-compatible HTTP API.
public struct LMStudioAnswerGenerator: ScreenshotAnswerGenerating {
    public static let defaultServerURL = URL(string: "http://127.0.0.1:1234")!

    public let serverURL: URL
    private let session: URLSession
    private let prompt: ScreenshotAnswerPrompt

    public init(
        serverURL: URL = Self.defaultServerURL,
        session: URLSession = .shared,
        prompt: ScreenshotAnswerPrompt = ScreenshotAnswerPrompt()
    ) throws {
        guard Self.isLoopback(serverURL) else {
            throw ScreenshotAnswerError.lmStudioEndpointMustBeLocal
        }
        self.serverURL = serverURL
        self.session = session
        self.prompt = prompt
    }

    public func availableModels() async throws -> [String] {
        try await availableModelInfos().map(\.key)
    }

    public func availableModelInfos() async throws -> [LMStudioModelInfo] {
        var request = URLRequest(url: serverURL.appending(path: "api/v1/models"))
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.models
                .filter { $0.type == "llm" }
                .sorted { $0.key < $1.key }
        } catch let error as ScreenshotAnswerError {
            throw error
        } catch is DecodingError {
            throw ScreenshotAnswerError.invalidLMStudioResponse
        } catch {
            throw ScreenshotAnswerError.lmStudioUnavailable
        }
    }

    public func answer(
        recognizedText: String,
        model: String,
        options: LMStudioGenerationOptions = LMStudioGenerationOptions()
    ) async throws -> String {
        try await generate(
            messages: prompt.messages(for: recognizedText),
            model: model,
            options: options
        )
    }

    public func describe(
        recognizedText: String,
        model: String,
        options: LMStudioGenerationOptions = LMStudioGenerationOptions()
    ) async throws -> String {
        try await generate(
            messages: prompt.descriptionMessages(for: recognizedText),
            model: model,
            options: options
        )
    }

    public func describeImage(
        imageURL: URL,
        recognizedText: String?,
        model: String,
        options: LMStudioGenerationOptions = LMStudioGenerationOptions()
    ) async throws -> String {
        let imageBase64 = try Self.imageBase64(from: imageURL)
        return try await generate(
            messages: prompt.imageDescriptionMessages(
                imageBase64: imageBase64,
                recognizedText: recognizedText
            ),
            model: model,
            options: options
        )
    }

    public func answerAboutAudio(
        transcript: String,
        screenshotText: String?,
        userQuestion: String?,
        organizeMultipleSpeakers: Bool = true,
        model: String,
        options: LMStudioGenerationOptions = LMStudioGenerationOptions()
    ) async throws -> String {
        try await generate(
            messages: prompt.audioMessages(
                transcript: transcript,
                screenshotText: screenshotText,
                userQuestion: userQuestion,
                organizeMultipleSpeakers: organizeMultipleSpeakers
            ),
            model: model,
            options: options
        )
    }

    private func generate(
        messages: [LMStudioMessage],
        model: String,
        options: LMStudioGenerationOptions
    ) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw ScreenshotAnswerError.noLMStudioModel }

        var request = URLRequest(url: serverURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try LMStudioRequestEncoder.encode(
            messages: messages,
            model: trimmedModel,
            options: options
        )

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode),
               messages.contains(where: { $0.imageBase64 != nil }),
               Self.isImageCapabilityError(data: data) {
                throw ScreenshotAnswerError.imageModelRequired(trimmedModel)
            }
            try Self.validate(response: response, data: data)
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                throw ScreenshotAnswerError.invalidLMStudioResponse
            }
            let answer = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw ScreenshotAnswerError.emptyAnswer }
            return answer
        } catch let error as ScreenshotAnswerError {
            throw error
        } catch is DecodingError {
            throw ScreenshotAnswerError.invalidLMStudioResponse
        } catch {
            throw ScreenshotAnswerError.lmStudioUnavailable
        }
    }

    public static func isLoopback(_ serverURL: URL) -> Bool {
        guard serverURL.scheme == "http",
              let host = serverURL.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func imageBase64(from imageURL: URL) throws -> String {
        guard let image = NSImage(contentsOf: imageURL),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenshotAnswerError.unreadableImage
        }

        let maximumDimension: CGFloat = 1_600
        let scale = min(1, maximumDimension / max(CGFloat(source.width), CGFloat(source.height)))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ScreenshotAnswerError.unreadableImage
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ScreenshotAnswerError.unreadableImage
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()

        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        ) else {
            throw ScreenshotAnswerError.unreadableImage
        }
        return data.base64EncodedString()
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ScreenshotAnswerError.invalidLMStudioResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let message = LMStudioErrorResponse.message(from: data), !message.isEmpty {
                throw ScreenshotAnswerError.lmStudioRequestFailed(message)
            }
            throw ScreenshotAnswerError.lmStudioUnavailable
        }
    }

    private static func isImageCapabilityError(data: Data) -> Bool {
        guard let message = LMStudioErrorResponse.message(from: data)?.lowercased() else {
            return false
        }
        let imageTerms = ["image", "vision", "multimodal", "image_url"]
        let unsupportedTerms = ["support", "unsupported", "not capable", "does not accept"]
        return imageTerms.contains(where: message.contains)
            && unsupportedTerms.contains(where: message.contains)
    }
}

struct LMStudioRequestEncoder {
    static func encode(
        messages: [LMStudioMessage],
        model: String,
        options: LMStudioGenerationOptions = LMStudioGenerationOptions()
    ) throws -> Data {
        try JSONEncoder().encode(
            ChatCompletionRequest(
                model: model,
                messages: messages.map(ChatCompletionMessage.init),
                temperature: 0.15,
                stream: false,
                draftModel: options.resolvedDraftModel(for: model)
            )
        )
    }
}

private struct ModelsResponse: Decodable {
    let models: [LMStudioModelInfo]
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatCompletionMessage]
    let temperature: Double
    let stream: Bool
    let draftModel: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case stream
        case draftModel = "draft_model"
    }
}

private struct ChatCompletionMessage: Encodable {
    let role: String
    let content: Content

    init(_ message: LMStudioMessage) {
        role = message.role
        if let imageBase64 = message.imageBase64 {
            content = .parts([
                .text(message.content),
                .imageURL("data:image/jpeg;base64,\(imageBase64)"),
            ])
        } else {
            content = .text(message.content)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch content {
        case let .text(text):
            try container.encode(text, forKey: .content)
        case let .parts(parts):
            try container.encode(parts, forKey: .content)
        }
    }

    enum Content {
        case text(String)
        case parts([ContentPart])
    }
}

private enum ContentPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private enum ImageURLCodingKeys: String, CodingKey {
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .imageURL(url):
            try container.encode("image_url", forKey: .type)
            var imageURL = container.nestedContainer(
                keyedBy: ImageURLCodingKeys.self,
                forKey: .imageURL
            )
            try imageURL.encode(url, forKey: .url)
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct LMStudioErrorResponse: Decodable {
    let error: ErrorPayload

    enum ErrorPayload: Decodable {
        case text(String)
        case object(String)

        private enum CodingKeys: String, CodingKey {
            case message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            let object = try decoder.container(keyedBy: CodingKeys.self)
            self = .object(try object.decode(String.self, forKey: .message))
        }

        var message: String {
            switch self {
            case let .text(message), let .object(message): message
            }
        }
    }

    static func message(from data: Data) -> String? {
        (try? JSONDecoder().decode(Self.self, from: data))?.error.message
    }
}
