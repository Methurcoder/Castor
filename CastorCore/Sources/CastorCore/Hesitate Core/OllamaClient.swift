import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public nonisolated struct OllamaClient: Sendable {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:11434")!
    private static let logger = CastorLog(category: "Ollama")

    public let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func models() async throws -> [OllamaModel] {
        var request = URLRequest(url: endpoint.appending(path: "api/tags"))
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TagsResponse.self, from: data).models.map {
            OllamaModel(name: $0.name, parameterSize: $0.details?.parameterSize)
        }
    }

    public func chat(model: String, messages: [OllamaChatMessage]) async throws -> String {
        do {
            return try await nonStreamingChat(
                model: model,
                messages: messages,
                format: .responseSchema
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.notice(
                "Ollama structured chat failed; retrying without schema. error=\(error.localizedDescription)"
            )
            do {
                return try await nonStreamingChat(
                    model: model,
                    messages: messages,
                    format: nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.notice(
                    "Ollama non-streaming chat failed; falling back to streaming chat. error=\(error.localizedDescription)"
                )
                return try await streamingChat(model: model, messages: messages, format: nil)
            }
        }
    }

    /// One-shot structured vision request used by Arils AI alignment. This is
    /// intentionally separate from conversational chat: it does not touch chat
    /// history or the motion/TTS response schema.
    public func arilsFaceLayoutAdjustment(
        model: String,
        prompt: String,
        imageBase64: String
    ) async throws -> String {
        let messages = [
            OllamaChatMessage(
                role: .user,
                content: prompt,
                images: [imageBase64]
            )
        ]
        do {
            return try await nonStreamingChat(
                model: model,
                messages: messages,
                format: .arilsFaceLayoutSchema
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.notice(
                "Ollama vision schema request failed; retrying in JSON mode. error=\(error.localizedDescription)"
            )
            return try await nonStreamingChat(
                model: model,
                messages: messages,
                format: .string("json")
            )
        }
    }

    private func streamingChat(
        model: String,
        messages: [OllamaChatMessage],
        format: JSONValue?
    ) async throws -> String {
        try await streamingChat(model: model, messages: messages, format: format, onDelta: nil)
    }

    /// Streams a plain (non-schema) chat response, invoking `onDelta` with each incremental text
    /// chunk as it arrives so callers can pipeline downstream work (e.g. text-to-speech) instead
    /// of waiting for the full reply. Used only by the on-device pipelined voice path; the
    /// fallback chain in `chat(...)` calls the private overload above and never triggers `onDelta`.
    public func chatStream(
        model: String,
        messages: [OllamaChatMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        try await streamingChat(model: model, messages: messages, format: nil, onDelta: onDelta)
    }

    private func streamingChat(
        model: String,
        messages: [OllamaChatMessage],
        format: JSONValue?,
        onDelta: ((String) -> Void)?
    ) async throws -> String {
        let request = try makeChatRequest(
            model: model,
            messages: messages,
            stream: true,
            format: format
        )
        let startedAt = Date()
        let (lines, response) = try await HTTPLineStream.lines(for: request, session: session)
        try validate(response: response)

        var content = ""
        var firstChunkAt: Date?

        for try await line in lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8), !data.isEmpty else {
                continue
            }

            let chunk: ChatStreamResponse
            do {
                chunk = try JSONDecoder().decode(ChatStreamResponse.self, from: data)
            } catch {
                Self.logger.notice(
                    "Ollama stream line could not be decoded. line=\(String(line.prefix(220)))"
                )
                throw error
            }

            if let error = chunk.error {
                throw OllamaClientError.serverError(error)
            }
            if let delta = chunk.contentDelta, !delta.isEmpty {
                if firstChunkAt == nil {
                    firstChunkAt = Date()
                }
                content += delta
                onDelta?(delta)
            }
            if chunk.done == true {
                break
            }
        }

        Self.logger.info(
            "Ollama streamed chat in \(CastorLog.fixed(Date().timeIntervalSince(startedAt), precision: 2))s; firstChunk=\(CastorLog.fixed((firstChunkAt?.timeIntervalSince(startedAt) ?? -1), precision: 2))s; chars=\(content.count)"
        )

        return content
    }

    private func nonStreamingChat(
        model: String,
        messages: [OllamaChatMessage],
        format: JSONValue?
    ) async throws -> String {
        let request = try makeChatRequest(
            model: model,
            messages: messages,
            stream: false,
            format: format
        )
        let startedAt = Date()
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let reply = try JSONDecoder().decode(ChatResponse.self, from: data)
        if let error = reply.error {
            throw OllamaClientError.serverError(error)
        }

        let content = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.logger.info(
            "Ollama non-streaming chat in \(CastorLog.fixed(Date().timeIntervalSince(startedAt), precision: 2))s; chars=\(content.count)"
        )

        return content
    }

    private func makeChatRequest(
        model: String,
        messages: [OllamaChatMessage],
        stream: Bool,
        format: JSONValue?
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: messages,
                stream: stream,
                keepAlive: "10m",
                format: format
            )
        )
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverMessage = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw OllamaClientError.httpError(statusCode: httpResponse.statusCode, message: serverMessage)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OllamaClientError.httpError(statusCode: httpResponse.statusCode, message: nil)
        }
    }
}

