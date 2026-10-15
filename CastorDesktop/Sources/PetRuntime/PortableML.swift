import ArilsInference
import ArilsRigPortable
import COnnxRuntime
import Foundation

/// The Mac app's anime face and segmentation models on ONNX Runtime, for
/// hosts without Core ML. Same exports, same contract and the same Swift
/// steps between networks (`ArilsInference`), so a Windows rig starts from
/// the same face markers and cut-out as the Mac.
///
/// Everything here is optional: without the runtime library or the model
/// files every entry point returns nil and rigging keeps its non-ML path.
public enum PortableML {
    public static let runtimeEnvironmentKey = "CASTOR_ONNXRUNTIME"
    public static let modelsEnvironmentKey = "CASTOR_MODELS_DIR"

    #if os(Windows)
    static let runtimeFileName = "onnxruntime.dll"
    #elseif os(macOS)
    static let runtimeFileName = "libonnxruntime.dylib"
    #else
    static let runtimeFileName = "libonnxruntime.so"
    #endif

    static var executableDirectory: URL? { Bundle.main.executableURL?.deletingLastPathComponent() }

    /// Where model files are looked for, most specific first.
    static var modelSearchDirectories: [URL] {
        var directories: [URL] = []
        let environment = ProcessInfo.processInfo.environment
        if let path = environment[modelsEnvironmentKey], !path.isEmpty { directories.append(URL(fileURLWithPath: path)) }
        if let executable = executableDirectory { directories.append(executable.appendingPathComponent("models")) }
        #if os(Windows)
        if let local = environment["LOCALAPPDATA"], !local.isEmpty {
            directories.append(URL(fileURLWithPath: local).appendingPathComponent("Castor/Models"))
        }
        #else
        directories.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Castor/Models"))
        #endif
        return directories
    }

