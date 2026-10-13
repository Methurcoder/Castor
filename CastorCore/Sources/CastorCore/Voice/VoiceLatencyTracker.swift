import Foundation

/// A single named timestamp captured during one voice turn (user input finalized through
/// first audio playback). Kept as plain data so the interval math can be unit tested without
/// touching os.Logger, actors, or real clocks.
public struct VoiceLatencyMark: Equatable {
    public enum Kind: String, CaseIterable {
        case inputFinalized
        case llmFirstToken
        case llmComplete
        case ttsRequestStarted
        case ttsResponseReceived
        case playbackStarted
    }

    public let kind: Kind
    public let elapsed: TimeInterval

    public init(kind: Kind, elapsed: TimeInterval) {
        self.kind = kind
        self.elapsed = elapsed
    }
}

/// Pure aggregation of a single voice turn's latency marks into human-readable deltas.
/// `VoiceLatencyTracker` (below) is the thin, effectful wrapper that captures real timestamps
/// and writes them through os.Logger; this struct only does arithmetic and formatting so it is
/// trivial to unit test.
public struct VoiceLatencyReport: Equatable {
    public let marks: [VoiceLatencyMark]

    /// Elapsed time (seconds, relative to `inputFinalized`) for each mark that was recorded,
    /// in the fixed `Kind` order, regardless of the order marks were inserted.
    public var orderedMarks: [VoiceLatencyMark] {
        VoiceLatencyMark.Kind.allCases.compactMap { kind in
            marks.first { $0.kind == kind }
        }
    }

    /// The time-to-first-audio, i.e. the elapsed time of the `playbackStarted` mark, if present.
    public var timeToFirstAudio: TimeInterval? {
        marks.first { $0.kind == .playbackStarted }?.elapsed
    }

    /// Deltas between consecutive recorded marks (in fixed `Kind` order), useful for identifying
    /// which stage of the pipeline dominates the latency.
    public func segmentDurations() -> [(from: VoiceLatencyMark.Kind, to: VoiceLatencyMark.Kind, duration: TimeInterval)] {
        let ordered = orderedMarks
        guard ordered.count > 1 else {
            return []
        }
        return (1..<ordered.count).map { index in
            let previous = ordered[index - 1]
            let current = ordered[index]
            return (previous.kind, current.kind, current.elapsed - previous.elapsed)
        }
    }

    /// A single-line, log-friendly summary such as:
    /// "TTFA=0.62s inputFinalized=0.00s llmFirstToken=0.18s(+0.18s) ttsRequestStarted=0.20s(+0.02s) ...".
    public func summaryLine() -> String {
        let ordered = orderedMarks
        guard !ordered.isEmpty else {
            return "TTFA=n/a (no marks recorded)"
        }

        let ttfaText = timeToFirstAudio.map { "\(CastorLog.fixed($0))s" } ?? "n/a"
        var previousElapsed: TimeInterval = 0
        let parts = ordered.enumerated().map { index, mark -> String in
            let delta = index == 0 ? mark.elapsed : mark.elapsed - previousElapsed
            previousElapsed = mark.elapsed
            return "\(mark.kind.rawValue)=\(CastorLog.fixed(mark.elapsed))s(+\(CastorLog.fixed(delta))s)"
        }
        return "TTFA=\(ttfaText) " + parts.joined(separator: " ")
    }

    public init(marks: [VoiceLatencyMark]) {
        self.marks = marks
    }
}

/// Captures wall-clock timestamps for one voice turn and emits them through os.Logger.
/// Not thread-safe by design: intended for single-threaded use from `@MainActor` call sites
/// such as `PetVoiceConversation`. All arithmetic is delegated to `VoiceLatencyReport` so it
/// can be exercised without a logger or real time source.
@MainActor
public final class VoiceLatencyTracker {
    private static let logger = CastorLog(subsystem: "Castor", category: "VoiceLatency")

    private var referenceTime: Date?
    private var marks: [VoiceLatencyMark] = []
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Starts a new turn. Must be called when the user's input is finalized (e.g. speech
    /// recognition stop, or text submit) — this becomes the zero point for all deltas.
    public func startTurn() {
        referenceTime = now()
        marks = []
        record(.inputFinalized)
    }

    /// Records a mark at the current time, relative to the turn's reference time. No-op if
    /// `startTurn()` was never called (e.g. logging is disabled or called out of order).
    public func record(_ kind: VoiceLatencyMark.Kind) {
        guard let referenceTime else {
            return
        }
        let elapsed = now().timeIntervalSince(referenceTime)
        marks.append(VoiceLatencyMark(kind: kind, elapsed: elapsed))
    }

    /// Builds the current report and writes its summary line to os.Logger. Call once the turn
    /// reaches first audio playback (or fails) so the log captures the full breakdown.
    @discardableResult
    public func finishAndLog() -> VoiceLatencyReport {
        let report = VoiceLatencyReport(marks: marks)
        Self.logger.info(report.summaryLine())
        return report
    }
}
