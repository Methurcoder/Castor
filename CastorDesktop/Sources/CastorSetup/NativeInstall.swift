import CDesktopUI
import Foundation
import PetRuntime
#if os(macOS)
import AppKit
import Darwin
#endif

enum NativeInstall {
    enum AdapterError: LocalizedError {
        case unsupported, unpack, stamp
        var errorDescription: String? {
            switch self {
            case .unsupported: "このOS/CPUにはまだ対応する配布アプリがありません。"
            case .unpack: "ZIPの展開に失敗しました。旧版とキャラクター・設定は保持しています。"
            case .stamp: "OSのネット由来の印を設定できませんでした。導入を中止しました。"
            }
        }
    }
    static var platform: String {
        get throws {
#if os(Windows)
            guard castor_native_windows_x64() == 1 else { throw AdapterError.unsupported }
            return "windows_x86_64"
#elseif os(macOS)
            let version=ProcessInfo.processInfo.operatingSystemVersion
            guard version.majorVersion>26 || version.majorVersion==26 && version.minorVersion>=5 else { throw AdapterError.unsupported }
            var arm: Int32=0;var size=MemoryLayout<Int32>.size
            _ = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
            return arm==1 ? "macos_arm64" : "macos_x86_64"
#else
            throw AdapterError.unsupported
#endif
        }
    }
    /// Where versions are installed. On a Mac this is outside ~/Applications,
    /// which then holds only the launch links (see DesktopInstallLayout).
    static var root: URL {
        get throws {
#if os(Windows)
            guard let local=ProcessInfo.processInfo.environment["LOCALAPPDATA"],!local.isEmpty else { throw AdapterError.unsupported }
            return URL(fileURLWithPath:local).appendingPathComponent("Programs/Castor",isDirectory:true)
#else
            return DesktopInstallLayout.macVersionsRoot(home:FileManager.default.homeDirectoryForCurrentUser)
#endif
        }
    }
    static func installationRoot(component:DesktopHelperComponent?) throws -> URL {
        DesktopInstallLayout.installationRoot(base:try root,component:component)
    }
#if os(macOS)
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// ~/Applications, where the one Castor.app (and CastorNeuralTTS.app) link goes.
    static var launchFolder: URL { DesktopInstallLayout.macLaunchFolder(home:home) }
    /// Where Setup up to v1.0.0 installed `component`, listed by Launchpad.
    static func legacyRoot(component:DesktopHelperComponent?) -> URL {
        DesktopInstallLayout.installationRoot(base:DesktopInstallLayout.macLegacyRoot(home:home),component:component)
    }
#endif
    /// The root holding the selected version: the installation root, or on a
    /// Mac the old place until the first update moves Castor out of it.
    static func selectedRoot(component:DesktopHelperComponent?) throws -> URL {
        let installRoot=try installationRoot(component:component)
#if os(macOS)
        return DesktopInstallLayout.selectedRoot(root:installRoot,legacyRoot:legacyRoot(component:component))
#else
        return installRoot
#endif
    }
    static func extract(_ archive: URL, _ destination: URL) async throws {
        try Task.checkCancellation()
#if os(Windows)
        let status=archive.path.withCString { archive in destination.path.withCString {
            castor_expand_zip(archive,$0,{_ in Task<Never,Never>.isCancelled ? 1 : 0},nil)
        }}
        if status==0 { throw CancellationError() };guard status>0 else { throw AdapterError.unpack }
#elseif os(macOS)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-x","-k",archive.path,destination.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try await withTaskCancellationHandler(operation: {
            try process.run()
            while process.isRunning {
                // Cancellation must wait for ditto to exit before stage cleanup.
                // An awaited sleep would throw before that invariant is restored.
                if Task.isCancelled { process.terminate() }
                try? await Task.sleep(for:.milliseconds(50))
                if Task.isCancelled && process.isRunning { process.waitUntilExit() }
            }
            try Task.checkCancellation()
            guard process.terminationStatus==0 else { throw AdapterError.unpack }
        }, onCancel: { if process.isRunning { process.terminate() } })
#else
        throw AdapterError.unsupported
