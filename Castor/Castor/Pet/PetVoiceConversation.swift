import Foundation
import Observation
import os
import CastorCore

enum PetVoicePhase: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case failed

    var label: String {
        switch self {
        case .idle:
            "Click to talk"
        case .listening:
            "Listening... click again when finished"
        case .thinking:
            "Thinking..."
        case .speaking:
            "Replying..."
        case .failed:
            "Click to try again"
        }
    }
}

@MainActor
@Observable
final class PetVoiceConversation {
    private static let logger = Logger(subsystem: "dev.pomegranate.prototype", category: "PetVoice")

    private(set) var phase: PetVoicePhase = .idle
    private(set) var transcript = ""
    private(set) var responseText = ""
    private(set) var errorMessage: String?
    private(set) var errorIsAppMessage = false
    private(set) var generationStatus = ""
    private(set) var activeBrain: CastorBrain = .onDevice
    private(set) var pendingApproval: CastorAgentApprovalRequest?

    let core = HesitateCore()

    private let speechInput = SpeechInputEngine()
    private let ollama = OllamaSession()
    private let codex = CodexAppServerSession()
    private let claudeCode = ClaudeCodeBridgeSession()
    private let speechOutput: PetSpeechOutput
    private var responseSpeech = OllamaSpeechMetadata.fallback
    private var interactionTask: Task<Void, Never>?
    private let latency = VoiceLatencyTracker()
    /// When the voice was last toggled, to drop a second toggle from the same click.
    private var lastToggle = Date.distantPast
    /// True from a listening request until speech input has started (or failed).
    private var listeningStartPending = false

    init() {
        speechOutput = PetSpeechOutput(
            voiceProfile: PetVoiceProfile.resolvedProfile()
        )
    }

    var caption: String {
        if let pendingApproval {
            return "\(pendingApproval.title)"
        }
        if phase == .failed, let errorMessage {
            return errorMessage
        }
        if phase == .speaking, !responseText.isEmpty {
            return responseText
        }
        if phase == .listening, !speechInput.transcript.isEmpty {
            return "“\(speechInput.transcript)”"
        }
        if phase == .listening, speechInput.state == .requestingPermission {
            return "Preparing \(speechInput.activeMicrophoneName.isEmpty ? "microphone" : speechInput.activeMicrophoneName)..."
        }
        if phase == .thinking, !transcript.isEmpty {
            if let onDeviceOperationNotice { return onDeviceOperationNotice }
            return "Generating reply for “\(transcript)”"
        }
        return phase.label
    }

    var isActive: Bool {
        phase != .idle && phase != .failed
    }

    var isListening: Bool {
        phase == .listening
    }

    var isSpeaking: Bool {
        phase == .speaking && speechOutput.isSpeaking
    }

    var listeningLevel: Double {
        phase == .listening ? speechInput.audioLevel : 0
    }

    var recognitionBackend: SpeechRecognitionBackend {
        speechInput.recognitionBackend
    }

    var responseSegments: [String] {
        speechOutput.segments
    }

    var currentResponseSegmentIndex: Int {
        speechOutput.currentSegmentIndex
    }

    var hasResponse: Bool {
        !responseSegments.isEmpty
    }

    var responseEmotion: OllamaSpeechEmotion {
        responseSpeech.emotion
    }

    var responseEmotionIntensity: Double {
        responseSpeech.intensity
    }

    var isUsingNeuralVoice: Bool {
        speechOutput.isUsingNeuralVoice
    }

    /// Real-audio playback energy (phase E), relayed from `PetSpeechOutput.playbackEnergy` for
    /// `PetFloatingView.petParameters` to fold into `MotionContext.speechEnergy`. `nil` means no
    /// live signal is available right now (nothing playing, or an unsupported playback path), in
    /// which case `CherryConnection` falls back to its legacy sine-wave mouth flap.
    var speechPlaybackEnergy: Double? {
        speechOutput.playbackEnergy
    }

    var canAcceptTextInput: Bool {
        phase != .listening
    }

    var canStopResponseGeneration: Bool {
        phase == .thinking
    }

