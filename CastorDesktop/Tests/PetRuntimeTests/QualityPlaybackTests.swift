import ArilsCore
import ArilsPlayer
import Foundation
import Testing
@testable import PetRuntime

private func solidArchive(_ color: [UInt8], depth: Float = 0, id: String = "head", order: Int = 0) throws -> AvatarArchive {
    let png = try PortableRigImage(width: 4, height: 4, rgba: Array(repeating: color, count: 16).flatMap { $0 }).pngData()
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    var mesh = DeformableMesh.grid(rect: rect, columns: 2, rows: 2)
    mesh.depths = Array(repeating: depth, count: mesh.vertexCount)
    let part = AvatarPart(id: id, kind: .head, rect: rect, zOrder: order, mesh: mesh)
    return AvatarArchive(rig: AvatarRig(imageWidth: 100, imageHeight: 100, parts: [part], parameters: StandardParameters.all), texturePNGs: [id: png])
}

private func qualityFixture(direction: QualitySideDirection = .right) throws -> QualityAvatarArchive {
    try QualityAvatarArchive(front: solidArchive([255, 0, 0, 255]), side: solidArchive([0, 0, 255, 255]),
        sideDirection: direction, registration: .init(frontNeck: SIMD2(0.5, 0.5), sideNeck: SIMD2(0.5, 0.5), sideScale: 1),
        assessment: .init(sameCharacterConfidence: 0.4, faceReadabilityConfidence: 0.5,
                          warnings: [.expressionNotReliable(confidence: 0.5)]))
}

private func center(_ canvas: PetCanvas) -> [UInt8] {
    let o = ((canvas.height / 2) * canvas.width + canvas.width / 2) * 4
    return Array(canvas.bgra[o..<o + 4])
}

@Test func qualityLoadsBothViewsAndTakesPrecedenceOverStandard() throws {
    let quality = try qualityFixture()
    struct Saved: Encodable { let arilsArchiveData: Data; let qualityArchiveData: Data }
    let json = try JSONEncoder().encode(Saved(arilsArchiveData: quality.side.data(), qualityArchiveData: quality.data()))
    for data in [try quality.data(), json] {
        guard case let .quality(loaded) = try PetSource.loadAsset(data: data) else { Issue.record("Quality was flattened"); return }
        #expect(loaded.front.texturePNGs == quality.front.texturePNGs)
        #expect(loaded.side.texturePNGs == quality.side.texturePNGs)
        #expect(loaded.sideDirection == quality.sideDirection)
        #expect(loaded.registration == quality.registration)
        #expect(try QualityAvatarArchive(data: PetAsset.quality(loaded).data()).side.texturePNGs == quality.side.texturePNGs)
    }
    let broken = try JSONEncoder().encode(Saved(arilsArchiveData: quality.front.data(), qualityArchiveData: Data([1, 2, 3])))
    #expect(throws: (any Error).self) { try PetSource.loadAsset(data: broken) }
}

@Test func qualityLegacyKeysRetainTwoDAndFaceReadability() throws {
    let quality = try qualityFixture()
    var plist = try #require(PropertyListSerialization.propertyList(from: quality.data(), format: nil) as? [String: Any])
    plist.removeValue(forKey: "preferredPresentationMode")
    var assessment = try #require(plist["assessment"] as? [String: Any])
    assessment["expressionConfidence"] = assessment.removeValue(forKey: "faceReadabilityConfidence")
    plist["assessment"] = assessment
    let oldData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    let loaded = try QualityAvatarArchive(data: oldData)
    #expect(loaded.preferredPresentationMode == .twoD)
    #expect(loaded.assessment.faceReadabilityConfidence == quality.assessment.faceReadabilityConfidence)
    #expect(loaded.assessment.warnings == quality.assessment.warnings)
    let reencoded = try #require(PropertyListSerialization.propertyList(from: loaded.data(), format: nil) as? [String: Any])
    let newAssessment = try #require(reencoded["assessment"] as? [String: Any])
    #expect(newAssessment["expressionConfidence"] == nil)
    #expect(newAssessment["faceReadabilityConfidence"] != nil)
}

