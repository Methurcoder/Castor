import ArilsCore
import ArilsPlayer
import Foundation
import Testing

@testable import PetRuntime

@Test func defaultPetFilenamePrefersCastorAndFallsBackToExistingPomegranateExport() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("castor-default-pet-\(UUID().uuidString)")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    #expect(PetSource.defaultFileURL(in: directory).lastPathComponent == "CastorPet.json")
    let legacy = directory.appendingPathComponent("PomegranatePet.json")
    try Data("legacy".utf8).write(to: legacy)
    #expect(PetSource.defaultFileURL(in: directory) == legacy)
    let current = directory.appendingPathComponent("CastorPet.json")
    try Data("current".utf8).write(to: current)
    #expect(PetSource.defaultFileURL(in: directory) == current)
    #expect(try Data(contentsOf: legacy) == Data("legacy".utf8))
}

@Test func gazeFollowsThePointerAroundTheHead() {
    let head = CGRect(x: 100, y: 50, width: 100, height: 100)
    let size = SIMD2<Float>(300, 600)
    #expect(PetPlayer.gazeTarget(imagePoint: SIMD2(150, 100), headRect: head, imageSize: size) == SIMD2(0, 0))
    let right = PetPlayer.gazeTarget(imagePoint: SIMD2(300, 100), headRect: head, imageSize: size)
    #expect(right.x == 1 && right.y == 0)
    let up = PetPlayer.gazeTarget(imagePoint: SIMD2(150, 0), headRect: head, imageSize: size)
    #expect(up.y == 1)
}

@Test func drawsSyntheticPetIntoACanvasOnEveryPlatform() throws {
    let player = PetPlayer(archive: try syntheticArchive())
    var canvas = PetCanvas(width: 260, height: 340)
    player.render(into: &canvas, time: 0)
    var covered = 0
    for i in 0..<(canvas.width * canvas.height) where canvas.bgra[i * 4 + 3] > 0 { covered += 1 }
    #expect(covered > canvas.width * canvas.height / 20)          // the pet is drawn
    #expect(canvas.bgra[3] == 0)                                    // top-left corner stays clear
    // Premultiplied: no colour channel exceeds alpha.
    for i in stride(from: 0, to: canvas.bgra.count, by: 4) {
        let a = canvas.bgra[i + 3]
        #expect(canvas.bgra[i] <= a && canvas.bgra[i + 1] <= a && canvas.bgra[i + 2] <= a)
        if canvas.bgra[i] > a { break }
    }
}

@Test func rejectsFilesWithoutAnAvatar() {
    #expect(throws: (any Error).self) { try PetSource.load(data: Data("{}".utf8)) }
    #expect(throws: (any Error).self) { try PetSource.load(data: Data("not a pet".utf8)) }
}
