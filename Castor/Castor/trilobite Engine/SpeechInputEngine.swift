@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech
import CastorCore

@MainActor
@Observable
final class SpeechInputEngine {
    private(set) var state: SpeechInputState = .idle
    private(set) var transcript = ""
    private(set) var audioLevel = 0.0
    private(set) var errorMessage: String?
    private(set) var microphoneAuthorization: SpeechInputAuthorization = .notDetermined
    private(set) var speechAuthorization: SpeechInputAuthorization = .notDetermined
    private(set) var recognitionBackend: SpeechRecognitionBackend = .dictationTranscriber
    private(set) var activeMicrophoneName = ""

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var speechRecognizer: SFSpeechRecognizer?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var speechAnalyzer: SpeechAnalyzer?
    @ObservationIgnored private var dictationTranscriber: DictationTranscriber?
    @ObservationIgnored private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var analyzerTask: Task<Void, Never>?
    @ObservationIgnored private var transcriberResultTask: Task<Void, Never>?
    @ObservationIgnored private var audioConverter: AVAudioConverter?
    @ObservationIgnored private var analyzerAudioFormat: AVAudioFormat?
    @ObservationIgnored private var finalResultTimeout: Task<Void, Never>?
    @ObservationIgnored private var activeSessionID: UUID?
    @ObservationIgnored private var activeRecognitionID: UUID?
    @ObservationIgnored private var activeLocale = Locale.current
    @ObservationIgnored private var finalizationRequested = false
    @ObservationIgnored private var unexpectedRestartCount = 0
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var captureAnnouncementActive = false
    @ObservationIgnored private var smoothedAudioLevel = 0.0
    @ObservationIgnored private var silenceDetector = SpeechSilenceDetector()
    @ObservationIgnored private var transcriptAccumulator = SpeechTranscriptAccumulator()
    @ObservationIgnored private var progressiveTranscript = ProgressiveSpeechTranscript()

    init() {
        refreshAuthorizationState()
    }

    func start(locale: Locale = .current) async {
        cancel()
        transcript = ""
        transcriptAccumulator.reset()
        progressiveTranscript.reset()
        errorMessage = nil
        state = .requestingPermission

        let sessionID = UUID()
        activeSessionID = sessionID
        activeLocale = locale
        finalizationRequested = false
        unexpectedRestartCount = 0

        guard hasSpeechUsageDescription else {
            fail(
                "Speech recognition needs NSSpeechRecognitionUsageDescription in the app Info.plist.",
                sessionID: sessionID
            )
            return
        }

        let microphoneGranted = await requestMicrophoneAuthorization()
        guard activeSessionID == sessionID else {
            return
        }
        guard microphoneGranted else {
            fail("Microphone access was denied.", sessionID: sessionID)
            return
        }

        let speechGranted = await requestSpeechAuthorization()
        guard activeSessionID == sessionID else {
            return
        }
        guard speechGranted else {
            fail("Speech recognition access was denied.", sessionID: sessionID)
            return
        }

        activeMicrophoneName = AudioInputDeviceStore.availableDevices()
            .first(where: { $0.id == AudioInputDeviceStore.selectedDeviceUID })?.name
            ?? "System default"
        announceCaptureStarted()
        try? await Task.sleep(for: .milliseconds(250))
        guard activeSessionID == sessionID, !Task.isCancelled else {
            return
        }

        if await beginModernRecognition(locale: locale, sessionID: sessionID) {
            recognitionBackend = .dictationTranscriber
        } else {
            try? await Task.sleep(for: .milliseconds(220))
            guard activeSessionID == sessionID, !Task.isCancelled else {
                return
            }
            recognitionBackend = .legacySpeechRecognizer
            beginLegacyRecognition(locale: locale, sessionID: sessionID)
        }
    }

    func stop() async -> String {
        guard let sessionID = activeSessionID else {
            cleanupAudioCapture()
            if state != .failed {
                state = .idle
            }
            return transcript
        }

        requestFinalization(sessionID: sessionID)
        while activeSessionID == sessionID && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return transcript
    }

    func cancel() {
        guard let sessionID = activeSessionID else {
            cleanupAudioCapture()
            state = .idle
            errorMessage = nil
            return
        }

        finishSession(sessionID: sessionID, cancelRecognition: true)
        errorMessage = nil
    }

    private func requestFinalization(sessionID: UUID) {
        guard activeSessionID == sessionID else {
            return
        }

        finalizationRequested = true
        switch state {
        case .requestingPermission:
            finishSession(sessionID: sessionID, cancelRecognition: true)
        case .listening, .transcribing:
            state = .transcribing
            if recognitionBackend == .dictationTranscriber {
                analyzerInputContinuation?.finish()
                analyzerInputContinuation = nil
                finalizeModernRecognition(sessionID: sessionID)
            } else {
                recognitionRequest?.endAudio()
            }
            cleanupAudioCapture()
            scheduleFinalResultTimeout(sessionID: sessionID)
        case .idle, .failed:
            finishSession(sessionID: sessionID, cancelRecognition: true)
        }
    }

