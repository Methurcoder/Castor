import CoreML
import Foundation
import os
import CastorCore

/// The optional feeling classifier on the Mac (Core ML). When Castor Setup has
/// installed the Feelings component (or the files are in
/// `<Application Support>/Castor/Models/Feelings` or `$CASTOR_FEELINGS_DIR`),
/// each spoken line gets its own feeling; otherwise the language model's
/// `tts.emotion` is used as before. Setup ships the compiled model; a bare
/// package is compiled once and kept beside it when that folder is writable.
@Observable
final class PetFeelingReader {
    static let shared = PetFeelingReader()
    nonisolated private static let logger = Logger(subsystem: "dev.pomegranate.prototype", category: "Feelings")

    /// Ready to read lines; nil until loaded, or when the model is not installed.
    private(set) var classifier: FeelingClassifier?
    private var loading: Task<Void, Never>?

    /// Starts loading in the background once; cheap to call repeatedly.
    func loadIfAvailable() {
        guard classifier == nil, loading == nil else { return }
        loading = Task.detached(priority: .utility) {
            let loaded = await Self.load()
            await MainActor.run {
                self.classifier = loaded
                self.loading = nil
            }
        }
    }

    nonisolated private static func load() async -> FeelingClassifier? {
        guard let files = FeelingModelFiles.locate() else { return nil }
        do {
            let started = Date()
            let compiled = files.url("CastorFeelings.mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let package = files.url("CastorFeelings.mlpackage")
                guard FileManager.default.fileExists(atPath: package.path) else { return nil }
                let temporary = try await MLModel.compileModel(at: package)
                try? FileManager.default.removeItem(at: compiled)
                if (try? FileManager.default.moveItem(at: temporary, to: compiled)) == nil {
                    return try classifier(files: files, compiled: temporary, started: started)
                }
            }
            return try classifier(files: files, compiled: compiled, started: started)
        } catch {
            logger.notice("Feeling model unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func classifier(files: FeelingModelFiles, compiled: URL, started: Date) throws -> FeelingClassifier {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let classifier = files.classifier(runner: CoreMLFeelingRunner(model: model))
        logger.info("Feeling model ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        return classifier
    }
}

/// Runs `CastorFeelings.mlmodelc`: int32 `input_ids` and `attention_mask` [1, n]
/// (one unpadded line, so the mask is all ones) → `probabilities` [1, 9].
nonisolated struct CoreMLFeelingRunner: FeelingModelRunning, @unchecked Sendable {
    let model: MLModel

    func probabilities(tokenIDs: [Int32]) throws -> [Float] {
        let shape = [1, NSNumber(value: tokenIDs.count)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        let idPointer = ids.dataPointer.bindMemory(to: Int32.self, capacity: tokenIDs.count)
        let maskPointer = mask.dataPointer.bindMemory(to: Int32.self, capacity: tokenIDs.count)
        for (index, id) in tokenIDs.enumerated() {
            idPointer[index] = id
            maskPointer[index] = 1
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        guard let output = try model.prediction(from: input).featureValue(for: "probabilities")?.multiArrayValue else {
            throw CocoaError(.coderValueNotFound)
        }
        return (0..<output.count).map { output[$0].floatValue }
    }
}
