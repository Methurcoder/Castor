import Foundation
import Testing
@testable import PetRuntime
import CastorCore

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
        // Each case starts without a download kept from the case before it
        // (a verified download is otherwise reused by the next attempt).
        try? FileManager.default.removeItem(at:DesktopInstaller.downloadsFolder(root:root))
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
@Test func feelingZIPCarriesOnlyModelDataForItsPlatform() throws {
    let common=["feelings.json","tokenizer.json","LICENSE","THIRD_PARTY_NOTICES.md","licenses/","licenses/ruri-v3-70m-Apache-2.0-LICENSE.txt"]
    try PackageZIP.validate(installerZIP(common+["CastorFeelings.mlmodelc/","CastorFeelings.mlmodelc/model.mil","CastorFeelings.mlmodelc/weights/weight.bin"]),platform:"macos_arm64",component:.feelings)
    try PackageZIP.validate(installerZIP(common+["CastorFeelings.onnx"]),platform:"windows_x86_64",component:.feelings)
    for (name,platform) in [("CastorFeelings.onnx","macos_arm64"),("CastorFeelings.mlmodelc/model.mil","windows_x86_64"),("CastorPet.exe","windows_x86_64"),
                            ("CastorFeelings.app/Contents/MacOS/CastorFeelings","macos_arm64"),("licenses/run.exe","windows_x86_64"),("tokenizer_fixtures.json","macos_arm64")] {
        #expect(throws:(any Error).self){try PackageZIP.validate(installerZIP(common+[name]),platform:platform,component:.feelings)}
    }
}
@Test func feelingModelInstallsAsDataWithoutLaunchEntry() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("CastorHelpers/Feelings")
    defer {try? FileManager.default.removeItem(at:root.deletingLastPathComponent().deletingLastPathComponent())}
    let zip=installerZIP(["feelings.json","tokenizer.json","CastorFeelings.mlmodelc/model.mil"])
    let asset="CastorFeelings-v1.0.1-macos_arm64.zip"
    let release=DesktopRelease(tag_name:"v1.0.1",draft:false,prerelease:false,assets:[.init(name:asset,browser_download_url:"https://github.com/Methurcoder/Castor/releases/download/v1.0.1/\(asset)",size:Int64(zip.count))])
    let manifest=DesktopDownloadManifest(schema:1,version:"v1.0.1",platforms:[:],components:["Feelings":["macos_arm64":.init(asset:asset,sha256:PackageIntegrity.sha256(zip),bytes:Int64(zip.count))]])
    let installed=try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"macos_arm64",component:.feelings,
        extract:{_,to in
            try Data(#"{"feelings":["neutral","happy"]}"#.utf8).write(to:to.appendingPathComponent("feelings.json"))
            try Data("{}".utf8).write(to:to.appendingPathComponent("tokenizer.json"))
            let model=to.appendingPathComponent("CastorFeelings.mlmodelc");try FileManager.default.createDirectory(at:model,withIntermediateDirectories:false)
            try Data("mil".utf8).write(to:model.appendingPathComponent("model.mil"))
        },stamp:{_ in},download:{_,to in try zip.write(to:to)})
    #expect(installed.component == .feelings && installed.folder == "CastorFeelings-v1.0.1-macos_arm64")
    #expect(!DesktopHelperComponent.feelings.isApp)
    // The app finds the selected version from the same receipt Setup wrote.
    let found=try #require(FeelingModelFiles.installedComponent(root:root))
    #expect(found.standardizedFileURL.path == root.appendingPathComponent(installed.folder).standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath:found.appendingPathComponent("CastorFeelings.mlmodelc/model.mil").path))
    try DesktopInstaller.uninstall(root:root)
    #expect(FeelingModelFiles.installedComponent(root:root) == nil)
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
@Test func installerReportsDownloadProgressThenEachStep() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("castor-progress-\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:root)}
    let archive=installerZIP(["CastorPet.exe","swiftCore.dll"])
    let(release,manifest)=try installerFixture(archive,version:"v1")
    final class Recorder: @unchecked Sendable { let lock=NSLock(); var values:[DesktopInstallProgress]=[] }
    let recorder=Recorder()
    // The download grows the file in two halves and holds the first half until
    // it has been reported (a busy CI machine can be slow to poll).
    let download: @Sendable(URL,URL) async throws -> Void = {_,to in
        try archive.prefix(archive.count/2).write(to:to)
        for _ in 0..<200 {
            let seen=recorder.lock.withLock { recorder.values.contains { if case let .downloading(received,_) = $0 { received>0 } else { false } } }
            if seen { break }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        try archive.write(to:to)
    }
    _=try await DesktopInstaller.install(root:root,release:release,manifest:manifest,platform:"windows_x86_64",extract:installerExtract,stamp:{_ in},
        download:download,progress:{ value in recorder.lock.withLock { recorder.values.append(value) } })
    let values=recorder.lock.withLock { recorder.values }
    let received=values.compactMap { if case let .downloading(received,_) = $0 { received } else { nil } }
    #expect(received.contains { $0>0 && $0<Int64(archive.count) })
    #expect(received.last==Int64(archive.count))
    #expect(Array(values.suffix(3))==[.verifying,.extracting,.finishing])
}

// MARK: - Updates that download only what changed, and interrupted updates

/// A Windows release whose ZIPs install `files` (path -> contents), with a file
/// list and, when `patch` is given, a patch ZIP of those paths.
private struct UpdateFixture {
    let release: DesktopRelease
    let manifest: DesktopDownloadManifest
    let assets: [String: Data]
    /// What the fake extractor writes for each archive, by its SHA-256.
    let payloads: [String: [String: Data]]
    /// Files the fake extractor makes runnable, as a ZIP's modes would.
    let executables: Set<String>

    /// `executables` are runnable in the release; `listsExecutables: false`
    /// publishes a file list from before that was recorded.
    init(version: String, files: [String: Data], patch: [String]? = nil, platform: String = "windows_x86_64",
         executables: Set<String> = [], listsExecutables: Bool = true) throws {
        let stem="Castor-\(version)-\(platform)"
        let names=files.keys.sorted()
        // The ZIP bytes only need to be distinct and structurally valid; the
        // fake extractor below writes the real contents.
        let padding=platform.hasPrefix("macos") ? "Castor.app/Contents/Resources/\(version)" : "licenses/\(version)"
        let full=installerZIP(names+["\(padding)-full.txt"])
        var assets=[stem+".zip":full]
        var payloads=[PackageIntegrity.sha256(full):files]
        var listing:[String:Any]=["schema":1,"files":Dictionary(uniqueKeysWithValues:files.map { file in
            var entry:[String:Any]=["sha256":PackageIntegrity.sha256(file.value),"bytes":file.value.count]
            if listsExecutables,executables.contains(file.key) { entry["executable"]=true }
            return (file.key,entry) })]
        var patchFile: DesktopDownloadManifest.UpdateFile?
        if let patch {
            listing["patch"]=patch
            if !patch.isEmpty {
                let archive=installerZIP(patch.sorted()+["\(padding)-patch.txt"])
                assets[stem+"-patch.zip"]=archive
                payloads[PackageIntegrity.sha256(archive)]=files.filter { patch.contains($0.key) }
                patchFile = .init(asset:stem+"-patch.zip",sha256:PackageIntegrity.sha256(archive),bytes:Int64(archive.count))
            }
        }
        let listed=try JSONSerialization.data(withJSONObject:listing,options:[.sortedKeys])
        assets[stem+".files.json"]=listed
        self.assets=assets;self.payloads=payloads;self.executables=executables
        release=DesktopRelease(tag_name:version,draft:false,prerelease:false,assets:assets.map {
            .init(name:$0.key,browser_download_url:"https://github.com/Methurcoder/Castor/releases/download/\(version)/\($0.key)",size:Int64($0.value.count)) })
        manifest=DesktopDownloadManifest(schema:1,version:version,platforms:[platform:.init(
            asset:stem+".zip",sha256:PackageIntegrity.sha256(full),bytes:Int64(full.count),
            inventory:.init(asset:stem+".files.json",sha256:PackageIntegrity.sha256(listed),bytes:Int64(listed.count)),
            patch:patchFile)])
    }
}
private final class DownloadLog: @unchecked Sendable {
    let lock=NSLock();var names:[String]=[]
    func add(_ name:String){lock.withLock {names.append(name)}}
    var all:[String]{lock.withLock {names}}
}
private func updateDownload(_ fixtures:[UpdateFixture],log:DownloadLog) -> @Sendable(URL,URL) async throws -> Void {
    let assets=fixtures.reduce(into:[String:Data]()) { $0.merge($1.assets) { a,_ in a } }
    return { url,to in
        log.add(url.lastPathComponent)
        guard let data=assets[url.lastPathComponent] else { throw DesktopInstaller.InstallError.downloadFailed(404) }
        try data.write(to:to)
    }
}
private func updateExtract(_ fixtures:[UpdateFixture]) -> @Sendable(URL,URL) async throws -> Void {
    let payloads=fixtures.reduce(into:[String:[String:Data]]()) { $0.merge($1.payloads) { a,_ in a } }
    let executables=fixtures.reduce(into:Set<String>()) { $0.formUnion($1.executables) }
    return { archive,destination in
        guard let files=payloads[try PackageIntegrity.sha256(file:archive)] else { throw PackageZIP.ZIPError.invalid }
        for (path,data) in files {
            let file=destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:file)
            if executables.contains(path) {
                try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
            }
        }
    }
}
private func updateRoot(_ name:String)->URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("castor-\(name)-\(UUID().uuidString)")
}
private func contents(_ root:URL,_ app:DesktopInstalledApp,_ path:String) throws -> Data {
    try Data(contentsOf:root.appendingPathComponent(app.folder).appendingPathComponent(path))
}
private let baseFiles=["CastorPet.exe":Data("pet v1".utf8),"swiftCore.dll":Data("runtime".utf8),"UI/app.js":Data("page v1".utf8)]