    func refreshAuthorizationState() {
        microphoneAuthorization = Self.microphoneAuthorization(
            from: AVCaptureDevice.authorizationStatus(for: .audio)
        )
        speechAuthorization = Self.speechAuthorization(
            from: SFSpeechRecognizer.authorizationStatus()
        )
    }

    private var hasSpeechUsageDescription: Bool {
        guard let description = Bundle.main.object(
            forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription"
        ) as? String else {
            return false
        }
        return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            refreshAuthorizationState()
            return granted
        }

        refreshAuthorizationState()
        return status == .authorized
    }

    private func requestSpeechAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let requestedStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            refreshAuthorizationState()
            return requestedStatus == .authorized
        }

        refreshAuthorizationState()
        return status == .authorized
    }

    private func beginLegacyRecognition(locale: Locale, sessionID: UUID) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            fail("Speech recognition is unavailable for \(locale.identifier).", sessionID: sessionID)
            return
        }
        guard recognizer.isAvailable else {
            fail("Speech recognition is currently unavailable.", sessionID: sessionID)
            return
        }
        let engine = AVAudioEngine()

        do {
            try AudioInputDeviceStore.applySelectedDevice(to: engine)
        } catch {
            fail("Could not select \(activeMicrophoneName): \(error.localizedDescription)", sessionID: sessionID)
            return
        }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No usable microphone input format is available.", sessionID: sessionID)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        let recognitionID = UUID()
        speechRecognizer = recognizer
        recognitionRequest = request
        activeRecognitionID = recognitionID
        audioEngine = engine

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription

            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(
                    text: text,
                    isFinal: isFinal,
                    errorDescription: errorDescription,
                    sessionID: sessionID,
                    recognitionID: recognitionID
                )
            }
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            let level = Self.audioLevel(from: buffer)

            Task { @MainActor [weak self] in
                self?.handleAudioLevel(
                    level,
                    sessionID: sessionID,
                    recognitionID: recognitionID
                )
            }
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
            state = .listening
        } catch {
            fail("Could not start microphone input: \(error.localizedDescription)", sessionID: sessionID)
        }
    }

    private func beginModernRecognition(locale: Locale, sessionID: UUID) async -> Bool {
        guard let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            return false
        }

        let transcriber = DictationTranscriber(
            locale: supportedLocale,
            contentHints: [.shortForm, .farField],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.transcriptionConfidence]
        )

        do {
            let modules: [any SpeechModule] = [transcriber]
            let status = await AssetInventory.status(forModules: modules)
            if status != .installed,
               let installationRequest = try await AssetInventory.assetInstallationRequest(
                   supporting: modules
               ) {
                try await installationRequest.downloadAndInstall()
            }

            let engine = AVAudioEngine()
            try AudioInputDeviceStore.applySelectedDevice(to: engine)
            let inputNode = engine.inputNode
            let naturalFormat = inputNode.inputFormat(forBus: 0)
            guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
                return false
            }

            guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            ) else {
                return false
            }

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: SpeechAnalyzer.Options(
                    priority: .userInitiated,
                    modelRetention: .lingering
                )
            )
            try await analyzer.prepareToAnalyze(in: targetFormat)

            let streamPair = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .bufferingNewest(12)
            )
            analyzerInputContinuation = streamPair.continuation
            speechAnalyzer = analyzer
            dictationTranscriber = transcriber
            analyzerAudioFormat = targetFormat
            let converter = naturalFormat != targetFormat
                ? AVAudioConverter(from: naturalFormat, to: targetFormat)
                : nil
            audioConverter = converter

            let recognitionID = UUID()
            activeRecognitionID = recognitionID
            audioEngine = engine
            transcriberResultTask = Task { [weak self, transcriber] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else {
                            return
                        }
                        let text = String(result.text.characters)
                        self?.handleModernRecognitionResult(
                            text: text,
                            isFinal: result.isFinal,
                            sessionID: sessionID,
                            recognitionID: recognitionID
                        )
                    }
                } catch {
                    self?.handleModernRecognitionError(
                        error,
                        sessionID: sessionID,
                        recognitionID: recognitionID
                    )
                }
            }

            analyzerTask = Task { [weak self, analyzer, stream = streamPair.stream] in
                do {
                    try await analyzer.start(inputSequence: stream)
                } catch {
                    self?.handleModernRecognitionError(
                        error,
                        sessionID: sessionID,
                        recognitionID: recognitionID
                    )
                }
            }

            installModernAudioTap(
                inputNode: inputNode,
                naturalFormat: naturalFormat,
                targetFormat: targetFormat,
                converter: converter,
                continuation: streamPair.continuation,
                sessionID: sessionID,
                recognitionID: recognitionID
            )

            engine.prepare()
            try engine.start()
            state = .listening
            return true
        } catch {
            activeRecognitionID = nil
            cleanupModernRecognition()
            cleanupAudioCapture()
            return false
        }
    }

    private func installModernAudioTap(
        inputNode: AVAudioInputNode,
        naturalFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        sessionID: UUID,
        recognitionID: UUID
    ) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: naturalFormat
        ) { [weak self] buffer, _ in
            guard let self else {
                return
            }

            let analyzerBuffer: AVAudioPCMBuffer?
            if naturalFormat == targetFormat {
                analyzerBuffer = Self.copy(buffer)
            } else {
                analyzerBuffer = Self.convert(
                    buffer,
                    to: targetFormat,
                    using: converter
                )
            }

            if let analyzerBuffer {
                continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
            }
            let level = Self.audioLevel(from: buffer)
            Task { @MainActor [weak self] in
                self?.handleAudioLevel(
                    level,
                    sessionID: sessionID,
                    recognitionID: recognitionID
                )
            }
        }
        tapInstalled = true
    }

    private func handleModernRecognitionResult(
        text: String,
        isFinal: Bool,
        sessionID: UUID,
        recognitionID: UUID
    ) {
        guard activeSessionID == sessionID, activeRecognitionID == recognitionID else {
            return
        }

        let previousText = transcript
        transcript = progressiveTranscript.accept(text, isFinal: isFinal)
        if transcript != previousText, !transcript.isEmpty {
            silenceDetector.noteTranscriptActivity(at: ProcessInfo.processInfo.systemUptime)
            state = .transcribing
        }
    }

    private func handleModernRecognitionError(
        _ error: Error,
        sessionID: UUID,
        recognitionID: UUID
    ) {
        guard activeSessionID == sessionID, activeRecognitionID == recognitionID else {
            return
        }
        if finalizationRequested {
            finishSession(sessionID: sessionID, cancelRecognition: true)
        } else if transcript.isEmpty {
            activeRecognitionID = nil
            cleanupModernRecognition()
            cleanupAudioCapture()
            recognitionBackend = .legacySpeechRecognizer
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled,
                      let self,
                      activeSessionID == sessionID,
                      !finalizationRequested else {
                    return
                }
                beginLegacyRecognition(locale: activeLocale, sessionID: sessionID)
            }
        } else {
            fail(
                "Speech recognition failed: \(error.localizedDescription)",
                sessionID: sessionID
            )
        }
    }

    private func finalizeModernRecognition(sessionID: UUID) {
        guard let analyzer = speechAnalyzer else {
            finishSession(sessionID: sessionID, cancelRecognition: true)
            return
        }

        Task { [weak self, analyzer] in
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            guard let self, activeSessionID == sessionID else {
                return
            }
            finishSession(sessionID: sessionID, cancelRecognition: false)
        }
    }

    private func handleRecognitionResult(
        text: String?,
        isFinal: Bool,
        errorDescription: String?,
        sessionID: UUID,
        recognitionID: UUID
    ) {
        guard activeSessionID == sessionID, activeRecognitionID == recognitionID else {
            return
        }

        let bestText = transcriptAccumulator.accept(text)
        if !bestText.isEmpty {
            let previousText = transcript
            transcript = bestText
            if transcript != previousText {
                silenceDetector.noteTranscriptActivity(at: ProcessInfo.processInfo.systemUptime)
            }
            unexpectedRestartCount = 0
            if !isFinal {
                state = .transcribing
            }
        }

        if isFinal {
            if bestText.isEmpty && !finalizationRequested {
                restartRecognition(sessionID: sessionID, recognitionID: recognitionID)
            } else {
                finishSession(sessionID: sessionID, cancelRecognition: false)
            }
        } else if let errorDescription {
            if bestText.isEmpty && !finalizationRequested {
                restartRecognition(sessionID: sessionID, recognitionID: recognitionID)
            } else {
                fail("Speech recognition failed: \(errorDescription)", sessionID: sessionID)
            }
        }
    }

    private func handleAudioLevel(
        _ level: Double,
        sessionID: UUID,
        recognitionID: UUID
    ) {
        guard activeSessionID == sessionID,
              activeRecognitionID == recognitionID,
              audioEngine?.isRunning == true else {
            return
        }

        smoothedAudioLevel = smoothedAudioLevel * 0.72 + level * 0.28
        audioLevel = smoothedAudioLevel

        let shouldFinalize = silenceDetector.shouldFinalize(
            audioLevel: smoothedAudioLevel,
            hasTranscript: !transcript.isEmpty,
            at: ProcessInfo.processInfo.systemUptime
        )
        if shouldFinalize {
            requestFinalization(sessionID: sessionID)
        }
    }

    private func restartRecognition(sessionID: UUID, recognitionID: UUID) {
        guard activeSessionID == sessionID,
              activeRecognitionID == recognitionID,
              !finalizationRequested else {
            return
        }
        guard unexpectedRestartCount < 4 else {
            fail(
                "Speech recognition stopped repeatedly. Click to try again.",
                sessionID: sessionID
            )
            return
        }
        unexpectedRestartCount += 1

        activeRecognitionID = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        cleanupAudioCapture()
        silenceDetector.reset()
        state = .listening

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled,
                  let self,
                  activeSessionID == sessionID,
                  !finalizationRequested else {
                return
            }
            beginLegacyRecognition(locale: activeLocale, sessionID: sessionID)
        }
    }

    private func scheduleFinalResultTimeout(sessionID: UUID) {
        finalResultTimeout?.cancel()
        finalResultTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            guard !Task.isCancelled else {
                return
            }
            self?.finishSession(sessionID: sessionID, cancelRecognition: true)
        }
    }

    private func fail(_ message: String, sessionID: UUID) {
        guard activeSessionID == sessionID else {
            return
        }

        cleanup(sessionID: sessionID, cancelRecognition: true)
        errorMessage = message
        state = .failed
    }

    private func finishSession(sessionID: UUID, cancelRecognition: Bool) {
        guard activeSessionID == sessionID else {
            return
        }

        cleanup(sessionID: sessionID, cancelRecognition: cancelRecognition)
        errorMessage = nil
        state = .idle
    }

    private func cleanup(sessionID: UUID, cancelRecognition: Bool) {
        guard activeSessionID == sessionID else {
            return
        }

        finalResultTimeout?.cancel()
        finalResultTimeout = nil
        cleanupAudioCapture()
        cleanupModernRecognition()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if cancelRecognition {
            recognitionTask?.cancel()
        }
        recognitionTask = nil
        speechRecognizer = nil
        activeSessionID = nil
        activeRecognitionID = nil
        finalizationRequested = false
        unexpectedRestartCount = 0
        silenceDetector.reset()
        announceCaptureStopped()
    }

    private func cleanupAudioCapture() {
        guard let engine = audioEngine else {
            tapInstalled = false
            smoothedAudioLevel = 0
            audioLevel = 0
            return
        }

        audioEngine = nil
        let hadTap = tapInstalled
        tapInstalled = false
        if engine.isRunning {
            engine.stop()
        }
        if hadTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.reset()
        smoothedAudioLevel = 0
        audioLevel = 0
    }

    private func cleanupModernRecognition() {
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        transcriberResultTask?.cancel()
        transcriberResultTask = nil
        if let speechAnalyzer {
            Task {
                await speechAnalyzer.cancelAndFinishNow()
            }
        }
        speechAnalyzer = nil
        dictationTranscriber = nil
        audioConverter = nil
        analyzerAudioFormat = nil
        progressiveTranscript.reset()
    }

    private func announceCaptureStarted() {
        guard !captureAnnouncementActive else {
            return
        }
        captureAnnouncementActive = true
        NotificationCenter.default.post(name: .castorSpeechCaptureWillStart, object: nil)
    }

    private func announceCaptureStopped() {
        guard captureAnnouncementActive else {
            return
        }
        captureAnnouncementActive = false
        NotificationCenter.default.post(name: .castorSpeechCaptureDidStop, object: nil)
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else {
                continue
            }
            memcpy(
                destinationData,
                sourceData,
                Int(min(source[index].mDataByteSize, destination[index].mDataByteSize))
            )
        }
        return copy
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        using converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard let converter else {
            return nil
        }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              status != .error,
              output.frameLength > 0 else {
            return nil
        }
        return output
    }

    private static func audioLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return 0
        }

        let channelSamples = (0..<Int(buffer.format.channelCount)).lazy.map {
            UnsafeBufferPointer(start: channels[$0], count: frameCount)
        }
        return SpeechAudioMeter.level(from: channelSamples.joined())
    }

    private static func microphoneAuthorization(
        from status: AVAuthorizationStatus
    ) -> SpeechInputAuthorization {
        switch status {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    private static func speechAuthorization(
        from status: SFSpeechRecognizerAuthorizationStatus
    ) -> SpeechInputAuthorization {
        switch status {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }
}
