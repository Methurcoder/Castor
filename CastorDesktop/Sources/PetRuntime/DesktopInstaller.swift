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
    public init(version:String,platform:String,folder:String,component:DesktopHelperComponent?=nil) {
        self.version=version;self.platform=platform;self.folder=folder;self.component=component
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
    public static func selected(root: URL) throws -> DesktopInstalledApp? {
        let record=root.appendingPathComponent("CurrentInstall.json")
        guard FileManager.default.fileExists(atPath:record.path) else { return nil }
        let app=try JSONDecoder().decode(DesktopInstalledApp.self,from:Data(contentsOf:record))
        guard DesktopDownloadManifest.validVersion(app.version),["macos_arm64","macos_x86_64","windows_x86_64"].contains(app.platform),
              validFolder(app),!app.folder.contains("/"),!app.folder.contains("\\"),!app.folder.contains(":"),app.folder != ".",app.folder != ".." else { throw InstallError.invalidManifest }
        return app
    }
    /// Extract/stamp are native adapters. Stage and target share a volume; an
    /// incomplete/cancelled replacement never touches the previous installation.
    private static func validFolder(_ app: DesktopInstalledApp) -> Bool {
        let base="\(app.component?.stem ?? "Castor")-\(app.version)-\(app.platform)"
        if app.folder==base { return true }
        let prefix=base+"-repair-"
        return app.folder.hasPrefix(prefix) && UUID(uuidString:String(app.folder.dropFirst(prefix.count))) != nil
    }
    private static func lock(root: URL) throws -> UnsafeMutableRawPointer {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file=root.appendingPathComponent("Install.lock")
        guard let lease=file.path.withCString({castor_install_lock($0)}) else { throw InstallError.busy }
        return lease
    }
    public static func download(_ url: URL, to destination: URL) async throws {
        let session=URLSession(configuration:.ephemeral);defer { session.invalidateAndCancel() }
        let(file,response)=try await session.download(from:url)
        defer { try? FileManager.default.removeItem(at:file) }
        let status=(response as? HTTPURLResponse)?.statusCode ?? 0
        guard status==200 else { throw InstallError.downloadFailed(status) }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at:file,to:destination)
    }
    public static func install(root: URL, release: DesktopRelease, manifest: DesktopDownloadManifest, platform: String,
                               repair: Bool=false,component:DesktopHelperComponent?=nil, extract: @Sendable (URL,URL) async throws -> Void,
                               stamp: @Sendable (URL) throws -> Void,
                               download: @Sendable (URL,URL) async throws -> Void = { try await DesktopInstaller.download($0,to:$1) }) async throws -> DesktopInstalledApp {
        let(package,url)=try manifest.package(platform:platform,release:release,component:component)
        try Task.checkCancellation()
        let lease=try lock(root:root);defer { castor_install_unlock(lease) }
        let folder="\(component?.stem ?? "Castor")-\(manifest.version)-\(platform)"+(repair ? "-repair-\(UUID().uuidString)" : "")
        let target=root.appendingPathComponent(folder,isDirectory:true)
        guard !FileManager.default.fileExists(atPath:target.path) else { throw InstallError.existing }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let stage=root.appendingPathComponent(".castor-stage-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:stage) }
        let archive=stage.appendingPathComponent("app.zip")
        try await download(url,archive)
        let actualSize=(try FileManager.default.attributesOfItem(atPath:archive.path)[.size] as? NSNumber)?.int64Value
        guard actualSize==package.bytes,try PackageIntegrity.sha256(file:archive)==package.sha256 else { throw InstallError.integrity }
        try Task.checkCancellation()
        try PackageZIP.validate(Data(contentsOf:archive,options:.mappedIfSafe),platform:platform,component:component)
        let unpacked=stage.appendingPathComponent("payload",isDirectory:true)
        try FileManager.default.createDirectory(at:unpacked,withIntermediateDirectories:false)
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
        try stamp(unpacked)
        let installed=DesktopInstalledApp(version:manifest.version,platform:platform,folder:folder,component:component)
        let metadata=try JSONEncoder().encode(installed)
        try metadata.write(to:unpacked.appendingPathComponent("CastorInstall.json"),options:.withoutOverwriting)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at:unpacked,to:target)
        // At this point a fully recoverable new app exists; failure to select
        // it retains the old selection and all user data.
        try Task.checkCancellation()
        try metadata.write(to:root.appendingPathComponent("CurrentInstall.json"),options:.atomic)
        return installed
    }
    public static func uninstall(root: URL) throws {
        let lease=try lock(root:root);defer { castor_install_unlock(lease) }
        guard let app=try selected(root:root) else { return }
        let folder=root.appendingPathComponent(app.folder,isDirectory:true)
        let marker=folder.appendingPathComponent("CastorInstall.json")
        let own=try JSONDecoder().decode(DesktopInstalledApp.self,from:Data(contentsOf:marker))
        guard own.folder==app.folder,own.platform==app.platform,own.version==app.version,own.component==app.component,
              !((try folder.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink ?? false) else { throw InstallError.invalidManifest }
        try FileManager.default.removeItem(at:folder)
        try FileManager.default.removeItem(at:root.appendingPathComponent("CurrentInstall.json"))
    }
}