@Test func updateDownloadsOnlyChangedFilesAndCopiesTheRest() async throws {
    let root=updateRoot("delta");defer {try? FileManager.default.removeItem(at:root)}
    let v1=try UpdateFixture(version:"v1",files:baseFiles)
    var changed=baseFiles;changed["CastorPet.exe"]=Data("pet v2".utf8)
    let v2=try UpdateFixture(version:"v2",files:changed,patch:["CastorPet.exe"])
    let log=DownloadLog()
    _ = try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:"windows_x86_64",
        extract:updateExtract([v1,v2]),stamp:{_ in},download:updateDownload([v1,v2],log:log))
    #expect(log.all==["Castor-v1-windows_x86_64.files.json","Castor-v1-windows_x86_64.zip"])
    let second=DownloadLog()
    let app=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"windows_x86_64",
        extract:updateExtract([v1,v2]),stamp:{_ in},download:updateDownload([v1,v2],log:second))
    // Only the list and the one changed file; never the full ZIP.
    #expect(second.all==["Castor-v2-windows_x86_64.files.json","Castor-v2-windows_x86_64-patch.zip"])
    #expect(try contents(root,app,"CastorPet.exe")==Data("pet v2".utf8))
    #expect(try contents(root,app,"UI/app.js")==Data("page v1".utf8))
    #expect(app.files==changed.mapValues { PackageIntegrity.sha256($0) })
    #expect(try DesktopInstaller.selected(root:root)?.folder==app.folder)
    // Downloads are removed once installed.
    #expect(!FileManager.default.fileExists(atPath:DesktopInstaller.downloadsFolder(root:root).path))
}

