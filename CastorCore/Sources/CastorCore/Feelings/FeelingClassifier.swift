import Foundation

/// Runs the exported feeling model on one line's token ids (`<s> … </s>`) and
/// returns one probability per feeling, in the order of `feelings.json`.
/// Core ML on the Mac and ONNX Runtime on Windows implement it.
public nonisolated protocol FeelingModelRunning: Sendable {
    func probabilities(tokenIDs: [Int32]) throws -> [Float]
}

/// What a character feels while saying one line: a mix over the nine feelings.
public nonisolated struct FeelingEstimate: Sendable, Equatable {
    public let probabilities: [OllamaSpeechEmotion: Double]

    public init(probabilities: [OllamaSpeechEmotion: Double]) { self.probabilities = probabilities }

    /// The most likely feeling.
    public var emotion: OllamaSpeechEmotion {
        probabilities.max { a, b in a.value < b.value || (a.value == b.value && a.key.rawValue > b.key.rawValue) }?.key ?? .neutral
    }
    /// How clearly that feeling stands out, 0...1 (its probability).
    public var confidence: Double { probabilities[emotion] ?? 0 }

    /// Speech metadata for this line. The model reads the feeling; the
    /// language model's own intensity, pace and note are kept when it gave them.
    public func speechMetadata(keeping base: OllamaSpeechMetadata = .fallback) -> OllamaSpeechMetadata {
        // A clear reading speaks more strongly; an even mix stays mild.
        let intensity = emotion == .neutral ? min(base.intensity, 0.5) : max(0.35, min(1, 0.25 + confidence * 0.8))
        return OllamaSpeechMetadata(emotion: emotion, intensity: intensity,
                                    speakingRate: base.speakingRate, performanceNote: base.performanceNote)
    }
}

/// The distilled feeling classifier (Ruri v3 70m, Apache-2.0): tokenizer,
/// feeling order and a platform runner. Load it with `FeelingModelFiles`.
public nonisolated final class FeelingClassifier: Sendable {
    public let tokenizer: FeelingTokenizer
    public let feelings: [OllamaSpeechEmotion]
    public let maxTokens: Int
    private let runner: FeelingModelRunning

    public init(tokenizer: FeelingTokenizer, feelings: [OllamaSpeechEmotion], maxTokens: Int = 128, runner: FeelingModelRunning) {
        self.tokenizer = tokenizer
        self.feelings = feelings
        self.maxTokens = maxTokens
        self.runner = runner
    }

    /// The text the model was trained on: the reply alone, or with what the user said.
    public static func modelInput(reply: String, user: String?) -> String {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user = user?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty else { return "キャラ: \(reply)" }
        return "ユーザー: \(user)\nキャラ: \(reply)"
    }

    /// The feeling mix for one line the character says, or nil if the model fails.
    public func estimate(reply: String, user: String? = nil) -> FeelingEstimate? {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ids = tokenizer.encode(Self.modelInput(reply: reply, user: user), maxTokens: maxTokens)
        guard let values = try? runner.probabilities(tokenIDs: ids), values.count == feelings.count,
              values.allSatisfy({ $0.isFinite }) else { return nil }
        var probabilities: [OllamaSpeechEmotion: Double] = [:]
        for (feeling, value) in zip(feelings, values) { probabilities[feeling, default: 0] += Double(value) }
        return FeelingEstimate(probabilities: probabilities)
    }
}