#endif
    }
    static func stamp(_ payload: URL,component:DesktopHelperComponent?=nil) throws {
#if os(macOS)
        let app=payload.appendingPathComponent("\(component?.stem ?? "Castor").app")
        let value="0081;\(String(Int(Date().timeIntervalSince1970),radix:16));CastorSetup;\(UUID().uuidString)"
        let status=value.withCString { raw in app.path.withCString { path in
            setxattr(path,"com.apple.quarantine",raw,value.utf8.count,0,0)
        }}
        guard status==0 else { throw AdapterError.stamp }
#elseif os(Windows)
        let mark=Data("[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=https://github.com/Methurcoder/Castor\r\n".utf8)
        guard let files=FileManager.default.enumerator(at:payload,includingPropertiesForKeys:[.isRegularFileKey],options:[]) else {throw AdapterError.stamp}
        for case let file as URL in files {
            guard file.pathExtension.lowercased()=="exe" || file.pathExtension.lowercased()=="dll" || file.pathExtension.lowercased()=="cmd" || file.pathExtension.lowercased()=="ps1" || file.pathExtension.lowercased()=="pyd" else { continue }
            try mark.write(to:URL(fileURLWithPath:file.path+":Zone.Identifier"))
        }
#endif
    }
    static func createLaunchEntry(_ app: DesktopInstalledApp) throws {
        // Never overwrite another user's app or an unrelated Castor shortcut.
        let installBase=try installationRoot(component:app.component)
#if os(macOS)
        // The helper keeps its link too: Castor opens ~/Applications/CastorNeuralTTS.app.
        // A link an older Setup made to its version in ~/Applications is replaced.
        do {
            try DesktopInstallLayout.linkLaunchEntry(app,root:installBase,launchFolder:launchFolder,
                                                     legacyRoots:[legacyRoot(component:app.component)])
        } catch {throw AdapterError.unpack}
#elseif os(Windows)
        let base=try root
        guard try DesktopInstaller.selected(root:installBase)?.folder==app.folder else {throw AdapterError.unpack}
        guard app.component==nil else {return}
        let file=base.appendingPathComponent(app.folder).appendingPathComponent("CastorPet.exe")
        guard file.path.withCString({file in base.path.withCString {castor_pet_shortcut(file,$0,0)}})>0 else {throw AdapterError.unpack}
#endif
    }
    #if os(macOS)
    @MainActor
    #endif
    static func pruneOldVersions(component:DesktopHelperComponent?=nil) throws {
        let installRoot=try selectedRoot(component:component)
#if os(macOS)
        let running=NSWorkspace.shared.runningApplications.compactMap {$0.bundleURL?.resolvingSymlinksInPath()}
#endif
        let trash: (URL) throws -> Void = { folder in
#if os(macOS)
            if running.contains(where:{$0.path.hasPrefix(folder.path+"/")}) {return}
            try FileManager.default.trashItem(at:folder,resultingItemURL:nil)
#elseif os(Windows)
            guard folder.path.withCString({castor_recycle_directory($0)})>0 else {throw AdapterError.unpack}
#endif
        }
        var failure: Error?
        do { _ = try DesktopInstaller.pruneOldVersions(root:installRoot,trash:trash) } catch { failure=error }
#if os(macOS)
        // Versions an older Setup left in ~/Applications go to the Trash once
        // the new place has a version; a running one is retried next time.
        let legacy=legacyRoot(component:component)
        do {
            try DesktopInstallLayout.retireLegacyVersions(legacyRoot:legacy,root:try installationRoot(component:component),component:component,
                emptyFolders:component == nil ? [] : [legacy,legacy.deletingLastPathComponent()],trash:trash)
        } catch { failure=failure ?? error }
#endif
        if let failure { throw failure }
        // Only old, empty OS-lock metadata is hidden; no app/data is deleted.
#if os(macOS)
        var old=installRoot.appendingPathComponent("Install.lock")
        if FileManager.default.fileExists(atPath:old.path) {
            var values=URLResourceValues();values.isHidden=true;try? old.setResourceValues(values)
        }
#endif
    }
    /// `root` is where `app` is installed (the installation root by default).
    static func removeLaunchEntry(_ app: DesktopInstalledApp, root installRoot: URL? = nil) {
#if os(macOS)
        guard let installBase=installRoot ?? (try? installationRoot(component:app.component)) else{return}
        DesktopInstallLayout.removeLaunchEntry(app,root:installBase,launchFolder:launchFolder)
#elseif os(Windows)
        guard let base=try? root,let _=installRoot ?? (try? installationRoot(component:app.component)) else{return}
        guard app.component==nil else {return}
        let file=base.appendingPathComponent(app.folder).appendingPathComponent("CastorPet.exe")
        _ = file.path.withCString {file in base.path.withCString {castor_pet_shortcut(file,$0,1)}}
#endif
    }
    #if os(macOS)
    @MainActor
    #endif
    /// `root` is where `app` is installed (the installation root by default).
    static func launch(_ app: DesktopInstalledApp, root: URL? = nil) throws {
        let folder=try (root ?? installationRoot(component:app.component)).appendingPathComponent(app.folder,isDirectory:true)
#if os(macOS)
        _ = NSWorkspace.shared.open(folder.appendingPathComponent("\(app.component?.stem ?? "Castor").app"))
#elseif os(Windows)
        // Shell launch retains Windows security checks/Mark of the Web.
        let executable=folder.appendingPathComponent(app.component?.executable(platform:app.platform) ?? "CastorPet.exe")
        guard executable.path.withCString({castor_launch_file($0)})>0 else { throw AdapterError.unpack }
#endif
    }
}