@Test func unchangedHelperUpdatesWithoutDownloadingItsPackage() async throws {
    let root=updateRoot("same");defer {try? FileManager.default.removeItem(at:root)}
    let v1=try UpdateFixture(version:"v1",files:baseFiles),v2=try UpdateFixture(version:"v2",files:baseFiles,patch:[])
    let log=DownloadLog()
    _ = try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:"windows_x86_64",
        extract:updateExtract([v1]),stamp:{_ in},download:updateDownload([v1],log:log))
    let second=DownloadLog()
    let app=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"windows_x86_64",
        extract:updateExtract([v1]),stamp:{_ in},download:updateDownload([v2],log:second))
    #expect(second.all==["Castor-v2-windows_x86_64.files.json"])
    #expect(app.version=="v2")
    #expect(try contents(root,app,"swiftCore.dll")==Data("runtime".utf8))
}

@Test func damagedInstalledFilesFallBackToTheFullPackage() async throws {
    let root=updateRoot("fallback");defer {try? FileManager.default.removeItem(at:root)}
    let v1=try UpdateFixture(version:"v1",files:baseFiles)
    var changed=baseFiles;changed["CastorPet.exe"]=Data("pet v2".utf8)
    let v2=try UpdateFixture(version:"v2",files:changed,patch:["CastorPet.exe"])
    let first=try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:"windows_x86_64",
        extract:updateExtract([v1,v2]),stamp:{_ in},download:updateDownload([v1,v2],log:DownloadLog()))
    // A file of the installed version changed on disk since it was installed.
    try Data("damaged".utf8).write(to:root.appendingPathComponent(first.folder).appendingPathComponent("UI/app.js"))
    let log=DownloadLog()
    let app=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"windows_x86_64",
        extract:updateExtract([v1,v2]),stamp:{_ in},download:updateDownload([v1,v2],log:log))
    #expect(log.all.last=="Castor-v2-windows_x86_64.zip")
    #expect(try contents(root,app,"UI/app.js")==Data("page v1".utf8))
    #expect(app.files==changed.mapValues { PackageIntegrity.sha256($0) })
}

private let macExecutable="Castor.app/Contents/MacOS/Castor"
private let macFiles=[macExecutable:Data("app v1".utf8),"Castor.app/Contents/Info.plist":Data("plist v1".utf8)]

// Mac packages are installed only on a Mac, where POSIX modes exist.
#if !os(Windows)
/// The installed v1 executable has lost its permission (same content), then
/// v2 changes only Info.plist, so the update would reuse that executable.
private func updateAfterLosingTheExecutableBit(listsExecutables: Bool) async throws -> (DesktopInstalledApp, [String], URL) {
    let root=updateRoot("mode")
    let platform="macos_arm64"
    let v1=try UpdateFixture(version:"v1",files:macFiles,platform:platform,executables:[macExecutable],
                             listsExecutables:listsExecutables)
    var changed=macFiles;changed["Castor.app/Contents/Info.plist"]=Data("plist v2".utf8)
    let v2=try UpdateFixture(version:"v2",files:changed,patch:["Castor.app/Contents/Info.plist"],platform:platform,
                             executables:[macExecutable],listsExecutables:listsExecutables)
    let first=try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:platform,
        extract:updateExtract([v1,v2]),stamp:{_ in},download:updateDownload([v1,v2],log:DownloadLog()))
    let installed=root.appendingPathComponent(first.folder).appendingPathComponent(macExecutable)
    try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:installed.path)
    let log=DownloadLog()
    let app=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:platform,
        extract:updateExtract([v1,v2]),stamp:{_ in},download:updateDownload([v1,v2],log:log))
    return (app,log.all,root)
}

