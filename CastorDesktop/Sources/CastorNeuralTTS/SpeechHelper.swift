#if os(macOS)
import AppKit
import CastorCore
import Foundation
import SwiftUI

@MainActor final class SpeechHelperModel: ObservableObject {
    static let shared = SpeechHelperModel()
    @Published var running = false
    @Published var preparing = false
    @Published var modelReady = false
    @Published var status = ""
    private var process: Process?
    private var stopping = false
    private var preparation: Task<Void, Never>?
    private var generation = 0
    private var parentWatchdog: Timer?
    private var ownedControlFile: URL?
    /// Started by Castor: no window, and nothing left running once the
    /// speech runtime is gone, so Castor sees the helper end.
    var runsInBackground = false
    var japanese: Bool { Locale.preferredLanguages.first?.hasPrefix("ja") == true }
    func text(_ ja: String, _ en: String) -> String { japanese ? ja : en }

    func attachToParent() -> Bool {
        guard parentWatchdog == nil else { return true }
        // Launch Services may reopen a GUI without delivering new argv. A bounded,
        // container-local request associates only this exact helper with its owner.
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/dev.pomegranate.prototype/Data/Library/Application Support/Castor/NeuralSpeechControl", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let candidates = files.prefix(256).compactMap { file -> (URL, Int32)? in
            guard NeuralSpeechHelperControl.validatedFile(file.path, directory: directory) != nil,
                  NeuralSpeechHelperControl.read(file) == .run,
                  let owner = NeuralSpeechHelperControl.owner(file, helper: Bundle.main.bundleURL),
                  NSRunningApplication(processIdentifier: owner.parentPID)?.bundleIdentifier == "dev.pomegranate.prototype" else { return nil }
            return (file, owner.parentPID)
        }
        guard candidates.count == 1, let (file, pid) = candidates.first else { return false }
        ownedControlFile = file
        parentWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NeuralSpeechHelperControl.read(file) != .run || NSRunningApplication(processIdentifier: pid)?.bundleIdentifier != "dev.pomegranate.prototype" {
                    NSApp.terminate(nil)
                }
            }
        }
        return true
    }

    func start() async {
        guard process == nil else { return }
        stopping = false
        guard let runtime = Bundle.main.url(forResource: "CastorSpeechRuntime", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: runtime.path) else {
            status = text("音声ランタイムがありません。導入GUIで修復してください。", "Speech runtime is missing. Repair using Setup.")
            if runsInBackground { NSApp.terminate(nil) }
            return
        }
        let task = Process(); task.executableURL = runtime; task.arguments = ["--headless"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONHOME", "PYTHONPATH", "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"] { environment.removeValue(forKey: key) }
        environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        task.environment = environment
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self, weak task] _ in
            Task { @MainActor in
                guard let self, self.process === task else { return }
                self.process = nil; self.running = false; self.modelReady = false
                self.status = self.text("停止しました。起動できない場合はポート8000の使用と導入状態を確認してください。", "Stopped. If startup failed, check port 8000 and repair using Setup.")
                if self.runsInBackground { NSApp.terminate(nil) }
            }
        }
        do {
            try task.run(); process = task; running = true
            status = text("起動中。モデルはまだ取得していません。", "Starting. No model download yet.")
            // The packaged runtime may need a few seconds to extract on first launch.
            let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
            for _ in 0..<120 {
                guard process === task, task.isRunning else { return }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/audio/status")!)
                request.timeoutInterval = 0.5
                if let (_, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    status = text("補助アプリを起動しました。モデルのロードはCastorの音声設定またはこの画面から選べます。", "Helper running. Choose Load in Castor Voice settings or this window to prepare the model.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            status = text("起動を確認できません。停止後、修復して再試行してください。", "Startup could not be confirmed. Stop, repair, then retry.")
            if runsInBackground { NSApp.terminate(nil) }
        } catch {
            status = text("音声ランタイムを起動できませんでした。導入GUIで修復してください。", "Could not start speech runtime. Repair using Setup.")
            if runsInBackground { NSApp.terminate(nil) }
        }
    }

    func refreshReadiness() async {
        let current = generation
        let ready = (try? await NeuralSpeechTransport().isModelReady(model: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit")) == true
        guard !Task.isCancelled, current == generation else { return }
        modelReady = running && !stopping && ready
    }

    func prepare() {
        guard !preparing else { return }
        modelReady = false
        preparing = true; generation += 1
        let current = generation
        preparation = Task {
            defer { if current == generation { preparing = false; preparation = nil } }
            await start()
            guard process?.isRunning == true, !Task.isCancelled else { return }
            status = text("モデルを取得・準備しています。初回は時間と空き容量が必要です。", "Downloading / preparing the model. The first run needs time and free space.")
            do {
                try await NeuralSpeechTransport().preload(model: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit")
                guard current == generation else { return }
                await refreshReadiness()
                status = text("Qwenモデルの準備ができました。", "Qwen model is ready.")
            } catch {
                guard current == generation else { return }
                status = Task.isCancelled
                    ? text("準備をキャンセルしました。モデル取得・読込の終了に時間がかかる場合があります。", "Preparation cancelled. Download / loading may take time to finish.")
                    : text("準備できませんでした。接続・空き容量を確認して再試行してください。", "Could not prepare. Check connection and free space, then retry.")
            }
        }
    }
    func cancel() { preparation?.cancel() }
    func stop() {
        stopping = true
        modelReady = false
        generation += 1; preparation?.cancel(); preparation = nil; preparing = false
        if let process, process.isRunning {
            status = text("停止しています…", "Stopping…"); process.terminate()
        } else { process = nil; running = false }
    }
    func stopBeforeQuit() {
        parentWatchdog?.invalidate(); preparation?.cancel()
        if process?.isRunning == true { process?.terminate() }
        if let ownedControlFile { NeuralSpeechHelperControl.remove(ownedControlFile) }
    }
}

@MainActor final class SpeechHelperDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { SpeechHelperModel.shared.stopBeforeQuit() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Started from Castor's Voice settings: runs without a window or Dock icon.
/// Castor stops it with its control file, and it ends with Castor.
@MainActor final class BackgroundSpeechHelperDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SpeechHelperModel.shared.runsInBackground = true
        Task { await SpeechHelperModel.shared.start() }
    }
    func applicationWillTerminate(_ notification: Notification) { SpeechHelperModel.shared.stopBeforeQuit() }
}

@main enum CastorNeuralTTSMain {
    static func main() {
        MainActor.assumeIsolated {
            // Only a launch Castor owns runs in the background; opening the
            // helper by hand still shows its window.
            if CommandLine.arguments.contains("--start"), SpeechHelperModel.shared.attachToParent() {
                let application = NSApplication.shared
                application.setActivationPolicy(.prohibited)
                let delegate = BackgroundSpeechHelperDelegate()
                application.delegate = delegate
                withExtendedLifetime(delegate) { application.run() }
            } else {
                CastorNeuralTTSApp.main()
            }
        }
    }
}

struct CastorNeuralTTSApp: App {
    @NSApplicationDelegateAdaptor(SpeechHelperDelegate.self) private var delegate
    @StateObject private var model = SpeechHelperModel.shared
    var body: some Scene {
        WindowGroup("Castor Neural TTS") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Qwen 3 TTS").font(.title.bold())
                Text(model.text("この端末で音声を生成します。マイクの録音や声の複製は行いません。", "Speech is generated on this device. No microphone recording or voice cloning."))
                Text(model.status.isEmpty ? model.text("停止中。モデルはまだ取得しません。", "Stopped. No model download yet.") : model.status)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.preparing { ProgressView() }
                HStack {
                    Button(model.text("音声helperを起動", "Start speech helper")) { Task { await model.start() } }
                        .disabled(model.running)
                    Button(model.text("停止", "Stop")) { model.stop() }.disabled(!model.running)
                }
                if model.modelReady {
                    Label(model.text("Qwen 3 TTSで話します（helper接続中）", "Qwen 3 TTS is ready (helper connected)"), systemImage: "checkmark.circle.fill")
                        .font(.headline)
                } else {
                Text(model.text("音声はQwen 3 TTSでよりリアルになります。ロードしますか？", "Qwen 3 TTS can make speech more natural. Load it?"))
                    .font(.headline)
                Button(model.text("ロード", "Load")) { model.prepare() }
                    .disabled(model.preparing)
                Text(model.text("「ロード」を押すまでモデルを取得・読込しません。初回は時間と空き容量が必要です。準備できるまでは標準音声を使えます。", "The model downloads / loads only when you press Load. The first download needs time and free space. System speech remains available."))
                    .font(.caption).foregroundStyle(.secondary)
                }
                if model.preparing { Button(model.text("準備をキャンセル", "Cancel preparation")) { model.cancel() } }
            }
            .padding(28).frame(width: 540, alignment: .leading)
            .task {
                if model.attachToParent() || CommandLine.arguments.contains("--start") { await model.start() }
                while !Task.isCancelled {
                    await model.refreshReadiness()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }.windowResizability(.contentSize)
    }
}
#else
@main enum CastorNeuralTTSUnsupported {
    static func main() { print("The Windows speech helper is packaged with its native Python GUI.") }
}
#endif
