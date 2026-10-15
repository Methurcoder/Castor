import AVFoundation
import Foundation
import NaturalLanguage
import Observation
import os
import CastorCore

struct PetSpeechLanguageContext {
    private(set) var detectedLanguage: NLLanguage?
    private(set) var systemVoiceLanguage = "en-US"
    private var sample = ""

    var neuralLanguageCode: String {
        NeuralSpeechClient.languageCode(for: detectedLanguage)
    }

    mutating func reset() {
        self = PetSpeechLanguageContext()
    }

    mutating func observe(_ text: String) {
        guard detectedLanguage == nil else {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        sample += sample.isEmpty ? trimmed : " \(trimmed)"
        detectedLanguage = NeuralSpeechClient.dominantLanguage(for: sample)
        systemVoiceLanguage = PetSpeechOutput.voiceLanguage(for: sample)
    }
}

@MainActor
@Observable
final class PetSpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private static let logger = Logger(subsystem: "dev.pomegranate.prototype", category: "PetSpeech")

    private(set) var segments: [String] = []
    private(set) var currentSegmentIndex = 0
    private(set) var isSpeaking = false
    private(set) var isUsingNeuralVoice = false

    private let synthesizer = AVSpeechSynthesizer()
    private let neuralClient: NeuralSpeechClient
    private let voiceProfile: PetVoiceProfile
    private var completion: (() -> Void)?
    private var activeUtterance: AVSpeechUtterance?
    private var audioPlayer: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    private var prefetchedAudio: (index: Int, task: Task<Data, Error>)?
    private var speechMetadata = OllamaSpeechMetadata.fallback
    private var shouldUseNeuralVoice = true
    private var languageContext = PetSpeechLanguageContext()

    // MARK: - Phase E: real-audio-driven playback energy

    /// Smoothed 0...1 envelope for whichever playback path is currently active. Read every frame
    /// by `playbackEnergy` (which also drives metering) rather than pushed on a timer, so it stays
    /// cheap when nothing is reading it (e.g. the pet window is occluded).
    /// `@ObservationIgnored`: the `playbackEnergy` getter advances these while it is being read
    /// from a SwiftUI view body (the pet's `TimelineView` samples it every frame). If Observation
    /// tracked them, that read-plus-mutate would invalidate the very view evaluation reading it —
    /// an "Observable mutated during view update" feedback loop. They are pull-driven sampling
    /// state, not UI state, so nothing needs to observe them.
    @ObservationIgnored private var speechEnergyEnvelope = SpeechEnergyEnvelope()
    @ObservationIgnored private var lastEnergySampleAt: Date?
    /// Deterministic pseudo-energy driver for the `AVSpeechSynthesizer` fallback path, built from
    /// `willSpeakRangeOfSpeechString` word-boundary events (no metering API exists for system
    /// speech). `nil` whenever system voice is not actively speaking a range.
    @ObservationIgnored private var systemVoiceEnergyPulse: (startedAt: Date, duration: TimeInterval)?

    /// Real playback energy for the mouth-flap (phase E), normalized to 0...1 and smoothed with
    /// asymmetric attack/release via `SpeechEnergyEnvelope`. `nil` when nothing is currently
    /// playing (silence) so callers can fall back to the legacy sine-wave flap; this is
    /// intentionally distinct from returning `0`, which would mean "playing but silent right now".
    /// Safe to read every frame from a `TimelineView`: `AVAudioPlayer.updateMeters()` is cheap and
    /// this method is the only place that calls it, so repeated reads in the same frame are fine.
    var playbackEnergy: Double? {
        let now = Date()
        let deltaTime = lastEnergySampleAt.map { now.timeIntervalSince($0) } ?? (1.0 / 30.0)
        lastEnergySampleAt = now

        guard isSpeaking else {
            speechEnergyEnvelope = SpeechEnergyEnvelope()
            return nil
        }

        let rawLevel = currentRawPlaybackLevel(at: now)
        guard let rawLevel else {
            return nil
        }

        speechEnergyEnvelope = speechEnergyEnvelope.stepping(toward: rawLevel, deltaTime: deltaTime)
        return speechEnergyEnvelope.value
    }