@Test func aReusedExecutableGetsThePublishedPermissionBack() async throws {
    let (app,downloads,root)=try await updateAfterLosingTheExecutableBit(listsExecutables:true)
    defer {try? FileManager.default.removeItem(at:root)}
    // Still an update of only the changed file, and the app runs.
    #expect(downloads==["Castor-v2-macos_arm64.files.json","Castor-v2-macos_arm64-patch.zip"])
    let executable=root.appendingPathComponent(app.folder).appendingPathComponent(macExecutable)
    #expect(FileManager.default.isExecutableFile(atPath:executable.path))
    let plist=root.appendingPathComponent(app.folder).appendingPathComponent("Castor.app/Contents/Info.plist")
    let mode=try FileManager.default.attributesOfItem(atPath:plist.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue==0o644)
}

@Test func anOlderListWithoutModesFallsBackRatherThanSelectAnAppThatCannotRun() async throws {
    let (app,downloads,root)=try await updateAfterLosingTheExecutableBit(listsExecutables:false)
    defer {try? FileManager.default.removeItem(at:root)}
    #expect(downloads.last=="Castor-v2-macos_arm64.zip")
    let executable=root.appendingPathComponent(app.folder).appendingPathComponent(macExecutable)
    #expect(FileManager.default.isExecutableFile(atPath:executable.path))
    #expect(try DesktopInstaller.selected(root:root)?.folder==app.folder)
}

#endif

/// Users of older versions have Install.lock beside the versions; it is held
/// exclusively on Windows while installing or cleaning up.
@Test func cleanupWorksBesideTheOldLockFile() async throws {
    let root=updateRoot("old-lock");defer {try? FileManager.default.removeItem(at:root)}
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    try Data().write(to:root.appendingPathComponent("Install.lock"))
    let v1=try UpdateFixture(version:"v1",files:baseFiles)
    var changed=baseFiles;changed["CastorPet.exe"]=Data("pet v2".utf8)
    let v2=try UpdateFixture(version:"v2",files:changed),v3=try UpdateFixture(version:"v3",files:baseFiles)
    let extract=updateExtract([v1,v2,v3]),download=updateDownload([v1,v2,v3],log:DownloadLog())
    for fixture in [v1,v2,v3] {
        _ = try await DesktopInstaller.install(root:root,release:fixture.release,manifest:fixture.manifest,platform:"windows_x86_64",extract:extract,stamp:{_ in},download:download)
    }
    try Data("partial".utf8).write(to:DesktopInstaller.metadataRoot(root:root).appendingPathComponent(".tmp-left"))
    // v1 is neither current nor previous.
    #expect(try DesktopInstaller.pruneOldVersions(root:root,trash:{try FileManager.default.removeItem(at:$0)})==1)
    _ = try await DesktopInstaller.install(root:root,release:v3.release,manifest:v3.manifest,platform:"windows_x86_64",repair:true,extract:extract,stamp:{_ in},download:download)
    #expect(!FileManager.default.fileExists(atPath:DesktopInstaller.metadataRoot(root:root).appendingPathComponent(".tmp-left").path))
}

@Test func anUpdateStoppedBeforeSelectionIsCheckedAndSelectedNextTime() async throws {
    let root=updateRoot("resume-select");defer {try? FileManager.default.removeItem(at:root)}
    let v1=try UpdateFixture(version:"v1",files:baseFiles)
    var changed=baseFiles;changed["CastorPet.exe"]=Data("pet v2".utf8)
    let v2=try UpdateFixture(version:"v2",files:changed,patch:["CastorPet.exe"])
    let extract=updateExtract([v1,v2]),download=updateDownload([v1,v2],log:DownloadLog())
    let first=try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:"windows_x86_64",extract:extract,stamp:{_ in},download:download)
    let oldSelection=try Data(contentsOf:DesktopInstaller.selectionFile(root:root))
    let second=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"windows_x86_64",extract:extract,stamp:{_ in},download:download)
    // Power cut after the new folder was placed, before it was selected:
    try oldSelection.write(to:DesktopInstaller.selectionFile(root:root))
    // ...and an interrupted run's work folder and temporary file were left behind.
    try FileManager.default.createDirectory(at:root.appendingPathComponent(".castor-stage-left"),withIntermediateDirectories:true)
    try Data("partial".utf8).write(to:DesktopInstaller.metadataRoot(root:root).appendingPathComponent(".tmp-left"))
    let log=DownloadLog()
    let resumed=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"windows_x86_64",
        extract:extract,stamp:{_ in},download:updateDownload([],log:log))
    #expect(log.all.isEmpty)
    #expect(resumed.folder==second.folder)
    #expect(try DesktopInstaller.selected(root:root)?.folder==second.folder)
    #expect(FileManager.default.fileExists(atPath:root.appendingPathComponent(first.folder).path))
    #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent(".castor-stage-left").path))
    #expect(!FileManager.default.fileExists(atPath:DesktopInstaller.metadataRoot(root:root).appendingPathComponent(".tmp-left").path))
    // A placed folder that was changed is never selected; the update installs beside it.
    try oldSelection.write(to:DesktopInstaller.selectionFile(root:root))
    try Data("changed".utf8).write(to:root.appendingPathComponent(second.folder).appendingPathComponent("CastorPet.exe"))
    let beside=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"windows_x86_64",
        extract:extract,stamp:{_ in},download:download)
    #expect(beside.folder.hasPrefix("Castor-v2-windows_x86_64-repair-"))
    #expect(try contents(root,beside,"CastorPet.exe")==Data("pet v2".utf8))
    #expect(try contents(root,second,"CastorPet.exe")==Data("changed".utf8))
}

