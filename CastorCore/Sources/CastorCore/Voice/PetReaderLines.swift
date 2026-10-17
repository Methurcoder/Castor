import Foundation

/// What the answer reader shows while a reply is spoken. A neural voice reads
/// a whole reply as one segment, longer than the small reader can show, so
/// each spoken segment is cut into short lines and the reader follows the
/// line being spoken, estimated from how far playback has come.
public enum PetReaderLines {
    /// Short enough for about two lines of the small reader.
    public static let targetLength = 16
    public static let maximumLength = 22

    public struct Layout: Equatable, Sendable {
        public let lines: [String]
        /// The spoken segment each line belongs to.
        public let segmentOfLine: [Int]
    }

    public static func layout(for segments: [String]) -> Layout {
        var lines: [String] = []
        var owners: [Int] = []
        for (index, segment) in segments.enumerated() {
            var pieces = PetSpeechSegmenter.segments(from: segment, targetLength: targetLength, maximumLength: maximumLength)
            if pieces.isEmpty { pieces = [segment] }
            lines += pieces
            owners += Array(repeating: index, count: pieces.count)
        }
        return Layout(lines: lines, segmentOfLine: owners)
    }

    /// The line being spoken: the line of `segmentIndex` holding the character
    /// that `progress` (0...1 of the segment's playback) has reached.
    public static func currentLine(in layout: Layout, segmentIndex: Int, progress: Double) -> Int {
        guard !layout.lines.isEmpty else { return 0 }
        guard let first = layout.segmentOfLine.firstIndex(where: { $0 >= segmentIndex }) else {
            return layout.lines.count - 1
        }
        guard layout.segmentOfLine[first] == segmentIndex else { return first }
        let last = layout.segmentOfLine.lastIndex(of: segmentIndex) ?? first
        let counts = (first...last).map { layout.lines[$0].count }
        let reached = min(max(progress, 0), 1) * Double(counts.reduce(0, +))
        var start = 0
        for (offset, count) in counts.enumerated() {
            if reached < Double(start + count) { return first + offset }
            start += count
        }
        return last
    }
}
