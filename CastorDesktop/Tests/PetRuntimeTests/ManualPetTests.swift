import ArilsPlayer
import CastorCore
import Foundation
import Testing
@testable import PetRuntime

private func manualFixture() throws -> ManualPet {
    var pixels = [UInt8](repeating:255,count:32*32*4)
    for y in 4..<28 {for x in 4..<28 {let i=(y*32+x)*4;pixels[i]=240;pixels[i+1]=160;pixels[i+2]=120}}
    for y in 12..<15 {for x in 12..<15 {let i=(y*32+x)*4;pixels[i]=20;pixels[i+1]=30;pixels[i+2]=40}}
    let parts = [RigPart(kind:.head,normalizedRect:CGRect(x:0.125,y:0.125,width:0.75,height:0.75),shape:.rectangle,zIndex:0),
                 RigPart(kind:.leftEye,normalizedRect:CGRect(x:0.375,y:0.375,width:0.125,height:0.125),shape:.rectangle,zIndex:10)]
    return try ManualPet(document:RigDocument(version:1,imageName:"manual.png",imageSize:CGSize(width:32,height:32),parts:parts),
                         source:PortableRigImage(width:32,height:32,rgba:pixels))
}
@Test func manualSavedPetKeepsDocumentAndOriginalPixelsWithoutArilsSubstitution() throws {
    let pet = try manualFixture()
    let data = try pet.data()
    guard case let .manual(loaded) = try PetSource.loadAsset(data:data) else {Issue.record("Expected legacy manual asset");return}
    #expect(loaded.document == pet.document)
    #expect(loaded.source.rgba == pet.source.rgba)
    #expect(throws:PetSource.LoadError.self) { _ = try PetSource.load(data:data) }
    let object = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
    #expect(object["arilsArchiveData"] == nil)
    #expect(object["qualityArchiveData"] == nil)
}
@Test func manualPlaybackUsesSharedTransformsAndOpacity() throws {
    let pet = try manualFixture(),renderer = ManualPetRenderer(pet:pet)
    let control = PetPlayer(archive:pet.controlArchive)
    var rest = PetCanvas(width:64,height:64),moved = rest,transparent = rest
    var parameters = MotionParameters.neutral
    renderer.render(into:&rest,control:control,parameters:parameters,opacity:1)
    #expect(rest.bgra.contains{$0>0})
    parameters.headTilt=20;parameters.eyeOpen=0.1;parameters.bodyLift=3
    renderer.render(into:&moved,control:control,parameters:parameters,opacity:1)
    #expect(moved.bgra != rest.bgra)
    renderer.render(into:&transparent,control:control,parameters:parameters,opacity:0)
    #expect(transparent.bgra.allSatisfy{$0==0})
    let player = PetPlayback(asset:.manual(pet))
    player.render(into:&rest,time:1)
    player.render(into:&moved,time:2)
    #expect(rest.bgra != moved.bgra)
}
@Test func manualLibraryFailureDoesNotReplaceSelectedPet() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let library = PortablePetLibrary(root:root),pet = try manualFixture()
    let file = try library.saveNew(pet.data())
    var invalid = pet.document
    invalid.parts[0].normalizedRect = CGRect(x:-1,y:0,width:1,height:1)
    #expect(throws:RigDocument.ValidationError.self){_ = try ManualPet(document:invalid,source:pet.source)}
    #expect(try library.selectedFile() == file)
}
