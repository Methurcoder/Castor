#if canImport(CoreML)
import CoreML
import Foundation

/// `InferenceModel` on Core ML: the Mac runtime for the shared pipelines.
public final class CoreMLInferenceModel: InferenceModel, @unchecked Sendable {
    private let model: MLModel

    public init(contentsOf url: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    public func run(_ inputs: [String: InferenceTensor], outputs: [String]) throws -> [String: InferenceTensor] {
        var features: [String: Any] = [:]
        for (name, tensor) in inputs {
            let array = try MLMultiArray(shape: tensor.shape.map { NSNumber(value: $0) }, dataType: .float32)
            let strides = array.strides.map(\.intValue)
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            tensor.values.withUnsafeBufferPointer { values in
                Self.walk(tensor.shape, strides) { flat, offset in pointer[offset] = values[flat] }
            }
            features[name] = array
        }
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        var results: [String: InferenceTensor] = [:]
        for name in outputs {
            guard let array = prediction.featureValue(for: name)?.multiArrayValue else { throw InferenceError.missingOutput(name) }
            results[name] = Self.tensor(from: array)
        }
        return results
    }

    /// A model output copied into contiguous Float32, honouring the array's
    /// strides (GPU outputs are often row-padded) and its element type.
    static func tensor(from array: MLMultiArray) -> InferenceTensor {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        var out = [Float](repeating: 0, count: shape.reduce(1, *))
        out.withUnsafeMutableBufferPointer { out in
            func copy<T>(_ type: T.Type, _ convert: (T) -> Float) {
                let pointer = array.dataPointer.bindMemory(to: T.self, capacity: array.count)
                walk(shape, strides) { flat, offset in out[flat] = convert(pointer[offset]) }
            }
            switch array.dataType {
            case .float16:
                #if arch(arm64)
                copy(Float16.self) { Float($0) }
                #else
                // Swift Float16 is unavailable on Intel macOS; Core ML converts.
                var index = [Int](repeating: 0, count: shape.count)
                for flat in 0..<out.count {
                    out[flat] = array[index.map { NSNumber(value: $0) }].floatValue
                    var axis = shape.count - 1
                    while axis >= 0 {
                        index[axis] += 1
                        if index[axis] < shape[axis] { break }
                        index[axis] = 0
                        axis -= 1
                    }
                }
                #endif
            case .double: copy(Double.self) { Float($0) }
            default: copy(Float.self) { $0 }
            }
        }
        return InferenceTensor(shape: shape, values: out)
    }

    /// Visits a tensor of rank 1...4 in row-major order, passing the flat
    /// index and the element offset given `strides`.
    @inline(__always)
    static func walk(_ shape: [Int], _ strides: [Int], _ body: (Int, Int) -> Void) {
        precondition(shape.count >= 1 && shape.count <= 4 && strides.count == shape.count)
        let pad = 4 - shape.count
        let d = [Int](repeating: 1, count: pad) + shape
        let s = [Int](repeating: 0, count: pad) + strides
        var flat = 0
        for a in 0..<d[0] {
            for b in 0..<d[1] {
                for c in 0..<d[2] {
                    let base = a * s[0] + b * s[1] + c * s[2]
                    for e in 0..<d[3] {
                        body(flat, base + e * s[3])
                        flat += 1
                    }
                }
            }
        }
    }
}
#endif
