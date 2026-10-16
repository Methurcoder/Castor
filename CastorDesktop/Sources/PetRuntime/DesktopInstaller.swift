import Foundation
import CInstallLock
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DesktopHelperComponent:String,Codable,Sendable {
    case neuralTTS = "NeuralTTS"
    public var stem:String {"Castor"+rawValue}
    public func executable(platform:String)->String {
        platform.hasPrefix("macos") ? "\(stem).app/Contents/MacOS/\(stem)":"\(stem).exe"
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
    case finishing
}
public struct DesktopDownloadManifest: Decodable, Sendable {
    public struct Package: Decodable, Sendable { public let asset: String; public let sha256: String; public let bytes: Int64 }
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
              let asset=release.assets.first(where:{$0.name==package.asset}),
              release.assets.filter({$0.name==package.asset}).count==1,asset.size==package.bytes,
              let url=URL(string:asset.browser_download_url),url.scheme=="https",url.host=="github.com",
              url.user==nil,url.password==nil,url.port==nil,url.query==nil,url.fragment==nil,
              url.path=="/Methurcoder/Castor/releases/download/\(version)/\(package.asset)" else { throw DesktopInstaller.InstallError.invalidManifest }
        return(package,url)
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
    private static func readRecord(_ file:URL) throws -> DesktopInstalledApp? {
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
    private struct Lease {
        let primary:UnsafeMutableRawPointer
        let legacy:UnsafeMutableRawPointer?
        func release() {castor_install_unlock(primary);if let legacy {castor_install_unlock(legacy)}}
    }
    private static func lock(root:URL) throws -> Lease {
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
    /// size can be shown as progress while the download runs.
    public static func download(_ url: URL, to destination: URL) async throws {
        guard FileManager.default.createFile(atPath:destination.path,contents:nil),
              let handle=try? FileHandle(forWritingTo:destination) else { throw InstallError.downloadFailed(0) }
        let receiver=StreamingDownload(handle:handle)
        let session=URLSession(configuration:.ephemeral,delegate:receiver,delegateQueue:nil)
        defer { session.invalidateAndCancel(); try? handle.close() }
        let task=session.dataTask(with:url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                receiver.start(continuation)
                task.resume()
            }
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard receiver.status==200 else { throw InstallError.downloadFailed(receiver.status) }
    }
    public static func install(root: URL, release: DesktopRelease, manifest: DesktopDownloadManifest, platform: String,
                               repair: Bool=false,component:DesktopHelperComponent?=nil, extract: @Sendable (URL,URL) async throws -> Void,
                               stamp: @Sendable (URL) throws -> Void,
                               download: @Sendable (URL,URL) async throws -> Void = { try await DesktopInstaller.download($0,to:$1) },
                               progress: (@Sendable (DesktopInstallProgress) -> Void)? = nil) async throws -> DesktopInstalledApp {
        let(package,url)=try manifest.package(platform:platform,release:release,component:component)
        try Task.checkCancellation()
        let lease=try lock(root:root);defer { lease.release() }
        let previous=try selected(root:root)
        let folder="\(component?.stem ?? "Castor")-\(manifest.version)-\(platform)"+(repair ? "-repair-\(UUID().uuidString)" : "")
        let target=root.appendingPathComponent(folder,isDirectory:true)
        guard !FileManager.default.fileExists(atPath:target.path) else { throw InstallError.existing }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let stage=root.appendingPathComponent(".castor-stage-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:stage) }
        let archive=stage.appendingPathComponent("app.zip")
        // The archive grows as it downloads; its size is the progress.
        let watcher=progress.map { report in
            Task.detached {
                report(.downloading(received:0,total:package.bytes))
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds:200_000_000)
                    if Task.isCancelled { break }
                    let size=(try? FileManager.default.attributesOfItem(atPath:archive.path)[.size] as? NSNumber)?.int64Value ?? 0
                    report(.downloading(received:min(size,package.bytes),total:package.bytes))
                }
            }
        }
        do { try await download(url,archive) } catch { watcher?.cancel(); throw error }
        // Stop the watcher before the next step, so no late report follows it.
        watcher?.cancel()
        await watcher?.value
        progress?(.downloading(received:package.bytes,total:package.bytes))
        progress?(.verifying)
        let actualSize=(try FileManager.default.attributesOfItem(atPath:archive.path)[.size] as? NSNumber)?.int64Value
        guard actualSize==package.bytes,try PackageIntegrity.sha256(file:archive)==package.sha256 else { throw InstallError.integrity }
        try Task.checkCancellation()
        try PackageZIP.validate(Data(contentsOf:archive,options:.mappedIfSafe),platform:platform,component:component)
        let unpacked=stage.appendingPathComponent("payload",isDirectory:true)
        try FileManager.default.createDirectory(at:unpacked,withIntermediateDirectories:false)
        progress?(.extracting)
        try await extract(archive,unpacked)
        try Task.checkCancellation()
        let executable=unpacked.appendingPathComponent(component?.executable(platform:platform) ?? (platform.hasPrefix("macos") ? "Castor.app/Contents/MacOS/Castor" : "CastorPet.exe"))
        guard FileManager.default.fileExists(atPath:executable.path),
              component != nil||platform.hasPrefix("macos")||FileManager.default.fileExists(atPath:unpacked.appendingPathComponent("swiftCore.dll").path) else { throw InstallError.missingApp }
        if component != nil,platform=="windows_x86_64" {
            let runtime=unpacked.appendingPathComponent("_internal",isDirectory:true)
            let files=(try? FileManager.default.contentsOfDirectory(atPath:runtime.path)) ?? []
            guard FileManager.default.fileExists(atPath:runtime.appendingPathComponent("base_library.zip").path),
                  files.contains(where:{$0.lowercased().hasPrefix("python") && $0.lowercased().hasSuffix(".dll")}) else {throw InstallError.missingApp}
        }
        progress?(.finishing)
        try stamp(unpacked)
        let installed=DesktopInstalledApp(version:manifest.version,platform:platform,folder:folder,component:component,files:try fileFingerprint(unpacked))
        let metadata=try JSONEncoder().encode(installed)
        try metadata.write(to:unpacked.appendingPathComponent("CastorInstall.json"),options:.withoutOverwriting)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at:unpacked,to:target)
        // At this point a fully recoverable new app exists; failure to select
        // it retains the old selection and all user data.
        try Task.checkCancellation()
        if let previous {try JSONEncoder().encode(previous).write(to:previousFile(root:root),options:.atomic)}
        try metadata.write(to:selectionFile(root:root),options:.atomic)
        let legacy=root.appendingPathComponent("CurrentInstall.json")
        if let old=try? readRecord(legacy),old.folder==previous?.folder,old.platform==previous?.platform,old.component==previous?.component {
            // PreviousInstall now preserves this exact old receipt.
            try? FileManager.default.removeItem(at:legacy)
        }
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
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var writeError: Error?
    private(set) var status = 0

    init(handle: FileHandle) { self.handle = handle }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock { status = code }
        completionHandler(code == 200 ? .allow : .cancel)
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
        else if code != 200 { continuation?.resume(throwing: DesktopInstaller.InstallError.downloadFailed(code)) }
        else if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}