    /// Raw (unsmoothed) 0...1 level for whichever playback path is active right now, or `nil` if
    /// there is no usable signal (e.g. system voice with no active word-boundary pulse yet).
    private func currentRawPlaybackLevel(at date: Date) -> Double? {
        if let audioPlayer {
            audioPlayer.isMeteringEnabled = true
            audioPlayer.updateMeters()
            let decibels = audioPlayer.averagePower(forChannel: 0)
            return SpeechEnergyEnvelope.normalizedLevel(fromDecibels: decibels)
        }

        guard let systemVoiceEnergyPulse else {
            return nil
        }
        return Self.systemVoicePseudoEnergy(
            elapsed: date.timeIntervalSince(systemVoiceEnergyPulse.startedAt),
            pulseDuration: systemVoiceEnergyPulse.duration
        )
    }

    /// Deterministic decaying pulse used as a stand-in "energy" for each word boundary reported by
    /// `AVSpeechSynthesizer`'s `willSpeakRangeOfSpeechString` delegate callback (there is no
    /// metering API for system speech). Peaks just after the word starts and decays back toward a
    /// low idle level over `pulseDuration`, so consecutive word-boundary events read as a wobbling
    /// envelope rather than a constant flat value.
    static func systemVoicePseudoEnergy(elapsed: TimeInterval, pulseDuration: TimeInterval) -> Double {
        guard pulseDuration > 0 else {
            return 0
        }
        let progress = max(0, min(1, elapsed / pulseDuration))
        // Fast rise then decay, similar in shape to a percussive envelope: peaks around 15% of the
        // pulse then eases back down.
        let rise = min(1, progress / 0.15)
        let decay = 1 - max(0, (progress - 0.15) / 0.85)
        return 0.35 + 0.65 * rise * decay
    }

    /// True while a `beginStreaming(...)` turn is still receiving sentences (LLM generation not
    /// finished yet). While true, running out of buffered segments waits for more instead of
    /// treating the reply as complete.
    private var isStreamingReply = false
    private var isStreamFinished = true
    private var streamWaitTask: Task<Void, Never>?

    /// Fired exactly once per `speak(...)`/`beginStreaming(...)` turn, right before the first
    /// segment's audio actually starts playing (neural WAV playback or system-voice utterance
    /// start). Used by `PetVoiceConversation` to record the `playbackStarted` TTFA mark without
    /// this file needing to know anything about `VoiceLatencyTracker`.
    var onPlaybackStarted: (() -> Void)?
    private var hasReportedPlaybackStarted = false

    /// Fired exactly once per turn, right after the first segment's neural TTS audio bytes are
    /// received from the local server (before playback actually starts). For system-voice
    /// fallback there is no separate network round trip, so this fires immediately before
    /// playback starts. Used for the `ttsResponseReceived` TTFA mark.
    var onFirstAudioReceived: (() -> Void)?
    private var hasReportedFirstAudioReceived = false

    init(
        voiceProfile: PetVoiceProfile = .defaultProfile,
        neuralClient: NeuralSpeechClient = NeuralSpeechClient()
    ) {
        self.voiceProfile = voiceProfile
        self.neuralClient = neuralClient
        super.init()
        synthesizer.delegate = self
    }

    /// Compatibility call site only. Model loading waits for the Voice Load action;
    /// opening settings or starting a conversation never prepares a model.
    func warmUpNeuralVoice() {
        neuralClient.warmUp()
    }

    func speak(
        _ text: String,
        speech: OllamaSpeechMetadata = .fallback,
        completion: @escaping () -> Void
    ) {
        stop()

        segments = PetSpeechSegmenter.spokenReplySegments(from: text, isFirstSpokenText: true)
        Self.logger.info("Speak requested; chars=\(text.count) segments=\(self.segments.count)")
        guard !segments.isEmpty else {
            completion()
            return
        }

        self.completion = completion
        speechMetadata = speech
        languageContext.reset()
        languageContext.observe(text)
        currentSegmentIndex = 0
        isSpeaking = true
        shouldUseNeuralVoice = Self.shouldAttemptNeuralVoice(engine: NeuralVoiceEngineStore.selected)
        isStreamingReply = false
        isStreamFinished = true
        hasReportedPlaybackStarted = false
        hasReportedFirstAudioReceived = false
        speakCurrentSegment()
    }

