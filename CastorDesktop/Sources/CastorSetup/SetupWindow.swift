#if os(Windows)
import CastorCore
import CDesktopUI
import Foundation
import PetRuntime
import WinSDK

/// The setup wizard on WebView2: welcome, license, details, install and done,
/// or the management page once Castor is installed. The steps are the same
/// as the native dialogs in `setupUI()`, which stay as the fallback without
/// WebView2. Page messages are handled from a thread timer on this thread,
/// outside WebView2's event handlers; installs run off it.
final class SetupWindow {
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static var current: SetupWindow?
    private static var unavailable = false
    private static let lock = NSLock()
    private static var queue: [() -> Void] = []
    private static var draining = false

    private let strings = SetupLocalization()
    private var job: Task<Void, Never>?
    private var generation = 0
    private var timer: UINT_PTR = 0

    /// Shows the wizard until it is closed. False when WebView2 or the page
    /// is unavailable, so the caller can use the native dialogs instead.
    static func run() -> Bool {
        guard let ui = uiFolder, let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !local.isEmpty else { return false }
        let data = URL(fileURLWithPath: local).appendingPathComponent("Castor/WebView2Setup", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let window = SetupWindow()
        current = window
        let status = window.strings.title.withCString { title in
            castor_webview_open(title, nativePath(ui), nativePath(data), 820, 600, castor_system_dark(), { json, _ in
                guard let json, let data = String(cString: json).data(using: .utf8),
                      let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                SetupWindow.enqueue { SetupWindow.current?.handle(message) }
            }, nil)
        }
        guard status == 1 else { current = nil; return false }
        window.timer = SetTimer(nil, 0, 40, { _, _, _, _ in SetupWindow.drain() })
        var message = MSG()
        while current != nil, !unavailable, GetMessageW(&message, nil, 0, 0) {
            _ = TranslateMessage(&message)
            _ = DispatchMessageW(&message)
        }
        return !unavailable
    }

    private static var uiFolder: URL? {
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        // The build scripts copy the page from source beside CastorSetup.exe.
        let page = folder.appendingPathComponent("SetupUI")
        return FileManager.default.fileExists(atPath: page.appendingPathComponent("index.html").path) ? page : nil
    }

    private static func nativePath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    private static func enqueue(_ work: @escaping () -> Void) {
        lock.lock(); queue.append(work); lock.unlock()
    }

    private static func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        if let window = current, castor_webview_state() == -1 {
            unavailable = true
            window.finish()
            castor_webview_close()
            return
        }
        while true {
            lock.lock(); let items = queue; queue.removeAll(); lock.unlock()
            if items.isEmpty { return }
            items.forEach { $0() }
        }
    }

    private func finish() {
        job?.cancel(); job = nil; generation += 1
        if timer != 0 { _ = KillTimer(nil, timer); timer = 0 }
        if SetupWindow.current === self { SetupWindow.current = nil }
    }

    // MARK: Page messages

    private func handle(_ message: [String: Any]) {
        let component: DesktopHelperComponent? = message["component"] is String ? .neuralTTS : nil
        switch message["type"] as? String {
        case "ready": sendInit()
        case "install": install(component: component, repair: message["repair"] as? Bool ?? false)
        case "cancel":
            job?.cancel(); job = nil; generation += 1
            post(["type": "cancelled"])
        case "launch":
            do {
                if let app = try DesktopInstaller.selected(root: NativeInstall.installationRoot(component: component)) { try NativeInstall.launch(app) }
                else { post(["type": "message", "text": strings.notInstalled(helper: component != nil)]) }
            } catch { fail(error) }
        case "remove":
            do {
                let root = try NativeInstall.installationRoot(component: component)
                let old = try DesktopInstaller.selected(root: root)
                try DesktopInstaller.uninstall(root: root)
                if let old { NativeInstall.removeLaunchEntry(old) }
                post(["type": "message", "text": old == nil ? strings.notInstalled(helper: component != nil) : strings.removed(helper: component != nil)])
                sendStatus()
            } catch { fail(error) }
        case "cleanup":
            do {
                try NativeInstall.pruneOldVersions(component: component)
                post(["type": "message", "text": strings.cleanupFinished])
            } catch { post(["type": "message", "text": strings.cleanupFailed(error)]) }
        case "close": castor_webview_close()
        case "closed": finish()
        default: break
        }
    }

