import ArilsCore
import ArilsPlayer
import ArilsRigPortable
import Foundation
import Testing
@testable import PetRuntime

private func layeredFixture(twoSubjects: Bool = false) throws -> PortableRigImage {
    let w = 144, h = 192
    var bitmap = Bitmap(width: w, height: h)
    for y in 0..<h { for x in 0..<w {
        let head = pow((Float(x) - 72) / 32, 2) + pow((Float(y) - 42) / 34, 2) < 1
        let body = x >= 48 && x < 96 && y >= 68 && y < 186
        if head || body { bitmap.setRGBA(x: x, y: y, SIMD4(0.85, 0.65, 0.55, 1)) }
        if (x >= 55 && x < 65 || x >= 80 && x < 90) && y >= 35 && y < 41 {
            bitmap.setRGBA(x: x, y: y, SIMD4(0.1, 0.1, 0.1, 1))
        }
        if x >= 66 && x < 78 && y >= 55 && y < 59 { bitmap.setRGBA(x: x, y: y, SIMD4(0.5, 0.1, 0.1, 1)) }
        if twoSubjects && x < 20 && y > 100 { bitmap.setRGBA(x: x, y: y, SIMD4(0.2, 0.4, 0.8, 1)) }
    }}
    return try PortableRigImage(png: LayeredRigging.png(from: bitmap))
}
private var confirmedMarkers: PortableFaceLayout {
    PortableFaceLayout(head: CGRect(x: 38, y: 7, width: 68, height: 70),
        eyeLeft: CGRect(x: 54, y: 33, width: 12, height: 10), eyeRight: CGRect(x: 79, y: 33, width: 12, height: 10),
        mouth: CGRect(x: 64, y: 52, width: 16, height: 10))
}

@Test func layeredRigBuildsActualMacLayersAndKeepsSource() async throws {
    let image = try layeredFixture()
    let prepared = try await LayeredRigging.prepare(image)
    #expect(prepared.face.sourceLabel == "Illustration heuristic" || prepared.face.sourceLabel == "Template (manual review)")
    let archive = try LayeredRigging.build(prepared, markers: confirmedMarkers)
    #expect(Set(archive.texturePNGs.keys) == Set(["body", "neckSeam", "head", "eyeLeft", "eyeRight", "mouth"]))
    #expect(archive.rig.parts.first { $0.id == "eyeLeft" }?.parentID == "head")
    #expect(archive.rig.firstPart(ofKind: .head)?.deformations.isEmpty == false)
    #expect(prepared.source.rgba == image.rgba)
    #expect(prepared.maskIsAuthoritative)
    let saved = try LayeredRigging.savedPetData(source: image, asset: .standard(archive))
    #expect(try PetSource.loadAsset(data: saved).front.rig == archive.rig)
}

@Test func layeredQualityBuildsRegisteredDepthAndSavedBothViews() async throws {
    let image = try layeredFixture(), prepared = try await LayeredRigging.prepare(image)
    let quality = try await LayeredRigging.buildQuality(front: prepared, side: prepared,
        frontMarkers: confirmedMarkers, sideMarkers: confirmedMarkers, direction: .left, sideFileName: "synthetic-side.png")
    #expect(quality.front.rig.parts.contains { $0.mesh.depths.contains { $0 > 0 } })
    #expect(quality.sideDirection == .left)
    #expect(quality.registration.sideScale == 1)
    #expect(quality.front.rig.validatedPoseLimits.maximumYawDegrees <= 20)
    let saved = try LayeredRigging.savedPetData(source: image, asset: .quality(quality))
    guard case let .quality(loaded) = try PetSource.loadAsset(data: saved) else { Issue.record("Missing Quality"); return }
    #expect(loaded.front.rig == quality.front.rig && loaded.side.rig == quality.side.rig)
    #expect(loaded.side.texturePNGs == quality.side.texturePNGs)
}

@Test func layeredSelectionDoesNotMergeDifferentSubjects() async throws {
    let source = try layeredFixture(twoSubjects: true)
    do { _ = try await LayeredRigging.prepare(source); Issue.record("Selection was not requested") }
    catch LayeredRigging.RigError.selectSubject(let candidates) {
        #expect(candidates.count == 2)
        let selected = try await LayeredRigging.prepare(source, selecting: candidates[0].id)
        #expect(selected.preview.rgba[3] == 0)
        #expect(selected.source.rgba == source.rgba)
        #expect(selected.masks.extraction.values.contains { $0 > 0 })
    }
}

@Test func layeredAlphaConversionDoesNotMultiplyCoverageTwice() throws {
    let source = try PortableRigImage(width: 2, height: 1, rgba: [200, 100, 60, 128, 12, 30, 255, 0])
    let bitmap = LayeredRigging.bitmap(from: source)
    #expect(bitmap.pixels == [100, 50, 30, 128, 0, 0, 0, 0])
    let png = try LayeredRigging.png(from: bitmap)
    let decoded = try PortableRigImage(png: png)
    #expect(decoded.rgba[3] == 128 && decoded.rgba[7] == 0)
    #expect(abs(Int(decoded.rgba[0]) - 200) <= 1)
}
