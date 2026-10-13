import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech
import ScreenshotAnswerCore

enum SystemAudioLanguage: String, CaseIterable, Identifiable {
    case english = "en-US"
    case japanese = "ja-JP"

    var id: String { rawValue }

    func label(for language: InterfaceLanguage) -> String {
        switch self {
        case .english: language.text("英語", "English")
        case .japanese: language.text("日本語", "Japanese")
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

enum SystemAudioCaptureError: LocalizedError {
    case requiresMacOS26
    case speechPermissionDenied
    case unsupportedLanguage
    case speechModelUnavailable
    case noDisplay
    case notRunning
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .requiresMacOS26:
            "システム音声のローカル文字起こしにはmacOS 26以降が必要です。"
        case .speechPermissionDenied:
            "音声認識の権限がありません。システム設定のプライバシーとセキュリティで許可してください。"
        case .unsupportedLanguage:
            "選択した言語のオンデバイス文字起こしに対応していません。"
        case .speechModelUnavailable:
            "文字起こしモデルを準備できませんでした。ネットワーク接続と空き容量を確認してください。"
        case .noDisplay:
            "取得できるディスプレイがありません。"
        case .notRunning:
            "システム音声を取得していません。"
        case .noSpeechDetected:
            "音声から言葉を認識できませんでした。音量と言語を確認してください。"
        }
    }
}

@MainActor
final class SystemAudioCaptureCoordinator {
    private var modernSession: AnyObject?

    var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func start(
        language: SystemAudioLanguage,
        onTranscript: @escaping @Sendable (String) -> Void
    ) async throws {
        guard #available(macOS 26.0, *) else {
            throw SystemAudioCaptureError.requiresMacOS26
        }
        if let existing = modernSession as? ModernSystemAudioSession {
            await existing.cancel()
        }
        let session = ModernSystemAudioSession()
        try await session.start(locale: language.locale, onTranscript: onTranscript)
        modernSession = session
    }

    func stop() async throws -> String {
        guard #available(macOS 26.0, *),
              let session = modernSession as? ModernSystemAudioSession else {
            throw SystemAudioCaptureError.notRunning
        }
        defer { modernSession = nil }
        return try await session.stop()
    }

    func cancel() async {
        guard #available(macOS 26.0, *),
              let session = modernSession as? ModernSystemAudioSession else {
            modernSession = nil
            return
        }
        await session.cancel()
        modernSession = nil
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ModernSystemAudioSession {
    private var stream: SCStream?
    private var receiver: AnalyzerAudioReceiver?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<String, Error>?
    private var isRunning = false

    func start(
        locale: Locale,
        onTranscript: @escaping @Sendable (String) -> Void
    ) async throws {
        guard await Self.requestSpeechAuthorization() else {
            throw SystemAudioCaptureError.speechPermissionDenied
        }
        guard SpeechTranscriber.isAvailable,
              let supportedLocale = await SpeechTranscriber.supportedLocale(
                equivalentTo: locale
              ) else {
            throw SystemAudioCaptureError.unsupportedLanguage
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .transcription
        )
        let modules: [any SpeechModule] = [transcriber]
        do {
            let status = await AssetInventory.status(forModules: modules)
            if status != .installed,
               let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
               ) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw SystemAudioCaptureError.speechModelUnavailable
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw SystemAudioCaptureError.speechModelUnavailable
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .lingering
            )
        )
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let inputPair = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(24)
        )
        let receiver = AnalyzerAudioReceiver(
            targetFormat: analyzerFormat,
            continuation: inputPair.continuation
        )
        try stream.addStreamOutput(
            receiver,
            type: .audio,
            sampleHandlerQueue: receiver.queue
        )
        let resultTask = Task<String, Error> {
            var accumulator = AudioTranscriptAccumulator()
            for try await result in transcriber.results {
                let segment = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segment.isEmpty else { continue }
                let transcript = accumulator.consume(segment, isFinal: result.isFinal)
                onTranscript(transcript)
            }
            return accumulator.transcript
        }

        self.stream = stream
        self.receiver = receiver
        self.analyzer = analyzer
        self.resultTask = resultTask

        do {
            try await analyzer.start(inputSequence: inputPair.stream)
            try await stream.startCapture()
            isRunning = true
        } catch {
            inputPair.continuation.finish()
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            self.stream = nil
            self.receiver = nil
            self.analyzer = nil
            self.resultTask = nil
            throw error
        }
    }

    func stop() async throws -> String {
        guard isRunning,
              let stream,
              let receiver,
              let analyzer,
              let resultTask else {
            throw SystemAudioCaptureError.notRunning
        }

        isRunning = false
        do {
            try await stream.stopCapture()
        } catch {
            receiver.finish()
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            cleanup()
            throw error
        }
        receiver.finish()
        let transcript: String
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            transcript = try await resultTask.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cleanup()
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            cleanup()
            throw error
        }
        guard !transcript.isEmpty else {
            throw SystemAudioCaptureError.noSpeechDetected
        }
        return transcript
    }

    func cancel() async {
        if isRunning, let stream {
            try? await stream.stopCapture()
        }
        receiver?.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        resultTask?.cancel()
        cleanup()
    }

    private func cleanup() {
        isRunning = false
        stream = nil
        receiver = nil
        analyzer = nil
        resultTask = nil
    }

    private static func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

@available(macOS 26.0, *)
private final class AnalyzerAudioReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(
        label: "dev.pomegranate.screenshot-answer.system-audio",
        qos: .userInitiated
    )

    private let targetFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?

    init(
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else { return }

        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard let description = sampleBuffer.formatDescription?
                .audioStreamBasicDescription,
                  let naturalFormat = AVAudioFormat(
                    standardFormatWithSampleRate: description.mSampleRate,
                    channels: description.mChannelsPerFrame
                  ),
                  let borrowedBuffer = AVAudioPCMBuffer(
                    pcmFormat: naturalFormat,
                    bufferListNoCopy: audioBufferList.unsafePointer
                  ) else {
                return
            }

            let analyzerBuffer: AVAudioPCMBuffer?
            if naturalFormat == targetFormat {
                analyzerBuffer = Self.copy(borrowedBuffer)
            } else {
                if converter == nil || converterSourceFormat != naturalFormat {
                    converter = AVAudioConverter(from: naturalFormat, to: targetFormat)
                    converterSourceFormat = naturalFormat
                }
                analyzerBuffer = Self.convert(
                    borrowedBuffer,
                    to: targetFormat,
                    using: converter
                )
            }
            if let analyzerBuffer {
                continuation.yield(AnalyzerInput(buffer: analyzerBuffer))
            }
        }
    }

    func finish() {
        continuation.finish()
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
        guard let converter else { return nil }
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
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
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
}
