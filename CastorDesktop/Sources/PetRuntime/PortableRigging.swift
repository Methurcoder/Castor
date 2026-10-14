import ArilsCore
import ArilsPlayer
import CStbImage
import CPlatformImage
import Foundation

/// First portable rigging backend. All coordinates are image pixels, viewer's left/right.
/// This is an editable 2D warp prototype, not parity with Mac automatic depth/Quality rigs.
public struct PortableRigImage: Sendable {
    public let width: Int
    public let height: Int
    public internal(set) var rgba: [UInt8]

    public enum ImageError: LocalizedError {
        case invalidImage, imageTooLarge, invalidMarkers
        public var errorDescription: String? {
            switch self {
            case .invalidImage: return "画像を読み込めませんでした。見えるキャラクターが含まれる画像を選んでください。"
            case .imageTooLarge: return "4096×4096ピクセル以下、64MiB以下の画像を選んでください。"
            case .invalidMarkers: return "頭・目・口の範囲を確認してください。目と口は頭の内側、左右は見る側基準です。"
            }
        }
    }

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw ImageError.imageTooLarge }
        guard rgba.count == width * height * 4 else { throw ImageError.invalidImage }
        self.width = width; self.height = height; self.rgba = rgba
    }

    public init(png: Data) throws {
        guard !png.isEmpty, png.count <= 64 * 1024 * 1024 else { throw ImageError.imageTooLarge }
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0
        let valid = png.withUnsafeBytes { raw in
            stbi_info_from_memory(raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), &width, &height, &channels)
        }
        if valid == 0 {
            let info=png.withUnsafeBytes {raw in castor_image_info(raw.bindMemory(to:UInt8.self).baseAddress,raw.count,&width,&height)}
            guard info>0,width>0,height>0 else {throw ImageError.invalidImage}
            guard width<=4096,height<=4096 else {throw ImageError.imageTooLarge}
            var pixels=[UInt8](repeating:0,count:Int(width)*Int(height)*4)
            let decoded=png.withUnsafeBytes {raw in pixels.withUnsafeMutableBufferPointer {
                castor_image_decode(raw.bindMemory(to:UInt8.self).baseAddress,raw.count,$0.baseAddress,width,height)
            }}
            guard decoded>0 else {throw ImageError.invalidImage}
            try self.init(width:Int(width),height:Int(height),rgba:pixels);return
        }
        guard width > 0, height > 0 else { throw ImageError.invalidImage }
        guard width <= 4096, height <= 4096 else { throw ImageError.imageTooLarge }
        let decoded = png.withUnsafeBytes { raw in
            stbi_load_from_memory(raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), &width, &height, &channels, 4)
        }
        guard let decoded else { throw ImageError.invalidImage }
        defer { stbi_image_free(decoded) }
        try self.init(width: Int(width), height: Int(height),
                      rgba: Array(UnsafeBufferPointer(start: decoded, count: Int(width) * Int(height) * 4)))
    }

    public func pngData() -> Data { PortablePNG.encode(width: width, height: height, rgba: rgba) }
}

public struct PortableFaceLayout: Codable, Equatable, Sendable {
    public var head: CGRect
    public var eyeLeft: CGRect
    public var eyeRight: CGRect
    public var mouth: CGRect
    public var rectangles: [CGRect] { [head, eyeLeft, eyeRight, mouth] }

    public init(head: CGRect, eyeLeft: CGRect, eyeRight: CGRect, mouth: CGRect) {
        self.head = head; self.eyeLeft = eyeLeft; self.eyeRight = eyeRight; self.mouth = mouth
    }

    public func validate(width: Int, height: Int) throws {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard rectangles.allSatisfy({ rect in
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) &&
                rect.width >= 1 && rect.height >= 1 && bounds.contains(rect)
        }), [eyeLeft, eyeRight, mouth].allSatisfy(head.contains), eyeLeft.midX < eyeRight.midX else {
            throw PortableRigImage.ImageError.invalidMarkers
        }
    }
}

public struct PortableRigDraft: Sendable {
    public let image: PortableRigImage
    public let layout: PortableFaceLayout
    public let warnings: [String]
}

