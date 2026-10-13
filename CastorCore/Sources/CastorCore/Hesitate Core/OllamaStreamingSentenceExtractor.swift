import Foundation

/// Incrementally pulls out complete sentences from plain-text tokens streamed by Ollama, so the
/// on-device voice path can start text-to-speech on the first sentence before the whole reply has
/// finished generating.
///
/// This is intentionally separate from `OllamaResponseParser`/`PetSpeechSegmenter`: it only deals
/// with *plain* streamed text (no JSON schema), and it must be safe to call repeatedly as more
/// text arrives without ever emitting the same sentence twice or emitting a sentence that might
/// still grow (e.g. "3." inside "3.14" must not be treated as a sentence end).
///
/// Used only by the pipelined on-device streaming path added for TTFA. The structured JSON
/// fallback chain in `OllamaClient.chat(...)` and `OllamaResponseParser` are unrelated and
/// unchanged by this type.
public struct OllamaStreamingSentenceExtractor {
    private static let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？"]
    private static let closingCharacters: Set<Character> = ["\"", "'", "”", "’", "」", "』", "）", ")", "]", "】"]

    /// Characters accumulated so far that have not yet been emitted as a completed sentence.
    public private(set) var pendingText: String = ""

    /// Appends newly streamed text and returns any sentences that can now be safely emitted, in
    /// order. Whitespace inside a sentence is preserved as streamed; trimming happens per emitted
    /// sentence.
    public mutating func append(_ delta: String) -> [String] {
        guard !delta.isEmpty else {
            return []
        }
        pendingText += delta

        var emitted: [String] = []
        while let (sentence, remainder) = Self.extractLeadingSentence(from: pendingText) {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                emitted.append(trimmed)
            }
            pendingText = remainder
        }
        return emitted
    }

    /// Call once the stream has finished. Returns any leftover text as a final "sentence" (it may
    /// not end with punctuation, e.g. the model stopped mid-clause), or nil if nothing remains.
    public mutating func flushRemainder() -> String? {
        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Attempts to split off one complete leading sentence from `text`. Returns nil if no
    /// sentence boundary is available yet. A terminator found at the very end of the buffered
    /// text is emitted immediately (nothing is withheld waiting for possible closing quotes) —
    /// closing quotes that stream in afterward are instead absorbed into the *next* sentence's
    /// leading edge being trimmed away, which is an acceptable trade-off for speaking a reply as
    /// early as possible. The only real ambiguity this function withholds on is a "." at the very
    /// end of the buffer that could still turn into a decimal point (e.g. "3." -> "3.14").
    private static func extractLeadingSentence(from text: String) -> (sentence: String, remainder: String)? {
        guard let terminatorIndex = firstUnambiguousTerminator(in: text) else {
            return nil
        }

        // Absorb any immediately-following closing punctuation/quotes already present in the
        // buffer (e.g. a closing "\"" right after "."), but don't block on more arriving later.
        var boundary = text.index(after: terminatorIndex)
        while boundary < text.endIndex, closingCharacters.contains(text[boundary]) {
            boundary = text.index(after: boundary)
        }

        let sentence = String(text[text.startIndex..<boundary])
        let remainder = String(text[boundary...])
        return (sentence, remainder)
    }

    /// Finds the index of the first sentence-ending character that is not ambiguous given the
    /// text seen so far (e.g. a "." between two digits, which could be a decimal point, or a "."
    /// at the very end of the buffer preceded by a digit, which could still become one once more
    /// digits stream in).
    private static func firstUnambiguousTerminator(in text: String) -> String.Index? {
        for index in text.indices {
            let character = text[index]
            guard sentenceEndings.contains(character) else {
                continue
            }
            if isSentenceEnding(character, at: index, in: text) {
                return index
            }
        }
        return nil
    }

    private static func isSentenceEnding(
        _ character: Character,
        at index: String.Index,
        in text: String
    ) -> Bool {
        guard character == "." else {
            return true
        }

        let previousIndex: String.Index? = index > text.startIndex ? text.index(before: index) : nil
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else {
            // We don't yet know what follows this period. If it's plausibly a decimal point
            // (preceded by a digit), withhold judgement until more text streams in by treating
            // it as "not a sentence end yet" — the caller will re-check on the next append.
            if let previousIndex, text[previousIndex].isNumber {
                return false
            }
            return true
        }

        let isEmbeddedBetweenReadableCharacters =
            previousIndex.map { text[$0].isLetter || text[$0].isNumber } == true
            && (text[nextIndex].isLetter || text[nextIndex].isNumber)
        return !isEmbeddedBetweenReadableCharacters
    }

    public init(pendingText: String = "") {
        self.pendingText = pendingText
    }
}
