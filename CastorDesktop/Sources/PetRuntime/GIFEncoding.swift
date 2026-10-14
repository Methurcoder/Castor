import Foundation

/// Independent GIF89a writer. Palette reduction and LZW run locally; no helpers.
/// Format reference: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
struct GIFStream {
    private(set) var data: Data
    let width: Int, height: Int
    init(width: Int, height: Int) {
        self.width = width; self.height = height
        data = Data("GIF89a".utf8)
        word(width); word(height)
        data.append(contentsOf: [0xF0, 0, 0, 0, 0, 0, 255, 255, 255]) // two global colours
        data.append(contentsOf: [0x21, 0xFF, 11])
        data.append(Data("NETSCAPE2.0".utf8))
        data.append(contentsOf: [3, 1, 0, 0, 0]) // repeat forever
    }
    private mutating func word(_ value: Int) {
        data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    @discardableResult mutating func append(_ canvas: PetCanvas, delay: Int) -> PetCanvas {
        let quantized = Self.quantize(canvas)
        data.append(contentsOf: [0x21, 0xF9, 4, 4]) // disposal=keep; all pixels opaque
        word(delay); data.append(contentsOf: [0, 0, 0x2C])
        word(0); word(0); word(width); word(height)
        data.append(0x87); data.append(contentsOf: quantized.palette) // local 256-colour palette
        data.append(8)
        let compressed = Self.lzw(quantized.indices)
        for offset in stride(from: 0, to: compressed.count, by: 255) {
            let end = min(offset + 255, compressed.count)
            data.append(UInt8(end - offset)); data.append(contentsOf: compressed[offset..<end])
        }
        data.append(0)
        var preview = PetCanvas(width: width, height: height)
        for (i, index) in quantized.indices.enumerated() {
            let p = Int(index) * 3
            preview.bgra[i * 4] = quantized.palette[p + 2]
            preview.bgra[i * 4 + 1] = quantized.palette[p + 1]
            preview.bgra[i * 4 + 2] = quantized.palette[p]
            preview.bgra[i * 4 + 3] = 255
        }
        return preview
    }
    mutating func finish() -> Data { data.append(0x3B); return data }

    /// Weighted median cut of the actual RGB colours. No coarse histogram is
    /// used, so an image with <=256 colours is preserved exactly.
    private static func quantize(_ canvas: PetCanvas) -> (palette: [UInt8], indices: [UInt8]) {
        func color(_ i: Int) -> Int { Int(canvas.bgra[i + 2]) << 16 | Int(canvas.bgra[i + 1]) << 8 | Int(canvas.bgra[i]) }
        var count: [Int: Int] = [:]
        for i in stride(from: 0, to: canvas.bgra.count, by: 4) { count[color(i), default: 0] += 1 }
        func component(_ rgb: Int, _ axis: Int) -> Int { (rgb >> ((2 - axis) * 8)) & 255 }
        func dimensions(_ colors: [Int]) -> (axis: Int, range: Int, population: Int) {
            var minV = SIMD3<Int>(repeating: 255), maxV = SIMD3<Int>(repeating: 0), population = 0
            for c in colors {
                population += count[c]!
                for axis in 0..<3 { let v = component(c, axis); minV[axis] = min(minV[axis], v); maxV[axis] = max(maxV[axis], v) }
            }
            var axis = 0
            for a in 1..<3 where maxV[a] - minV[a] > maxV[axis] - minV[axis] { axis = a }
            return (axis, maxV[axis] - minV[axis], population)
        }
        var boxes = [count.keys.sorted()]
        while boxes.count < 256 {
            var selected: Int?, best = -1
            for i in boxes.indices where boxes[i].count > 1 {
                let d = dimensions(boxes[i]); let score = d.range * d.population
                if score > best { selected = i; best = score }
            }
            guard let selected else { break }
            let d = dimensions(boxes[selected])
            let ordered = boxes[selected].sorted { a, b in
                let ca = component(a, d.axis), cb = component(b, d.axis)
                return ca == cb ? a < b : ca < cb
            }
            var cumulative = 0, split = 1
            for i in 0..<(ordered.count - 1) {
                cumulative += count[ordered[i]]!; split = i + 1
                if cumulative * 2 >= d.population { break }
            }
            boxes[selected] = Array(ordered[..<split]); boxes.append(Array(ordered[split...]))
        }
        var palette = [UInt8](repeating: 0, count: 768), lookup: [Int: UInt8] = [:]
        for (index, colors) in boxes.enumerated() {
            var sum = SIMD3<Int>.zero, population = 0
            for c in colors {
                let n = count[c]!; population += n; lookup[c] = UInt8(index)
                sum &+= SIMD3(component(c, 0), component(c, 1), component(c, 2)) &* SIMD3(repeating: n)
            }
            if population > 0 { for c in 0..<3 { palette[index * 3 + c] = UInt8((sum[c] + population / 2) / population) } }
        }
        return (palette, stride(from: 0, to: canvas.bgra.count, by: 4).map { lookup[color($0)]! })
    }

    static func lzw(_ indices: [UInt8]) -> [UInt8] {
        var dictionary: [Int: Int] = [:], next = 258
        var bytes: [UInt8] = [], buffer: UInt32 = 0, bufferedBits = 0
        var width = 9, decoderNext = 258, hasPrevious = false
        // Grow the bit width at the decoder's boundary, which trails insertion
        // by one code. Tracking emission avoids the classic GIF off-by-one.
        func emit(_ code: Int) {
            buffer |= UInt32(code) << UInt32(bufferedBits); bufferedBits += width
            while bufferedBits >= 8 { bytes.append(UInt8(truncatingIfNeeded: buffer)); buffer >>= 8; bufferedBits -= 8 }
            if code == 256 { width = 9; decoderNext = 258; hasPrevious = false }
            else if code != 257 {
                if hasPrevious, decoderNext < 4096 {
                    decoderNext += 1
                    if decoderNext == 1 << width, width < 12 { width += 1 }
                }
                hasPrevious = true
            }
        }
        emit(256)
        if let first = indices.first {
            var prefix = Int(first)
            for byte in indices.dropFirst() {
                let key = (prefix << 8) | Int(byte)
                if let known = dictionary[key] { prefix = known }
                else {
                    emit(prefix)
                    if next < 4096 { dictionary[key] = next; next += 1 }
                    else { emit(256); dictionary.removeAll(keepingCapacity: true); next = 258 }
                    prefix = Int(byte)
                }
            }
            emit(prefix)
        }
        emit(257)
        if bufferedBits > 0 { bytes.append(UInt8(truncatingIfNeeded: buffer)) }
        return bytes
    }
}