/// Where the optional feeling model lives and what it contains:
/// `feelings.json`, `tokenizer.json` and the platform model
/// (`CastorFeelings.mlpackage` / `.mlmodelc` on the Mac, `CastorFeelings.onnx` on Windows).
public nonisolated struct FeelingModelFiles: Sendable {
    public static let folderName = "Feelings"
    public static let environmentKey = "CASTOR_FEELINGS_DIR"

    public let directory: URL
    public let feelings: [OllamaSpeechEmotion]
    public let maxTokens: Int
    public let tokenizer: FeelingTokenizer

    /// Folders searched in order: `$CASTOR_FEELINGS_DIR`; the version Castor Setup
    /// selected under `componentRoot`; then the hand-placed
    /// `<Application Support>/Castor/Models/Feelings` (Mac) or
    /// `%LOCALAPPDATA%\Castor\Models\Feelings` (Windows).
    public static func searchDirectories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var directories: [URL] = []
        if let path = environment[environmentKey], !path.isEmpty { directories.append(URL(fileURLWithPath: path)) }
        if let root = componentRoot(environment: environment), let installed = installedComponent(root: root) {
            directories.append(installed)
        }
        #if os(Windows)
        if let local = environment["LOCALAPPDATA"], !local.isEmpty {
            directories.append(URL(fileURLWithPath: local).appendingPathComponent("Castor/Models/\(folderName)"))
        }
        #else
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(support.appendingPathComponent("Castor/Models/\(folderName)"))
        }
        #endif
        return directories
    }

    /// Where Castor Setup installs the optional Feelings component:
    /// `~/Library/Application Support/Castor/Versions/CastorHelpers/Feelings` (Mac,
    /// the real home even inside the sandbox) or
    /// `%LOCALAPPDATA%\Programs\Castor\CastorHelpers\Feelings` (Windows).
    public static func componentRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        #if os(Windows)
        guard let local = environment["LOCALAPPDATA"], !local.isEmpty else { return nil }
        return URL(fileURLWithPath: local).appendingPathComponent("Programs/Castor/CastorHelpers/\(folderName)", isDirectory: true)
        #elseif os(macOS)
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Application Support/Castor/Versions/CastorHelpers/\(folderName)", isDirectory: true)
        #else
        return nil
        #endif
    }

    /// The version folder Castor Setup selected under `root`, read from its
    /// receipt (`.CastorInstaller/CurrentInstall.json`, or the older
    /// `CurrentInstall.json`). Nil when nothing is installed or the receipt
    /// names anything but a plain `CastorFeelings-…` folder.
    public static func installedComponent(root: URL) -> URL? {
        struct Receipt: Decodable { let folder: String }
        let receipts = [root.appendingPathComponent(".CastorInstaller/CurrentInstall.json"), root.appendingPathComponent("CurrentInstall.json")]
        guard let file = receipts.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: file), data.count <= 4_194_304,
              let folder = (try? JSONDecoder().decode(Receipt.self, from: data))?.folder,
              folder.hasPrefix("CastorFeelings-"), !folder.contains("/"), !folder.contains("\\"), !folder.contains(":"), !folder.contains("..")
        else { return nil }
        return root.appendingPathComponent(folder, isDirectory: true)
    }

    /// The first folder holding a readable model description, or nil.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> FeelingModelFiles? {
        for directory in searchDirectories(environment: environment) {
            if let files = try? FeelingModelFiles(directory: directory) { return files }
        }
        return nil
    }

    public init(directory: URL) throws {
        struct Description: Decodable { let feelings: [String]; let max_tokens: Int? }
        let description = try JSONDecoder().decode(Description.self, from: Data(contentsOf: directory.appendingPathComponent("feelings.json")))
        let feelings = description.feelings.compactMap(OllamaSpeechEmotion.init(rawValue:))
        guard feelings.count == description.feelings.count, !feelings.isEmpty else {
            throw FeelingTokenizer.LoadError.malformed("feelings.json names a feeling Castor does not know")
        }
        self.directory = directory
        self.feelings = feelings
        maxTokens = description.max_tokens ?? 128
        tokenizer = try FeelingTokenizer(tokenizerJSON: Data(contentsOf: directory.appendingPathComponent("tokenizer.json")))
    }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func classifier(runner: FeelingModelRunning) -> FeelingClassifier {
        FeelingClassifier(tokenizer: tokenizer, feelings: feelings, maxTokens: maxTokens, runner: runner)
    }
}

public nonisolated extension OllamaSpeechEmotion {
    /// A short English acting direction for instruction-following TTS (Qwen3-TTS).
    var voiceDirection: String {
        switch self {
        case .neutral: "Speak naturally and conversationally."
        case .happy: "Sound genuinely happy, warm, and lightly animated."
        case .sad: "Sound subdued and tender without becoming theatrical."
        case .angry: "Sound controlled but clearly annoyed. Do not shout."
        case .surprised: "Express mild surprise through intonation only."
        case .thoughtful: "Sound reflective, with small pauses and careful phrasing."
        case .embarrassed: "Sound shy and slightly flustered, with gentle hesitation."
        case .frustrated: "Sound vexed at losing, with a little determined edge. Do not sound tearful."
        case .jealous: "Sound a little sulky and jealous, pouting but still endearing."
        }
    }
}
