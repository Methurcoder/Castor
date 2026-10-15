#if os(Windows)
import CastorCore
import CDesktopUI
import Foundation
import PetRuntime
import WinSDK

/// The Mac-style creation window: the page in UI/ on WebView2, with this
/// controller doing the work. Page messages are queued and handled from a
/// thread timer on the native thread, never inside WebView2's own event
/// handlers, so native dialogs (file picker, AI provider choice) can nest.
/// Model work runs off the UI thread; results come back through the queue.
final class CreationWindow {
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static var current: CreationWindow?
    static var isOpen: Bool { current != nil }

    private static let lock = NSLock()
    private static var queue: [() -> Void] = []
    private static var draining = false

    private var language: SettingsDisplayLanguage
    private let onCreated: (PetAsset) -> Void
    private let onSettings: () -> SettingsDisplayLanguage?
    private let onUnavailable: () -> Void
    private var sources: [String] = []
    private var prepared: PreparedPortableRig?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var timer: UINT_PTR = 0

    private init(language: SettingsDisplayLanguage, onCreated: @escaping (PetAsset) -> Void,
                 onSettings: @escaping () -> SettingsDisplayLanguage?, onUnavailable: @escaping () -> Void) {
        self.language = language
        self.onCreated = onCreated
        self.onSettings = onSettings
        self.onUnavailable = onUnavailable
    }

    /// Shows the window, or brings an open one forward. False when WebView2 or
    /// the page files are missing; callers then use the native dialogs.
    /// `onUnavailable` covers WebView2 failing after the window appeared.
    static func open(language: SettingsDisplayLanguage, onCreated: @escaping (PetAsset) -> Void,
                     onSettings: @escaping () -> SettingsDisplayLanguage?, onUnavailable: @escaping () -> Void) -> Bool {
        if current != nil { return castor_webview_open("Castor", "", "", 0, 0, 1, nil, nil) == 1 }
        guard let ui = uiFolder, let root = try? WindowsRiggingFlow.directory else { return false }
        let data = root.appendingPathComponent("WebView2", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let window = CreationWindow(language: language, onCreated: onCreated, onSettings: onSettings, onUnavailable: onUnavailable)
        current = window
        let status = castor_webview_open("Castor", nativePath(ui), nativePath(data), 1180, 800, castor_system_dark(), { json, _ in
            guard let json, let data = String(cString: json).data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            CreationWindow.enqueue { CreationWindow.current?.handle(message) }
        }, nil)
        guard status == 1 else { current = nil; return false }
        window.timer = SetTimer(nil, 0, 40, { _, _, _, _ in CreationWindow.drain() })
        return true
    }

    /// The page ships as the SwiftPM resource bundle beside the executable,
    /// or as a plain UI folder in a hand-made layout.
    private static var uiFolder: URL? {
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        return [folder.appendingPathComponent("CastorDesktop_CastorPet.resources/UI"), folder.appendingPathComponent("UI")]
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
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
            window.finish()
            castor_webview_close()
            window.onUnavailable()
            return
        }
        while true {
            lock.lock(); let items = queue; queue.removeAll(); lock.unlock()
            if items.isEmpty { return }
            items.forEach { $0() }
        }
    }

    private func finish() {
        task?.cancel(); task = nil; generation += 1
        if timer != 0 { _ = KillTimer(nil, timer); timer = 0 }
        if CreationWindow.current === self { CreationWindow.current = nil }
    }