@Test func anInterruptedDownloadContinuesFromWhereItStopped() async throws {
    let root=updateRoot("resume-download");defer {try? FileManager.default.removeItem(at:root)}
    let v1=try UpdateFixture(version:"v1",files:baseFiles)
    let full=v1.assets["Castor-v1-windows_x86_64.zip"]!
    enum Stop: Error { case shutdown }
    final class Seen: @unchecked Sendable { let lock=NSLock(); var sizes:[Int]=[] }
    let seen=Seen()
    let download: @Sendable(URL,URL) async throws -> Void = { url,to in
        guard url.lastPathComponent.hasSuffix(".zip") else { return try v1.assets[url.lastPathComponent]!.write(to:to) }
        let existing=(try? Data(contentsOf:to)) ?? Data()
        seen.lock.withLock { seen.sizes.append(existing.count) }
        if existing.isEmpty {
            try full.prefix(full.count/2).write(to:to)
            throw Stop.shutdown
        }
        // A range request: append only the rest.
        let handle=try FileHandle(forWritingTo:to);defer {try? handle.close()}
        _ = try handle.seekToEnd();try handle.write(contentsOf:full.suffix(from:existing.count))
    }
    await #expect(throws:Stop.self) {
        try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:"windows_x86_64",
            extract:updateExtract([v1]),stamp:{_ in},download:download)
    }
    #expect(try DesktopInstaller.selected(root:root)==nil)
    let app=try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:"windows_x86_64",
        extract:updateExtract([v1]),stamp:{_ in},download:download)
    #expect(seen.lock.withLock { seen.sizes }==[0,full.count/2])
    #expect(try contents(root,app,"CastorPet.exe")==Data("pet v1".utf8))
}

@Test func aDamagedSelectionDoesNotBlockTheNextInstall() async throws {
    let root=updateRoot("damaged-selection");defer {try? FileManager.default.removeItem(at:root)}
    let v1=try UpdateFixture(version:"v1",files:baseFiles),v2=try UpdateFixture(version:"v2",files:baseFiles,patch:[])
    let extract=updateExtract([v1,v2]),download=updateDownload([v1,v2],log:DownloadLog())
    _ = try await DesktopInstaller.install(root:root,release:v1.release,manifest:v1.manifest,platform:"windows_x86_64",extract:extract,stamp:{_ in},download:download)
    // An empty selection file, as an older version could leave after a power cut.
    try Data().write(to:DesktopInstaller.selectionFile(root:root))
    let app=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"windows_x86_64",extract:extract,stamp:{_ in},download:download)
    #expect(try DesktopInstaller.selected(root:root)?.folder==app.folder)
}

@Test func durableWriteReplacesWholeFilesOnly() throws {
    let folder=updateRoot("durable");defer {try? FileManager.default.removeItem(at:folder)}
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let file=folder.appendingPathComponent("CurrentInstall.json")
    try DesktopInstaller.durableWrite(Data("first".utf8),to:file)
    try DesktopInstaller.durableWrite(Data("second".utf8),to:file)
    #expect(try Data(contentsOf:file)==Data("second".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath:folder.path)==["CurrentInstall.json"])
}