public enum PortableRigBuilder {
    /// No model download: preserve alpha, or flood-fill a uniform corner background.
    /// Face markers are a template and MUST be reviewed by the user.
    public static func prepare(_ source: PortableRigImage) throws -> PortableRigDraft {
        var image = source
        var warnings = ["顔マーカーはテンプレートです。位置を確認して補正してください。", "2D変形の試作です。Mac版の自動リギング・Qualityと同等の品質ではありません。"]
        if !stride(from: 3, to: image.rgba.count, by: 4).contains(where: { image.rgba[$0] < 250 }) {
            if removeUniformBackground(&image) { warnings.append("画像の端につながる単色背景を除去しました。") }
            else { warnings.append("背景を切り抜けませんでした。透過PNGを使うと改善します。") }
        }
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height { for x in 0..<image.width where image.rgba[(y * image.width + x) * 4 + 3] > 32 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }}
        guard maxX > minX, maxY > minY else { throw PortableRigImage.ImageError.invalidImage }
        let subject = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let head = CGRect(x: subject.minX + subject.width * 0.15, y: subject.minY,
                          width: subject.width * 0.7, height: subject.height * 0.34)
        func feature(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: head.minX + head.width * x, y: head.minY + head.height * y,
                   width: max(1, head.width * w), height: max(1, head.height * h))
        }
        let layout = PortableFaceLayout(head: head, eyeLeft: feature(0.2, 0.5, 0.2, 0.12),
                                        eyeRight: feature(0.6, 0.5, 0.2, 0.12), mouth: feature(0.4, 0.78, 0.2, 0.1))
        try layout.validate(width: image.width, height: image.height)
        return PortableRigDraft(image: image, layout: layout, warnings: warnings)
    }

    /// Uses existing Arils mesh/keyform operations and PNG/binary-plist archive format.
    /// One full-image surface avoids duplicate alpha/crop seams at the rest pose.
    public static func build(image: PortableRigImage, layout: PortableFaceLayout) throws -> AvatarArchive {
        try layout.validate(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let mesh = DeformableMesh.grid(rect: rect, columns: 48, rows: 64)
        func weight(_ p: SIMD2<Float>, in region: CGRect) -> Float {
            let x = (CGFloat(p.x) - region.midX) / (region.width * 0.7)
            let y = (CGFloat(p.y) - region.midY) / (region.height * 0.8)
            let d = Float(x * x + y * y)
            return max(0, 1 - d) * max(0, 1 - d)
        }
        func keys(xs: [Float], ys: [Float], displacement: (SIMD2<Float>, Float, Float) -> SIMD2<Float>) -> [WarpKeyformKey] {
            xs.flatMap { x in ys.map { y in
                WarpKeyformKey(parameterXValue: x, parameterYValue: y,
                               vertexOffsets: mesh.vertices.map { displacement($0, x, y) })
            }}
        }
        let turn = keys(xs: [-20, 0, 20], ys: [-6, 0, 6]) { p, x, y in
            let w = weight(p, in: layout.head)
            return SIMD2(x / 20 * Float(layout.head.width) * 0.05,
                         -y / 6 * Float(layout.head.height) * 0.035) * w
        }
        let blink = keys(xs: [0, 1], ys: [0, 1]) { p, left, right in
            let l = (Float(layout.eyeLeft.midY) - p.y) * (1 - left) * weight(p, in: layout.eyeLeft)
            let r = (Float(layout.eyeRight.midY) - p.y) * (1 - right) * weight(p, in: layout.eyeRight)
            return SIMD2(0, (l + r) * 0.85)
        }
        let gaze = keys(xs: [-1, 0, 1], ys: [-1, 0, 1]) { p, x, y in
            let w = weight(p, in: layout.eyeLeft) + weight(p, in: layout.eyeRight)
            return SIMD2(x * Float(layout.eyeLeft.width) * 0.04,
                         -y * Float(layout.eyeLeft.height) * 0.035) * w
        }
        let mouth = keys(xs: [0, 1], ys: [-1, 0, 1]) { p, openness, form in
            let w = weight(p, in: layout.mouth)
            return SIMD2((p.x - Float(layout.mouth.midX)) * form * 0.16,
                         (p.y - Float(layout.mouth.midY)) * openness * 0.6) * w
        }
        let body = AvatarPart(id: "portableSurface", kind: .body, rect: rect, pivot: SIMD2(0.5, 1), zOrder: 0,
            mesh: mesh, deformations: [
                .scale(parameter: .breath, pivot: SIMD2(0.5, 1), gainX: 0.004, gainY: 0.011),
                .rotate(parameter: .bodyAngleZ, pivot: SIMD2(0.5, 1), degreesPerUnit: 0.35),
                .rotate(parameter: .angleZ, pivot: SIMD2(0.5, 0.55), degreesPerUnit: 0.2),
                .translate(parameter: .bodyY, gainX: 0, gainY: -0.012),
                .scale(parameter: .touchSquash, pivot: SIMD2(0.5, 1), gainX: 0.01, gainY: -0.025),
                .warpKeyform(parameterX: .angleX, parameterY: .angleY, keys: turn),
                .warpKeyform(parameterX: .eyeLeftOpen, parameterY: .eyeRightOpen, keys: blink),
                .warpKeyform(parameterX: .eyeBallX, parameterY: .eyeBallY, keys: gaze),
                .warpKeyform(parameterX: .mouthOpen, parameterY: .mouthForm, keys: mouth)
            ])
        // Invisible semantic head locates the gaze/petting zone; it never duplicates pixels.
        let head = AvatarPart(id: "portableHeadZone", kind: .head, rect: layout.head, zOrder: 1,
                              opacity: 0, mesh: .grid(rect: layout.head, columns: 1, rows: 1))
        let rig = AvatarRig(imageWidth: image.width, imageHeight: image.height, parts: [body, head],
                            parameters: StandardParameters.all,
                            validatedPoseLimits: .init(minimumYawDegrees: -20, maximumYawDegrees: 20,
                                                       minimumPitchDegrees: -6, maximumPitchDegrees: 6))
        let empty = try PortableRigImage(width: 1, height: 1, rgba: [0, 0, 0, 0])
        return AvatarArchive(rig: rig, texturePNGs: [body.id: image.pngData(), head.id: empty.pngData()])
    }

    /// Compatible subset of macOS SavedPetCharacter; keep original image and optional fields.
    public static func savedPetData(image: PortableRigImage, archive: AvatarArchive) throws -> Data {
        struct Saved: Encodable { let imageData: Data; let arilsArchiveData: Data }
        return try JSONEncoder().encode(Saved(imageData: image.pngData(), arilsArchiveData: archive.data()))
    }

    private static func removeUniformBackground(_ image: inout PortableRigImage) -> Bool {
        let w = image.width, h = image.height
        let corners = [0, w - 1, (h - 1) * w, h * w - 1]
        let color = (0..<3).map { c in Int(image.rgba[corners[0] * 4 + c]) }
        guard corners.allSatisfy({ i in (0..<3).allSatisfy { abs(Int(image.rgba[i * 4 + $0]) - color[$0]) < 8 } }) else { return false }
        var seen = [Bool](repeating: false, count: w * h), queue: [Int] = []
        func enqueue(_ i: Int) {
            guard !seen[i] else { return }; seen[i] = true
            if (0..<3).allSatisfy({ abs(Int(image.rgba[i * 4 + $0]) - color[$0]) <= 18 }) { queue.append(i) }
        }
        for x in 0..<w { enqueue(x); enqueue((h - 1) * w + x) }
        for y in 0..<h { enqueue(y * w); enqueue(y * w + w - 1) }
        var cursor = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1; image.rgba[i * 4 + 3] = 0
            if i % w > 0 { enqueue(i - 1) }; if i % w < w - 1 { enqueue(i + 1) }
            if i >= w { enqueue(i - w) }; if i < w * (h - 1) { enqueue(i + w) }
        }
        return !queue.isEmpty
    }
}

