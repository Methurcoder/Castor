import Foundation
import CInstallLock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DesktopHelperComponent:String,Codable,Sendable,CaseIterable {
    case neuralTTS = "NeuralTTS"
    /// The optional feeling model (data only: nothing to run or launch).
    case feelings = "Feelings"
    public var stem:String {"Castor"+rawValue}
    /// A helper app people launch (as opposed to data Castor reads).
    public var isApp:Bool {self == .neuralTTS}
    /// The file that must be present in an installed copy: the helper's
    /// executable, or the feeling model's description.
    public func executable(platform:String)->String {
        guard isApp else {return "feelings.json"}
        return platform.hasPrefix("macos") ? "\(stem).app/Contents/MacOS/\(stem)":"\(stem).exe"
    }
}
public struct DesktopRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable { public let name: String; public let browser_download_url: String; public let size: Int64 }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
}
/// One published release, as the update history shows it.
public struct DesktopReleaseNote: Decodable, Sendable, Equatable {
    public let tag_name: String
    public let name: String?
    public let body: String?
    public let published_at: String?
    public let draft: Bool
    public let prerelease: Bool
    public init(tag_name: String, name: String?, body: String?, published_at: String?, draft: Bool = false, prerelease: Bool = false) {
        self.tag_name = tag_name; self.name = name; self.body = body; self.published_at = published_at
        self.draft = draft; self.prerelease = prerelease
    }
    /// The display name ("Castor v1.0.0 (d)"), or the tag.
    public var title: String { (name?.isEmpty == false ? name : nil) ?? tag_name }
    /// The publication day, yyyy-MM-dd.
    public var day: String { String((published_at ?? "").prefix(10)) }
}
/// Where an installation is, for a progress display.
public enum DesktopInstallProgress: Sendable, Equatable {
    case downloading(received: Int64, total: Int64)
    case verifying
    case extracting
    /// Copying files that did not change from the installed version.
    case reusing
    case finishing
}
public struct DesktopDownloadManifest: Decodable, Sendable {
    /// A Release asset with its published size and SHA-256.
    public struct UpdateFile: Decodable, Sendable { public let asset: String; public let sha256: String; public let bytes: Int64 }
    public struct Package: Decodable, Sendable {
        public let asset: String; public let sha256: String; public let bytes: Int64
        /// Optional, ignored by older installers: the list of every installed
        /// file with its SHA-256 (`<package>.files.json`) and a ZIP of only the
        /// files that changed since the previous Release (`<package>-patch.zip`).
        public let inventory: UpdateFile?
        public let patch: UpdateFile?
        public init(asset:String,sha256:String,bytes:Int64,inventory:UpdateFile?=nil,patch:UpdateFile?=nil) {
            self.asset=asset;self.sha256=sha256;self.bytes=bytes;self.inventory=inventory;self.patch=patch
        }
    }
    public let schema: Int
    public let version: String
    public let platforms: [String: Package]
    public let components:[String:[String:Package]]?
    public init(schema:Int,version:String,platforms:[String:Package],components:[String:[String:Package]]?=nil) {
        self.schema=schema;self.version=version;self.platforms=platforms;self.components=components
    }
    public func package(platform: String, release: DesktopRelease,component:DesktopHelperComponent?=nil) throws -> (Package, URL) {
        let packages=component.map {components?[$0.rawValue] ?? [:]} ?? platforms
        let stem=component?.stem ?? "Castor"
        guard schema==1,version==release.tag_name,Self.validVersion(version),!release.draft,!release.prerelease,
              let package=packages[platform],package.asset=="\(stem)-\(version)-\(platform).zip",
              package.sha256.count==64,package.sha256.allSatisfy({"0123456789abcdef".contains($0)}),package.bytes>0,package.bytes<2_147_483_648,
              let url=Self.releaseURL(package.asset,bytes:package.bytes,release:release) else { throw DesktopInstaller.InstallError.invalidManifest }
        return(package,url)
    }
    /// The file list and patch of `package`, when this Release publishes them.
    func updateFiles(_ package:Package,platform:String,release:DesktopRelease,component:DesktopHelperComponent?)
        -> (inventory:(UpdateFile,URL),patch:(UpdateFile,URL)?)? {
        let stem="\(component?.stem ?? "Castor")-\(version)-\(platform)"
        func checked(_ file:UpdateFile?,name:String,limit:Int64)->(UpdateFile,URL)? {
            guard let file,file.asset==name,file.sha256.count==64,file.sha256.allSatisfy({"0123456789abcdef".contains($0)}),
                  file.bytes>0,file.bytes<limit,let url=Self.releaseURL(file.asset,bytes:file.bytes,release:release) else {return nil}
            return(file,url)
        }
        guard let inventory=checked(package.inventory,name:stem+".files.json",limit:16_777_216) else {return nil}
        return(inventory,checked(package.patch,name:stem+"-patch.zip",limit:2_147_483_648))
    }
    /// The download URL of a Release asset, if it is published exactly once with this size.
    static func releaseURL(_ name:String,bytes:Int64,release:DesktopRelease)->URL? {
        guard release.assets.filter({$0.name==name}).count==1,let asset=release.assets.first(where:{$0.name==name}),asset.size==bytes,
              let url=URL(string:asset.browser_download_url),url.scheme=="https",url.host=="github.com",
              url.user==nil,url.password==nil,url.port==nil,url.query==nil,url.fragment==nil,
              url.path=="/Methurcoder/Castor/releases/download/\(release.tag_name)/\(name)" else {return nil}
        return url
    }
    static func validVersion(_ value: String) -> Bool {
        value.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",options:.regularExpression) != nil
    }
}
public struct DesktopInstalledApp: Codable, Sendable {
    public let version: String
    public let platform: String
    public let folder: String
    public let component:DesktopHelperComponent?
    public let files:[String:String]?
    public init(version:String,platform:String,folder:String,component:DesktopHelperComponent?=nil,files:[String:String]?=nil) {
        self.version=version;self.platform=platform;self.folder=folder;self.component=component;self.files=files
    }
}
public enum DesktopInstaller {
    public enum InstallError: LocalizedError {
        case noRelease, invalidManifest, downloadFailed(Int), integrity, existing, missingApp, busy
        public var errorDescription: String? {
            switch self {
            case .noRelease: "公開された配布Releaseがまだありません。ソース公開だけではアプリを取得できません。"
            case .invalidManifest: "配布情報が不正、またはこのOS/CPU向け本体・追加helperがありません。"
            case let .downloadFailed(status): "取得に失敗しました（HTTP \(status)）。既存アプリとデータは保持しています。"
            case .integrity: "容量またはSHA-256が一致しません。既存アプリを保持して取得を中止しました。"
            case .existing: "同じ版が既にあります。起動または修復を選んでください。"
            case .busy: "別の導入・削除が処理中です。終了後にもう一度実行してください。"
            case .missingApp: "展開したアプリ本体または必要なランタイムがありません。"
            }
        }
    }
    public static func latest() async throws -> (DesktopRelease, DesktopDownloadManifest) {
        let session=URLSession(configuration:.ephemeral);defer { session.invalidateAndCancel() }
        var request=URLRequest(url:URL(string:"https://api.github.com/repos/Methurcoder/Castor/releases/latest")!)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept");request.timeoutInterval=30
        let(data,response)=try await session.data(for:request)
        let status=(response as? HTTPURLResponse)?.statusCode ?? 0
        if status==404 { throw InstallError.noRelease };guard status==200,data.count<=2_097_152 else { throw InstallError.downloadFailed(status) }
        let release=try JSONDecoder().decode(DesktopRelease.self,from:data)
        guard release.assets.filter({$0.name=="castor-downloads.json"}).count==1,
              let asset=release.assets.first(where:{$0.name=="castor-downloads.json"}),asset.size>0,asset.size<=1_048_576,
              let url=URL(string:asset.browser_download_url),url.scheme=="https",url.host=="github.com",
              DesktopDownloadManifest.validVersion(release.tag_name),!release.draft,!release.prerelease,
              url.user==nil,url.password==nil,url.port==nil,url.query==nil,url.fragment==nil,
              url.path=="/Methurcoder/Castor/releases/download/\(release.tag_name)/castor-downloads.json" else { throw InstallError.invalidManifest }
        let(manifest,manifestResponse)=try await session.data(from:url)
        guard (manifestResponse as? HTTPURLResponse)?.statusCode==200,manifest.count<=1_048_576 else { throw InstallError.invalidManifest }
        try Task.checkCancellation()
        return(release,try JSONDecoder().decode(DesktopDownloadManifest.self,from:manifest))
    }
    /// Published releases, newest first, for the update history.
    public static func releaseNotes(limit: Int = 30) async throws -> [DesktopReleaseNote] {
        let session=URLSession(configuration:.ephemeral);defer { session.invalidateAndCancel() }
        var request=URLRequest(url:URL(string:"https://api.github.com/repos/Methurcoder/Castor/releases?per_page=\(max(1,min(limit,100)))")!)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept");request.timeoutInterval=30
        let(data,response)=try await session.data(for:request)
        let status=(response as? HTTPURLResponse)?.statusCode ?? 0
        guard status==200,data.count<=8_388_608 else { throw InstallError.downloadFailed(status) }
        return try JSONDecoder().decode([DesktopReleaseNote].self,from:data).filter { !$0.draft && !$0.prerelease }
    }
    public static func metadataRoot(root:URL)->URL {root.appendingPathComponent(".CastorInstaller",isDirectory:true)}
    public static func selectionFile(root:URL)->URL {metadataRoot(root:root).appendingPathComponent("CurrentInstall.json")}
    private static func previousFile(root:URL)->URL {metadataRoot(root:root).appendingPathComponent("PreviousInstall.json")}
    static func readRecord(_ file:URL) throws -> DesktopInstalledApp? {
        guard FileManager.default.fileExists(atPath:file.path) else {return nil}
        guard !(try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink ?? false) else {throw InstallError.invalidManifest}
        let data=try Data(contentsOf:file);guard data.count<=4_194_304 else {throw InstallError.invalidManifest}
        let app=try JSONDecoder().decode(DesktopInstalledApp.self,from:data)
        guard DesktopDownloadManifest.validVersion(app.version),["macos_arm64","macos_x86_64","windows_x86_64"].contains(app.platform),validFolder(app),
              !app.folder.contains("/"),!app.folder.contains("\\"),!app.folder.contains(":"),app.folder != ".",app.folder != ".." else {throw InstallError.invalidManifest}
        return app
    }
    public static func selected(root:URL) throws -> DesktopInstalledApp? {
        let file=selectionFile(root:root)
        if FileManager.default.fileExists(atPath:file.path) {return try readRecord(file)}
        // Old receipts remain readable and are never overwritten by migration.
        return try readRecord(root.appendingPathComponent("CurrentInstall.json"))
    }
    /// Extract/stamp are native adapters. Stage and target share a volume; an
    /// incomplete/cancelled replacement never touches the previous installation.
    private static func validFolder(_ app: DesktopInstalledApp) -> Bool {
        let base="\(app.component?.stem ?? "Castor")-\(app.version)-\(app.platform)"
        if app.folder==base { return true }
        let prefix=base+"-repair-"
        return app.folder.hasPrefix(prefix) && UUID(uuidString:String(app.folder.dropFirst(prefix.count))) != nil
    }
    struct Lease {
        let primary:UnsafeMutableRawPointer
        let legacy:UnsafeMutableRawPointer?
        func release() {castor_install_unlock(primary);if let legacy {castor_install_unlock(legacy)}}
    }
    static func lock(root:URL) throws -> Lease {
        let manager=FileManager.default,meta=metadataRoot(root:root)
        try manager.createDirectory(at:meta,withIntermediateDirectories:true)
        guard !(try meta.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink ?? false) else {throw InstallError.invalidManifest}
        let old=root.appendingPathComponent("Install.lock")
        let legacy=manager.fileExists(atPath:old.path) ? old.path.withCString {castor_install_lock($0)}:nil
        if manager.fileExists(atPath:old.path),legacy==nil {throw InstallError.busy}
        guard let primary=meta.appendingPathComponent("Install.lock").path.withCString({castor_install_lock($0)}) else {
            if let legacy {castor_install_unlock(legacy)};throw InstallError.busy
        }
        return Lease(primary:primary,legacy:legacy)
    }
    /// Streams the body into `destination` as it arrives, so its growing
    /// size can be shown as progress while the download runs. A partial file
    /// left by an interrupted run (shutdown, crash, lost connection) is
    /// continued with an HTTP range request; a server that answers with the
    /// whole file instead simply restarts it.
    public static func download(_ url: URL, to destination: URL) async throws {
        let manager=FileManager.default
        if !manager.fileExists(atPath:destination.path) { guard manager.createFile(atPath:destination.path,contents:nil) else { throw InstallError.downloadFailed(0) } }
        guard let handle=try? FileHandle(forWritingTo:destination) else { throw InstallError.downloadFailed(0) }
        let offset=(try? handle.seekToEnd()) ?? 0
        let receiver=StreamingDownload(handle:handle,offset:offset)
        let session=URLSession(configuration:.ephemeral,delegate:receiver,delegateQueue:nil)
        defer { session.invalidateAndCancel(); try? handle.close() }
        var request=URLRequest(url:url)
        if offset>0 { request.setValue("bytes=\(offset)-",forHTTPHeaderField:"Range") }
        let task=session.dataTask(with:request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                receiver.start(continuation)
                task.resume()
            }
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard receiver.status==200||receiver.status==206 else { throw InstallError.downloadFailed(receiver.status) }
    }