    /// Starts a pipelined turn: playback begins as soon as `appendStreamedSentence(...)` supplies
    /// the first sentence, instead of waiting for the whole reply. Callers must eventually call
    /// `finishStreaming()` (success) so buffering knows no more sentences are coming; on failure,
    /// callers should call `stop()` instead. If the LLM stream fails before any sentence arrives,
    /// nothing has started speaking yet, so the existing `speak(...)` fallback can run normally.
    func beginStreaming(
        speech: OllamaSpeechMetadata = .fallback,
        completion: @escaping () -> Void
    ) {
        stop()
        self.completion = completion
        speechMetadata = speech
        languageContext.reset()
        currentSegmentIndex = 0
        segments = []
        isStreamingReply = true
        isStreamFinished = false
        shouldUseNeuralVoice = Self.shouldAttemptNeuralVoice(engine: NeuralVoiceEngineStore.selected)
        hasReportedPlaybackStarted = false
        hasReportedFirstAudioReceived = false
    }

    /// Appends a sentence produced mid-stream. The sentence is re-split with the same tuning as
    /// `speak(...)` (short natural phrases; the very first spoken text additionally shrunk to its
    /// earliest pause) so TTS request sizes and reader granularity match the full-reply path. If
    /// nothing is currently speaking, playback starts immediately; otherwise the new segments are
    /// queued and picked up once earlier ones finish. No-op if `beginStreaming(...)` was not
    /// called or the stream was already stopped/finished.
    func appendStreamedSentence(_ sentence: String) {
        guard isStreamingReply else {
            return
        }

        let wasEmpty = segments.isEmpty
        languageContext.observe(sentence)
        let newSegments = PetSpeechSegmenter.spokenReplySegments(
            from: sentence,
            isFirstSpokenText: wasEmpty
        )
        guard !newSegments.isEmpty else {
            return
        }

        let wasWaitingForThisSegment = streamWaitTask != nil && segments.count == currentSegmentIndex
        segments.append(contentsOf: newSegments)
        Self.logger.info(
            "Streamed sentence appended; chars=\(sentence.count) newSegments=\(newSegments.count) totalSegments=\(self.segments.count)"
        )

        if wasEmpty || wasWaitingForThisSegment {
            streamWaitTask?.cancel()
            streamWaitTask = nil
            isSpeaking = true
            speakCurrentSegment()
        }
    }

    /// Marks the streamed reply as complete. If segments are still queued or playing, playback
    /// continues normally and finishes once the last one is done; if nothing was ever appended
    /// (e.g. the model produced no usable sentence), the completion handler fires immediately.
    func finishStreaming() {
        guard isStreamingReply else {
            return
        }
        isStreamFinished = true
        isStreamingReply = false

        if segments.isEmpty {
            streamWaitTask?.cancel()
            streamWaitTask = nil
            finishAllSegments()
        } else if !isSpeaking, !segments.indices.contains(currentSegmentIndex) {
            streamWaitTask?.cancel()
            streamWaitTask = nil
            finishAllSegments()
        }
    }