/// Small dependency-free lossless PNG encoder: RGBA8, filter 0, stored DEFLATE.
/// Avoids requiring Python, an external encoder, or platform image frameworks.
private enum PortablePNG {
    static func encode(width: Int, height: Int, rgba: [UInt8]) -> Data {
        func bytes(_ n: UInt32) -> [UInt8] { [UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)] }
        let crcTable: [UInt32] = (0..<256).map { n in
            var c = UInt32(n); for _ in 0..<8 { c = c & 1 == 0 ? c >> 1 : (c >> 1) ^ 0xedb88320 }; return c
        }
        var result = Data([137, 80, 78, 71, 13, 10, 26, 10])
        func chunk(_ type: String, _ payload: [UInt8]) {
            let content = Array(type.utf8) + payload
            var crc: UInt32 = 0xffffffff
            for b in content { crc = crcTable[Int((crc ^ UInt32(b)) & 255)] ^ (crc >> 8) }
            result.append(contentsOf: bytes(UInt32(payload.count)) + content + bytes(crc ^ 0xffffffff))
        }
        chunk("IHDR", bytes(UInt32(width)) + bytes(UInt32(height)) + [8, 6, 0, 0, 0])
        var raw: [UInt8] = []; raw.reserveCapacity((width * 4 + 1) * height)
        for y in 0..<height { raw.append(0); raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)]) }
        var deflate: [UInt8] = [0x78, 0x01], offset = 0
        while offset < raw.count {
            let count = min(65535, raw.count - offset), inverse = UInt16(~UInt16(count))
            deflate.append(offset + count == raw.count ? 1 : 0)
            deflate.append(contentsOf: [UInt8(truncatingIfNeeded: count), UInt8(count >> 8), UInt8(truncatingIfNeeded: inverse), UInt8(inverse >> 8)])
            deflate.append(contentsOf: raw[offset..<(offset + count)]); offset += count
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for value in raw { a = (a + UInt32(value)) % 65521; b = (b + a) % 65521 }
        deflate.append(contentsOf: bytes((b << 16) | a))
        chunk("IDAT", deflate); chunk("IEND", [])
        return result
    }
}
