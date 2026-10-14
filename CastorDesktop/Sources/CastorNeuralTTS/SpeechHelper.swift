#if os(macOS)
import AppKit
import CastorCore
import Foundation
import SwiftUI

@MainActor final class SpeechHelperModel: ObservableObject {
    static let shared = SpeechHelperModel()
    @Published var running = false
    @Published var preparing = false
    @Published var status = ""
    private var process: Process?
    private var preparation: Task<Void, Never>?
    private var generation = 0
    var japanese: Bool { Locale.preferredLanguages.first?.hasPrefix("ja") == true }
    func text(_ ja: String, _ en: String) -> String { japanese ? ja : en }

    func start() async {
        guard process == nil else { return }
        guard let runtime = Bundle.main.url(forResource: "CastorSpeechRuntime", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: runtime.path) else {
            status = text("音声ランタイムがありません。導入GUIで修復してください。", "Speech runtime is missing. Repair using Setup.")
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
                self.process = nil; self.running = false
                self.status = self.text("停止しました。起動できない場合はポート8000の使用と導入状態を確認してください。", "Stopped. If startup failed, check port 8000 and repair using Setup.")
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
                    status = text("起動しました。CastorのVoiceでQwenを使えます。", "Running. Qwen is available in Castor Voice settings.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            status = text("起動を確認できません。停止後、修復して再試行してください。", "Startup could not be confirmed. Stop, repair, then retry.")
        } catch {
            status = text("音声ランタイムを起動できませんでした。導入GUIで修復してください。", "Could not start speech runtime. Repair using Setup.")
        }
    }

    func prepare() {
        guard !preparing else { return }
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
        generation += 1; preparation?.cancel(); preparation = nil; preparing = false
        if let process, process.isRunning {
            status = text("停止しています…", "Stopping…"); process.terminate()
        } else { process = nil; running = false }
    }
    func stopBeforeQuit() { preparation?.cancel(); if process?.isRunning == true { process?.terminate() } }
}

@MainActor final class SpeechHelperDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { SpeechHelperModel.shared.stopBeforeQuit() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct CastorNeuralTTSApp: App {
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
                Button(model.text("モデルを取得・準備（任意）", "Download / prepare model (optional)")) { model.prepare() }
                    .disabled(model.preparing)
                Text(model.text("初回は大きなモデルを取得します。時間と空き容量が必要です。準備できるまではCastorの標準音声を使えます。", "The initial large model download needs time and free space. Castor system speech remains available."))
                    .font(.caption).foregroundStyle(.secondary)
                if model.preparing { Button(model.text("準備をキャンセル", "Cancel preparation")) { model.cancel() } }
            }
            .padding(28).frame(width: 540, alignment: .leading)
            .task { if CommandLine.arguments.contains("--start") { await model.start() } }
        }.windowResizability(.contentSize)
    }
}
#else
@main enum CastorNeuralTTSUnsupported {
    static func main() { print("The Windows speech helper is packaged with its native Python GUI.") }
}
#endif
