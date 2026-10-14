import ArilsCore
import ArilsPlayer
import Foundation
import PetRuntime
import Testing

/// Small deterministic PNG and rig: no personal pet, Apple frameworks or filesystem search.
func syntheticArchive() throws -> AvatarArchive {
    let rect = CGRect(x: 30, y: 25, width: 40, height: 60)
    let part = AvatarPart(id: "head", kind: .head, rect: rect, zOrder: 0,
        mesh: .grid(rect: rect, columns: 2, rows: 2),
        deformations: [.translate(parameter: .angleX, gainX: 0.01, gainY: 0)])
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4YCTXgIwZSBcAAMORHAGxU9i3AAAAAElFTkSuQmCC"))
    return AvatarArchive(rig: AvatarRig(imageWidth: 100, imageHeight: 120,
        parts: [part], parameters: StandardParameters.all), texturePNGs: ["head": png])
}

@Test func loadsBareSavedAndQualityArchives() throws {
    let archive = try syntheticArchive()
    let data = try archive.data()
    struct Saved: Encodable { var arilsArchiveData: Data?; var qualityArchiveData: Data? }
    let quality = try QualityAvatarArchive(front: archive, side: archive, sideDirection: .right,
        assessment: .init(sameCharacterConfidence: 0.5, faceReadabilityConfidence: 0.5, warnings: [])).data()
    let sources = [data,
        try JSONEncoder().encode(Saved(arilsArchiveData: data)),
        try JSONEncoder().encode(Saved(qualityArchiveData: quality))]
    for source in sources {
        let loaded = try PetSource.load(data: source)
        #expect(loaded.rig == archive.rig)
        #expect(loaded.texturePNGs == archive.texturePNGs)
    }
}

@Test func opacityAndPoseChangeTheRenderedPixels() throws {
    let player = PetPlayer(archive: try syntheticArchive())
    var normal = PetCanvas(width: 130, height: 170)
    var faint = normal
    var turned = normal
    player.parameterOverrides = [.angleX: 0]
    player.render(into: &normal, time: 0)
    player.render(into: &faint, time: 0, opacity: 0.22)
    let alphas = stride(from: 3, to: normal.bgra.count, by: 4)
    let normalAlpha = alphas.reduce(0) { $0 + Int(normal.bgra[$1]) }
    let faintAlpha = alphas.reduce(0) { $0 + Int(faint.bgra[$1]) }
    #expect(normalAlpha > 0)
    #expect(faintAlpha > 0 && faintAlpha < normalAlpha / 2)
    #expect(alphas.contains { normal.bgra[$0] > 0 && normal.bgra[$0] < 255 })
    player.parameterOverrides = [.angleX: 20]
    player.render(into: &turned, time: 0)
    #expect(normal.bgra != turned.bgra)
}

@Test func rejectsCorruptedSavedArchive() throws {
    struct Saved: Encodable { var arilsArchiveData: Data }
    let data = try JSONEncoder().encode(Saved(arilsArchiveData: Data([0, 1, 2])))
    #expect(throws: (any Error).self) { try PetSource.load(data: data) }
}