    /// Where downloads wait until they are verified and installed. A file
    /// here survives an interrupted update so the next run continues it.
    static func downloadsFolder(root:URL)->URL {metadataRoot(root:root).appendingPathComponent("Downloads",isDirectory:true)}

    /// Downloads (or continues) one Release asset and checks its size and SHA-256.
    private static func fetch(_ file:DesktopDownloadManifest.UpdateFile,from url:URL,root:URL,
                              download: @Sendable (URL,URL) async throws -> Void,
                              progress: (@Sendable (DesktopInstallProgress) -> Void)?) async throws -> URL {
        let manager=FileManager.default,folder=downloadsFolder(root:root)
        try manager.createDirectory(at:folder,withIntermediateDirectories:true)
        guard !(try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink ?? false) else {throw InstallError.invalidManifest}
        let part=folder.appendingPathComponent(file.sha256+".zip")
        // Only one download is kept: anything else here is from an older Release.
        for other in (try? manager.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? [] where other.lastPathComponent != part.lastPathComponent {
            try? manager.removeItem(at:other)
        }
        func size()->Int64 {(try? manager.attributesOfItem(atPath:part.path)[.size] as? NSNumber)?.int64Value ?? -1}
        if size()>file.bytes { try manager.removeItem(at:part) }
        if size()<file.bytes {
            let watcher=progress.map { report in
                Task.detached {
                    report(.downloading(received:max(0,size()),total:file.bytes))
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds:200_000_000)
                        if Task.isCancelled { break }
                        report(.downloading(received:min(max(0,size()),file.bytes),total:file.bytes))
                    }
                }
            }
            do { try await download(url,part) } catch { watcher?.cancel(); throw error }
            // Stop the watcher before the next step, so no late report follows it.
            watcher?.cancel()
            await watcher?.value
        }
        progress?(.downloading(received:file.bytes,total:file.bytes))
        progress?(.verifying)
        guard size()==file.bytes,try PackageIntegrity.sha256(file:part)==file.sha256 else {
            try? manager.removeItem(at:part)
            throw InstallError.integrity
        }
        return part
    }

    /// Every file of a package as published (`<package>.files.json`).
    struct UpdateInventory: Decodable {
        struct Entry: Decodable {
            let sha256: String; let bytes: Int64
            /// Runnable in the release ZIP. Absent in lists published before
            /// it was recorded.
            let executable: Bool?
        }
        let schema: Int
        let files: [String: Entry]
        let patch: [String]?
        var hashes: [String: String] { files.mapValues(\.sha256) }
        func validate() throws {
            var folded=Set<String>()
            guard schema==1,!files.isEmpty,files.count<=20_000,
                  files.allSatisfy({ path,entry in
                      DesktopInstaller.safeRelativePath(path) && folded.insert(path.lowercased()).inserted && entry.bytes>=0
                          && entry.sha256.count==64 && entry.sha256.allSatisfy({"0123456789abcdef".contains($0)})
                  }),
                  (patch ?? []).allSatisfy({files[$0] != nil}) else {throw InstallError.invalidManifest}
        }
    }
    static func safeRelativePath(_ path:String)->Bool {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        return !path.isEmpty && path.utf8.count<=1024 && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where:{$0.value<32})
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Builds the new version from the installed one: files whose SHA-256 is
    /// already on disk are copied, the rest come from the patch ZIP. Throws if
    /// anything is missing or differs, so the caller can fall back to the full ZIP.
    private static func assembleFromInstalled(_ inventory:UpdateInventory,patch:(DesktopDownloadManifest.UpdateFile,URL)?,
                                              previous:DesktopInstalledApp,root:URL,stage:URL,into payload:URL,platform:String,
                                              component:DesktopHelperComponent?,extract: @Sendable (URL,URL) async throws -> Void,
                                              download: @Sendable (URL,URL) async throws -> Void,
                                              progress: (@Sendable (DesktopInstallProgress) -> Void)?) async throws -> [String:String] {
        let manager=FileManager.default
        let installed=root.appendingPathComponent(previous.folder,isDirectory:true)
        guard previous.platform==platform,previous.component==component,let known=previous.files,!known.isEmpty,
              !(try installed.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink ?? false) else {throw InstallError.missingApp}
        var local=[String:String]()
        for (path,sha) in known where safeRelativePath(path) { local[sha]=local[sha] ?? path }
        var sources=[String:URL]()
        var missing=Set<String>()
        for (path,entry) in inventory.files {
            if let found=local[entry.sha256] { sources[path]=installed.appendingPathComponent(found) } else { missing.insert(path) }
        }
        if !missing.isEmpty {
            guard let patch,missing.isSubset(of:Set(inventory.patch ?? [])) else {throw InstallError.missingApp}
            let archive=try await fetch(patch.0,from:patch.1,root:root,download:download,progress:progress)
            try Task.checkCancellation()
            try PackageZIP.validate(Data(contentsOf:archive,options:.mappedIfSafe),platform:platform,component:component)
            let unpacked=stage.appendingPathComponent("patch",isDirectory:true)
            try manager.createDirectory(at:unpacked,withIntermediateDirectories:false)
            progress?(.extracting)
            try await extract(archive,unpacked)
            for path in missing { sources[path]=unpacked.appendingPathComponent(path) }
        }
        try Task.checkCancellation()
        progress?(.reusing)
        try manager.createDirectory(at:payload,withIntermediateDirectories:false)
        for (path,source) in sources.sorted(by:{$0.key<$1.key}) {
            let flags=try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard flags.isRegularFile==true,flags.isSymbolicLink != true else {throw InstallError.missingApp}
            let target=payload.appendingPathComponent(path)
            try manager.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            try manager.copyItem(at:source,to:target)
            try Task.checkCancellation()
        }
        progress?(.verifying)
        let assembled=try fileFingerprint(payload)
        guard assembled==inventory.hashes else {throw InstallError.integrity}
        try applyAndCheckModes(inventory,in:payload,platform:platform,component:component)
        return assembled
    }

    /// A reused file matches by content alone, and keeps whatever permission
    /// its installed copy has, which may have been lost. Sets each file's mode
    /// from the published list, then checks that everything the release runs
    /// is runnable — the Mac app's executable even when an older list does not
    /// say. Throws so the caller falls back to the full package.
    static func applyAndCheckModes(_ inventory:UpdateInventory,in payload:URL,platform:String,
                                   component:DesktopHelperComponent?) throws {
        #if !os(Windows)
        let manager=FileManager.default
        for (path,entry) in inventory.files {
            guard let executable=entry.executable else {continue}
            try manager.setAttributes([.posixPermissions:executable ? 0o755 : 0o644],
                                      ofItemAtPath:payload.appendingPathComponent(path).path)
        }
        var runnable=inventory.files.filter { $0.value.executable==true }.map(\.key)
        if platform.hasPrefix("macos"), component?.isApp ?? true {
            runnable.append(component?.executable(platform:platform) ?? "Castor.app/Contents/MacOS/Castor")
        }
        guard runnable.allSatisfy({ manager.isExecutableFile(atPath:payload.appendingPathComponent($0).path) }) else {
            throw InstallError.integrity
        }
        #endif
    }

    /// Removes work folders of runs that were interrupted (shutdown, crash).
    /// Called under the install lock, so no other run is using them.
    private static func removeStaleWork(root:URL) {
        let manager=FileManager.default
        for item in (try? manager.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
        where item.lastPathComponent.hasPrefix(".castor-stage-") { try? manager.removeItem(at:item) }
        for item in (try? manager.contentsOfDirectory(at:metadataRoot(root:root),includingPropertiesForKeys:nil)) ?? []
        where item.lastPathComponent.hasPrefix(".tmp-") { try? manager.removeItem(at:item) }
    }

    /// An installed version folder that is complete: its own record matches
    /// and every file still has the SHA-256 recorded when it was installed.
    private static func completedInstall(_ folder:URL,name:String,version:String,platform:String,
                                         component:DesktopHelperComponent?)->DesktopInstalledApp? {
        guard !((try? folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) ?? true),
              let record=try? readRecord(folder.appendingPathComponent("CastorInstall.json")),
              record.folder==name,record.version==version,record.platform==platform,record.component==component,
              let files=record.files,!files.isEmpty,(try? fileFingerprint(folder))==files else {return nil}
        return record
    }

    /// Writes `data` so that after a power cut the file holds either its old
    /// or its new contents, never a partial or empty file.
    static func durableWrite(_ data:Data,to file:URL) throws {
        // Same folder, so the replacement is a rename; leftovers are removed by removeStaleWork.
        let staging=file.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to:staging,options:.withoutOverwriting)
        let replaced=staging.path.withCString { from in file.path.withCString { castor_durable_replace(from,$0) } }
        guard replaced==1 else { try? FileManager.default.removeItem(at:staging); throw InstallError.missingApp }
    }

    /// Flushes every file of a new version to disk before it is selected.
    /// Best effort: a file that cannot be opened for flushing is left as is.
    private static func flushTree(_ folder:URL) {
        guard let items=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey]) else {return}
        for case let item as URL in items where (try? item.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true {
            _ = item.path.withCString { castor_flush_path($0) }
        }
        _ = folder.path.withCString { castor_flush_path($0) }
    }

    /// Makes `installed` the current version. The previous selection is kept
    /// as PreviousInstall.json first, so an interruption between the two
    /// writes leaves the old selection in place.
    private static func select(_ installed:DesktopInstalledApp,previous:DesktopInstalledApp?,root:URL) throws {
        if let previous,previous.folder != installed.folder { try durableWrite(JSONEncoder().encode(previous),to:previousFile(root:root)) }
        try durableWrite(JSONEncoder().encode(installed),to:selectionFile(root:root))
        let legacy=root.appendingPathComponent("CurrentInstall.json")
        if let old=try? readRecord(legacy),old.folder==previous?.folder,old.platform==previous?.platform,old.component==previous?.component {
            // PreviousInstall now preserves this exact old receipt.
            try? FileManager.default.removeItem(at:legacy)
        }
    }

    /// Installs the Release next to the current version and selects it.
    ///
    /// Safe to interrupt at any point (shutdown, crash, cancel):
    /// - work happens in a stage folder; the old version and its selection are untouched;
    /// - a partial download is continued by the next run;
    /// - the new version appears by one rename, with its files flushed first;
    /// - if a run stopped after that rename but before selecting it, the next
    ///   run checks the placed folder file by file and only then selects it;
    /// - selection files are replaced in one step that survives a power cut.
    ///
    /// When the Release lists its files, only changed files are downloaded and
    /// unchanged ones are copied from the installed version; every file is
    /// checked against the list, and any difference falls back to the full ZIP.
    public static func install(root: URL, release: DesktopRelease, manifest: DesktopDownloadManifest, platform: String,
                               repair: Bool=false,component:DesktopHelperComponent?=nil, extract: @Sendable (URL,URL) async throws -> Void,
                               stamp: @Sendable (URL) throws -> Void,
                               download: @Sendable (URL,URL) async throws -> Void = { try await DesktopInstaller.download($0,to:$1) },
                               progress: (@Sendable (DesktopInstallProgress) -> Void)? = nil) async throws -> DesktopInstalledApp {
        let(package,url)=try manifest.package(platform:platform,release:release,component:component)
        try Task.checkCancellation()
        let manager=FileManager.default
        try manager.createDirectory(at:root,withIntermediateDirectories:true)
        let lease=try lock(root:root);defer { lease.release() }
        removeStaleWork(root:root)
        // An unreadable selection (for example damaged by an older version
        // during a power cut) must not block the repair that replaces it.
        let previous=try? selected(root:root)
        let base="\(component?.stem ?? "Castor")-\(manifest.version)-\(platform)"
        var folder=base+(repair ? "-repair-\(UUID().uuidString)" : "")
        var target=root.appendingPathComponent(folder,isDirectory:true)
        if manager.fileExists(atPath:target.path) {
            if previous?.folder==folder { throw InstallError.existing }
            progress?(.verifying)
            if let placed=completedInstall(target,name:folder,version:manifest.version,platform:platform,component:component) {
                // An earlier run placed this version and stopped before selecting it.
                try Task.checkCancellation()
                try select(placed,previous:previous,root:root)
                return placed
            }
            // Leave an unknown or changed folder untouched and install beside it.
            folder=base+"-repair-\(UUID().uuidString)"
            target=root.appendingPathComponent(folder,isDirectory:true)
        }
        let stage=root.appendingPathComponent(".castor-stage-\(UUID().uuidString)",isDirectory:true)
        try manager.createDirectory(at:stage,withIntermediateDirectories:false)
        defer { try? manager.removeItem(at:stage) }
        let unpacked=stage.appendingPathComponent("payload",isDirectory:true)

        // The published file list, when there is one, checks every installed file.
        var inventory: UpdateInventory?
        let updateFiles=manifest.updateFiles(package,platform:platform,release:release,component:component)
        if let (listed,listedURL)=updateFiles?.inventory {
            let file=stage.appendingPathComponent("files.json")
            do {
                try await download(listedURL,file)
                let data=try Data(contentsOf:file)
                guard Int64(data.count)==listed.bytes,PackageIntegrity.sha256(data)==listed.sha256 else {throw InstallError.integrity}
                let decoded=try JSONDecoder().decode(UpdateInventory.self,from:data)
                try decoded.validate()
                inventory=decoded
            } catch is CancellationError { throw CancellationError() } catch { inventory=nil }
        }
        var verified: [String:String]?
        if !repair,let inventory,let previous {
            do {
                verified=try await assembleFromInstalled(inventory,patch:updateFiles?.patch,previous:previous,root:root,stage:stage,
                    into:unpacked,platform:platform,component:component,extract:extract,download:download,progress:progress)
            } catch is CancellationError { throw CancellationError() } catch {
                // Anything missing or different: use the full package instead.
                try? manager.removeItem(at:unpacked)
                verified=nil
            }
        }
        if verified==nil {
            let archive=try await fetch(.init(asset:package.asset,sha256:package.sha256,bytes:package.bytes),from:url,root:root,
                                        download:download,progress:progress)
            try Task.checkCancellation()
            try PackageZIP.validate(Data(contentsOf:archive,options:.mappedIfSafe),platform:platform,component:component)
            try manager.createDirectory(at:unpacked,withIntermediateDirectories:false)
            progress?(.extracting)
            try await extract(archive,unpacked)
        }
        try Task.checkCancellation()
        let executable=unpacked.appendingPathComponent(component?.executable(platform:platform) ?? (platform.hasPrefix("macos") ? "Castor.app/Contents/MacOS/Castor" : "CastorPet.exe"))
        guard manager.fileExists(atPath:executable.path),
              !platform.hasPrefix("macos")||component?.isApp==false||manager.isExecutableFile(atPath:executable.path),
              component != nil||platform.hasPrefix("macos")||manager.fileExists(atPath:unpacked.appendingPathComponent("swiftCore.dll").path) else { throw InstallError.missingApp }
        if component == .neuralTTS,platform=="windows_x86_64" {
            let runtime=unpacked.appendingPathComponent("_internal",isDirectory:true)
            let files=(try? manager.contentsOfDirectory(atPath:runtime.path)) ?? []
            guard manager.fileExists(atPath:runtime.appendingPathComponent("base_library.zip").path),
                  files.contains(where:{$0.lowercased().hasPrefix("python") && $0.lowercased().hasSuffix(".dll")}) else {throw InstallError.missingApp}
        }
        progress?(.finishing)
        try stamp(unpacked)
        // Stamping marks files (quarantine, Zone.Identifier) without changing
        // their contents, so a file list verified above is still exact.
        let files=try verified ?? fileFingerprint(unpacked)
        if let inventory,files != inventory.hashes { throw InstallError.integrity }
        let installed=DesktopInstalledApp(version:manifest.version,platform:platform,folder:folder,component:component,files:files)
        let metadata=try JSONEncoder().encode(installed)
        try metadata.write(to:unpacked.appendingPathComponent("CastorInstall.json"),options:.withoutOverwriting)
        flushTree(unpacked)
        try Task.checkCancellation()
        try manager.moveItem(at:unpacked,to:target)
        _ = root.path.withCString { castor_flush_path($0) }
        // At this point a fully recoverable new app exists; failure to select
        // it retains the old selection and all user data, and the next run
        // selects it after checking it.
        try Task.checkCancellation()
        try select(installed,previous:previous,root:root)
        try? manager.removeItem(at:downloadsFolder(root:root))
        return installed
    }
    private static func fileFingerprint(_ folder:URL) throws -> [String:String] {
        guard let items=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else {throw InstallError.missingApp}
        var files=[String:String]()
        for case let item as URL in items {
            let flags=try item.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard flags.isSymbolicLink != true else {throw InstallError.invalidManifest}
            if flags.isRegularFile == true {
                let base=folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                let full=item.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                guard Array(full.prefix(base.count))==base else {throw InstallError.invalidManifest}
                let relative=full.dropFirst(base.count).joined(separator:"/")
                if relative=="CastorInstall.json" || relative==".DS_Store" {continue}
                guard files.count<20_000 else {throw InstallError.invalidManifest}
                files[relative]=try PackageIntegrity.sha256(file:item)
            }
        }
        return files
    }
    /// Recycle only unchanged, inventoried managed versions. Unknown/modified
    /// folders, active selection and the previous selection remain untouched.
    public static func pruneOldVersions(root:URL,trash:(URL)throws->Void) throws -> Int {
        let lease=try lock(root:root);defer {lease.release()}
        guard let current=try selected(root:root) else {return 0}
        let previous=try readRecord(previousFile(root:root))
        let keep=Set([current.folder,previous?.folder].compactMap {$0})
        var count=0
        for folder in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) {
            guard !keep.contains(folder.lastPathComponent),folder.lastPathComponent.hasPrefix((current.component?.stem ?? "Castor")+"-") else {continue}
            let flags=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard flags.isDirectory==true,flags.isSymbolicLink != true,
                  let old=try? readRecord(folder.appendingPathComponent("CastorInstall.json")),
                  old.folder==folder.lastPathComponent,old.platform==current.platform,old.component==current.component,
                  let inventory=old.files,!inventory.isEmpty,
                  let actual=try? fileFingerprint(folder),actual==inventory else {continue}
            try trash(folder);if !FileManager.default.fileExists(atPath:folder.path) {count+=1}
        }
        return count
    }
    public static func uninstall(root: URL) throws {
        let lease=try lock(root:root);defer { lease.release() }
        guard let app=try selected(root:root) else { return }
        let folder=root.appendingPathComponent(app.folder,isDirectory:true)
        let marker=folder.appendingPathComponent("CastorInstall.json")
        let own=try JSONDecoder().decode(DesktopInstalledApp.self,from:Data(contentsOf:marker))
        guard own.folder==app.folder,own.platform==app.platform,own.version==app.version,own.component==app.component,
              !((try folder.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink ?? false) else { throw InstallError.invalidManifest }
        try FileManager.default.removeItem(at:folder)
        let record=selectionFile(root:root)
        try FileManager.default.removeItem(at:FileManager.default.fileExists(atPath:record.path) ? record:root.appendingPathComponent("CurrentInstall.json"))
    }
}

/// Receives a download chunk by chunk into a file.
private final class StreamingDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    /// Bytes already in the file from an interrupted download.
    private let offset: UInt64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var writeError: Error?
    private(set) var status = 0

    init(handle: FileHandle, offset: UInt64 = 0) { self.handle = handle; self.offset = offset }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        var code = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            if code == 200 {
                // The whole file: start over.
                try handle.truncate(atOffset: 0)
            } else if code == 206 {
                // Only a continuation of exactly what is on disk is accepted.
                let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                if offset == 0 || !range.hasPrefix("bytes \(offset)-") {
                    try handle.truncate(atOffset: 0)
                    code = 0
                }
            }
        } catch {
            lock.withLock { writeError = error }
            code = 0
        }
        lock.withLock { status = code }
        completionHandler(code == 200 || code == 206 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle.write(contentsOf: data) } catch {
            lock.withLock { writeError = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure, code) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?, Int) in
            defer { self.continuation = nil }
            return (self.continuation, writeError, status)
        }
        if let failure { continuation?.resume(throwing: failure) }
        else if code != 200 && code != 206 { continuation?.resume(throwing: DesktopInstaller.InstallError.downloadFailed(code)) }
        else if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}