    // MARK: Page messages

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "ready":
            sources = message["sources"] as? [String] ?? []
            sendInit()
        case "openImage":
            guard task == nil else { return }
            do { if let url = try WindowsRiggingFlow.choose(kind: "image") { analyse(try Data(contentsOf: url)) } }
            catch { fail(error) }
        case "openImageData":
            guard task == nil, let text = message["data"] as? String, let comma = text.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(text[text.index(after: comma)...])) else { return }
            analyse(data)
        case "save": save(message["markers"])
        case "cancel":
            task?.cancel(); task = nil; generation += 1
            post(["type": "idle"])
        case "voice", "settings":
            if let updated = onSettings() { language = updated; sendInit() }
        case "aiSetup": suggest()
        case "closed": finish()
        default: break
        }
    }

    private func say(_ japanese: String, _ english: String) -> String { language == .japanese ? japanese : english }

    private func sendInit() {
        var strings: [String: String] = [:]
        for source in sources {
            let label = CastorAppStrings.label(source, language: language)
            if label != source { strings[source] = label }
        }
        post(["type": "init", "language": language == .japanese ? "ja" : "en", "strings": strings])
    }

    private func post(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        _ = castor_webview_post(text)
    }

    private func fail(_ error: Error) {
        if error is CancellationError { post(["type": "idle"]); return }
        post(["type": "error", "message": CastorAppStrings.label(error.localizedDescription, language: language)])
    }

    /// Runs `operation` off the UI thread behind the page's busy overlay. A
    /// cancelled or superseded run never reaches `completion`.
    private func run<T>(_ busyText: String, _ operation: @escaping @Sendable () async throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
        generation += 1
        let ticket = generation
        post(["type": "busy", "text": busyText])
        let done = Box(completion)
        task = Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            let boxed = Box(result)
            CreationWindow.enqueue {
                guard let window = CreationWindow.current, window.generation == ticket else { return }
                window.task = nil
                done.value(boxed.value)
            }
        }
    }

    // MARK: Rigging

    private func analyse(_ data: Data, selecting candidate: Int? = nil) {
        let source: PortableRigImage
        do { source = try PortableRigImage(png: data) } catch { fail(error); return }
        run(say("キャラクターを切り抜いて、顔の位置を推定しています…", "Cutting out the character and finding the face…"), {
            let prepared = try await LayeredRigging.prepare(source, selecting: candidate)
            return (prepared, prepared.preview.pngData().base64EncodedString())
        }) { [self] result in
            switch result {
            case .success(let (prepared, png)):
                show(prepared, png: png)
            case .failure(let error):
                guard case .selectSubject(let candidates)? = error as? LayeredRigging.RigError else { fail(error); return }
                post(["type": "idle"])
                let items = candidates.map { candidate -> String in
                    let r = candidate.normalizedBounds
                    return say("キャラクター \(candidate.id + 1) — X \(Int(r.minX * 100))%、Y \(Int(r.minY * 100))%、幅 \(Int(r.width * 100))%、高さ \(Int(r.height * 100))%",
                               "Character \(candidate.id + 1) — X \(Int(r.minX * 100))%, Y \(Int(r.minY * 100))%, width \(Int(r.width * 100))%, height \(Int(r.height * 100))%")
                }
                do {
                    if let index = try WindowsRiggingFlow.option(title: say("Castor - 作成するキャラクターを選択", "Castor - Choose the character"), items: items) {
                        analyse(data, selecting: candidates[index].id)
                    }
                } catch { fail(error) }
            }
        }
    }

    private func show(_ prepared: PreparedPortableRig, png: String) {
        self.prepared = prepared
        let label = prepared.face.sourceLabel
        let estimator = label == OnnxAnimeFaceEstimator.sourceLabel ? "model" : label.hasPrefix("Template") ? "template" : "heuristic"
        post(["type": "prepared", "image": "data:image/png;base64," + png,
              "width": prepared.source.width, "height": prepared.source.height,
              "markers": json(LayeredRigging.markers(prepared.face.layout)), "estimator": estimator,
              "warnings": prepared.warnings.map { CastorAppStrings.label($0, language: language) }])
    }

    private func json(_ layout: PortableFaceLayout) -> [String: [Double]] {
        func values(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
        return ["head": values(layout.head), "eyeLeft": values(layout.eyeLeft),
                "eyeRight": values(layout.eyeRight), "mouth": values(layout.mouth)]
    }

    private func layout(from value: Any?) -> PortableFaceLayout? {
        guard let markers = value as? [String: Any] else { return nil }
        func rect(_ key: String) -> CGRect? {
            guard let items = markers[key] as? [Any], items.count == 4 else { return nil }
            let n = items.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) ?? ($0 as? NSNumber)?.doubleValue }
            guard n.count == 4, n.allSatisfy(\.isFinite) else { return nil }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
        guard let head = rect("head"), let eyeLeft = rect("eyeLeft"), let eyeRight = rect("eyeRight"),
              let mouth = rect("mouth") else { return nil }
        return PortableFaceLayout(head: head, eyeLeft: eyeLeft, eyeRight: eyeRight, mouth: mouth)
    }

    private func save(_ value: Any?) {
        guard task == nil, let prepared, let markers = layout(from: value) else { return }
        do { try markers.validate(width: prepared.source.width, height: prepared.source.height) }
        catch { fail(error); return }
        run(say("頭・体・目・口のレイヤーと可動範囲を作成しています…", "Building the head, body, eye and mouth layers…"), {
            let asset = PetAsset.standard(try LayeredRigging.build(prepared, markers: markers))
            let data = try LayeredRigging.savedPetData(source: prepared.source, asset: asset)
            _ = try PortablePetLibrary(root: WindowsRiggingFlow.directory).saveNew(data)
            return asset
        }) { [self] result in
            switch result {
            case .success(let asset):
                onCreated(asset)
                post(["type": "saved", "message": say("ペットを保存して、デスクトップに表示しました。", "The pet was saved and shown on the desktop.")])
            case .failure(let error):
                fail(error)
            }
        }
    }

    /// Optional AI marker suggestion; the result is only a proposal on the page.
    private func suggest() {
        guard task == nil else { return }
        guard let prepared else {
            post(["type": "toast", "message": say("先に画像を読み込んでください。", "Import an image first.")])
            return
        }
        let preferences = (try? DesktopPreferenceStore(root: WindowsRiggingFlow.directory).load()) ?? DesktopPreferences()
        do {
            guard let suggestion = try WindowsAIAlignmentFlow.suggest(prepared, preferences: preferences) else { return }
            post(["type": "markers", "markers": json(LayeredRigging.markers(suggestion.layout)), "note": suggestion.explanation])
        } catch { fail(error) }
    }
}
#endif
