import Arils
import Combine
import SwiftUI
import CastorCore

/// Renders a saved Arils avatar as the floating pet and keeps the engine fed
/// with the conversation state.
///
/// The Arils engine runs its own display loop (Metal view), so this sits
/// *outside* `PetFloatingView`'s `TimelineView` — the `CherryConnection`
/// motion path is not involved. The engine's built-in behaviors (idle motion,
/// hover gaze, head-pat strokes) work as-is; this view only bridges what the
/// engine cannot know:
/// - `voice.isSpeaking` / `speechPlaybackEnergy` → lip sync (30 Hz is plenty;
///   the engine's analyzer treats levels older than 0.3 s as silence);
/// - taps (the Metal view consumes mouse events, so tap-to-talk is forwarded
///   through `CharacterEngine.onTap`).
struct ArilsPetView: View {
    let archiveData: Data
    let voice: PetVoiceConversation
    let trilobite: TrilobiteEngine?
    let isWindowVisible: Bool
    let onTap: () -> Void

    @State private var engine: CharacterEngine?
    @State private var loadFailed = false
    @AppStorage(WideHeadRangeSettingsStore.enabledKey)
    private var isWideHeadRangeEnabled = WideHeadRangeSettingsStore.defaultEnabled
    private let voiceSync = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if let engine {
                AvatarView(engine: engine)
            } else if loadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Arils avatar could not be loaded; re-save the pet from Image Rigging.")
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard engine == nil, !loadFailed else { return }
            loadEngine()
        }
        .onChange(of: isWideHeadRangeEnabled) {
            // The range is fixed per engine; rebuild with the new setting.
            engine = nil
            loadEngine()
        }
        .background {
            if isWindowVisible {
                Color.clear
                    .onReceive(voiceSync) { _ in
                        synchronizeEngine()
                    }
            }
        }
    }

    private func loadEngine() {
        do {
            let loaded = try CharacterEngine(
                archiveData: archiveData,
                configuration: CharacterEngine.Configuration(extendedHeadRange: isWideHeadRangeEnabled)
            )
            loaded.onTap = onTap
            engine = loaded
        } catch {
            loadFailed = true
        }
    }

    private func synchronizeEngine() {
        guard let engine else { return }
        engine.isSpeaking = voice.isSpeaking
        if voice.isSpeaking, let level = voice.speechPlaybackEnergy {
            engine.pushSpeechLevel(Float(level))
        }
        engine.energy = voice.isActive ? 0.72 : 0.5
        if let trilobite {
            TrilobiteArilsFaceBridge.apply(trilobite.snapshot, to: engine)
        } else {
            engine.externalGazeTarget = nil
            engine.faceTrackingInput = nil
        }
    }
}

/// Wider head movement (beta): the head turns and tilts about twice as far
/// toward what the pet looks at, and the body follows. Edges the image does
/// not contain can show at the extremes.
enum WideHeadRangeSettingsStore {
    static let enabledKey = "Pomegranate.Pet.WideHeadRange.v1"
    static let defaultEnabled = false
}
