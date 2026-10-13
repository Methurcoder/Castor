import Foundation

/// Keeps finalized speech segments on separate lines while replacing the
/// current provisional segment. SpeechTranscriber does not provide speaker
/// identities, but preserving utterance boundaries gives the local model
/// substantially better evidence for conservative dialogue reconstruction.
public struct AudioTranscriptAccumulator: Sendable, Equatable {
    private var finalizedSegments: [String] = []
    private var provisionalSegment = ""

    public init() {}

    @discardableResult
    public mutating func consume(_ text: String, isFinal: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        if isFinal {
            finalizedSegments.append(trimmed)
            provisionalSegment = ""
        } else {
            provisionalSegment = trimmed
        }
        return transcript
    }

    public var transcript: String {
        (finalizedSegments + (provisionalSegment.isEmpty ? [] : [provisionalSegment]))
            .joined(separator: "\n")
    }
}
