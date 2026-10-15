import Foundation
import Testing
@testable import PetRuntime

private func installerZIP(_ names: [String]) -> Data {
    var out=Data(),central=Data()
    func word(_ value: Int, _ count: Int, _ bytes: inout Data) { for i in 0..<count {bytes.append(UInt8(truncatingIfNeeded:value >> (i*8)))} }
    for name in names {
        let filename=Data(name.utf8),offset=out.count
        word(0x04034b50,4,&out);word(20,2,&out);word(0,2,&out);word(0,2,&out)
        word(0,4,&out);word(0,4,&out);word(0,4,&out);word(0,4,&out)
        word(filename.count,2,&out);word(0,2,&out);out.append(filename)
        word(0x02014b50,4,&central);word(20,2,&central);word(20,2,&central)
        word(0,2,&central);word(0,2,&central);word(0,4,&central);word(0,4,&central)
        word(0,4,&central);word(0,4,&central);word(filename.count,2,&central)
        word(0,2,&central);word(0,2,&central);word(0,2,&central);word(0,2,&central)
        word(0,4,&central);word(offset,4,&central);central.append(filename)
    }
    let offset=out.count;out.append(central)
    word(0x06054b50,4,&out);word(0,2,&out);word(0,2,&out);word(names.count,2,&out);word(names.count,2,&out)
    word(central.count,4,&out);word(offset,4,&out);word(0,2,&out)
    return out
}
private func installerFixture(_ bytes: Data, version: String) throws -> (DesktopRelease,DesktopDownloadManifest) {
    let asset="Castor-\(version)-windows_x86_64.zip"
    let release=DesktopRelease(tag_name:version,draft:false,prerelease:false,assets:[.init(name:asset,browser_download_url:"https://github.com/Methurcoder/Castor/releases/download/\(version)/\(asset)",size:Int64(bytes.count))])
    let manifest=DesktopDownloadManifest(schema:1,version:version,platforms:["windows_x86_64":.init(asset:asset,sha256:PackageIntegrity.sha256(bytes),bytes:Int64(bytes.count))])
    return(release,manifest)
}
private let installerExtract: @Sendable(URL,URL) async throws -> Void = { _, destination in
    try Data("executable fixture".utf8).write(to:destination.appendingPathComponent("CastorPet.exe"))
    try Data("runtime fixture".utf8).write(to:destination.appendingPathComponent("swiftCore.dll"))
}
@Test func packageSHA256MatchesPublishedVectorsAndStreaming() throws {
    #expect(PackageIntegrity.sha256(Data())=="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(PackageIntegrity.sha256(Data("abc".utf8))=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let data=Data(repeating:97,count:1_000_000)
    #expect(PackageIntegrity.sha256(data)=="cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:file)}
    let large=Data(repeating:31,count:1_048_681);try large.write(to:file)
    #expect(try PackageIntegrity.sha256(file:file)==PackageIntegrity.sha256(large))
}
@Test func installerZIPRejectsTraversalAliasesAndUnexpectedPayloads() throws {
    try PackageZIP.validate(installerZIP(["CastorPet.exe","swiftCore.dll"]),platform:"windows_x86_64")
    try PackageZIP.validate(installerZIP(["Castor.app/Contents/MacOS/Castor"]),platform:"macos_arm64")
    for names in [["../CastorPet.exe"],["CastorPet.exe","castorpet.exe"],["CON.dll"],["aux.DLL"],["C:evil.dll"],["a\\evil.dll"],["evil?.dll"],[".hidden"],["Castor.app//evil"]] {
        #expect(throws:(any Error).self) { try PackageZIP.validate(installerZIP(names),platform:names[0].hasPrefix("Castor.app") ? "macos_arm64":"windows_x86_64") }
    }
    var malformed=installerZIP(["CastorPet.exe"]);malformed[26]=255
    #expect(throws:(any Error).self) {try PackageZIP.validate(malformed,platform:"windows_x86_64")}
}
@Test func installerUpdateRepairAndRemovalKeepUserDataAndPreviousVersions() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("castor-install-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let archive=installerZIP(["CastorPet.exe","swiftCore.dll"])
    let(v1,m1)=try installerFixture(archive,version:"v1"),(v2,m2)=try installerFixture(archive,version:"v2")
    let download: @Sendable(URL,URL) async throws -> Void = {_,to in try archive.write(to:to)}
    let first=try await DesktopInstaller.install(root:root,release:v1,manifest:m1,platform:"windows_x86_64",extract:installerExtract,stamp:{_ in},download:download)
    let data=root.appendingPathComponent("UserPet.json");try Data("user pet".utf8).write(to:data)
    let second=try await DesktopInstaller.install(root:root,release:v2,manifest:m2,platform:"windows_x86_64",extract:installerExtract,stamp:{_ in},download:download)
    #expect(try DesktopInstaller.selected(root:root)?.folder==second.folder)
    #expect(FileManager.default.fileExists(atPath:root.appendingPathComponent(first.folder).path))
    let repaired=try await DesktopInstaller.install(root:root,release:v2,manifest:m2,platform:"windows_x86_64",repair:true,extract:installerExtract,stamp:{_ in},download:download)
    #expect(repaired.folder != second.folder)
    #expect(FileManager.default.fileExists(atPath:root.appendingPathComponent(second.folder).path))
    try DesktopInstaller.uninstall(root:root)
    #expect(try DesktopInstaller.selected(root:root)==nil)
    #expect(try Data(contentsOf:data)==Data("user pet".utf8))
    #expect(FileManager.default.fileExists(atPath:root.appendingPathComponent(second.folder).path))
}
@Test func installerFailuresAndCancellationNeverSelectOrDamageReplacement() async throws {
    enum Failure: Error {case injected}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("castor-install-failure-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let archive=installerZIP(["CastorPet.exe","swiftCore.dll"])
    let(v1,m1)=try installerFixture(archive,version:"v1"),(v2,m2)=try installerFixture(archive,version:"v2")
    let download: @Sendable(URL,URL) async throws -> Void = {_,to in try archive.write(to:to)}
    _ = try await DesktopInstaller.install(root:root,release:v1,manifest:m1,platform:"windows_x86_64",extract:installerExtract,stamp:{_ in},download:download)
    let selection=try Data(contentsOf:DesktopInstaller.selectionFile(root:root))
    for failure in 0..<4 {
        do {
            _ = try await DesktopInstaller.install(root:root,release:v2,manifest:m2,platform:"windows_x86_64",extract:{a,b in
                if failure==0 {throw Failure.injected};if failure==1 {throw CancellationError()}
                try await installerExtract(a,b)
            },stamp:{_ in if failure==2 {throw Failure.injected}},download:{url,to in
                if failure==3 {try Data("corrupt".utf8).write(to:to)}else{try await download(url,to)}
            })
            Issue.record("An injected failure should not succeed")
        } catch {}
        #expect(try Data(contentsOf:DesktopInstaller.selectionFile(root:root))==selection)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("Castor-v2-windows_x86_64").path))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath:root.path)).contains(where:{$0.hasPrefix(".castor-")}))
    }
}

private actor InstallerGate {
    var entered=false
    private var continuation: CheckedContinuation<Void,Never>?
    func wait() async {entered=true;await withCheckedContinuation {continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
}
@Test func installerConcurrentAndCancelledUpdateRetainTheOldSelection() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("castor-install-concurrent-\(UUID().uuidString)")
    defer{try? FileManager.default.removeItem(at:root)}
    let bytes=installerZIP(["CastorPet.exe","swiftCore.dll"])
    let(release,manifest)=try installerFixture(bytes,version:"v1")
    let download: @Sendable(URL,URL) async throws -> Void = {_,to in try bytes.write(to:to)}
    _ = try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"windows_x86_64",extract:installerExtract,stamp:{_ in},download:download)
    let original=try Data(contentsOf:DesktopInstaller.selectionFile(root:root)),gate=InstallerGate()
    let job=Task {
        try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"windows_x86_64",repair:true,
            extract:{a,b in await gate.wait();try await installerExtract(a,b)},stamp:{_ in},download:download)
    }
    for _ in 0..<200 {if await gate.entered {break};try await Task.sleep(for:.milliseconds(10))}
    #expect(await gate.entered)
    do {
        _ = try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"windows_x86_64",repair:true,
            extract:installerExtract,stamp:{_ in},download:download)
        Issue.record("Concurrent installer should be rejected")
    } catch DesktopInstaller.InstallError.busy {} catch {Issue.record("Unexpected lock error: \(error)")}
    job.cancel();await gate.release()
    do {_ = try await job.value;Issue.record("Cancelled installer should not succeed")}catch is CancellationError {}
    #expect(try Data(contentsOf:DesktopInstaller.selectionFile(root:root))==original)
    // The OS lock is released on cancellation; an immediate retry works.
    _ = try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"windows_x86_64",repair:true,
        extract:installerExtract,stamp:{_ in},download:download)
}

