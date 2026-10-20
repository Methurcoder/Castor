import Foundation

/// Unigram (SentencePiece-style) tokenizer for the feeling classifier, read from
/// a Hugging Face `tokenizer.json`. Reproduces `tokenizers` for this model's
/// settings: no normalizer, Metaspace (spaces become "▁", nothing prepended, no
/// split), Viterbi over Unicode scalars with unknown characters falling back to
/// their UTF-8 bytes (`<0xNN>`), then `<s> … </s>`. Checked against the Python
/// tokenizer on ~1,000 lines (see FeelingTokenizerTests).
public nonisolated struct FeelingTokenizer: Sendable {
    public enum LoadError: Error, Sendable { case notUnigram, malformed(String) }

    private struct Piece: Sendable { let id: Int32; let score: Double }
    private let pieces: [String: Piece]
    private let maxPieceScalars: Int
    private let unknownScore: Double
    private let unknownID: Int32
    private let byteIDs: [Int32?]
    public let beginID: Int32
    public let endID: Int32

    public init(tokenizerJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any] else { throw LoadError.malformed("no model") }
        guard model["type"] as? String == "Unigram" else { throw LoadError.notUnigram }
        guard let vocab = model["vocab"] as? [[Any]], !vocab.isEmpty else { throw LoadError.malformed("no vocab") }
        var pieces: [String: Piece] = [:]
        pieces.reserveCapacity(vocab.count)
        var minScore = Double.greatestFiniteMagnitude
        var longest = 1
        for (index, entry) in vocab.enumerated() {
            guard entry.count == 2, let piece = entry[0] as? String, let score = (entry[1] as? NSNumber)?.doubleValue else {
                throw LoadError.malformed("vocab entry \(index)")
            }
            // First occurrence wins, as in tokenizers' token_to_ids.
            if pieces[piece] == nil { pieces[piece] = Piece(id: Int32(index), score: score) }
            minScore = min(minScore, score)
            longest = max(longest, piece.unicodeScalars.count)
        }
        self.pieces = pieces
        maxPieceScalars = longest
        unknownScore = minScore - 10 // tokenizers' K_UNK_PENALTY
        unknownID = Int32((model["unk_id"] as? NSNumber)?.intValue ?? 0)
        byteIDs = (0..<256).map { byte in pieces[String(format: "<0x%02X>", byte)]?.id }
        let added = (root["added_tokens"] as? [[String: Any]]) ?? []
        func special(_ text: String) -> Int32? {
            if let token = added.first(where: { $0["content"] as? String == text }), let id = token["id"] as? NSNumber { return id.int32Value }
            return pieces[text]?.id
        }
        guard let begin = special("<s>"), let end = special("</s>") else { throw LoadError.malformed("no <s> or </s>") }
        beginID = begin
        endID = end
    }

    /// Token ids for `text`, wrapped in `<s> … </s>`, at most `maxTokens` long.
    public func encode(_ text: String, maxTokens: Int = 128) -> [Int32] {
        var ids = pieceIDs(text)
        let room = max(0, maxTokens - 2)
        if ids.count > room { ids.removeLast(ids.count - room) }
        return [beginID] + ids + [endID]
    }

    /// The Viterbi segmentation of `text` into vocabulary ids (no specials).
    public func pieceIDs(_ text: String) -> [Int32] {
        let scalars = Array(text.replacingOccurrences(of: " ", with: "\u{2581}").unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        let count = scalars.count
        // best[i]: best path covering scalars[0..<i]
        var bestScore = [Double](repeating: 0, count: count + 1)
        var bestStart = [Int](repeating: -1, count: count + 1)
        var bestID = [Int32](repeating: 0, count: count + 1)
        bestStart[0] = 0
        var view = String.UnicodeScalarView()
        for start in 0..<count {
            let base = bestScore[start]
            var hasSingle = false
            view.removeAll(keepingCapacity: true)
            for end in (start + 1)...min(count, start + maxPieceScalars) {
                view.append(scalars[end - 1])
                guard let piece = pieces[String(view)] else { continue }
                let candidate = base + piece.score
                if bestStart[end] < 0 || candidate > bestScore[end] {
                    bestScore[end] = candidate; bestStart[end] = start; bestID[end] = piece.id
                }
                if end == start + 1 { hasSingle = true }
            }
            if !hasSingle {
                let candidate = base + unknownScore
                if bestStart[start + 1] < 0 || candidate > bestScore[start + 1] {
                    bestScore[start + 1] = candidate; bestStart[start + 1] = start; bestID[start + 1] = unknownID
                }
            }
        }
        var spans: [(start: Int, end: Int, id: Int32)] = []
        var end = count
        while end > 0 {
            let start = bestStart[end]
            spans.append((start, end, bestID[end]))
            end = start
        }
        var ids: [Int32] = []
        for span in spans.reversed() {
            guard span.id == unknownID else { ids.append(span.id); continue }
            // Byte fallback: an unknown character becomes its UTF-8 bytes.
            var piece = String.UnicodeScalarView()
            piece.append(contentsOf: scalars[span.start..<span.end])
            let bytes = Array(String(piece).utf8)
            if bytes.allSatisfy({ byteIDs[Int($0)] != nil }) {
                ids += bytes.map { byteIDs[Int($0)]! }
            } else {
                ids.append(unknownID)
            }
        }
        return ids
    }
}
