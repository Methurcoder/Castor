import ArilsRigPortable
import Foundation
import Testing
@testable import PetRuntime
#if canImport(ImageIO)
import ImageIO
#endif

@Test func gifEncodesVariableCodeWidthsAndIndependentPalettes() throws {
    var canvas = PetCanvas(width: 256, height: 256)
    var generator: UInt32 = 0x31415926
    for i in stride(from: 0, to: canvas.bgra.count, by: 4) {
        generator ^= generator << 13; generator ^= generator >> 17; generator ^= generator << 5
        let shade = UInt8(truncatingIfNeeded: generator)
        canvas.bgra[i] = shade; canvas.bgra[i + 1] = shade; canvas.bgra[i + 2] = shade; canvas.bgra[i + 3] = 255
    }
    let original = canvas
    var writer = GIFStream(width: 256, height: 256)
    writer.append(canvas, delay: 5)
    for i in stride(from: 0, to: canvas.bgra.count, by: 4) { for c in 0..<3 { canvas.bgra[i + c] = 255 - canvas.bgra[i + c] } }
    writer.append(canvas, delay: 5)
    let gif = writer.finish()
    #expect(gif.prefix(6) == Data("GIF89a".utf8) && gif.last == 0x3B)
#if canImport(ImageIO)
    let decoded = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
    #expect(CGImageSourceGetCount(decoded) == 2)
    for (index, reference) in [original, canvas].enumerated() {
        let image = try #require(CGImageSourceCreateImageAtIndex(decoded, index, nil))
        let bitmap = try #require(Bitmap(image: image))
        for i in stride(from: 0, to: bitmap.pixels.count, by: 4) {
            #expect(bitmap.pixels[i] == reference.bgra[i + 2])
            #expect(bitmap.pixels[i + 1] == reference.bgra[i + 1])
            #expect(bitmap.pixels[i + 2] == reference.bgra[i])
        }
    }
#endif
    if let folder = ProcessInfo.processInfo.environment["CASTOR_GIF_VALIDATION_DIR"] {
        let root = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try gif.write(to: root.appendingPathComponent("lzw-palettes.gif"), options: .atomic)
        try Data(original.bgra).write(to: root.appendingPathComponent("frame-0.bgra"), options: .atomic)
        try Data(canvas.bgra).write(to: root.appendingPathComponent("frame-1.bgra"), options: .atomic)
    }
}

@Test func gifShareURLContainsNoAutomaticMediaUpload() {
    let components = URLComponents(url: PetGIFClip.sharingURL(), resolvingAgainstBaseURL: false)
    #expect(components?.host == "x.com")
    #expect(components?.queryItems?.contains { $0.name == "url" && $0.value == "https://github.com/Methurcoder/Castor" } == true)
    #expect(components?.queryItems?.allSatisfy { $0.name == "url" || $0.name == "text" } == true)
}