@Test func windowsAppZIPAcceptsTheShippedFoldersAndNothingElse() throws {
    // The v1.0 layout: creation window, setup wizard, ML models and licenses beside the executables.
    let shipped=["CastorPet.exe","CastorSetup.exe","Castor.ico","swiftCore.dll","WebView2Loader.dll","onnxruntime.dll",
        "UI/index.html","UI/app.css","UI/app.js","SetupUI/index.html","SetupUI/setup.css","SetupUI/setup.js",
        "models/AnimeFaceFeatures.onnx","models/AnimeFaceBoxHead.onnx","models/AnimeFaceLandmarks.onnx","models/AnimeSegmentation.onnx",
        "licenses/onnxruntime-1.30.0-LICENSE.txt","LICENSE","THIRD_PARTY_NOTICES.md","Start-Castor.cmd","Start-Castor.ps1"]
    try PackageZIP.validate(installerZIP(shipped),platform:"windows_x86_64")
    try PackageZIP.validate(installerZIP(["CastorPet.exe","UI/","models/","licenses/"]),platform:"windows_x86_64")
    for name in ["UI/evil.js","UI/sub/app.js","models/other.onnx","licenses/evil.exe","licenses/a/b.txt","pets/CastorPet.json","Other/app.js","UI/../CastorPet.exe"] {
        #expect(throws:(any Error).self){try PackageZIP.validate(installerZIP(["CastorPet.exe",name]),platform:"windows_x86_64")}
    }
}
@Test func helperZIPRejectsNestedWindowsAliasesAndKeepsAppRules() throws {
    let helper=installerZIP(["CastorNeuralTTS.exe","_internal/python312.dll","licenses/Qwen/LICENSE"])
    try PackageZIP.validate(helper,platform:"windows_x86_64",component:.neuralTTS)
    #expect(throws:(any Error).self){try PackageZIP.validate(helper,platform:"windows_x86_64")}
    for name in ["_internal/../bad.dll","_internal/CON.dll","_internal/folder./bad.dll","_internal/folder /bad.dll","outside.txt"] {
        #expect(throws:(any Error).self){try PackageZIP.validate(installerZIP([name]),platform:"windows_x86_64",component:.neuralTTS)}
    }
    try PackageZIP.validate(installerZIP(["CastorNeuralTTS.app/Contents/MacOS/CastorNeuralTTS"]),platform:"macos_arm64",component:.neuralTTS)
}
@Test func helperInstallationIsIndependentAndCancellationRetainsItsPreviousVersion() async throws {
    let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:base)}
    let appRoot=base.appendingPathComponent("App"),helperRoot=base.appendingPathComponent("Helper")
    let appZIP=installerZIP(["CastorPet.exe","swiftCore.dll"])
    let(appRelease,appManifest)=try installerFixture(appZIP,version:"v1")
    _ = try await DesktopInstaller.install(root:appRoot,release:appRelease,manifest:appManifest,platform:"windows_x86_64",extract:installerExtract,stamp:{_ in},download:{_,to in try appZIP.write(to:to)})
    let original=try Data(contentsOf:DesktopInstaller.selectionFile(root:appRoot))
    let helperZIP=installerZIP(["CastorNeuralTTS.exe","_internal/python312.dll","_internal/base_library.zip"])
    let asset="CastorNeuralTTS-v1-windows_x86_64.zip"
    let release=DesktopRelease(tag_name:"v1",draft:false,prerelease:false,assets:[.init(name:asset,browser_download_url:"https://github.com/Methurcoder/Castor/releases/download/v1/\(asset)",size:Int64(helperZIP.count))])
    let manifest=DesktopDownloadManifest(schema:1,version:"v1",platforms:[:],components:["NeuralTTS":["windows_x86_64":.init(asset:asset,sha256:PackageIntegrity.sha256(helperZIP),bytes:Int64(helperZIP.count))]])
    let download:@Sendable(URL,URL) async throws -> Void={_,to in try helperZIP.write(to:to)}
    let extract:@Sendable(URL,URL) async throws -> Void={_,to in
        try Data("helper".utf8).write(to:to.appendingPathComponent("CastorNeuralTTS.exe"))
        let runtime=to.appendingPathComponent("_internal");try FileManager.default.createDirectory(at:runtime,withIntermediateDirectories:false)
        try Data("runtime".utf8).write(to:runtime.appendingPathComponent("python312.dll"))
        try Data("stdlib".utf8).write(to:runtime.appendingPathComponent("base_library.zip"))
    }
    let installed=try await DesktopInstaller.install(root:helperRoot,release:release,manifest:manifest,platform:"windows_x86_64",component:.neuralTTS,extract:extract,stamp:{_ in},download:download)
    #expect(installed.component == .neuralTTS)
    #expect(try DesktopInstaller.selected(root:helperRoot)?.folder==installed.folder)
    #expect(throws:(any Error).self){_ = try manifest.package(platform:"windows_x86_64",release:release)}
    do {
        _ = try await DesktopInstaller.install(root:helperRoot,release:release,manifest:manifest,platform:"windows_x86_64",repair:true,component:.neuralTTS,extract:{_,_ in throw CancellationError()},stamp:{_ in},download:download)
        Issue.record("Cancelled helper update should fail")
    } catch {}
    #expect(try DesktopInstaller.selected(root:helperRoot)?.folder==installed.folder)
    try DesktopInstaller.uninstall(root:helperRoot)
    #expect(try Data(contentsOf:DesktopInstaller.selectionFile(root:appRoot))==original)
}


