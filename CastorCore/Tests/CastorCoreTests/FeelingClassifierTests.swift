import Foundation
import Testing
@testable import CastorCore

/// A tiny Unigram vocabulary in tokenizer.json form.
private func tinyTokenizer() throws -> FeelingTokenizer {
    var vocab: [[Any]] = [["<unk>", 0.0], ["<s>", 0.0], ["</s>", 0.0]]
    vocab += (0..<256).map { [String(format: "<0x%02X>", $0), 0.0] }
    vocab += [["▁", -2.0], ["あ", -3.0], ["い", -3.0], ["あい", -4.0], ["う", -3.0], ["あいう", -9.0], ["a", -1.0], ["b", -1.0], ["ab", -1.5]]
    let json: [String: Any] = [
        "added_tokens": [["id": 1, "content": "<s>"], ["id": 2, "content": "</s>"]],
        "model": ["type": "Unigram", "unk_id": 0, "byte_fallback": true, "vocab": vocab],
    ]
    return try FeelingTokenizer(tokenizerJSON: JSONSerialization.data(withJSONObject: json))
}

private func id(_ piece: String) -> Int32 {
    let base: [String: Int32] = ["▁": 259, "あ": 260, "い": 261, "あい": 262, "う": 263, "あいう": 264, "a": 265, "b": 266, "ab": 267]
    return base[piece]!
}

@Test func feelingTokenizerPicksTheBestSegmentation() throws {
    let tokenizer = try tinyTokenizer()
    // "あい" (-4) beats "あ"+"い" (-6); "あいう" (-9) loses to "あい"+"う" (-7).
    let first: [Int32] = [id("あい"), id("う")]
    let second: [Int32] = [id("ab"), id("▁"), id("a")]
    let third: [Int32] = [1, id("あ"), 2]
    #expect(tokenizer.pieceIDs("あいう") == first)
    #expect(tokenizer.pieceIDs("ab a") == second)
    #expect(tokenizer.encode("あ") == third)
    #expect(tokenizer.encode("") == [1, 2])
}

@Test func feelingTokenizerFallsBackToBytesForUnknownCharacters() throws {
    let tokenizer = try tinyTokenizer()
    // "猫" is not in the vocabulary: its three UTF-8 bytes E7 8C AB.
    let bytes: [Int32] = [0xE7, 0x8C, 0xAB].map { Int32(3 + $0) }
    let expected: [Int32] = bytes + [id("あ")]
    #expect(tokenizer.pieceIDs("猫あ") == expected)
    let long = tokenizer.encode(String(repeating: "a", count: 300), maxTokens: 10)
    #expect(long.count == 10 && long.first == 1 && long.last == 2)
}

/// Exact agreement with the Python `tokenizers` on ~1,000 lines, when the real
/// tokenizer is available (CASTOR_FEELINGS_DIR with tokenizer_fixtures.json).
@Test(.enabled(if: ProcessInfo.processInfo.environment["CASTOR_FEELINGS_DIR"].map {
    FileManager.default.fileExists(atPath: $0 + "/tokenizer_fixtures.json")
} ?? false))
func feelingTokenizerMatchesPythonTokenizers() throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CASTOR_FEELINGS_DIR"]!)
    let tokenizer = try FeelingTokenizer(tokenizerJSON: Data(contentsOf: directory.appendingPathComponent("tokenizer.json")))
    struct Fixture: Decodable { let text: String; let ids: [Int32] }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("tokenizer_fixtures.json")))
    var mismatches: [String] = []
    for fixture in fixtures where tokenizer.encode(fixture.text, maxTokens: 512) != fixture.ids { mismatches.append(fixture.text) }
    #expect(fixtures.count > 500)
    #expect(mismatches.isEmpty, "\(mismatches.count) differ, first: \(mismatches.prefix(3))")
}

private struct FixedRunner: FeelingModelRunning {
    let values: [Float]
    func probabilities(tokenIDs: [Int32]) throws -> [Float] { values }
}

@Test func feelingClassifierReadsTheMixAndKeepsTheLanguageModelPace() throws {
    let order: [OllamaSpeechEmotion] = [.neutral, .happy, .sad, .angry, .surprised, .thoughtful, .embarrassed, .frustrated, .jealous]
    let classifier = FeelingClassifier(tokenizer: try tinyTokenizer(), feelings: order,
                                       runner: FixedRunner(values: [0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.6, 0.05]))
    let estimate = try #require(classifier.estimate(reply: "あ", user: "い"))
    #expect(estimate.emotion == .frustrated)
    #expect(abs(estimate.confidence - 0.6) < 1e-6)
    let base = OllamaSpeechMetadata(emotion: .happy, intensity: 0.3, speakingRate: 1.2, performanceNote: "早口で")
    let speech = estimate.speechMetadata(keeping: base)
    #expect(speech.emotion == .frustrated && speech.speakingRate == 1.2 && speech.performanceNote == "早口で")
    #expect(speech.intensity > 0.6 && speech.intensity <= 1)
    #expect(classifier.estimate(reply: "  ") == nil)
    // A runner returning the wrong number of values is ignored, not trusted.
    let broken = FeelingClassifier(tokenizer: try tinyTokenizer(), feelings: order, runner: FixedRunner(values: [1]))
    #expect(broken.estimate(reply: "あ") == nil)
}

@Test func feelingModelInputMatchesTraining() {
    #expect(FeelingClassifier.modelInput(reply: " やった！ ", user: nil) == "キャラ: やった！")
    #expect(FeelingClassifier.modelInput(reply: "やった！", user: "勝ったよ") == "ユーザー: 勝ったよ\nキャラ: やった！")
}

@Test func feelingModelFilesNeedKnownFeelings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feelings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"feelings":["happy","grumpy"]}"#.utf8).write(to: directory.appendingPathComponent("feelings.json"))
    #expect(throws: (any Error).self) { try FeelingModelFiles(directory: directory) }
    let first = FeelingModelFiles.searchDirectories(environment: [FeelingModelFiles.environmentKey: directory.path]).first
    #expect(first?.standardizedFileURL.path == directory.standardizedFileURL.path)
}

@Test func feelingModelFilesFollowTheSetupReceipt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("feelings-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(FeelingModelFiles.installedComponent(root: root) == nil)
    let metadata = root.appendingPathComponent(".CastorInstaller")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let receipt = metadata.appendingPathComponent("CurrentInstall.json")
    try Data(#"{"version":"v1.0.1","platform":"macos_arm64","folder":"CastorFeelings-v1.0.1-macos_arm64","component":"Feelings"}"#.utf8).write(to: receipt)
    let installed = try #require(FeelingModelFiles.installedComponent(root: root))
    #expect(installed.lastPathComponent == "CastorFeelings-v1.0.1-macos_arm64")
    // A receipt pointing anywhere else is not followed.
    for folder in ["../Models", "Castor-v1.0.1-macos_arm64", "CastorFeelings-x/../../etc"] {
        try Data(#"{"folder":"\#(folder)"}"#.utf8).write(to: receipt)
        #expect(FeelingModelFiles.installedComponent(root: root) == nil)
    }
}