    static func modelURL(_ name: String) -> URL? {
        modelSearchDirectories.map { $0.appendingPathComponent(name + ".onnx") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var runtimeURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let path = environment[runtimeEnvironmentKey], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        if let executable = executableDirectory { candidates.append(executable.appendingPathComponent(runtimeFileName)) }
        candidates += modelSearchDirectories.map { $0.appendingPathComponent(runtimeFileName) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Why the models are unavailable, for the review screen (nil when ready).
    public private(set) nonisolated(unsafe) static var unavailableReason: String?

    private static let runtimeLoaded: Bool = {
        guard let url = runtimeURL else {
            unavailableReason = "ONNX Runtime (\(runtimeFileName)) was not found."
            return false
        }
        var error = [CChar](repeating: 0, count: 512)
        guard castor_onnx_load(url.path, &error, error.count) == 1 else {
            unavailableReason = "ONNX Runtime could not be loaded: " + String(cString: error)
            return false
        }
        return true
    }()

    static func open(_ name: String) -> OnnxInferenceModel? {
        guard runtimeLoaded else { return nil }
        guard let url = modelURL(name) else {
            unavailableReason = "\(name).onnx was not found."
            return nil
        }
        do {
            return try OnnxInferenceModel(contentsOf: url)
        } catch {
            unavailableReason = "\(name).onnx could not be opened: \(error)"
            return nil
        }
    }

    /// The face detector and landmark model, or nil when not installed.
    public static let face: AnimeFacePipeline? = {
        guard let features = open("AnimeFaceFeatures"),
              let boxHead = open("AnimeFaceBoxHead"),
              let landmarks = open("AnimeFaceLandmarks") else { return nil }
        return AnimeFacePipeline(features: features, boxHead: boxHead, landmarks: landmarks)
    }()

    /// The character segmentation model, or nil when not installed.
    public static let segmentation: AnimeSegmentationPipeline? = {
        open(AnimeSegmentationPipeline.modelName).map { AnimeSegmentationPipeline(model: $0) }
    }()
}

/// `InferenceModel` on ONNX Runtime (CPU).
public final class OnnxInferenceModel: InferenceModel, @unchecked Sendable {
    public struct RuntimeError: Error, CustomStringConvertible {
        public let description: String
    }

    private let session: OpaquePointer

    public init(contentsOf url: URL, threads: Int = 0) throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let session = castor_onnx_open(url.path, Int32(threads), &error, error.count) else {
            throw RuntimeError(description: String(cString: error))
        }
        self.session = session
    }

    deinit { castor_onnx_close(session) }

    public func run(_ inputs: [String: InferenceTensor], outputs: [String]) throws -> [String: InferenceTensor] {
        guard inputs.count == 1, let (inputName, tensor) = inputs.first else {
            throw RuntimeError(description: "exactly one input is supported")
        }
        let shape = tensor.shape.map(Int64.init)
        var outputPointers = [UnsafeMutablePointer<Float>?](repeating: nil, count: outputs.count)
        var outputShapes = [Int64](repeating: 0, count: outputs.count * 8)
        var outputRanks = [Int](repeating: 0, count: outputs.count)
        var error = [CChar](repeating: 0, count: 512)
        let names = outputs.map { strdup($0) }
        defer { names.forEach { free($0) } }
        let succeeded = names.map { UnsafePointer<CChar>($0) }.withUnsafeBufferPointer { namePointers in
            tensor.values.withUnsafeBufferPointer { values in
                castor_onnx_run(session, inputName, shape, shape.count, values.baseAddress,
                                namePointers.baseAddress, outputs.count,
                                &outputPointers, &outputShapes, &outputRanks, &error, error.count)
            }
        }
        defer { outputPointers.forEach { castor_onnx_free($0) } }
        guard succeeded == 1 else { throw RuntimeError(description: String(cString: error)) }
        var results: [String: InferenceTensor] = [:]
        for (i, name) in outputs.enumerated() {
            let dimensions = (0..<outputRanks[i]).map { Int(outputShapes[i * 8 + $0]) }
            let count = dimensions.reduce(1, *)
            guard let pointer = outputPointers[i] else { throw InferenceError.missingOutput(name) }
            results[name] = InferenceTensor(shape: dimensions, values: Array(UnsafeBufferPointer(start: pointer, count: count)))
        }
        return results
    }
}

/// Character cut-out from the anime segmentation model alone (there is no
/// Vision to fuse it with off the Mac). Not authoritative: estimated edges.
public struct OnnxSubjectMaskProvider: SubjectMaskProviding {
    public let isAuthoritativeAlpha = false

    public init() {}

    public func mask(for context: AnalysisContext) async -> FloatPlane? {
        await masks(for: context)?.analysis
    }

    public func masks(for context: AnalysisContext) async -> SubjectMaskSet? {
        guard let pipeline = PortableML.segmentation,
              let original = context.originalBitmap ?? context.decodedOriginalBitmap else { return nil }
        let box = AnimeSegmentationLetterbox(sourceWidth: original.width, sourceHeight: original.height)
        // Premultiplied RGB is the colour over black, as Core Graphics draws
        // it into the Mac model's opaque input.
        let letterboxed = AnimeSegmentationPipeline.downsample(
            rgba: original.pixels, width: original.width, height: original.height,
            toWidth: box.width, toHeight: box.height)
        guard let probability = try? pipeline.probability(letterboxed: letterboxed, box: box,
                                                          sourceWidth: original.width, sourceHeight: original.height),
              let extraction = SubjectMaskFusion.modelOnly(
                FloatPlane(width: original.width, height: original.height, values: probability)) else { return nil }
        return SubjectMaskSet(
            analysis: extraction.resized(width: context.analysis.width, height: context.analysis.height),
            extraction: extraction)
    }
}

/// Face layout from the anime face detector and 28 landmarks with the Mac's
/// calibration (`AnimeLandmarkLayout`).
public struct OnnxAnimeFaceEstimator: FaceLayoutEstimating {
    public static let sourceLabel = "Anime landmark model"
    public var estimatorSourceLabel: String { Self.sourceLabel }
    public var minimumDetectionScore: Float

    public init(minimumDetectionScore: Float = 0.5) {
        self.minimumDetectionScore = minimumDetectionScore
    }

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        guard let pipeline = PortableML.face,
              let original = context.originalBitmap ?? context.decodedOriginalBitmap else { return nil }
        // Transparency over white, as the detector was trained on illustrations.
        var rgb = [UInt8](repeating: 0, count: original.width * original.height * 3)
        for i in 0..<(original.width * original.height) {
            let a = original.pixels[i * 4 + 3]
            for c in 0..<3 { rgb[i * 3 + c] = UInt8(min(255, Int(original.pixels[i * 4 + c]) + 255 - Int(a))) }
        }
        guard let face = try? pipeline.detect(rgb: rgb, width: original.width, height: original.height) else { return nil }
        return AnimeLandmarkLayout.layout(
            width: CGFloat(original.width), height: CGFloat(original.height),
            faces: [.init(bbox: [face.box.x1, face.box.y1, face.box.x2, face.box.y2].map { CGFloat($0) },
                          score: face.score,
                          keypoints: face.keypoints.map { [CGFloat($0.x), CGFloat($0.y), CGFloat($0.score)] })],
            minimumDetectionScore: minimumDetectionScore)
    }

    public func calibratedConfidence(for layout: FaceLayout) -> Float {
        min(max(layout.confidence, 0), 1)
    }
}