@Test func installerMetadataIsHiddenAndLegacyReceiptMigratesOnlyAfterSuccess() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("castor-legacy-install-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let old=DesktopInstalledApp(version:"v0",platform:"windows_x86_64",folder:"Castor-v0-windows_x86_64")
    let legacy=root.appendingPathComponent("CurrentInstall.json")
    try JSONEncoder().encode(old).write(to:legacy)
    #expect(try DesktopInstaller.selected(root:root)?.folder==old.folder)
    let bytes=installerZIP(["CastorPet.exe","swiftCore.dll"])
    let(release,manifest)=try installerFixture(bytes,version:"v1")
    let current=try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"windows_x86_64",
        extract:installerExtract,stamp:{_ in},download:{_,to in try bytes.write(to:to)})
    #expect(try DesktopInstaller.selected(root:root)?.folder==current.folder)
    #expect(DesktopInstaller.selectionFile(root:root).deletingLastPathComponent().lastPathComponent==".CastorInstaller")
    #expect(!FileManager.default.fileExists(atPath:legacy.path))
    let previous=DesktopInstaller.metadataRoot(root:root).appendingPathComponent("PreviousInstall.json")
    #expect(try JSONDecoder().decode(DesktopInstalledApp.self,from:Data(contentsOf:previous)).folder==old.folder)
    try DesktopInstaller.uninstall(root:root)
    #expect(try DesktopInstaller.selected(root:root)==nil)
}
@Test func installerPruningKeepsCurrentPreviousAndModifiedFolders() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("castor-retain-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let bytes=installerZIP(["CastorPet.exe","swiftCore.dll"])
    var installs=[DesktopInstalledApp]()
    for version in ["v1","v2","v3"] {
        let(release,manifest)=try installerFixture(bytes,version:version)
        installs.append(try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"windows_x86_64",
            extract:installerExtract,stamp:{_ in},download:{_,to in try bytes.write(to:to)}))
    }
    let first=root.appendingPathComponent(installs[0].folder)
    let personal=first.appendingPathComponent("UserPet.json");try Data("private pet".utf8).write(to:personal)
    let trash=root.appendingPathComponent("Trash");try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:false)
    let before=try DesktopInstaller.pruneOldVersions(root:root,trash:{folder in try FileManager.default.moveItem(at:folder,to:trash.appendingPathComponent(folder.lastPathComponent))})
    #expect(before==0);#expect(try Data(contentsOf:personal)==Data("private pet".utf8))
    try FileManager.default.removeItem(at:personal)
    let count=try DesktopInstaller.pruneOldVersions(root:root,trash:{folder in try FileManager.default.moveItem(at:folder,to:trash.appendingPathComponent(folder.lastPathComponent))})
    #expect(count==1)
    #expect(!FileManager.default.fileExists(atPath:first.path))
    for kept in installs.suffix(2) {#expect(FileManager.default.fileExists(atPath:root.appendingPathComponent(kept.folder).path))}
    #expect(try DesktopInstaller.selected(root:root)?.folder==installs[2].folder)
}
