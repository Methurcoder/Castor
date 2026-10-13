import Foundation
import Observation

public enum OllamaConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

public enum LocalAIProvider: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case lmStudio
    case ollama

    public var label: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        }
    }
}

public enum OllamaModelSelectionStore {
    private static let key = "Pomegranate.Ollama.SelectedModel"

    public static var selectedModel: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

public enum LMStudioModelSelectionStore {
    private static let key = "Pomegranate.LMStudio.SelectedModel"

    public static var selectedModel: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

public enum LocalAIError: LocalizedError {
    case noModels(LocalAIProvider)
    case noSelectedModel

    public var errorDescription: String? {
        switch self {
        case let .noModels(provider):
            "\(provider.label) is connected, but no conversational models are available."
        case .noSelectedModel:
            "Select a local AI model before sending a message."
        }
    }
}

@MainActor
@Observable
public final class OllamaSession {
    private static let systemPrompt = """
    Return only JSON matching the requested schema.
    Keep response to one short sentence in the user's language unless they ask for more.
    \(onDeviceCapabilityInstruction)
    Do not include breath, sigh, gasp, whisper, mouth-noise, or nonverbal performance tags.
    """

    /// System prompt used only by `sendStreaming(...)`. Plain text (no JSON) so the streamed
    /// tokens can be sentence-split and spoken immediately; motion/TTS metadata falls back to
    /// defaults for this path, matching how a broken/plain reply is already treated in
    /// `OllamaResponseParser.parse(_:fallback:)`.
    private static let streamingSystemPrompt = """
    Reply in plain prose only. Do not use JSON, markdown, or code fences.
    Keep response to one short sentence in the user's language unless they ask for more.
    \(onDeviceCapabilityInstruction)
    Do not include breath, sigh, gasp, whisper, mouth-noise, or nonverbal performance tags.
    """

    private static let onDeviceCapabilityInstruction = """
    You can only chat: you cannot operate the user's Mac, read or change files, run commands, or control apps.
    If asked to perform an action, honestly say you cannot do it in on-device mode and suggest switching to Codex or Claude Code to request it.
    Never claim you performed an action you did not perform.
    """

    public private(set) var connectionState: OllamaConnectionState = .disconnected
    public private(set) var isLoading = false
    public private(set) var models: [OllamaModel] = []
    public private(set) var activeProvider: LocalAIProvider?
    public private(set) var availableProviders: Set<LocalAIProvider> = []
    public private(set) var responseText = ""
    public private(set) var responseSpeech = OllamaSpeechMetadata.fallback
    public private(set) var errorMessage: String?
    public var selectedModel: String? {
        didSet {
            guard selectedModel != oldValue else { return }
            persistSelectedModel()
        }
    }

    private let client: OllamaClient
    private let lmStudioClient: LMStudioClient?
    private var conversation: [OllamaChatMessage] = []

    public init(client: OllamaClient, lmStudioClient: LMStudioClient? = nil) {
        self.client = client
        self.lmStudioClient = lmStudioClient
        selectedModel = nil
    }

    public convenience init() {
        self.init(client: OllamaClient(), lmStudioClient: LMStudioClient())
    }

    public var endpoint: URL {
        activeProvider == .lmStudio ? (lmStudioClient?.endpoint ?? LMStudioClient.defaultEndpoint) : client.endpoint
    }

    public var ollamaEndpoint: URL {
        client.endpoint
    }

    public var lmStudioEndpoint: URL {
        lmStudioClient?.endpoint ?? LMStudioClient.defaultEndpoint
    }

    public static func resolvedModelName(
        availableModels: [OllamaModel],
        preferredModel: String?
    ) -> String? {
        preferredModel.flatMap { selected in
            availableModels.contains(where: { $0.name == selected }) ? selected : nil
        } ?? availableModels.first?.name
    }

