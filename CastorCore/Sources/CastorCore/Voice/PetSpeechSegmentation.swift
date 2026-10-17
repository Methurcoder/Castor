import Foundation

public enum PetSpeechSegmenter {
    /// The segment tuning used for spoken replies. Shared by the full-reply path
    /// (`PetSpeechOutput.speak`) and the streamed-sentence path
    /// (`PetSpeechOutput.appendStreamedSentence`) so both produce identical granularity for the
    /// TTS requests and the response reader.
    public static func spokenReplySegments(from text: String, isFirstSpokenText: Bool) -> [String] {
        segments(
            from: text,
            targetLength: 14,
            maximumLength: 18,
            shrinkFirstSegment: isFirstSpokenText
        )
    }

    /// The longest text a neural voice reads in one request. Qwen restarts its
    /// intonation with every request, so it reads whole sentences, joined up
    /// to this length, rather than short phrases.
    public static let neuralSegmentLength = 160

    /// Segments for a neural voice: whole sentences, consecutive ones joined
    /// while they fit in `neuralSegmentLength`. Only a sentence longer than
    /// that is split, at its most natural pause. The first sentence of a reply
    /// stays alone so the voice starts without waiting for the rest.
    public static func neuralReplySegments(from text: String, isFirstSpokenText: Bool) -> [String] {
        var joined: [String] = []
        for sentence in segments(from: text, maximumLength: neuralSegmentLength) {
            if let last = joined.last, !(isFirstSpokenText && joined.count == 1),
               let merged = neuralJoin(last, sentence) {
                joined[joined.count - 1] = merged
            } else {
                joined.append(sentence)
            }
        }
        return joined
    }

    /// `first` and `second` read as one neural request, or nil when that
    /// would exceed `neuralSegmentLength`.
    public static func neuralJoin(_ first: String, _ second: String) -> String? {
        let needsSpace = first.last.map { $0.isASCII } ?? false
        let merged = first + (needsSpace ? " " : "") + second
        return merged.count <= neuralSegmentLength ? merged : nil
    }

    public static func segments(
        from text: String,
        targetLength: Int? = nil,
        maximumLength: Int = 80,
        shrinkFirstSegment: Bool = false
    ) -> [String] {
        let maximumLength = max(12, maximumLength)
        let targetLength = targetLength.map { min(max(8, $0), maximumLength) }
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return []
        }

        let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？"]
        let closingCharacters: Set<Character> = ["\"", "'", "”", "’", "」", "』", "）", ")", "]", "】"]
        var sentences: [String] = []
        var current = ""
        var justEndedSentence = false

        for index in normalized.indices {
            let character = normalized[index]
            if justEndedSentence, !closingCharacters.contains(character) {
                append(current, to: &sentences)
                current = ""
                justEndedSentence = false
            }

            current.append(character)
            if sentenceEndings.contains(character),
               isSentenceEnding(character, at: index, in: normalized) {
                justEndedSentence = true
            }
        }
        append(current, to: &sentences)

        let result = sentences.flatMap {
            splitLongSegment($0, targetLength: targetLength, maximumLength: maximumLength)
        }

        guard shrinkFirstSegment, let firstSegment = result.first else {
            return result
        }