    func toggle() {
        // One click can reach more than one handler; a toggle this soon after
        // the last would stop listening before it starts.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.35 else { return }
        lastToggle = now
        switch phase {
        case .idle, .failed:
            beginListening()
        case .listening:
            finishListening()
        case .speaking:
            speechOutput.stop()
            beginListening()
        case .thinking:
            stopResponseGeneration()
        }
    }

    func submitText(_ text: String) {
        let typedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typedText.isEmpty, canAcceptTextInput else {
            return
        }

        let previousTask = interactionTask
        previousTask?.cancel()
        speechInput.cancel()
        speechOutput.stop()
        interactionTask = Task {
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            await submitPrompt(typedText, emptyInputMessage: "Type something first.")
        }
    }

    /// Plays the rate-limited evasion line only while otherwise idle. In-progress listening,
    /// generation, approvals, and spoken replies always win and are never interrupted by moving.
    func speakEvasionCue(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .idle, !line.isEmpty else { return }
        responseText = line
        responseSpeech = .fallback
        phase = .speaking
        core.request(.surprised)
        speechOutput.speak(line, speech: .fallback) { [weak self] in
            guard let self else { return }
            self.phase = .idle
            self.core.request(.idle)
        }
    }

    func stopResponseGeneration() {
        interactionTask?.cancel()
        interactionTask = nil
        speechInput.cancel()
        speechOutput.stop()
        phase = .idle
        errorMessage = nil
        generationStatus = ""
        pendingApproval = nil
        core.request(.idle)
    }

    func cancel() {
        interactionTask?.cancel()
        interactionTask = nil
        codex.disconnect()
        claudeCode.disconnect()
        speechInput.cancel()
        speechOutput.stop()
        core.request(.idle)
        phase = .idle
        transcript = ""
        responseText = ""
        errorMessage = nil
        generationStatus = ""
        pendingApproval = nil
    }