@Test func updateFileListsRejectUnsafePaths() throws {
    for path in ["../evil.dll","/evil.dll","a//b","a\\b","C:evil","./a",""] {
        #expect(!DesktopInstaller.safeRelativePath(path))
    }
    #expect(DesktopInstaller.safeRelativePath("UI/app.js"))
    let json=Data(#"{"schema":1,"files":{"a.dll":{"sha256":"\#(String(repeating:"0",count:64))","bytes":1},"A.DLL":{"sha256":"\#(String(repeating:"0",count:64))","bytes":1}}}"#.utf8)
    let listed=try JSONDecoder().decode(DesktopInstaller.UpdateInventory.self,from:json)
    #expect(throws:(any Error).self) { try listed.validate() }
}

// MARK: - One Castor in ~/Applications (Launchpad lists every app there)

/// A Mac version selected in `root`, as Setup records it.
@discardableResult
private func fakeMacInstall(root:URL,component:DesktopHelperComponent?=nil,version:String) throws -> DesktopInstalledApp {
    let stem=component?.stem ?? "Castor",manager=FileManager.default
    let folder=root.appendingPathComponent("\(stem)-\(version)-macos_arm64")
    let executable="\(stem).app/Contents/MacOS/\(stem)",body=Data("\(stem) \(version)".utf8)
    try manager.createDirectory(at:folder.appendingPathComponent(executable).deletingLastPathComponent(),withIntermediateDirectories:true)
    try body.write(to:folder.appendingPathComponent(executable))
    let app=DesktopInstalledApp(version:version,platform:"macos_arm64",folder:folder.lastPathComponent,component:component,
                                files:[executable:PackageIntegrity.sha256(body)])
    try JSONEncoder().encode(app).write(to:folder.appendingPathComponent("CastorInstall.json"))
    try manager.createDirectory(at:DesktopInstaller.metadataRoot(root:root),withIntermediateDirectories:true)
    try JSONEncoder().encode(app).write(to:DesktopInstaller.selectionFile(root:root))
    return app
}
/// What Setup up to v1.0.0 left: a version folder in ~/Applications and the link to it.
@discardableResult
private func legacyMacInstall(home:URL,component:DesktopHelperComponent?=nil) throws -> URL {
    let stem=component?.stem ?? "Castor"
    let root=DesktopInstallLayout.installationRoot(base:DesktopInstallLayout.macLegacyRoot(home:home),component:component)
    let folder=root.appendingPathComponent(try fakeMacInstall(root:root,component:component,version:"v1.0.0").folder)
    try FileManager.default.createSymbolicLink(at:DesktopInstallLayout.macLaunchFolder(home:home).appendingPathComponent(stem+".app"),
                                               withDestinationURL:folder.appendingPathComponent(stem+".app"))
    return folder
}
/// Moves items into `folder`, as the OS Trash would.
private func trash(into folder:URL) throws -> (URL) throws -> Void {
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    return { item in try FileManager.default.moveItem(at:item,to:folder.appendingPathComponent(UUID().uuidString+"-"+item.lastPathComponent)) }
}
private func linkTarget(_ folder:URL,_ name:String="Castor.app") throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath:folder.appendingPathComponent(name).path)
}
private func macRelease(_ version:String,_ files:[String:Data],patch:[String]?=nil) throws -> UpdateFixture {
    try UpdateFixture(version:version,files:files,patch:patch,platform:"macos_arm64",executables:[macExecutable])
}

// Launch links in ~/Applications and the old layout there exist only on the Mac.
#if !os(Windows)
@Test func aMacInstallAndItsUpdatesLeaveOneCastorInApplications() async throws {
    let home=updateRoot("mac-new");defer {try? FileManager.default.removeItem(at:home)}
    let root=DesktopInstallLayout.macVersionsRoot(home:home),apps=DesktopInstallLayout.macLaunchFolder(home:home)
    let legacy=DesktopInstallLayout.macLegacyRoot(home:home)
    var changed=macFiles;changed["Castor.app/Contents/Info.plist"]=Data("plist v2".utf8)
    let v1=try macRelease("v1",macFiles),v2=try macRelease("v2",changed,patch:["Castor.app/Contents/Info.plist"])
    let v3=try macRelease("v3",macFiles,patch:["Castor.app/Contents/Info.plist"])
    let fixtures=[v1,v2,v3],discard=try trash(into:home.appendingPathComponent("Trash"))
    for fixture in fixtures {
        let app=try await DesktopInstaller.install(root:root,release:fixture.release,manifest:fixture.manifest,platform:"macos_arm64",
            extract:updateExtract(fixtures),stamp:{_ in},download:updateDownload(fixtures,log:DownloadLog()))
        try DesktopInstallLayout.linkLaunchEntry(app,root:root,launchFolder:apps,legacyRoots:[legacy])
        _ = try DesktopInstaller.pruneOldVersions(root:root,trash:discard)
        #expect(try DesktopInstallLayout.retireLegacyVersions(legacyRoot:legacy,root:root,component:nil,trash:discard)==0)
        // The link and nothing else, hidden or not: versions and records are under Library.
        #expect(try FileManager.default.contentsOfDirectory(atPath:apps.path)==["Castor.app"])
        #expect(try linkTarget(apps)==root.appendingPathComponent(app.folder).appendingPathComponent("Castor.app").path)
        #expect(FileManager.default.isExecutableFile(atPath:apps.appendingPathComponent(macExecutable).path))
    }
    #expect(DesktopInstallLayout.selectedRoot(root:root,legacyRoot:legacy)==root)
    // Removing the app removes its link only.
    let current=try #require(try DesktopInstaller.selected(root:root))
    try DesktopInstaller.uninstall(root:root)
    DesktopInstallLayout.removeLaunchEntry(current,root:root,launchFolder:apps)
    #expect(try FileManager.default.contentsOfDirectory(atPath:apps.path).isEmpty)
}

