import ArilsCore
import ArilsPlayer
import Foundation
import PetRuntime
import Testing

private func illustration(opaque: Bool = false) throws -> PortableRigImage {
    let w = 96, h = 128
    var rgba = [UInt8](repeating: opaque ? 255 : 0, count: w * h * 4)
    for y in 8..<120 { for x in 18..<78 {
        let i = (y * w + x) * 4
        rgba[i] = 210; rgba[i + 1] = 80; rgba[i + 2] = 110; rgba[i + 3] = 255
    }}
    return try PortableRigImage(width: w, height: h, rgba: rgba)
}

@Test func portablePNGPreservesStraightAlphaAndCrossesDeflateBlocks() throws {
    let w = 198, h = 103
    let pixels = (0..<(w * h * 4)).map { UInt8(truncatingIfNeeded: $0 * 37) }
    let image = try PortableRigImage(width: w, height: h, rgba: pixels)
    let decoded = try PortableRigImage(png: image.pngData())
    #expect(decoded.width == w && decoded.height == h)
    #expect(decoded.rgba == pixels)
}

@Test func portablePreparationPreservesAlphaAndRequiresMarkerReview() throws {
    let image = try illustration()
    let draft = try PortableRigBuilder.prepare(image)
    #expect(draft.image.rgba == image.rgba)
    #expect(!draft.warnings.isEmpty)
    try draft.layout.validate(width: image.width, height: image.height)
    #expect(draft.layout.eyeLeft.midX < draft.layout.eyeRight.midX)
}

@Test func portableBackgroundRemovalIsConnectedToImageEdges() throws {
    var image = try illustration(opaque: true)
    // A white region enclosed by the subject must survive the edge flood fill.
    var pixels = image.rgba
    let enclosed = (60 * image.width + 48) * 4
    for c in 0..<3 { pixels[enclosed + c] = 255 }
    image = try PortableRigImage(width: image.width, height: image.height, rgba: pixels)
    let draft = try PortableRigBuilder.prepare(image)
    #expect(draft.image.rgba[3] == 0)
    #expect(draft.image.rgba[enclosed + 3] == 255)
    #expect(image.rgba[3] == 255)
}

@Test func portableRigRejectsUnboundedAndMisorderedMarkers() throws {
    let image = try illustration()
    let draft = try PortableRigBuilder.prepare(image)
    var layout = draft.layout
    layout.head.origin.x = -.infinity
    #expect(throws: (any Error).self) { try PortableRigBuilder.build(image: image, layout: layout) }
    layout = draft.layout
    swap(&layout.eyeLeft, &layout.eyeRight)
    #expect(throws: (any Error).self) { try PortableRigBuilder.build(image: image, layout: layout) }
}

@Test func portableRigRoundTripsThroughExistingArchiveAndSavedPetLoader() throws {
    let draft = try PortableRigBuilder.prepare(illustration())
    let archive = try PortableRigBuilder.build(image: draft.image, layout: draft.layout)
    let decoded = try AvatarArchive(data: archive.data())
    #expect(decoded.rig == archive.rig && decoded.texturePNGs == archive.texturePNGs)
    let saved = try PortableRigBuilder.savedPetData(image: draft.image, archive: archive)
    let loaded = try PetSource.load(data: saved)
    #expect(loaded.rig == archive.rig)
    struct MacFields: Decodable { let imageData: Data; let arilsArchiveData: Data }
    let fields = try JSONDecoder().decode(MacFields.self, from: saved)
    #expect(try PortableRigImage(png: fields.imageData).rgba == draft.image.rgba)
    #expect(try AvatarArchive(data: fields.arilsArchiveData).rig == archive.rig)
    let player = PetPlayer(archive: loaded)
    var first = PetCanvas(width: 96, height: 128), turned = first
    player.parameterOverrides = [.angleX: 0, .angleY: 0, .eyeLeftOpen: 1, .eyeRightOpen: 1]
    player.render(into: &first, time: 0)
    #expect(first.bgra.contains { $0 != 0 })
    player.parameterOverrides[.angleX] = 20
    player.render(into: &turned, time: 0)
    #expect(turned.bgra != first.bgra)
}