        let shrunkFirst = shrinkLeadingSegment(firstSegment)
        guard shrunkFirst.count > 1 else {
            return result
        }
        return shrunkFirst + result.dropFirst()
    }

    /// Splits the first segment at its earliest natural pause (comma, reading-point, or similar)
    /// so the very first thing spoken is as short as possible, reducing time-to-first-audio. Only
    /// applied to the first segment; every later segment keeps its normal length. Falls back to
    /// returning the segment unchanged if it has no early break point worth using.
    private static func shrinkLeadingSegment(_ segment: String) -> [String] {
        let earlyBreaks: Set<Character> = [",", "，", "、", ";", "；", ":", "："]
        let characters = Array(segment)
        // Don't bother shrinking segments that are already short.
        guard characters.count > 10 else {
            return [segment]
        }

        // Search up to roughly the first half of the segment (or 24 characters, whichever is
        // smaller) for the earliest natural pause; going further defeats the purpose of shrinking.
        let searchLimit = min(characters.count - 2, max(6, min(24, characters.count / 2)))
        guard searchLimit >= 2 else {
            return [segment]
        }

        for index in 0...searchLimit where earlyBreaks.contains(characters[index]) {
            let breakIndex = index + 1
            let head = String(characters[..<breakIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(characters[breakIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty, !tail.isEmpty else {
                continue
            }
            return [head, tail]
        }

        return [segment]
    }

    private static func isSentenceEnding(
        _ character: Character,
        at index: String.Index,
        in text: String
    ) -> Bool {
        guard character == "." else {
            return true
        }

        let previousIndex: String.Index? =
            index > text.startIndex ? text.index(before: index) : nil
        let nextIndex = text.index(after: index)
        let isEmbeddedBetweenReadableCharacters =
            previousIndex.map { text[$0].isLetter || text[$0].isNumber } == true
            && nextIndex < text.endIndex
            && (text[nextIndex].isLetter || text[nextIndex].isNumber)
        return !isEmbeddedBetweenReadableCharacters
    }

    private static func splitLongSegment(
        _ segment: String,
        targetLength: Int?,
        maximumLength: Int
    ) -> [String] {
        var remainder = Array(segment)
        var result: [String] = []

        while remainder.count > maximumLength {
            let breakIndex = targetLength.flatMap {
                naturalBreakIndex(in: remainder, targetLength: $0, maximumLength: maximumLength)
            } ?? legacyBreakIndex(in: remainder, maximumLength: maximumLength)
            let splitIndex = breakIndex ?? maximumLength
            append(String(remainder[..<splitIndex]), to: &result)
            remainder.removeFirst(splitIndex)
            while remainder.first?.isWhitespace == true {
                remainder.removeFirst()
            }
        }

        append(String(remainder), to: &result)
        return result
    }

    private static func legacyBreakIndex(in characters: [Character], maximumLength: Int) -> Int? {
        let preferredBreaks: Set<Character> = [",", "，", "、", ";", "；", ":", "："]
        let searchEnd = min(maximumLength - 1, characters.count - 1)
        let minimumBreak = min(6, searchEnd)

        guard searchEnd >= minimumBreak else {
            return nil
        }

        for index in stride(from: searchEnd, through: minimumBreak, by: -1) {
            if preferredBreaks.contains(characters[index]) {
                return index + 1
            }
        }
        for index in stride(from: searchEnd, through: minimumBreak, by: -1)
        where characters[index].isWhitespace {
            return index
        }
        return nil
    }

    private static func naturalBreakIndex(
        in characters: [Character],
        targetLength: Int,
        maximumLength: Int
    ) -> Int? {
        let preferredBreaks: Set<Character> = [",", "，", "、", ";", "；", ":", "："]
        let japanesePhraseBreaks: Set<Character> = ["は", "が", "を", "に", "で", "と", "へ", "も"]
        let searchEnd = min(maximumLength - 1, characters.count - 1)
        let minimumBreak = min(6, searchEnd)
        var best: (index: Int, score: Int)?

        guard searchEnd >= minimumBreak else {
            return nil
        }

        func consider(_ candidate: Int, priority: Int) {
            guard candidate >= minimumBreak,
                  candidate < characters.count else {
                return
            }
            let score = abs(candidate - targetLength) + priority
            if score < (best?.score ?? Int.max) {
                best = (candidate, score)
            }
        }

        for index in minimumBreak...searchEnd {
            let character = characters[index]
            if preferredBreaks.contains(character) {
                consider(index + 1, priority: 0)
            } else if character.isWhitespace {
                consider(index, priority: 2)
            } else if japanesePhraseBreaks.contains(character) {
                consider(index + 1, priority: 4)
            }
        }

        return best?.index
    }

    private static func append(_ candidate: String, to segments: inout [String]) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let hasReadableContent = trimmed.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
                || CharacterSet(charactersIn: "\u{3040}-\u{30FF}\u{3400}-\u{9FFF}").contains($0)
        }
        if !hasReadableContent, !segments.isEmpty {
            segments[segments.count - 1].append(trimmed)
        } else {
            segments.append(trimmed)
        }
    }
}

/// Pure dB-to-0..1 normalization + asymmetric attack/release smoothing for the mouth-open energy
/// signal driving the real-audio-driven mouth flap (phase E). Kept independent of
/// `AVAudioPlayer`/`AVSpeechSynthesizer` so it is trivially unit-testable: feed it a sequence of
/// raw levels (dB or an already-linear 0..1 pseudo-level) and it returns a smoothed 0..1 value.
///
/// Attack is fast (the mouth should open quickly once sound starts) and release is slower (the
/// mouth should ease closed rather than snapping shut between syllables), matching how a real
/// audio envelope follower is typically tuned.
public struct SpeechEnergyEnvelope: Equatable {
    public private(set) var value: Double = 0

    /// How quickly `value` approaches a *larger* raw level, per second of `deltaTime` (as a
    /// fraction closed per second, exponential approach). Higher = snappier attack.
    public var attackRate: Double = 18.0
    /// How quickly `value` approaches a *smaller* raw level. Lower than `attackRate` so the mouth
    /// doesn't slam shut between syllables.
    public var releaseRate: Double = 6.0

    /// Converts a raw average power reading in dBFS (as returned by
    /// `AVAudioPlayer.averagePower(forChannel:)`, typically in roughly -160...0) into a 0...1
    /// linear-ish level. Values at or below `silenceFloor` map to 0; values at or above 0 dB map
    /// to 1. This is a simple linear remap in dB space (not perceptual loudness), which is
    /// sufficient for driving a mouth-flap amplitude rather than anything audio-accurate.
    public static func normalizedLevel(fromDecibels decibels: Float, silenceFloor: Float = -50) -> Double {
        guard decibels.isFinite else {
            return 0
        }
        let clampedFloor = min(silenceFloor, -1)
        let clamped = max(clampedFloor, min(0, decibels))
        return Double((clamped - clampedFloor) / -clampedFloor)
    }

    /// Advances the envelope toward `rawLevel` (expected already in 0...1) by `deltaTime` seconds,
    /// using the faster `attackRate` when `rawLevel` is above the current value and the slower
    /// `releaseRate` when it is below. Returns the updated envelope (value semantics, so callers
    /// keep the returned copy for the next step) — this makes the function a pure step, safe to
    /// unit test without any audio session.
    public func stepping(toward rawLevel: Double, deltaTime: TimeInterval) -> SpeechEnergyEnvelope {
        let target = max(0, min(1, rawLevel))
        let rate = target >= value ? attackRate : releaseRate
        // Exponential approach: value moves a fraction of the remaining distance each step,
        // scaled by elapsed time so the result is frame-rate independent.
        let clampedDeltaTime = max(0, deltaTime)
        let alpha = 1 - exp(-rate * clampedDeltaTime)
        var next = self
        next.value = value + (target - value) * alpha
        return next
    }

    public init(value: Double = 0, attackRate: Double = 18.0, releaseRate: Double = 6.0) {
        self.value = value
        self.attackRate = attackRate
        self.releaseRate = releaseRate
    }
}

/// Maps a smoothed speech energy level (0...1, from `SpeechEnergyEnvelope`) to a `mouthOpen`
/// value. Deliberately a free pure function (not a method on `CherryConnection`) so both
/// `CherryConnection.applyContextOverlay` and tests can use it without needing a `CherryConnection`
/// instance. Monotonic in `energy` and stays near-closed for low energy, opening smoothly as
/// energy rises — tuned so quiet speech still shows a little mouth movement but silence closes it.
public enum SpeechEnergyMouthMapping {
    /// mouthOpen value when `energy == 0` (a relaxed, nearly-closed mouth rather than a hard 0,
    /// matching the idle/thinking resting mouthOpen baselines elsewhere in `CherryConnection`).
    public static let closedFloor = 0.06
    /// mouthOpen value approached as `energy` -> 1.
    public static let openCeiling = 0.82
    /// Curve shape: energy is raised to this power before the linear remap, so small energies
    /// open the mouth a little (not none) while still keeping quiet ambient noise mostly closed.
    public static let curveExponent = 0.72

    public static func mouthOpen(forEnergy energy: Double) -> Double {
        let clamped = max(0, min(1, energy))
        let curved = pow(clamped, curveExponent)
        return closedFloor + (openCeiling - closedFloor) * curved
    }
}