@Test func theFirstUpdateFromTheOldLayoutMovesCastorOutOfApplications() async throws {
    let home=updateRoot("mac-migrate");defer {try? FileManager.default.removeItem(at:home)}
    let root=DesktopInstallLayout.macVersionsRoot(home:home),apps=DesktopInstallLayout.macLaunchFolder(home:home)
    let legacy=DesktopInstallLayout.macLegacyRoot(home:home)
    let old=try legacyMacInstall(home:home)
    // Characters and settings are in the app's container, which Setup never touches.
    let container=home.appendingPathComponent("Library/Containers/dev.pomegranate.prototype/Data/Library/Application Support/Castor")
    try FileManager.default.createDirectory(at:container,withIntermediateDirectories:true)
    let pet=container.appendingPathComponent("CastorPet.json");try Data("my pet".utf8).write(to:pet)
    // Until the update, Launch and Remove find the version where it is.
    #expect(DesktopInstallLayout.selectedRoot(root:root,legacyRoot:legacy)==legacy)

    var changed=macFiles;changed["Castor.app/Contents/Info.plist"]=Data("plist v2".utf8)
    let v2=try macRelease("v2",macFiles),v3=try macRelease("v3",changed,patch:["Castor.app/Contents/Info.plist"])
    let log=DownloadLog()
    let app=try await DesktopInstaller.install(root:root,release:v2.release,manifest:v2.manifest,platform:"macos_arm64",
        extract:updateExtract([v2,v3]),stamp:{_ in},download:updateDownload([v2,v3],log:log))
    // Nothing to reuse in the new place yet, so the whole package.
    #expect(log.all==["Castor-v2-macos_arm64.files.json","Castor-v2-macos_arm64.zip"])
    // The old link points into ~/Applications; it is the installer's, so it is replaced.
    try DesktopInstallLayout.linkLaunchEntry(app,root:root,launchFolder:apps,legacyRoots:[legacy])
    #expect(try linkTarget(apps)==root.appendingPathComponent(app.folder).appendingPathComponent("Castor.app").path)
    let trashFolder=home.appendingPathComponent("Trash")
    #expect(try DesktopInstallLayout.retireLegacyVersions(legacyRoot:legacy,root:root,component:nil,trash:trash(into:trashFolder))==1)
    #expect(try FileManager.default.contentsOfDirectory(atPath:apps.path)==["Castor.app"])
    // In the Trash, not deleted: the old version and its records.
    let trashed=try FileManager.default.contentsOfDirectory(atPath:trashFolder.path)
    #expect(trashed.contains {$0.hasSuffix("-"+old.lastPathComponent)})
    #expect(trashed.contains {$0.hasSuffix("-.CastorInstaller")})
    #expect(try Data(contentsOf:pet)==Data("my pet".utf8))
    #expect(DesktopInstallLayout.selectedRoot(root:root,legacyRoot:legacy)==root)

    // The next update reuses the files of the version in the new place.
    let second=DownloadLog()
    let next=try await DesktopInstaller.install(root:root,release:v3.release,manifest:v3.manifest,platform:"macos_arm64",
        extract:updateExtract([v2,v3]),stamp:{_ in},download:updateDownload([v2,v3],log:second))
    #expect(second.all==["Castor-v3-macos_arm64.files.json","Castor-v3-macos_arm64-patch.zip"])
    try DesktopInstallLayout.linkLaunchEntry(next,root:root,launchFolder:apps,legacyRoots:[legacy])
    #expect(try FileManager.default.contentsOfDirectory(atPath:apps.path)==["Castor.app"])
    #expect(try linkTarget(apps)==root.appendingPathComponent(next.folder).appendingPathComponent("Castor.app").path)
}

@Test func theHelperMovesTooAndKeepsTheLinkCastorOpensItBy() throws {
    let home=updateRoot("mac-helper");defer {try? FileManager.default.removeItem(at:home)}
    let apps=DesktopInstallLayout.macLaunchFolder(home:home)
    let root=DesktopInstallLayout.installationRoot(base:DesktopInstallLayout.macVersionsRoot(home:home),component:.neuralTTS)
    let legacy=DesktopInstallLayout.installationRoot(base:DesktopInstallLayout.macLegacyRoot(home:home),component:.neuralTTS)
    try legacyMacInstall(home:home,component:.neuralTTS)
    let app=try fakeMacInstall(root:root,component:.neuralTTS,version:"v2")
    try DesktopInstallLayout.linkLaunchEntry(app,root:root,launchFolder:apps,legacyRoots:[legacy])
    #expect(try DesktopInstallLayout.retireLegacyVersions(legacyRoot:legacy,root:root,component:.neuralTTS,
        emptyFolders:[legacy,legacy.deletingLastPathComponent()],trash:trash(into:home.appendingPathComponent("Trash")))==1)
    // Castor opens ~/Applications/CastorNeuralTTS.app; the emptied CastorHelpers folder is gone.
    #expect(try FileManager.default.contentsOfDirectory(atPath:apps.path)==["CastorNeuralTTS.app"])
    #expect(try linkTarget(apps,"CastorNeuralTTS.app")==root.appendingPathComponent(app.folder).appendingPathComponent("CastorNeuralTTS.app").path)
}

