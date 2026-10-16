import Foundation

public enum SpeechInputState: Equatable {
    case idle
    case requestingPermission
    case listening
    case transcribing
    case failed
}

public enum SpeechInputAuthorization: Equatable {
    case notDetermined
    case granted
    case denied
}

public enum SpeechRecognitionBackend: Equatable {
    case dictationTranscriber
    case legacySpeechRecognizer
}

public struct SpeechTranscriptAccumulator {
    public private(set) var bestText = ""

    public init() {}

    public mutating func reset() {
        bestText = ""
    }

    @discardableResult
    public mutating func accept(_ candidate: String?) -> String {
        guard let candidate else {
            return bestText
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return bestText
        }

        bestText = trimmed
        return bestText
    }
}

public struct ProgressiveSpeechTranscript {
    public private(set) var finalizedText = ""
    public private(set) var volatileText = ""

    public init() {}

    public var text: String {
        [finalizedText, volatileText]
            .filter { !$0.isEmpty }
            .joined(separator: finalizedText.isEmpty || volatileText.isEmpty ? "" : " ")
    }

    public mutating func reset() {
        finalizedText = ""
        volatileText = ""
    }

    @discardableResult
    public mutating func accept(_ candidate: String, isFinal: Bool) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return text
        }

        if isFinal {
            if finalizedText.isEmpty {
                finalizedText = trimmed
            } else {
                finalizedText += " " + trimmed
            }
            volatileText = ""
        } else {
            volatileText = trimmed
        }
        return text
    }
}

public struct SpeechAudioMeter {
    public static func level<S: Sequence>(from samples: S) -> Double where S.Element == Float {
        var sum = 0.0
        var count = 0

        for sample in samples {
            let value = Double(sample)
            sum += value * value
            count += 1
        }

        guard count > 0 else {
            return 0
        }

        return min(1, sqrt(sum / Double(count)) * 5)
    }

    public init() {}
}

public struct SpeechSilenceDetector {
    public var minimumLevelThreshold = 0.008
    public var requiredSilence = 1.15
    public var calibrationDuration = 0.55

    public private(set) var lastVoiceTime: TimeInterval?
    public private(set) var hasObservedTranscript = false
    public private(set) var calibratedThreshold = 0.008
    private var calibrationStartedAt: TimeInterval?
    private var calibrationTotal = 0.0
    private var calibrationSamples = 0

    public init(
        minimumLevelThreshold: Double = 0.008,
        requiredSilence: Double = 1.15,
        calibrationDuration: Double = 0.55
    ) {
        self.minimumLevelThreshold = minimumLevelThreshold
        self.requiredSilence = requiredSilence
        self.calibrationDuration = calibrationDuration
        calibratedThreshold = minimumLevelThreshold
    }

    public mutating func reset() {
        lastVoiceTime = nil
        hasObservedTranscript = false
        calibratedThreshold = minimumLevelThreshold
        calibrationStartedAt = nil
        calibrationTotal = 0
        calibrationSamples = 0
    }

    public mutating func noteTranscriptActivity(at time: TimeInterval) {
        hasObservedTranscript = true
        lastVoiceTime = time
    }

    public mutating func shouldFinalize(
        audioLevel: Double,
        hasTranscript: Bool,
        at time: TimeInterval
    ) -> Bool {
        updateCalibration(audioLevel: audioLevel, at: time)

        if audioLevel > calibratedThreshold {
            lastVoiceTime = time
        }

        if hasTranscript && !hasObservedTranscript {
            noteTranscriptActivity(at: time)
        }

        guard hasObservedTranscript, let lastVoiceTime else {
            return false
        }

        return time - lastVoiceTime >= requiredSilence
    }

    private mutating func updateCalibration(audioLevel: Double, at time: TimeInterval) {
        guard calibrationDuration > 0 else {
            return
        }
        if calibrationStartedAt == nil {
            calibrationStartedAt = time
        }
        guard let calibrationStartedAt,
              time - calibrationStartedAt <= calibrationDuration else {
            return
        }

        calibrationTotal += audioLevel
        calibrationSamples += 1
        let noiseFloor = calibrationTotal / Double(calibrationSamples)
        calibratedThreshold = max(minimumLevelThreshold, min(1, noiseFloor * 2.4))
    }
}

/// A content-free diagnostic snapshot. Never stores audio, transcripts or device names.
public nonisolated struct SpeechInputDiagnostics: Sendable, Equatable {
    public var backend = "starting"
    public var locale = "auto"
    public var asset = "unknown"
    public var microphone = "unknown"
    public var speechPermission = "unknown"
    public var buffers = 0
    public var delivered = 0
    public var dropped = 0
    public var peak = 0.0
    public var partials = 0
    public var end = "starting"
    public var error = "none"
    public init() {}
    public var code: String {
        func token(_ value: String) -> String {
            String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }.prefix(64))
        }
        let level = peak.isFinite ? Int(min(1, max(0, peak)) * 1000) : 0
        return "SI1 backend=\(token(backend)) locale=\(token(locale)) asset=\(token(asset)) mic=\(token(microphone)) speech=\(token(speechPermission)) buffers=\(buffers) sent=\(delivered) drop=\(dropped) peak=\(level) partial=\(partials) end=\(token(end)) error=\(token(error))"
    }
}

/// Only application-owned speech errors go through this mapper. Provider replies stay untouched.
public nonisolated enum SpeechInputMessages {
    public static func localized(_ message: String, language: SettingsDisplayLanguage) -> String {
        guard language == .japanese else { return message }
        let pairs = [
            ("I couldn't hear that. Click to try again.", "音声を文字にできませんでした。認識言語を確認して、もう一度話してください。"),
            ("Type something first.", "メッセージを入力してください。"),
            ("Microphone access was denied.", "マイクの使用が許可されていません。設定から許可してください。"),
            ("Speech recognition access was denied.", "音声認識が許可されていません。設定 → 入力から許可設定を開いてください。"),
            ("Speech recognition is currently unavailable.", "音声認識を現在利用できません。認識言語とOSの音声データを確認してください。"),
            ("No usable microphone input format is available.", "使用できるマイク入力が見つかりません。入力デバイスを確認してください。"),
            ("Speech recognition stopped repeatedly. Click to try again.", "音声認識が繰り返し停止しました。入力設定を確認して再試行してください。"),
            ("Speech recognition failed: ", "音声認識に失敗しました: "),
            ("Speech recognition is unavailable for ", "この言語の音声認識を利用できません: "),
            ("Could not start microphone input: ", "マイク入力を開始できませんでした: "),
            ("Could not select ", "マイクを選択できませんでした: ")
        ]
        for (source, translated) in pairs where message.hasPrefix(source) {
            return translated + message.dropFirst(source.count)
        }
        return message
    }
}

/// Notification observers reserve acknowledgements before their capture queue releases the mic.
/// A listener waits for all observers, rather than guessing a device-release delay.
public nonisolated final class SpeechCaptureHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var posting = true
    private var waiter: CheckedContinuation<Void, Never>?
    public init() {}
    public func reserve() -> @Sendable () -> Void {
        lock.withLock { pending += 1 }
        return { [self] in
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                pending -= 1
                guard pending == 0, !posting else { return nil }
                defer { waiter = nil }
                return waiter
            }
            continuation?.resume()
        }
    }
    public func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                posting = false
                if pending == 0 { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
