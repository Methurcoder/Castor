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
            case .unpack: "ZIPの展開に失敗しました。旧版とペット・設定は保持しています。"
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
    static var root: URL {
        get throws {
#if os(Windows)
            guard let local=ProcessInfo.processInfo.environment["LOCALAPPDATA"],!local.isEmpty else { throw AdapterError.unsupported }
            return URL(fileURLWithPath:local).appendingPathComponent("Programs/Castor",isDirectory:true)
#else
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications",isDirectory:true)
#endif
        }
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
    static func stamp(_ payload: URL) throws {
#if os(macOS)
        let app=payload.appendingPathComponent("Castor.app")
        let value="0081;\(String(Int(Date().timeIntervalSince1970),radix:16));CastorSetup;\(UUID().uuidString)"
        let status=value.withCString { raw in app.path.withCString { path in
            setxattr(path,"com.apple.quarantine",raw,value.utf8.count,0,0)
        }}
        guard status==0 else { throw AdapterError.stamp }
#elseif os(Windows)
        let mark=Data("[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=https://github.com/Methurcoder/Castor\r\n".utf8)
        for file in try FileManager.default.contentsOfDirectory(at:payload,includingPropertiesForKeys:nil) {
            guard file.pathExtension.lowercased()=="exe" || file.pathExtension.lowercased()=="dll" || file.pathExtension.lowercased()=="cmd" || file.pathExtension.lowercased()=="ps1" else { continue }
            try mark.write(to:URL(fileURLWithPath:file.path+":Zone.Identifier"))
        }
#endif
    }
    #if os(macOS)
    @MainActor
    #endif
    static func launch(_ app: DesktopInstalledApp) throws {
        let folder=try root.appendingPathComponent(app.folder,isDirectory:true)
#if os(macOS)
        _ = NSWorkspace.shared.open(folder.appendingPathComponent("Castor.app"))
#elseif os(Windows)
        // Shell launch retains Windows security checks/Mark of the Web.
        let executable=folder.appendingPathComponent("CastorPet.exe")
        guard executable.path.withCString({castor_launch_file($0)})>0 else { throw AdapterError.unpack }
#endif
    }
}