public nonisolated enum OllamaClientError: LocalizedError {
    case invalidResponse
    case emptyResponse
    case httpError(statusCode: Int, message: String?)
    case noModels
    case noSelectedModel
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Ollama returned an invalid response."
        case .emptyResponse:
            "Ollama returned an empty reply."
        case let .httpError(statusCode, message):
            message ?? "Ollama returned HTTP \(statusCode)."
        case .noModels:
            "Ollama is connected, but no models are installed."
        case .noSelectedModel:
            "Select an Ollama model before sending a message."
        case let .serverError(message):
            message
        }
    }
}

private nonisolated struct TagsResponse: Decodable {
    struct Model: Decodable {
        struct Details: Decodable {
            let parameterSize: String?

            enum CodingKeys: String, CodingKey {
                case parameterSize = "parameter_size"
            }
        }

        let name: String
        let details: Details?
    }

    let models: [Model]
}

private nonisolated struct ChatRequest: Encodable {
    let model: String
    let messages: [OllamaChatMessage]
    let stream: Bool
    let keepAlive: String
    let format: JSONValue?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case keepAlive = "keep_alive"
        case format
    }
}

private nonisolated enum JSONValue: Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    static let responseSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "response": .object([
                "type": .string("string")
            ]),
            "motion_state": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("idle"),
                    .string("thinking"),
                    .string("listening"),
                    .string("surprised")
                ])
            ]),
            "tts": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "emotion": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("neutral"),
                            .string("happy"),
                            .string("sad"),
                            .string("angry"),
                            .string("surprised"),
                            .string("thoughtful"),
                            .string("embarrassed")
                        ])
                    ]),
                    "intensity": .object([
                        "type": .string("number"),
                        "minimum": .number(0),
                        "maximum": .number(1)
                    ]),
                    "speaking_rate": .object([
                        "type": .string("number"),
                        "minimum": .number(0.5),
                        "maximum": .number(1.5)
                    ]),
                    "performance_note": .object([
                        "type": .string("string")
                    ])
                ]),
                "required": .array([
                    .string("emotion"),
                    .string("intensity"),
                    .string("speaking_rate")
                ])
            ])
        ]),
        "required": .array([
            .string("response"),
            .string("motion_state"),
            .string("tts")
        ])
    ])

    private static let normalizedRectSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "x": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
            "y": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
            "width": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)]),
            "height": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(1)])
        ]),
        "required": .array([.string("x"), .string("y"), .string("width"), .string("height")])
    ])

    static let arilsFaceLayoutSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "operation": .object([
                "type": .string("string"),
                "enum": .array([.string("POME_ARILS_FACE_LAYOUT_V1")])
            ]),
            "head": normalizedRectSchema,
            "eye_left": normalizedRectSchema,
            "eye_right": normalizedRectSchema,
            "mouth": normalizedRectSchema,
            "confidence": .object([
                "type": .string("number"),
                "minimum": .number(0),
                "maximum": .number(1)
            ]),
            "explanation": .object(["type": .string("string")])
        ]),
        "required": .array([
            .string("operation"), .string("head"), .string("eye_left"),
            .string("eye_right"), .string("mouth"), .string("confidence"),
            .string("explanation")
        ])
    ])

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try single.encode(value)
        case let .number(value):
            try single.encode(value)
        case let .bool(value):
            try single.encode(value)
        case let .array(values):
            try single.encode(values)
        case let .object(values):
            try single.encode(values)
        }
    }
}

private nonisolated struct ChatMessagePayload: Decodable {
    let content: String?
}

private nonisolated struct ChatStreamResponse: Decodable {
    let message: ChatMessagePayload?
    let response: String?
    let done: Bool?
    let error: String?

    var contentDelta: String? {
        message?.content ?? response
    }
}

private nonisolated struct ChatResponse: Decodable {
    let message: ChatMessagePayload?
    let response: String?
    let error: String?

    var content: String {
        message?.content ?? response ?? ""
    }
}

private nonisolated struct ErrorResponse: Decodable {
    let error: String
}
