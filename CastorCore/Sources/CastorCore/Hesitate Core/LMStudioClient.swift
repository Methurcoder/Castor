import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public nonisolated struct LMStudioClient: Sendable {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:1234")!
    private static let logger = CastorLog(category: "LMStudio")

    public let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Uses LM Studio's native model endpoint so embedding models can be excluded
    /// from the conversational model picker.
    public func models() async throws -> [OllamaModel] {
        var request = URLRequest(url: endpoint.appending(path: "api/v1/models"))
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let responseBody = try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
        return responseBody.models
            .filter { $0.type == "llm" }
            .map { OllamaModel(name: $0.key, parameterSize: $0.parameterSize) }
    }

    public func chat(model: String, messages: [OllamaChatMessage]) async throws -> String {
        do {
            return try await nonStreamingChat(
                model: model,
                messages: messages,
                responseFormat: .castorResponse
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.notice(
                "LM Studio structured chat failed; retrying without schema. error=\(error.localizedDescription)"
            )
            return try await nonStreamingChat(model: model, messages: messages, responseFormat: nil)
        }
    }

    public func chatStream(
        model: String,
        messages: [OllamaChatMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        let request = try makeChatRequest(
            model: model,
            messages: messages,
            stream: true,
            responseFormat: nil
        )
        let startedAt = Date()
        let (lines, response) = try await HTTPLineStream.lines(for: request, session: session)
        try validate(response: response)

        var content = ""
        var firstChunkAt: Date?
        for try await line in lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let data = payload.data(using: .utf8) else { continue }

            let chunk = try JSONDecoder().decode(LMStudioChatStreamResponse.self, from: data)
            if let message = chunk.error?.message {
                throw LMStudioClientError.serverError(message)
            }
            guard let delta = chunk.choices.first?.delta.content, !delta.isEmpty else { continue }
            if firstChunkAt == nil {
                firstChunkAt = Date()
            }
            content += delta
            onDelta(delta)
        }

        Self.logger.info(
            "LM Studio streamed chat in \(CastorLog.fixed(Date().timeIntervalSince(startedAt), precision: 2))s; firstChunk=\(CastorLog.fixed((firstChunkAt?.timeIntervalSince(startedAt) ?? -1), precision: 2))s; chars=\(content.count)"
        )
        return content
    }

    private func nonStreamingChat(
        model: String,
        messages: [OllamaChatMessage],
        responseFormat: LMStudioResponseFormat?
    ) async throws -> String {
        let request = try makeChatRequest(
            model: model,
            messages: messages,
            stream: false,
            responseFormat: responseFormat
        )
        let startedAt = Date()
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let reply = try JSONDecoder().decode(LMStudioChatResponse.self, from: data)
        if let message = reply.error?.message {
            throw LMStudioClientError.serverError(message)
        }
        let content = (reply.choices.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw LMStudioClientError.emptyResponse
        }
        Self.logger.info(
            "LM Studio non-streaming chat in \(CastorLog.fixed(Date().timeIntervalSince(startedAt), precision: 2))s; chars=\(content.count)"
        )
        return content
    }

    private func makeChatRequest(
        model: String,
        messages: [OllamaChatMessage],
        stream: Bool,
        responseFormat: LMStudioResponseFormat?
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LMStudioChatRequest(
                model: model,
                messages: messages,
                stream: stream,
                responseFormat: responseFormat
            )
        )
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LMStudioClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(LMStudioErrorEnvelope.self, from: data))?.error.message
            throw LMStudioClientError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LMStudioClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LMStudioClientError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
}

public nonisolated enum LMStudioClientError: LocalizedError {
    case invalidResponse
    case emptyResponse
    case httpError(statusCode: Int, message: String?)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "LM Studio returned an invalid response."
        case .emptyResponse:
            "LM Studio returned an empty reply."
        case let .httpError(statusCode, message):
            message ?? "LM Studio returned HTTP \(statusCode)."
        case let .serverError(message):
            message
        }
    }
}

private nonisolated struct LMStudioModelsResponse: Decodable {
    struct Model: Decodable {
        let type: String
        let key: String
        let parameterSize: String?

        enum CodingKeys: String, CodingKey {
            case type, key
            case parameterSize = "params_string"
        }
    }

    let models: [Model]
}

private nonisolated struct LMStudioChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
    let responseFormat: LMStudioResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case responseFormat = "response_format"
    }
}

private nonisolated struct LMStudioResponseFormat: Encodable {
    struct JSONSchema: Encodable {
        let name: String
        let strict: Bool
        let schema: LMStudioJSONValue
    }

    let type: String
    let jsonSchema: JSONSchema

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    static let castorResponse = LMStudioResponseFormat(
        type: "json_schema",
        jsonSchema: JSONSchema(
            name: "castor_response",
            strict: true,
            schema: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "response": .object(["type": .string("string")]),
                    "motion_state": .object([
                        "type": .string("string"),
                        "enum": .array([.string("idle"), .string("thinking"), .string("listening"), .string("surprised")])
                    ]),
                    "tts": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "properties": .object([
                            "emotion": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("neutral"), .string("happy"), .string("sad"),
                                    .string("angry"), .string("surprised"), .string("thoughtful"),
                                    .string("embarrassed")
                                ])
                            ]),
                            "intensity": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
                            "speaking_rate": .object(["type": .string("number"), "minimum": .number(0.5), "maximum": .number(1.5)])
                        ]),
                        "required": .array([.string("emotion"), .string("intensity"), .string("speaking_rate")])
                    ])
                ]),
                "required": .array([.string("response"), .string("motion_state"), .string("tts")])
            ])
        )
    )
}

private nonisolated enum LMStudioJSONValue: Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([LMStudioJSONValue])
    case object([String: LMStudioJSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

private nonisolated struct LMStudioErrorPayload: Decodable {
    let message: String
}

private nonisolated struct LMStudioErrorEnvelope: Decodable {
    let error: LMStudioErrorPayload
}

private nonisolated struct LMStudioChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }

    let choices: [Choice]
    let error: LMStudioErrorPayload?
}

private nonisolated struct LMStudioChatStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }

    let choices: [Choice]
    let error: LMStudioErrorPayload?
}
