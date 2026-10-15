import Foundation

/// A dense Float32 tensor in row-major (C) order — the only thing that crosses
/// between the shared pipelines and a runtime.
public struct InferenceTensor: Sendable {
    public var shape: [Int]
    public var values: [Float]

    public init(shape: [Int], values: [Float]) {
        precondition(shape.reduce(1, *) == values.count, "tensor shape \(shape) does not match \(values.count) values")
        self.shape = shape
        self.values = values
    }

    public init(zeros shape: [Int]) {
        self.init(shape: shape, values: [Float](repeating: 0, count: shape.reduce(1, *)))
    }

    /// The last three dimensions of a (…, C, H, W) tensor.
    var chw: (channels: Int, height: Int, width: Int) {
        let rank = shape.count
        return (rank >= 3 ? shape[rank - 3] : 1, rank >= 2 ? shape[rank - 2] : 1, shape[rank - 1])
    }

    subscript(c: Int, y: Int, x: Int) -> Float {
        let (_, height, width) = chw
        return values[(c * height + y) * width + x]
    }

    /// Element (r, c) of an (N, K) tensor.
    subscript(row r: Int, column c: Int) -> Float {
        values[r * (shape.count > 1 ? shape[1] : 1) + c]
    }
}

/// One exported network with named Float32 inputs and outputs: Core ML on the
/// Mac, ONNX Runtime on Windows. Both are fed and read through
/// `InferenceTensor`, so the steps between networks are written once.
public protocol InferenceModel: AnyObject, Sendable {
    func run(_ inputs: [String: InferenceTensor], outputs: [String]) throws -> [String: InferenceTensor]
}

public enum InferenceError: Error, Sendable {
    case missingOutput(String)
    case unexpectedShape(String)
}

extension InferenceModel {
    func output(_ name: String, of results: [String: InferenceTensor]) throws -> InferenceTensor {
        guard let tensor = results[name] else { throw InferenceError.missingOutput(name) }
        return tensor
    }
}