@Test func portableImageRejectsOversizedAndMalformedInputs() {
    #expect(throws: (any Error).self) { try PortableRigImage(width: 4097, height: 1, rgba: []) }
    #expect(throws: (any Error).self) { try PortableRigImage(width: 2, height: 2, rgba: [0]) }
    #expect(throws: (any Error).self) { try PortableRigImage(png: Data([1, 2, 3])) }
}

@Test func portableLibraryPreservesHistoryAndSelectionOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = PortablePetLibrary(root: root)
    let draft = try PortableRigBuilder.prepare(illustration())
    let archive = try PortableRigBuilder.build(image: draft.image, layout: draft.layout)
    let data = try PortableRigBuilder.savedPetData(image: draft.image, archive: archive)
    let first = try library.saveNew(data), second = try library.saveNew(data)
    #expect(first != second)
    #expect(try Data(contentsOf: first) == data)
    #expect(try library.selectedFile() == second)
    #expect(throws: (any Error).self) { try library.saveNew(Data([1, 2, 3])) }
    #expect(throws: (any Error).self) { try library.remember(root.appendingPathComponent("missing.json")) }
    #expect(try library.selectedFile() == second)
    #expect(try Data(contentsOf: second) == data)
}

@Test func portableLibraryListsNewestFirstDrawsThumbnailsAndKeepsTheShownPet() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = PortablePetLibrary(root: root)
    #expect(try library.entries().isEmpty)
    let draft = try PortableRigBuilder.prepare(illustration())
    let archive = try PortableRigBuilder.build(image: draft.image, layout: draft.layout)
    let data = try PortableRigBuilder.savedPetData(image: draft.image, archive: archive)
    let first = try library.saveNew(data)
    Thread.sleep(forTimeInterval: 0.05)
    let second = try library.saveNew(data)
    #expect(try library.entries().map(\.file.lastPathComponent) == [second, first].map(\.lastPathComponent))
    let png = try library.thumbnail(for: first)
    #expect(png.starts(with: [137, 80, 78, 71]))
    let picture = try PortableRigImage(png: png)
    #expect(picture.width == 208 && picture.height == 272)
    #expect(picture.rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
    #expect(try library.thumbnail(for: first) == png)          // cached beside the file
    #expect(try library.entries().count == 2)                   // the picture is not a pet
    var recycled: [String] = []
    #expect(throws: (any Error).self) { try library.remove(second) { recycled.append($0.lastPathComponent) } }   // shown on the desktop
    try library.remove(first) { recycled.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
    #expect(recycled == [first.lastPathComponent, library.thumbnailFile(for: first).lastPathComponent])
    #expect(try library.entries().map(\.file.lastPathComponent) == [second.lastPathComponent])
    #expect(throws: (any Error).self) { try library.remove(root.appendingPathComponent("elsewhere.json")) { _ in } }
}

@Test func portableLibraryNamesPetsBesideTheirFilesAndKeepsThemClean() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = PortablePetLibrary(root: root)
    let draft = try PortableRigBuilder.prepare(illustration())
    let data = try PortableRigBuilder.savedPetData(image: draft.image, archive: try PortableRigBuilder.build(image: draft.image, layout: draft.layout))
    let named = try library.saveNew(data, name: "  うちの子\n2  ")
    #expect(library.name(of: named) == "うちの子2")
    #expect(try Data(contentsOf: named) == data)                 // the pet file is untouched
    let unnamed = try library.saveNew(data)
    #expect(library.name(of: unnamed) == nil)
    try library.setName(String(repeating: "あ", count: 60), for: unnamed)
    #expect(library.name(of: unnamed)?.count == PortablePetLibrary.maximumNameLength)
    try library.setName("   ", for: unnamed)
    #expect(library.name(of: unnamed) == nil)
    #expect(try library.entries().count == 2)                    // name files are not pets
    #expect(throws: (any Error).self) { try library.setName("x", for: root.appendingPathComponent("elsewhere.json")) }
    var recycled: [String] = []
    try library.remove(named) { recycled.append($0.lastPathComponent); try FileManager.default.removeItem(at: $0) }
    #expect(recycled.contains(library.nameFile(for: named).lastPathComponent))
}
