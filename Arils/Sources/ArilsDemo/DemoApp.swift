import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

import Arils

/// Standalone playground for the engine: `swift run arils-demo`, then drop a
/// character image on the window. Hover to be watched, drag on the head to
/// pet, toggle speech, play an audio file for real lip sync, switch the
/// conversation behavior and personality, or trigger micro-actions.
@main
struct ArilsDemoApp: App {
    init() {
        // `swift run` executables have no app bundle; opt into a real UI app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Arils Demo") {
            DemoRootView()
                .frame(minWidth: 640, minHeight: 560)
        }
    }
}

struct DemoRootView: View {
    @State private var engine: CharacterEngine?
    @State private var statusMessage = "キャラクター画像をここにドロップしてください"
    @State private var isRigging = false
    @State private var isSpeaking = false
    @State private var energy: Float = 0.5
    @State private var behavior: MotionBehavior = .idle
    @State private var personalityName = "standard"
    @State private var sourceImage: CGImage?
    @State private var audioPlayer = DemoAudioPlayer()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let engine {
                    AvatarView(engine: engine)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                        if isRigging {
                            ProgressView()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            Divider()

            controls
                .padding(12)

            motionControls
                .padding([.horizontal, .bottom], 12)
        }
    }

    private var motionControls: some View {
        HStack(spacing: 16) {
            Picker("Behavior", selection: $behavior) {
                ForEach(MotionBehavior.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 220)
            .onChange(of: behavior) { _, value in engine?.behavior = value }

            Picker("Personality", selection: $personalityName) {
                ForEach(MotionPersonality.presets, id: \.name) { Text($0.name).tag($0.name) }
            }
            .frame(width: 220)
            .onChange(of: personalityName) { _, _ in
                // Personality is part of the engine configuration: re-create it.
                if let sourceImage { Task { await rig(sourceImage) } }
            }

            Menu("Micro-action") {
                ForEach(MicroActionLayer.Kind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) { engine?.triggerMicroAction(kind) }
                }
            }
            .frame(width: 140)

            Spacer()
        }
        .disabled(engine == nil)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Toggle("Speak (procedural)", isOn: $isSpeaking)
                .onChange(of: isSpeaking) { _, speaking in
                    engine?.isSpeaking = speaking
                    if !speaking { audioPlayer.stop() }
                }
                .disabled(engine == nil)

            Button("Play audio…") {
                playAudioFile()
            }
            .disabled(engine == nil)

            Button("くしゃみ") {
                engine?.triggerSneeze()
            }
            .disabled(engine == nil)

            HStack(spacing: 6) {
                Text("Energy")
                Slider(value: $energy, in: 0...1)
                    .frame(width: 140)
                    .onChange(of: energy) { _, value in
                        engine?.energy = value
                    }
            }
            .disabled(engine == nil)

            Spacer()

            Text("hover: 視線 / 頭をドラッグ: なでる")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                await loadImage(at: url)
            }
        }
        return true
    }

    @MainActor
    private func loadImage(at url: URL) async {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusMessage = "画像を読み込めませんでした: \(url.lastPathComponent)"
            return
        }
        sourceImage = cgImage
        await rig(cgImage)
    }

    @MainActor
    private func rig(_ cgImage: CGImage) async {
        isRigging = true
        statusMessage = "自動リギング中…"
        let personality = MotionPersonality.presets.first { $0.name == personalityName }?.personality ?? .standard
        do {
            let newEngine = try await CharacterEngine.make(
                image: cgImage,
                configuration: .init(personality: personality)
            )
            newEngine.isSpeaking = isSpeaking
            newEngine.energy = energy
            newEngine.behavior = behavior
            engine = newEngine
        } catch {
            statusMessage = "リギングに失敗しました: \(error)"
        }
        isRigging = false
    }

    private func playAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let engine else { return }
        isSpeaking = true
        engine.isSpeaking = true
        audioPlayer.play(url: url, engine: engine) {
            Task { @MainActor in
                isSpeaking = false
                engine.isSpeaking = false
            }
        }
    }
}

/// Plays an audio file through AVAudioEngine. The whole clip is analyzed
/// into a `LipSyncTimeline` first and the mouth follows the player's own
/// clock — the accurate path a host should use for TTS, where the audio
/// exists before playback. The output tap still feeds the live analyzer as
/// a fallback.
@MainActor
final class DemoAudioPlayer {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    func play(url: URL, engine: CharacterEngine, completion: @escaping @Sendable () -> Void) {
        stop()
        guard let file = try? AVAudioFile(forReading: url) else {
            completion()
            return
        }
        if let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
           (try? file.read(into: buffer)) != nil,
           let channel = buffer.floatChannelData?[0] {
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let timeline = engine.makeSpeechTimeline(samples: samples, sampleRate: file.processingFormat.sampleRate)
            engine.playSpeechTimeline(timeline) { [weak self] in self?.playbackTime }
            file.framePosition = 0
        }
        let audioEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: file.processingFormat)

        audioEngine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            engine.pushSpeechSamples(samples, sampleRate: buffer.format.sampleRate)
        }

        do {
            try audioEngine.start()
        } catch {
            completion()
            return
        }
        player.scheduleFile(file, at: nil) {
            Task { @MainActor in engine.stopSpeechTimeline() }
            completion()
        }
        player.play()
        self.audioEngine = audioEngine
        self.playerNode = player
    }

    /// Seconds of audio rendered so far plus the output device latency, or
    /// nil when nothing plays.
    var playbackTime: Double? {
        guard let playerNode, let audioEngine, playerNode.isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate + audioEngine.outputNode.presentationLatency
    }

    func stop() {
        playerNode?.stop()
        audioEngine?.mainMixerNode.removeTap(onBus: 0)
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
    }
}