@Test func qualityRejectsUnsupportedVersionAndBrokenRegistration() throws {
    var quality = try qualityFixture()
    quality.formatVersion = 999
    #expect(throws: (any Error).self) { try PetSource.loadAsset(data: quality.data()) }
    quality.formatVersion = 1
    quality.registration.sideScale = 0
    #expect(throws: (any Error).self) { try PetSource.loadAsset(data: quality.data()) }
    quality.registration.sideScale = .infinity
    #expect(throws: (any Error).self) { try PetSource.loadAsset(data: quality.data()) }
}

@Test func qualityCompositesRegisteredViewsWithoutMirroringTheOtherSide() throws {
    let player = PetPlayback(asset: .quality(try qualityFixture()))
    player.automaticTurn = false
    player.presentationMode = .twoD
    var canvas = PetCanvas(width: 80, height: 100)
    player.viewTurn = 0
    player.render(into: &canvas, time: 0)
    #expect(center(canvas) == [0, 0, 255, 255])
    #expect(canvas.bgra[3] == 0) // centered fit leaves a top margin
    player.viewTurn = 1
    player.render(into: &canvas, time: 0)
    #expect(center(canvas) == [255, 0, 0, 255])
    player.viewTurn = 0.5
    player.render(into: &canvas, time: 0)
    // source-over of independently faded NSViews, not RGB interpolation.
    #expect(center(canvas) == [128, 0, 64, 191])
    player.viewTurn = -1
    player.render(into: &canvas, time: 0)
    #expect(center(canvas) == [0, 0, 255, 255])
    let left = PetPlayback(asset: .quality(try qualityFixture(direction: .left)))
    left.automaticTurn = false; left.viewTurn = -1
    left.render(into: &canvas, time: 0)
    #expect(center(canvas) == [255, 0, 0, 255])
}

@Test func qualityAlignsNecksForDifferentImageShapes() {
    let bounds = CGRect(x: 10, y: 20, width: 300, height: 400)
    let frontSize = CGSize(width: 200, height: 600), sideSize = CGSize(width: 500, height: 300)
    let registration = QualityViewRegistration(frontNeck: SIMD2(0.4, 0.3), sideNeck: SIMD2(0.6, 0.7), sideScale: 0.7)
    let front = QualityRegistrationLayout.aspectFitRect(imageSize: frontSize, in: bounds)
    let side = QualityRegistrationLayout.sideFrame(bounds: bounds, frontImageSize: frontSize,
                                                  sideImageSize: sideSize, registration: registration)
    #expect(abs(front.minX + front.width * CGFloat(registration.frontNeck.x) - side.minX - side.width * CGFloat(registration.sideNeck.x)) < 0.0001)
    #expect(abs(front.minY + front.height * CGFloat(registration.frontNeck.y) - side.minY - side.height * CGFloat(registration.sideNeck.y)) < 0.0001)
    #expect(abs(side.width / side.height - sideSize.width / sideSize.height) < 0.0001)
}

@Test func qualityAutomaticTurnUsesSharedSpringsAndReturnsToFront() throws {
    let player = PetPlayback(asset: .quality(try qualityFixture()))
    var canvas = PetCanvas(width: 20, height: 20)
    for step in 0..<120 {
        let t = Double(step) / 30
        player.pointerMoved(to: SIMD2(20, 10), canvasWidth: 20, canvasHeight: 20, time: t)
        player.render(into: &canvas, time: t)
    }
    #expect(player.viewTurn > 0.99 && player.sideBlend == 1)
    for step in 120..<240 {
        let t = Double(step) / 30
        player.pointerMoved(to: nil, canvasWidth: 20, canvasHeight: 20, time: t)
        player.render(into: &canvas, time: t)
    }
    #expect(abs(player.viewTurn) < 0.01 && player.sideBlend == 0)
    player.automaticTurn = false; player.viewTurn = .nan; player.viewPitch = .infinity
    player.render(into: &canvas, time: 8)
    #expect(player.viewTurn == 0 && player.viewPitch == 0)
}