    public func connect() async {
        connectionState = .connecting
        errorMessage = nil
        availableProviders = []

        var lmStudioModels: [OllamaModel]?
        var lmStudioFailure: Error?
        if let lmStudioClient {
            do {
                lmStudioModels = try await lmStudioClient.models()
                availableProviders.insert(.lmStudio)
            } catch {
                lmStudioFailure = error
            }
        }

        var ollamaModels: [OllamaModel]?
        var ollamaFailure: Error?
        do {
            ollamaModels = try await client.models()
            availableProviders.insert(.ollama)
        } catch {
            ollamaFailure = error
        }

        // A usable LM Studio connection wins. Ollama remains the automatic fallback
        // when LM Studio is stopped or has no conversational model.
        if let lmStudioModels, !lmStudioModels.isEmpty {
            activate(.lmStudio, models: lmStudioModels)
        } else if let ollamaModels, !ollamaModels.isEmpty {
            activate(.ollama, models: ollamaModels)
        } else if let lmStudioModels {
            activate(.lmStudio, models: lmStudioModels)
            errorMessage = LocalAIError.noModels(.lmStudio).localizedDescription
        } else if let ollamaModels {
            activate(.ollama, models: ollamaModels)
            errorMessage = LocalAIError.noModels(.ollama).localizedDescription
        } else {
            models = []
            activeProvider = nil
            selectedModel = nil
            connectionState = .disconnected
            errorMessage = connectionFailureMessage(
                lmStudioFailure: lmStudioFailure,
                ollamaFailure: ollamaFailure
            )
        }
    }

    public func send(
        _ prompt: String,
        to core: HesitateCore,
        personalityInstruction: String? = nil
    ) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return
        }
        do {
            try await waitUntilIdle()
        } catch {
            core.request(.idle)
            return
        }
        applyPersistedModelSelection()
        guard let selectedModel else {
            errorMessage = LocalAIError.noSelectedModel.localizedDescription
            return
        }

        isLoading = true
        defer {
            isLoading = false
        }
        errorMessage = nil
        core.request(.thinking)

        let userMessage = OllamaChatMessage(role: .user, content: trimmedPrompt)
        let personality = personalityInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let personalityLine = personality.flatMap { value in
            value.isEmpty ? nil : "Character direction: \(value)"
        }
        let systemPrompt = [
            Self.systemPrompt,
            personalityLine
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
        let requestMessages = [
            OllamaChatMessage(role: .system, content: systemPrompt)
        ] + conversation + [userMessage]

        do {
            let content = try await chat(model: selectedModel, messages: requestMessages)
            let reply = OllamaResponseParser.parse(content)

            responseText = reply.text
            responseSpeech = reply.speech
            conversation.append(userMessage)
            conversation.append(
                OllamaChatMessage(
                    role: .assistant,
                    content: responseText
                )
            )
            trimConversation()
            core.request(reply.motionState)
            connectionState = .connected
        } catch is CancellationError {
            errorMessage = nil
            core.request(.idle)
        } catch {
            errorMessage = userFacingMessage(for: error)
            core.request(.idle)
        }
    }

    /// Pipelined variant of `send(...)`: streams plain-text tokens from the active local provider and invokes
    /// `onSentence` as soon as each complete sentence is available, so the caller can start
    /// text-to-speech before the full reply has finished generating. Throws on any failure
    /// (connection, decode, cancellation) instead of setting `errorMessage`, so the caller can
    /// safely fall back to the non-streaming `send(...)` path without leaving stray state behind.
    ///
    /// On success, `responseText`/`responseSpeech`/`conversation` are updated the same way as
    /// `send(...)`, except `responseSpeech` always falls back to `.fallback` because this path
    /// never receives structured `tts` metadata (the model is asked for plain prose only).
    public func sendStreaming(
        _ prompt: String,
        to core: HesitateCore,
        personalityInstruction: String? = nil,
        onSentence: @escaping (String) -> Void
    ) async throws {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw OllamaClientError.emptyResponse }
        try await waitUntilIdle()
        applyPersistedModelSelection()
        guard let selectedModel else {
            throw LocalAIError.noSelectedModel
        }

        isLoading = true
        defer {
            isLoading = false
        }
        errorMessage = nil
        core.request(.thinking)