@Test func theLaunchLinkReplacesOnlyLinksTheInstallerMade() throws {
    let home=updateRoot("mac-link");defer {try? FileManager.default.removeItem(at:home)}
    let manager=FileManager.default
    let root=DesktopInstallLayout.macVersionsRoot(home:home),apps=DesktopInstallLayout.macLaunchFolder(home:home)
    let legacy=DesktopInstallLayout.macLegacyRoot(home:home),link=apps.appendingPathComponent("Castor.app")
    let app=try fakeMacInstall(root:root,version:"v2")
    let wanted=root.appendingPathComponent(app.folder).appendingPathComponent("Castor.app").path
    func linked()->Bool {(try? DesktopInstallLayout.linkLaunchEntry(app,root:root,launchFolder:apps,legacyRoots:[legacy])) != nil}
    // A copy of the app someone put there.
    try manager.createDirectory(at:link.appendingPathComponent("Contents"),withIntermediateDirectories:true)
    #expect(!linked());#expect(manager.fileExists(atPath:link.appendingPathComponent("Contents").path))
    try manager.removeItem(at:link)
    // Links to an app elsewhere, to a look-alike folder without the installer's
    // record, and to a folder whose record is the helper's.
    let elsewhere=home.appendingPathComponent("Elsewhere/Castor.app")
    let lookalike=apps.appendingPathComponent("Castor-mine/Castor.app")
    let helperRecord=apps.appendingPathComponent("Castor-v1-macos_arm64")
    for folder in [elsewhere,lookalike,helperRecord.appendingPathComponent("Castor.app")] {
        try manager.createDirectory(at:folder,withIntermediateDirectories:true)
    }
    try JSONEncoder().encode(DesktopInstalledApp(version:"v1",platform:"macos_arm64",folder:"CastorNeuralTTS-v1-macos_arm64",component:.neuralTTS))
        .write(to:helperRecord.appendingPathComponent("CastorInstall.json"))
    for other in [elsewhere,lookalike,helperRecord.appendingPathComponent("Castor.app")] {
        try manager.createSymbolicLink(at:link,withDestinationURL:other)
        #expect(!linked());#expect(try linkTarget(apps)==other.path)
        try manager.removeItem(at:link)
    }
    // A version that is not selected gets no link.
    let unselected=DesktopInstalledApp(version:"v9",platform:"macos_arm64",folder:"Castor-v9-macos_arm64")
    #expect((try? DesktopInstallLayout.linkLaunchEntry(unselected,root:root,launchFolder:apps,legacyRoots:[legacy]))==nil)
    #expect(!manager.fileExists(atPath:link.path))
    // A link an older Setup made, whose version is already in the Trash.
    try manager.createSymbolicLink(atPath:link.path,withDestinationPath:"Castor-v1.0.0-macos_arm64/Castor.app")
    #expect(linked());#expect(try linkTarget(apps)==wanted)
    try manager.removeItem(at:link)
    // And one whose version is still there.
    try legacyMacInstall(home:home)
    #expect(linked());#expect(try linkTarget(apps)==wanted)
}

@Test func retiringTheOldLayoutMovesOnlyTheInstallersVersions() throws {
    let home=updateRoot("mac-retire");defer {try? FileManager.default.removeItem(at:home)}
    let manager=FileManager.default
    let root=DesktopInstallLayout.macVersionsRoot(home:home),apps=DesktopInstallLayout.macLaunchFolder(home:home)
    let legacy=DesktopInstallLayout.macLegacyRoot(home:home)
    let old=try legacyMacInstall(home:home),meta=DesktopInstaller.metadataRoot(root:legacy)
    let discard=try trash(into:home.appendingPathComponent("Trash"))
    // Nothing moves before the new place has a version.
    #expect(try DesktopInstallLayout.retireLegacyVersions(legacyRoot:legacy,root:root,component:nil,trash:discard)==0)
    #expect(manager.fileExists(atPath:old.path))
    try fakeMacInstall(root:root,version:"v2")
    // Not the installer's: a folder from the older script downloader (no record) and another app.
    let script=apps.appendingPathComponent("Castor-v0.9-macos_arm64/Castor.app"),other=apps.appendingPathComponent("Other.app")
    for folder in [script,other] {try manager.createDirectory(at:folder,withIntermediateDirectories:true)}
    // While the old version runs, the Trash leaves it, and its records stay with it.
    #expect(try DesktopInstallLayout.retireLegacyVersions(legacyRoot:legacy,root:root,component:nil,trash:{_ in})==0)
    #expect(manager.fileExists(atPath:old.path));#expect(manager.fileExists(atPath:meta.path))
    // A later run moves it.
    #expect(try DesktopInstallLayout.retireLegacyVersions(legacyRoot:legacy,root:root,component:nil,trash:discard)==1)
    #expect(!manager.fileExists(atPath:old.path));#expect(!manager.fileExists(atPath:meta.path))
    #expect(manager.fileExists(atPath:script.path));#expect(manager.fileExists(atPath:other.path))
}

#endif