    private func installed(_ component: DesktopHelperComponent?) -> Any {
        guard let root = try? NativeInstall.installationRoot(component: component),
              let app = try? DesktopInstaller.selected(root: root) else { return NSNull() }
        return app.version
    }

    private func sendInit() {
        let folder = Bundle.main.executableURL?.deletingLastPathComponent()
        func text(_ name: String) -> String {
            folder.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) }
                ?? "https://github.com/Methurcoder/Castor/blob/main/\(name)"
        }
        let root = (try? NativeInstall.root).map { SetupWindow.nativePath($0).replacingOccurrences(of: "/", with: "\\") } ?? ""
        post(["type": "init", "language": strings.isJapanese ? "ja" : "en",
              "installed": installed(nil), "helper": installed(.neuralTTS),
              "license": text("LICENSE"), "notices": text("THIRD_PARTY_NOTICES.md"), "root": root])
    }

    private func sendStatus() {
        post(["type": "status", "installed": installed(nil), "helper": installed(.neuralTTS)])
    }

    private func post(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        _ = castor_webview_post(text)
    }

    private func fail(_ error: Error) {
        post(["type": "error", "message": strings.errorMessage(error)])
    }

    // MARK: Install

    private func install(component: DesktopHelperComponent?, repair: Bool) {
        guard job == nil else { return }
        let platform: String, root: URL
        do { platform = try NativeInstall.platform; root = try NativeInstall.installationRoot(component: component) }
        catch { fail(error); return }
        generation += 1
        let ticket = generation
        post(["type": "progress", "text": strings.text(
            "対応する\(component == nil ? "アプリ" : "Neural TTS helper")を取得・検証・導入しています…",
            "Downloading, verifying and installing the \(component == nil ? "app" : "Neural TTS helper")…")])
        job = Task.detached(priority: .userInitiated) {
            let result: Result<DesktopInstalledApp, Error>
            do {
                let (release, manifest) = try await DesktopInstaller.latest()
                result = .success(try await DesktopInstaller.install(root: root, release: release, manifest: manifest, platform: platform,
                    repair: repair, component: component, extract: { try await NativeInstall.extract($0, $1) },
                    stamp: { try NativeInstall.stamp($0, component: component) }))
            } catch { result = .failure(error) }
            let boxed = Box(result)
            SetupWindow.enqueue {
                guard let window = SetupWindow.current, window.generation == ticket else { return }
                window.job = nil
                window.finishInstall(boxed.value, component: component)
            }
        }
    }

    private func finishInstall(_ result: Result<DesktopInstalledApp, Error>, component: DesktopHelperComponent?) {
        let app: DesktopInstalledApp
        switch result {
        case .success(let installed): app = installed
        case .failure(let error):
            if error is CancellationError { post(["type": "cancelled"]) } else { fail(error) }
            return
        }
        var note = ""
        do {
            try NativeInstall.createLaunchEntry(app)
            // Cleanup is best effort and cannot turn a completed installation into a failure.
            try? NativeInstall.pruneOldVersions(component: component)
        } catch {
            note = strings.text("ショートカットを作れませんでした。既存の同名項目は保持しています。このセットアップの「起動」から開けます。",
                                "A shortcut could not be created. An existing item with the same name was kept. Use Launch in this setup to open it.")
        }
        note += (note.isEmpty ? "" : "\n") + strings.text("初回にはSmartScreenの確認が出る場合があります。", "SmartScreen may ask for confirmation on first launch.")
        post(["type": "installed", "version": app.version, "component": component.map { $0.rawValue as Any } ?? NSNull(), "note": note])
        sendStatus()
    }
}
#endif
