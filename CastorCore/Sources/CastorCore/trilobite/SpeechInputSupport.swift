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
