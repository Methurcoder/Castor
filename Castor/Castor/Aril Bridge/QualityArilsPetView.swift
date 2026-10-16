import Arils
import Combine
import SwiftUI

/// Renders a saved two-view (front + side) Arils Quality avatar as the
/// floating pet — the Quality sibling of `ArilsPetView`, bridging the same
/// three things the engine cannot know on its own:
/// - `voice.isSpeaking` / `speechPlaybackEnergy` → lip sync (both views);
/// - taps → `voice.toggle()` via `QualityCharacterEngine.onTap`;
/// - conversation activity → `energy`.
struct QualityArilsPetView: View {
    let archiveData: Data
    let voice: PetVoiceConversation
    let trilobite: TrilobiteEngine?
    let isWindowVisible: Bool
    let onTap: () -> Void

    @State private var engine: QualityCharacterEngine?
    @State private var loadFailed = false
    @AppStorage(WideHeadRangeSettingsStore.enabledKey)
    private var isWideHeadRangeEnabled = WideHeadRangeSettingsStore.defaultEnabled
    @AppStorage(NaturalFaceMotionSettingsStore.enabledKey)
    private var isNaturalFaceMotionEnabled = NaturalFaceMotionSettingsStore.defaultEnabled
    private let voiceSync = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if let engine {
                QualityAvatarView(engine: engine)
            } else if loadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Arils Quality avatar could not be loaded; re-save the pet from Image Rigging.")
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
        .onChange(of: isNaturalFaceMotionEnabled) {
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
            let loaded = try QualityCharacterEngine(
                archiveData: archiveData,
                configuration: CharacterEngine.Configuration(
                    extendedHeadRange: isWideHeadRangeEnabled,
                    followingHair: isNaturalFaceMotionEnabled
                )
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