@Test func qualityHybridHonorsArchiveLimitsAndSuppressesProfilePitch() throws {
    var quality = try qualityFixture()
    quality.front.rig.validatedPoseLimits = .init(minimumYawDegrees: -20, maximumYawDegrees: 10,
                                                 minimumPitchDegrees: -3, maximumPitchDegrees: 6)
    let player = PetPlayback(asset: .quality(quality))
    player.automaticTurn = false; player.viewTurn = 0.2; player.viewPitch = 1
    var canvas = PetCanvas(width: 20, height: 20)
    player.render(into: &canvas, time: 0)
    #expect(player.sideBlend > 0)
    #expect(player.front.viewAngleXOverride == 10)
    #expect(player.front.viewAngleYOverride == 6 * (1 - player.sideBlend))
    #expect(player.side?.viewAngleYOverride == 0)
    player.viewTurn = 1
    player.render(into: &canvas, time: 0)
    #expect(player.front.viewAngleYOverride == 0)
}

@Test func depthWinsOverPainterOrderAndTransparentTexelsNeverOcclude() throws {
    let near = try solidArchive([255, 0, 0, 255], depth: 80, id: "near", order: 0)
    let far = try solidArchive([0, 0, 255, 255], id: "far", order: 1)
    var combined = near
    combined.rig.parts += far.rig.parts
    combined.texturePNGs.merge(far.texturePNGs) { _, new in new }
    var canvas = PetCanvas(width: 50, height: 50)
    PetPlayer(archive: combined).render(into: &canvas, time: 0)
    #expect(center(canvas) == [0, 0, 255, 255]) // red near surface beats later blue
    let invisibleNear = try solidArchive([255, 0, 0, 0], depth: 80, id: "near", order: 0)
    combined.texturePNGs["near"] = invisibleNear.texturePNGs["near"]
    PetPlayer(archive: combined).render(into: &canvas, time: 0)
    #expect(center(canvas) == [255, 0, 0, 255]) // far blue remains visible
}

@Test func depthFeatherBlendsOnceAndWholePetOpacityPreservesItsClassification() throws {
    let near = try solidArchive([255, 0, 0, 100], depth: 80, id: "near", order: 0)
    let far = try solidArchive([0, 0, 255, 255], id: "far", order: 1)
    var combined = near
    combined.rig.parts += far.rig.parts
    combined.texturePNGs.merge(far.texturePNGs) { _, new in new }
    let player = PetPlayer(archive: combined)
    var canvas = PetCanvas(width: 50, height: 50)
    player.render(into: &canvas, time: 0)
    #expect(center(canvas) == [155, 0, 100, 255])
    player.render(into: &canvas, time: 0, opacity: 0.2)
    #expect(center(canvas) == [31, 0, 20, 51])
}

@Test func flatMeshHasNoDoubledAlphaOnSharedTriangleEdges() throws {
    let player = PetPlayer(archive: try solidArchive([255, 0, 0, 128]))
    var canvas = PetCanvas(width: 40, height: 40)
    player.render(into: &canvas, time: 0)
    for y in 5..<35 { for x in 5..<35 {
        #expect(canvas.bgra[(y * 40 + x) * 4 + 3] == 128)
    }}
}

@Test func textureVerticalGuttersMatchMetalClampToZero() {
    let texture = PetTexture(width: 1, height: 1, pixels: [1, 0, 0, 1])
    #expect(texture.sample(0, 0) == SIMD4(1, 0, 0, 1))
    #expect(texture.sample(-10, -0.5) == SIMD4(0.5, 0, 0, 0.5))
    #expect(texture.sample(10, 0.5) == SIMD4(0.5, 0, 0, 0.5))
    #expect(texture.sample(0, 1) == .zero)
}

@Test func qualityLibraryKeepsBothViewsAndPreviousSelectionOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("castor-quality-library-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let library = PortablePetLibrary(root: root)
    struct Saved: Encodable { let qualityArchiveData: Data }
    let data = try JSONEncoder().encode(Saved(qualityArchiveData: qualityFixture().data()))
    let file = try library.saveNew(data)
    guard case .quality = try PetSource.loadAsset(contentsOf: file) else { Issue.record("Both views were lost"); return }
    #expect(try library.selectedFile() == file)
    let broken = try JSONEncoder().encode(Saved(qualityArchiveData: Data([0, 1, 2])))
    #expect(throws: (any Error).self) { try library.saveNew(broken) }
    #expect(try library.selectedFile() == file)
    #expect(try Data(contentsOf: file) == data)
}
