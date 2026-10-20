import CastorCore
import Foundation
import Testing
@testable import PetRuntime

/// End to end on ONNX Runtime (the Windows path), when both the runtime and the
/// exported feeling model are available: CASTOR_ONNXRUNTIME and CASTOR_FEELINGS_DIR
/// (with python_reference.json from the export).
@Test(.enabled(if: ["CASTOR_ONNXRUNTIME", "CASTOR_FEELINGS_DIR"].allSatisfy { ProcessInfo.processInfo.environment[$0]?.isEmpty == false }))
func onnxFeelingsMatchThePythonModel() throws {
    let classifier = try #require(DesktopFeelings.classifier)
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CASTOR_FEELINGS_DIR"]!)
    struct Reference: Decodable { let text: String; let probs: [Double] }
    let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: directory.appendingPathComponent("python_reference.json")))
    var largest = 0.0
    var sameTop = 0
    for reference in references {
        let estimate = try #require(classifier.estimate(reply: reference.text))
        let mine = classifier.feelings.map { estimate.probabilities[$0] ?? 0 }
        largest = max(largest, zip(mine, reference.probs).map { abs($0 - $1) }.max() ?? 0)
        let top = reference.probs.indices.max { reference.probs[$0] < reference.probs[$1] }!
        if classifier.feelings[top] == estimate.emotion { sameTop += 1 }
    }
    #expect(sameTop == references.count)
    #expect(largest < 0.001)
    let instruction = DesktopFeelings.instruction(base: "Speak gently.", reply: "あとちょっとで勝てたのに……！", user: "ゲームどうだった？")
    #expect(instruction.hasPrefix("Speak gently. ") && instruction.contains("vexed"))
}

@Test func voiceInstructionIsUnchangedWithoutTheModel() {
    #expect(DesktopFeelings.instruction(base: "Speak gently.", reply: "やった！", user: nil, classifier: nil) == "Speak gently.")
}
