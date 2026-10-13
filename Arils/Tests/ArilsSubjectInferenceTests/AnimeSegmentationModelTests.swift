import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import ArilsSubjectInference

@Test func letterboxMatchesTheUpstreamPreprocessing() {
    // inference.get_mask: the long side becomes the input size, int() floors
    // the short side, and the image is centred with floor division.
    let tall = AnimeSegmentationModel.Letterbox(sourceWidth: 1024, sourceHeight: 1536)
    #expect(tall == .init(top: 0, left: 171, height: 1024, width: 682))
    let wide = AnimeSegmentationModel.Letterbox(sourceWidth: 1586, sourceHeight: 992)
    #expect(wide == .init(top: 192, left: 0, height: 640, width: 1024))
    let square = AnimeSegmentationModel.Letterbox(sourceWidth: 300, sourceHeight: 300)
    #expect(square == .init(top: 0, left: 0, height: 1024, width: 1024))
}

extension AnimeSegmentationModel.Letterbox {
    init(top: Int, left: Int, height: Int, width: Int) {
        self.init(sourceWidth: 1, sourceHeight: 1)
        self.top = top
        self.left = left
        self.height = height
        self.width = width
    }
}

@Test func cropResizeIgnoresThePaddingAndKeepsEdges() {
    // A 4x4 square with a 2x4 letterbox band in rows 1...2; padding is 9 so
    // any leak into the result would be visible.
    var values = [Float](repeating: 9, count: 16)
    for x in 0..<4 {
        values[1 * 4 + x] = 0
        values[2 * 4 + x] = 1
    }
    let box = AnimeSegmentationModel.Letterbox(top: 1, left: 0, height: 2, width: 4)
    let resized = AnimeSegmentationModel.resizeCrop(values, size: 4, box: box, toWidth: 8, height: 4)
    #expect(resized.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(resized[0] == 0)          // top row comes from the band's top row
    #expect(resized[3 * 8 + 7] == 1)  // bottom row from its bottom row
}

@Test func modelSegmentsADatasetCharacterWhenAvailable() throws {
    guard let model = AnimeSegmentationModel.shared else { return } // generated, not checked in
    let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Arils_Dataset/images/012(1)_pastfailure.png")
    guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return } // dataset is local-only
    let probability = try model.probability(for: image)
    #expect(probability.count == image.width * image.height)
    func at(_ x: Int, _ y: Int) -> Float { probability[y * image.width + x] }
    #expect(at(5, 5) < 0.05)                       // background corner
    #expect(at(image.width - 5, image.height - 5) < 0.05)
    #expect(at(512, 280) > 0.95)                   // face
    #expect(at(512, 700) > 0.95)                   // dress
}