    func resolvePendingApproval(approved: Bool) {
        guard let pendingApproval else { return }
        Task {
            do {
                switch pendingApproval {
                case .codex(let request):
                    try await codex.resolveApproval(request, approved: approved)
                case .claudeCode(let request):
                    try await claudeCode.resolveApproval(request, approved: approved)
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func beginListening() {
        interactionTask?.cancel()
        speechOutput.stop()
        let startedAt = Date()
        Self.logger.info("Voice interaction started")
        phase = .listening
        transcript = ""
        responseText = ""
        errorMessage = nil
        generationStatus = ""
        pendingApproval = nil
        core.request(.listening)
        speechOutput.warmUpNeuralVoice()

        listeningStartPending = true
        interactionTask = Task {
            let speechStart = Date()
            await speechInput.start(locale: preferredRecognitionLocale)
            listeningStartPending = false
            Self.logger.info(
                "Speech input start finished in \(Date().timeIntervalSince(speechStart), format: .fixed(precision: 2))s; backend=\(String(describing: self.speechInput.recognitionBackend), privacy: .public)"
            )
            guard !Task.isCancelled else {
                return
            }

            if let inputError = speechInput.errorMessage {
                fail(inputError, isAppMessage: true)
                return
            }

            while phase == .listening,
                  speechInput.state != .idle,
                  speechInput.state != .failed,
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }

            guard !Task.isCancelled, phase == .listening else {
                return
            }

            if let inputError = speechInput.errorMessage {
                fail(inputError, isAppMessage: true)
            } else {
                Self.logger.info(
                    "Speech input finalized in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s; transcriptChars=\(self.speechInput.transcript.count)"
                )
                await submitPrompt(
                    speechInput.transcript,
                    emptyInputMessage: "I couldn't hear that. Click to try again.\n[\(speechInput.diagnostics.code)]"
                )
            }
        }
    }

    private func finishListening() {
        guard phase == .listening else {
            return
        }
        // Until the microphone is running, stopping would only cut the start
        // short and report that nothing was heard.
        guard !listeningStartPending, speechInput.state != .requestingPermission else {
            return
        }

        interactionTask?.cancel()
        interactionTask = Task {
            let stopStart = Date()
            let recognizedText = await speechInput.stop()
            Self.logger.info(
                "Manual speech stop returned in \(Date().timeIntervalSince(stopStart), format: .fixed(precision: 2))s; transcriptChars=\(recognizedText.count)"
            )
            guard !Task.isCancelled else {
                return
            }

            await submitPrompt(
                recognizedText,
                emptyInputMessage: "I couldn't hear that. Click to try again.\n[\(speechInput.diagnostics.code)]"
            )
        }
    }

    private func submitPrompt(_ text: String, emptyInputMessage: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            fail(emptyInputMessage, isAppMessage: true)
            return
        }

        latency.startTurn()
        transcript = prompt
        responseText = ""
        errorMessage = nil
        phase = .thinking
        generationStatus = "Preparing your message..."
        pendingApproval = nil
        core.request(.thinking)
        let submitStartedAt = Date()
        Self.logger.info("Submitting prompt to Castor; chars=\(prompt.count)")

        let preferences = CastorAgentPreferenceStore.current
        activeBrain = preferences.resolvedBrain(for: prompt)
        generationStatus = localGenerationStatus("Preparing your message...")
        let personality = PetPersonalityStore.customPersonality

        switch activeBrain {
        case .onDevice:
            await submitPromptToOllama(prompt, personality: personality, submitStartedAt: submitStartedAt)
        case .codex:
            await submitPromptToCodex(prompt, preferences: preferences, personality: personality, submitStartedAt: submitStartedAt)
        case .claudeCode:
            await submitPromptToClaudeCode(prompt, preferences: preferences, personality: personality, submitStartedAt: submitStartedAt)
        case .antigravity:
            fail(CastorAgentError.providerNotAvailable(activeBrain.label).localizedDescription)
        }
    }

    private func submitPromptToCodex(
        _ prompt: String,
        preferences: CastorAgentPreferences,
        personality: String,
        submitStartedAt: Date
    ) async {
        let reply: String
        do {
            reply = try await codex.send(
                prompt: prompt,
                serverURL: preferences.codexServerURL,
                workspacePath: preferences.workspacePath,
                personalityInstruction: personality,
                onDelta: { [weak self] text in
                    self?.responseText = text
                },
                onStatus: { [weak self] status in
                    self?.generationStatus = status
                },
                onApproval: { [weak self] approval in
                    self?.pendingApproval = approval.map(CastorAgentApprovalRequest.codex)
                }
            )
            responseSpeech = .fallback
            core.request(.idle)
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard !Task.isCancelled else { return }
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else {
            fail("\(activeBrain.label) returned an empty reply.")
            return
        }

        latency.record(.llmComplete)
        speakFullReply(trimmedReply, submitStartedAt: submitStartedAt)
    }

    private func submitPromptToClaudeCode(
        _ prompt: String,
        preferences: CastorAgentPreferences,
        personality: String,
        submitStartedAt: Date
    ) async {
        let reply: String
        do {
            reply = try await claudeCode.send(
                prompt: prompt,
                bridgeURL: preferences.claudeCodeBridgeURL,
                workspacePath: preferences.workspacePath,
                personalityInstruction: personality,
                onDelta: { [weak self] text in
                    self?.responseText = text
                },
                onStatus: { [weak self] status in
                    self?.generationStatus = status
                },
                onApproval: { [weak self] approval in
                    self?.pendingApproval = approval.map(CastorAgentApprovalRequest.claudeCode)
                }
            )
            responseSpeech = .fallback
            core.request(.idle)
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard !Task.isCancelled else { return }
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else {
            fail("Claude Code returned an empty reply.")
            return
        }

        latency.record(.llmComplete)
        speakFullReply(trimmedReply, submitStartedAt: submitStartedAt)
    }

    /// On-device path: tries the pipelined streaming route first (speaks the first sentence as
    /// soon as it is available), and falls back to the original "wait for full reply, then
    /// speak" behavior if streaming fails for any reason (Ollama down, decode error, cancelled
    /// before the first sentence, etc.). This preserves the existing fallback chain inside
    /// `OllamaClient.chat(...)` (schema -> plain -> streaming) for the non-pipelined path; the
    /// pipelined path is an independent, additive route that never partially commits UI state
    /// before falling back.
    private func submitPromptToOllama(_ prompt: String, personality: String, submitStartedAt: Date) async {
        do {
            try await connectOllamaIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription)
            return
        }

        if await submitPromptToOllamaStreaming(prompt, personality: personality, submitStartedAt: submitStartedAt) {
            return
        }

        guard !Task.isCancelled else { return }
        await submitPromptToOllamaNonStreaming(prompt, personality: personality, submitStartedAt: submitStartedAt)
    }

    /// Returns true if the pipelined streaming path took ownership of the turn (whether it
    /// succeeded or failed *after* committing to speaking), i.e. the caller should not also run
    /// the non-streaming fallback. Returns false if streaming failed before anything was spoken,
    /// so the caller can safely retry with the original non-streaming path.
    private func submitPromptToOllamaStreaming(
        _ prompt: String,
        personality: String,
        submitStartedAt: Date
    ) async -> Bool {
        generationStatus = localGenerationStatus("Generating on device...")
        let startedAt = Date()
        var hasSpokenAnySentence = false
        var recordedFirstToken = false

        speechOutput.onPlaybackStarted = { [weak self] in
            self?.latency.record(.playbackStarted)
        }
        speechOutput.onFirstAudioReceived = { [weak self] in
            self?.latency.record(.ttsResponseReceived)
        }

        do {
            try await ollama.sendStreaming(
                prompt,
                to: core,
                personalityInstruction: personality
            ) { [weak self] sentence in
                guard let self else { return }
                if !recordedFirstToken {
                    recordedFirstToken = true
                    latency.record(.llmFirstToken)
                }
                if !hasSpokenAnySentence {
                    hasSpokenAnySentence = true
                    responseText = sentence
                    generationStatus = ""
                    pendingApproval = nil
                    phase = .speaking
                    // No structured motion metadata arrives on this plain-text path, so return
                    // the character to idle while speaking, matching the Codex path's handling.
                    core.request(.idle)
                    latency.record(.ttsRequestStarted)
                    speechOutput.beginStreaming(speech: .fallback) { [weak self] in
                        self?.finishSpeaking(submitStartedAt: submitStartedAt)
                    }
                } else {
                    responseText += " " + sentence
                }
                speechOutput.appendStreamedSentence(sentence)
            }
        } catch is CancellationError {
            if hasSpokenAnySentence {
                speechOutput.stop()
                return true
            }
            // Distinguish a real turn cancellation (user stopped/replaced the turn: own the turn
            // and do nothing) from a guard rejection inside `sendStreaming` (e.g. a lingering
            // `isLoading` race) that surfaces as `CancellationError` without the task actually
            // being cancelled — the latter must fall through to the non-streaming path so the
            // turn doesn't stall in `.thinking`.
            return Task.isCancelled
        } catch {
            Self.logger.notice(
                "Ollama streaming pipeline failed; falling back to non-streaming path. hasSpoken=\(hasSpokenAnySentence) error=\(error.localizedDescription, privacy: .public)"
            )
            if hasSpokenAnySentence {
                // We already started speaking part of a reply; committing to a full restart via
                // the non-streaming path would be a confusing user-facing regression, so treat
                // this as a normal end-of-speech instead of retrying.
                speechOutput.finishStreaming()
                return true
            }
            return false
        }

        Self.logger.info(
            "Ollama streaming chat finished in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s; spoke=\(hasSpokenAnySentence)"
        )

        guard hasSpokenAnySentence else {
            // The model produced no usable sentence at all (e.g. empty reply); let the caller
            // fall back to the non-streaming path, which has its own empty-reply handling.
            return false
        }

        latency.record(.llmComplete)
        responseSpeech = ollama.responseSpeech
        speechOutput.finishStreaming()
        return true
    }

    private func submitPromptToOllamaNonStreaming(
        _ prompt: String,
        personality: String,
        submitStartedAt: Date
    ) async {
        let reply: String
        do {
            reply = try await sendToOllama(prompt, personality: personality)
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard !Task.isCancelled else { return }
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty else {
            fail("\(activeBrain.label) returned an empty reply.")
            return
        }

        latency.record(.llmComplete)
        speakFullReply(trimmedReply, submitStartedAt: submitStartedAt)
    }

    private func speakFullReply(_ trimmedReply: String, submitStartedAt: Date) {
        responseText = trimmedReply
        generationStatus = ""
        pendingApproval = nil
        phase = .speaking
        speechOutput.onPlaybackStarted = { [weak self] in
            self?.latency.record(.playbackStarted)
        }
        speechOutput.onFirstAudioReceived = { [weak self] in
            self?.latency.record(.ttsResponseReceived)
        }
        latency.record(.ttsRequestStarted)
        speechOutput.speak(trimmedReply, speech: responseSpeech) { [weak self] in
            self?.finishSpeaking(submitStartedAt: submitStartedAt)
        }
    }

    private func finishSpeaking(submitStartedAt: Date) {
        let report = latency.finishAndLog()
        Self.logger.info(
            "Castor response completed in \(Date().timeIntervalSince(submitStartedAt), format: .fixed(precision: 2))s; ttfa=\((report.timeToFirstAudio ?? -1), format: .fixed(precision: 2))s"
        )
        phase = .idle
        core.request(.idle)
    }

    private func connectOllamaIfNeeded() async throws {
        if ollama.connectionState != .connected || ollama.selectedModel == nil {
            generationStatus = localGenerationStatus("Connecting to local AI...")
            let connectStartedAt = Date()
            await ollama.connect()
            Self.logger.info(
                "Local AI connect finished in \(Date().timeIntervalSince(connectStartedAt), format: .fixed(precision: 2))s; provider=\(self.ollama.activeProvider?.label ?? "none", privacy: .public)"
            )
        }
        try Task.checkCancellation()

        guard ollama.selectedModel != nil else {
            throw CastorAgentError.providerFailure(
                ollama.errorMessage ?? "Start LM Studio or Ollama and install a conversational model first."
            )
        }
    }

    private func sendToOllama(_ prompt: String, personality: String) async throws -> String {
        try await connectOllamaIfNeeded()

        generationStatus = localGenerationStatus("Generating on device...")
        let startedAt = Date()
        await ollama.send(
            prompt,
            to: core,
            personalityInstruction: personality
        )
        try Task.checkCancellation()
        Self.logger.info(
            "Local AI chat finished in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s; provider=\(self.ollama.activeProvider?.label ?? "none", privacy: .public)"
        )

        if let ollamaError = ollama.errorMessage {
            throw CastorAgentError.providerFailure(ollamaError)
        }
        responseSpeech = ollama.responseSpeech
        return ollama.responseText
    }

    private var onDeviceOperationNotice: String? {
        guard activeBrain == .onDevice,
              CastorAgentPreferences.promptNeedsExternalAgent(transcript) else { return nil }
        return "On-device mode can only chat. Request actions with Codex / Claude Code."
    }

    private func localGenerationStatus(_ status: String) -> String {
        guard let onDeviceOperationNotice else { return status }
        return "\(status)\n\(onDeviceOperationNotice)"
    }

    private func fail(_ message: String, isAppMessage: Bool = false) {
        errorIsAppMessage = isAppMessage
        speechInput.cancel()
        speechOutput.stop()
        errorMessage = message
        generationStatus = ""
        pendingApproval = nil
        phase = .failed
        core.request(.idle)
    }

    private var preferredRecognitionLocale: Locale {
        let selected = UserDefaults.standard.string(forKey: "Castor.Input.SpeechLanguage") ?? "auto"
        if ["ja-JP", "en-US"].contains(selected) { return Locale(identifier: selected) }
        let preferredLanguage = Locale.preferredLanguages.first ?? Locale.current.identifier
        return Locale(identifier: preferredLanguage)
    }
}

private enum CastorAgentError: LocalizedError {
    case providerNotAvailable(String)
    case providerFailure(String)

    var errorDescription: String? {
        switch self {
        case .providerNotAvailable(let provider):
            "\(provider) support is prepared but not connected yet. Choose On-device, Codex, or Claude Code."
        case .providerFailure(let message):
            message
        }
    }
}