    func stop() {
        streamWaitTask?.cancel()
        streamWaitTask = nil
        isStreamingReply = false
        isStreamFinished = true
        synthesisTask?.cancel()
        synthesisTask = nil
        prefetchedAudio?.task.cancel()
        prefetchedAudio = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeUtterance = nil
        completion = nil
        isSpeaking = false
        isUsingNeuralVoice = false
        segments = []
        currentSegmentIndex = 0
        languageContext.reset()
        systemVoiceEnergyPulse = nil
        speechEnergyEnvelope = SpeechEnergyEnvelope()
        lastEnergySampleAt = nil

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NSURLErrorDomain
            && cocoaError.code == NSURLErrorCancelled
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, utteranceID == activeUtteranceID else {
                return
            }
            isSpeaking = true
            reportPlaybackStartedIfNeeded()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finish(utteranceID)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, utteranceID == activeUtteranceID else {
                return
            }
            resetPlaybackState()
        }
    }

    /// System-voice fallback path for phase E: `AVSpeechSynthesizer` exposes no audio metering
    /// API, so each word-boundary event starts a short deterministic decaying pulse
    /// (`systemVoicePseudoEnergy`) that `currentRawPlaybackLevel(at:)` reads while it's live. This
    /// keeps the mouth wobbling roughly in time with word boundaries instead of holding a static
    /// shape or falling back to a silent mouth for the entire system-voice segment.
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        let wordLength = max(1, characterRange.length)
        Task { @MainActor [weak self] in
            guard let self, utteranceID == activeUtteranceID else {
                return
            }
            // Longer words get a slightly longer pulse so the envelope roughly tracks how long
            // that word takes to speak, without needing real timing information.
            let pulseDuration = min(0.6, 0.16 + Double(wordLength) * 0.02)
            systemVoiceEnergyPulse = (startedAt: Date(), duration: pulseDuration)
        }
    }

    private func speakCurrentSegment() {
        guard segments.indices.contains(currentSegmentIndex) else {
            finishAllSegments()
            return
        }

        let segment = segments[currentSegmentIndex]
        guard shouldUseNeuralVoice else {
            Self.logger.info("Using system voice for segment \(self.currentSegmentIndex + 1)/\(self.segments.count); chars=\(segment.count)")
            speakWithSystemVoice(segment)
            return
        }

        synthesisTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let startedAt = Date()
                let audioData: Data
                if let prefetchedAudio, prefetchedAudio.index == currentSegmentIndex {
                    self.prefetchedAudio = nil
                    audioData = try await prefetchedAudio.task.value
                } else {
                    audioData = try await neuralClient.audio(
                        for: segment,
                        profile: voiceProfile,
                        speech: speechMetadata,
                        languageCode: languageContext.neuralLanguageCode
                    )
                }
                try Task.checkCancellation()
                Self.logger.info(
                    "Neural voice segment ready in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 2))s; segment=\(self.currentSegmentIndex + 1)/\(self.segments.count) chars=\(segment.count)"
                )
                reportFirstAudioReceivedIfNeeded()
                let player = try AVAudioPlayer(data: audioData)
                player.delegate = self
                player.isMeteringEnabled = true
                audioPlayer = player
                isUsingNeuralVoice = true
                systemVoiceEnergyPulse = nil
                player.prepareToPlay()
                guard player.play() else {
                    throw NeuralSpeechError.invalidResponse
                }
                reportPlaybackStartedIfNeeded()
                prefetchNextSegment()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, !Self.isCancellationError(error) else {
                    return
                }
                Self.logger.notice(
                    "Neural voice unavailable; falling back to system voice. segment=\(self.currentSegmentIndex + 1)/\(self.segments.count) error=\(error.localizedDescription, privacy: .public)"
                )
                prefetchedAudio?.task.cancel()
                prefetchedAudio = nil
                shouldUseNeuralVoice = false
                isUsingNeuralVoice = false
                speakWithSystemVoice(segment)
            }
        }
    }

    private func speakWithSystemVoice(_ segment: String) {
        reportFirstAudioReceivedIfNeeded()
        audioPlayer = nil
        systemVoiceEnergyPulse = nil
        let utterance = AVSpeechUtterance(string: segment)
        utterance.voice = AVSpeechSynthesisVoice(language: languageContext.systemVoiceLanguage)
        utterance.rate = systemRate
        utterance.pitchMultiplier = systemPitch
        utterance.volume = 0.92

        activeUtterance = utterance
        synthesizer.speak(utterance)
    }

    private var activeUtteranceID: ObjectIdentifier? {
        activeUtterance.map(ObjectIdentifier.init)
    }

    private func finish(_ utteranceID: ObjectIdentifier) {
        guard utteranceID == activeUtteranceID else {
            return
        }

        activeUtterance = nil
        advanceToNextSegment()
    }

    private func advanceToNextSegment() {
        let nextIndex = currentSegmentIndex + 1
        if segments.indices.contains(nextIndex) {
            currentSegmentIndex = nextIndex
            speakCurrentSegment()
            return
        }

        guard isStreamingReply, !isStreamFinished else {
            finishAllSegments()
            return
        }

        // The stream is still generating and hasn't produced the next sentence yet: wait briefly
        // rather than declaring the reply finished. `appendStreamedSentence` cancels this task
        // and resumes playback once a new sentence arrives; `finishStreaming` lets it expire.
        currentSegmentIndex = nextIndex
        isSpeaking = false
        streamWaitTask?.cancel()
        streamWaitTask = Task { [weak self] in
            guard let self else {
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                if Task.isCancelled {
                    return
                }
                if segments.indices.contains(nextIndex) {
                    isSpeaking = true
                    speakCurrentSegment()
                    return
                }
                if isStreamFinished {
                    finishAllSegments()
                    return
                }
            }
        }
    }

    private func reportPlaybackStartedIfNeeded() {
        guard !hasReportedPlaybackStarted else {
            return
        }
        hasReportedPlaybackStarted = true
        onPlaybackStarted?()
    }

    private func reportFirstAudioReceivedIfNeeded() {
        guard !hasReportedFirstAudioReceived else {
            return
        }
        hasReportedFirstAudioReceived = true
        onFirstAudioReceived?()
    }

    private func finishAllSegments() {
        synthesisTask = nil
        prefetchedAudio?.task.cancel()
        prefetchedAudio = nil
        audioPlayer = nil
        activeUtterance = nil
        isSpeaking = false
        isUsingNeuralVoice = false
        isStreamingReply = false
        isStreamFinished = true
        systemVoiceEnergyPulse = nil
        speechEnergyEnvelope = SpeechEnergyEnvelope()
        lastEnergySampleAt = nil
        let completion = completion
        self.completion = nil
        completion?()
    }

    private func resetPlaybackState() {
        synthesisTask?.cancel()
        synthesisTask = nil
        prefetchedAudio?.task.cancel()
        prefetchedAudio = nil
        audioPlayer?.stop()
        audioPlayer = nil
        activeUtterance = nil
        completion = nil
        isSpeaking = false
        isUsingNeuralVoice = false
        isStreamingReply = false
        isStreamFinished = true
        segments = []
        currentSegmentIndex = 0
        systemVoiceEnergyPulse = nil
        speechEnergyEnvelope = SpeechEnergyEnvelope()
        lastEnergySampleAt = nil
    }

    private var systemRate: Float {
        let baseRate = 0.47 * speechMetadata.speakingRate * voiceProfile.speakingRateMultiplier
        return Float(min(max(baseRate, 0.35), 0.62))
    }

    private func prefetchNextSegment() {
        let nextIndex = currentSegmentIndex + 1
        guard shouldUseNeuralVoice, segments.indices.contains(nextIndex) else {
            prefetchedAudio = nil
            return
        }

        let nextSegment = segments[nextIndex]
        let client = neuralClient
        let profile = voiceProfile
        let speech = speechMetadata
        prefetchedAudio = (
            nextIndex,
            Task {
                try await client.audio(
                    for: nextSegment,
                    profile: profile,
                    speech: speech,
                    languageCode: languageContext.neuralLanguageCode
                )
            }
        )
    }

    private var systemPitch: Float {
        let offset: Double
        switch speechMetadata.emotion {
        case .happy, .surprised:
            offset = 0.08 * speechMetadata.intensity
        case .sad, .thoughtful:
            offset = -0.05 * speechMetadata.intensity
        case .angry:
            offset = -0.02
        case .embarrassed:
            offset = 0.04
        case .neutral:
            offset = 0
        }
        return Float(min(max(1.03 + offset, 0.85), 1.25))
    }

    /// Picks the `AVSpeechSynthesisVoice` BCP-47 locale for system-voice fallback. Now that
    /// `.system` can be selected for any language (not just English), this uses
    /// `NLLanguageRecognizer` (shared with `NeuralSpeechClient.languageCode(for:)` via
    /// `NeuralSpeechClient.dominantLanguage(for:)`) instead of a Japanese/English-only heuristic.
    /// Ambiguous Han text keeps the legacy "ja-JP" fallback; other unavailable or unsupported
    /// detections fall back to "en-US".
    static func shouldAttemptNeuralVoice(engine: NeuralVoiceEngine) -> Bool {
        NeuralSpeechClient.modelName(engine: engine) != nil
    }

    static func voiceLanguage(for text: String) -> String {
        guard let language = NeuralSpeechClient.dominantLanguage(for: text) else {
            // Preserve the old Japanese fallback for ambiguous Han-only fragments instead of
            // selecting a Chinese voice from an untrusted short-text guess.
            return NeuralSpeechClient.containsHanCharacters(text) ? "ja-JP" : "en-US"
        }

        switch language {
        case .japanese:
            return "ja-JP"
        case .english:
            return "en-US"
        case .simplifiedChinese:
            return "zh-CN"
        case .traditionalChinese:
            return "zh-TW"
        case .korean:
            return "ko-KR"
        case .french:
            return "fr-FR"
        case .german:
            return "de-DE"
        case .spanish:
            return "es-ES"
        default:
            return "en-US"
        }
    }
}

extension PetSpeechOutput: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === audioPlayer else {
                return
            }
            audioPlayer = nil
            advanceToNextSegment()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, player === audioPlayer else {
                return
            }
            audioPlayer = nil
            shouldUseNeuralVoice = false
            guard segments.indices.contains(currentSegmentIndex) else {
                finishAllSegments()
                return
            }
            speakWithSystemVoice(segments[currentSegmentIndex])
        }
    }
}
