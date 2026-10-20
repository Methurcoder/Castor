import ArilsInference
import CastorCore
import Foundation

/// The optional feeling classifier on Windows (ONNX Runtime). Installed as
/// `%LOCALAPPDATA%\Castor\Models\Feelings` (`feelings.json`, `tokenizer.json`,
/// `CastorFeelings.onnx`); without it, or without ONNX Runtime, nothing changes.
public enum DesktopFeelings {
    /// Loaded on first use (about a second); nil when not installed.
    public static let classifier: FeelingClassifier? = {
        guard let files = FeelingModelFiles.locate(),
              let model = PortableML.openModel(at: files.url("CastorFeelings.onnx")) else { return nil }
        return files.classifier(runner: OnnxFeelingRunner(model: model))
    }()

    /// The voice instruction for a reply: the person's own instruction, plus how
    /// the character feels saying this reply when the classifier is installed.
    public static func instruction(base: String, reply: String, user: String?, classifier: FeelingClassifier? = classifier) -> String {
        guard let estimate = classifier?.estimate(reply: reply, user: user), estimate.emotion != .neutral else { return base }
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "" : base + " ") + estimate.emotion.voiceDirection
    }
}

/// Runs `CastorFeelings.onnx`: float32 `input_ids` [1, n] → `probabilities` [1, 9].
public struct OnnxFeelingRunner: FeelingModelRunning, @unchecked Sendable {
    let model: InferenceModel

    public init(model: InferenceModel) { self.model = model }

    public func probabilities(tokenIDs: [Int32]) throws -> [Float] {
        let input = InferenceTensor(shape: [1, tokenIDs.count], values: tokenIDs.map(Float.init))
        guard let output = try model.run(["input_ids": input], outputs: ["probabilities"])["probabilities"] else {
            throw InferenceError.missingOutput("probabilities")
        }
        return output.values
    }
}