        let userMessage = OllamaChatMessage(role: .user, content: trimmedPrompt)
        let personality = personalityInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let personalityLine = personality.flatMap { value in
            value.isEmpty ? nil : "Character direction: \(value)"
        }
        let systemPrompt = [
            Self.streamingSystemPrompt,
            personalityLine
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
        let requestMessages = [
            OllamaChatMessage(role: .system, content: systemPrompt)
        ] + conversation + [userMessage]

        var extractor = OllamaStreamingSentenceExtractor()
        let content = try await chatStream(
            model: selectedModel,
            messages: requestMessages
        ) { delta in
            for sentence in extractor.append(delta) {
                onSentence(sentence)
            }
        }
        try Task.checkCancellation()

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw OllamaClientError.emptyResponse
        }
        if let remainder = extractor.flushRemainder() {
            onSentence(remainder)
        }
        responseText = trimmedContent
        responseSpeech = .fallback
        conversation.append(userMessage)
        conversation.append(OllamaChatMessage(role: .assistant, content: trimmedContent))
        trimConversation()
        connectionState = .connected
    }

    public func clearConversation() {
        conversation = []
        responseText = ""
        responseSpeech = .fallback
        errorMessage = nil
    }

    private func trimConversation() {
        let maximumMessages = 4
        if conversation.count > maximumMessages {
            conversation.removeFirst(conversation.count - maximumMessages)
        }
    }

    private func waitUntilIdle() async throws {
        while isLoading {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func applyPersistedModelSelection() {
        guard let activeProvider,
              let preferredModel = persistedModel(for: activeProvider),
              models.contains(where: { $0.name == preferredModel }) else {
            return
        }
        selectedModel = preferredModel
    }

    private func activate(_ provider: LocalAIProvider, models availableModels: [OllamaModel]) {
        if activeProvider != nil, activeProvider != provider {
            conversation = []
        }
        activeProvider = provider
        models = availableModels
        selectedModel = Self.resolvedModelName(
            availableModels: availableModels,
            preferredModel: persistedModel(for: provider)
        )
        connectionState = .connected
    }

    private func persistedModel(for provider: LocalAIProvider) -> String? {
        switch provider {
        case .lmStudio: LMStudioModelSelectionStore.selectedModel
        case .ollama: OllamaModelSelectionStore.selectedModel
        }
    }

    private func persistSelectedModel() {
        switch activeProvider {
        case .lmStudio:
            LMStudioModelSelectionStore.selectedModel = selectedModel
        case .ollama:
            OllamaModelSelectionStore.selectedModel = selectedModel
        case nil:
            break
        }
    }

    private func chat(model: String, messages: [OllamaChatMessage]) async throws -> String {
        switch activeProvider {
        case .lmStudio:
            guard let lmStudioClient else { throw LMStudioClientError.invalidResponse }
            return try await lmStudioClient.chat(model: model, messages: messages)
        case .ollama:
            return try await client.chat(model: model, messages: messages)
        case nil:
            throw LocalAIError.noSelectedModel
        }
    }

    private func chatStream(
        model: String,
        messages: [OllamaChatMessage],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        switch activeProvider {
        case .lmStudio:
            guard let lmStudioClient else { throw LMStudioClientError.invalidResponse }
            return try await lmStudioClient.chatStream(model: model, messages: messages, onDelta: onDelta)
        case .ollama:
            return try await client.chatStream(model: model, messages: messages, onDelta: onDelta)
        case nil:
            throw LocalAIError.noSelectedModel
        }
    }

    private func connectionFailureMessage(
        lmStudioFailure: Error?,
        ollamaFailure: Error?
    ) -> String {
        let details = [
            lmStudioFailure.map { "LM Studio: \(userFacingMessage(for: $0))" },
            ollamaFailure.map { "Ollama: \(userFacingMessage(for: $0))" }
        ].compactMap { $0 }
        guard !details.isEmpty else {
            return "Could not connect to LM Studio or Ollama."
        }
        return "Could not connect to LM Studio or Ollama. " + details.joined(separator: " ")
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
