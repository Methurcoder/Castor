import PetRuntime
import AppKit
import SwiftUI
import CastorCore

/// メイン画面。キャラクターを主役にした 1 カラム構成で、
/// 上部にモード切替、下部に状態切替、右上に設定とデバッグ表示の入口だけを置く。
/// 詳細設定は macOS 標準の Settings ウインドウ(CastorSettingsView)へ移した。
struct ContentView: View {
    let core: HesitateCore
    let trilobite: TrilobiteEngine

    @State private var incomingAIImage: NSImage?
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    @Environment(\.openSettings) private var openSettings
    @State private var experienceMode: ExperienceMode = .rigging
    @State private var isDebugPanelVisible = false
    @State private var ambientLightPosition: CGPoint?
    @AppStorage("Pomegranate.AppearanceMode")
    private var appearance: AppearanceMode = .system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = palette

        VStack(spacing: 20) {
            Picker("Mode", selection: $experienceMode) {
                ForEach(ExperienceMode.allCases) { mode in
                    Text(displayLanguage == .japanese ? (mode == .aiSetup ? "AIで設定" : "リギング") : mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 500)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .castorGlassSurface(palette: palette, cornerRadius: 18)

            stage(palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if experienceMode != .aiSetup {
                Picker("Motion State", selection: stateBinding) {
                    ForEach(MotionState.allCases) { state in
                        Text(state.label).tag(state)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .castorGlassSurface(palette: palette, cornerRadius: 18)
                .padding(.bottom, 6)
            }

            if isDebugPanelVisible {
                VStack(spacing: 12) {
                    MotionStateReadout(core: core, trilobite: trilobite, palette: palette)
                    TrilobiteDebugView(trilobite: trilobite, palette: palette)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(20)
        .frame(
            minWidth: fixedWindowSize?.width ?? 980,
            maxWidth: fixedWindowSize?.width ?? .infinity,
            minHeight: fixedWindowHeight ?? 700,
            maxHeight: fixedWindowHeight ?? .infinity
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                ambientLightPosition = location
            case .ended:
                ambientLightPosition = nil
            }
        }
        .foregroundStyle(palette.primaryText)
        .background(background(palette))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                debugToggleButton(palette)
                settingsButton(palette)
            }
            .padding(16)
        }
        .animation(.easeInOut(duration: 0.18), value: isDebugPanelVisible)
        .tint(CastorBrand.accent)
        .preferredColorScheme(appearance.preferredColorScheme)
        .alert(displayLanguage == .japanese ? "マイクを使うには許可が必要です" : "Allow microphone access to use audio", isPresented: Binding(
            get: { trilobite.isMicrophoneGuidancePresented },
            set: { trilobite.isMicrophoneGuidancePresented = $0 }
        )) {
            Button(displayLanguage == .japanese ? "システム設定を開く" : "Open System Settings") {
                if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
            }
            Button(displayLanguage == .japanese ? "Castorの設定を開く" : "Open Castor Settings") { openSettings() }
            Button(displayLanguage == .japanese ? "後で" : "Later",role:.cancel) {}
        } message: {
            Text(displayLanguage == .japanese
                ? "拒否してもペットの作成や文字での会話は使えます。システム設定 → プライバシーとセキュリティ → マイクでCastorを許可した後、Castorの設定 → 入力でマイクをオンにできます。音量への反応は端末内で処理し、音声チャットはマイクボタンを押したときだけ認識します。"
                : "You can still create pets and use text chat. Allow Castor in System Settings → Privacy & Security → Microphone, then turn on Microphone in Castor Settings → Input. Audio-level reactions stay on this device; voice chat listens only when you press its microphone button.")
        }
    }

    @ViewBuilder
    private func stage(_ palette: CastorPalette) -> some View {
        switch experienceMode {
        case .aiSetup:
            ArilsAISetupView(palette: palette) { image in
                incomingAIImage = image
                experienceMode = .rigging
            }
        case .rigging:
            ImageRiggingView(
                core: core,
                trilobite: trilobite,
                palette: palette,
                animationsPaused: false,
                initialImage: incomingAIImage
            )
        }
    }

    /// Rigging 以外は最小限の固定サイズに収める。Rigging は編集作業向けに広くリサイズ可能のまま。
    private var fixedWindowSize: CGSize? {
        switch experienceMode {
        case .aiSetup:
            CGSize(width: 780, height: 650)
        case .rigging:
            nil
        }
    }

    private var fixedWindowHeight: CGFloat? {
        fixedWindowSize.map { $0.height + (isDebugPanelVisible ? 210 : 0) }
    }

    private var stateBinding: Binding<MotionState> {
        Binding(
            get: { core.snapshot.state },
            set: { core.request($0) }
        )
    }

    private var resolvedIsDark: Bool {
        switch appearance {
        case .system:
            colorScheme == .dark
        case .light:
            false
        case .dark:
            true
        }
    }

    private var palette: CastorPalette {
        CastorPalette(isDark: resolvedIsDark)
    }

    private func settingsButton(_ palette: CastorPalette) -> some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondaryText)
        .castorGlassSurface(palette: palette, cornerRadius: 16, isElevated: false)
        .accessibilityLabel("Settings")
    }

    private func debugToggleButton(_ palette: CastorPalette) -> some View {
        Button {
            isDebugPanelVisible.toggle()
        } label: {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDebugPanelVisible ? palette.accent : palette.secondaryText)
        .castorGlassSurface(
            palette: palette,
            cornerRadius: 16,
            borderColor: isDebugPanelVisible ? palette.accent.opacity(0.55) : nil,
            isElevated: false
        )
        .accessibilityLabel("Toggle debug panel")
    }

    private func background(_ palette: CastorPalette) -> some View {
        CastorAmbientBackground(
            accent: CastorBrand.accent,
            isDark: resolvedIsDark,
            lightPosition: ambientLightPosition
        )
    }
}

struct MotionParameterTimeline<Content: View>: View {
    let core: HesitateCore
    let trilobite: TrilobiteEngine
    let isPaused: Bool
    private let content: (MotionParameters, Date) -> Content
    private let connection = CherryConnection()

    init(
        core: HesitateCore,
        trilobite: TrilobiteEngine,
        isPaused: Bool,
        @ViewBuilder content: @escaping (MotionParameters, Date) -> Content
    ) {
        self.core = core
        self.trilobite = trilobite
        self.isPaused = isPaused
        self.content = content
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: isPaused
            )
        ) { timeline in
            let parameters = connection.parameters(
                from: core.snapshot,
                trilobite: trilobite.snapshot,
                at: timeline.date
            )
            content(parameters, timeline.date)
        }
    }
}

private struct MotionStateReadout: View {
    let core: HesitateCore
    let trilobite: TrilobiteEngine
    let palette: CastorPalette
    private let connection = CherryConnection()
    @State private var values = Values()

    var body: some View {
        HStack(spacing: 12) {
            readoutItem("Core", values.coreState)
            readoutItem("Input", values.inputState)
            readoutItem("Cherry", values.mouthOpen)
            readoutItem("Engine", values.headTilt)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .castorGlassSurface(
            palette: palette,
            isElevated: false
        )
        .task {
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sample() {
        let input = trilobite.snapshot
        let snapshot = core.snapshot
        let parameters = connection.parameters(
            from: snapshot,
            trilobite: input,
            at: .now
        )
        values = Values(
            coreState: snapshot.state.label,
            inputState: input.isListening ? "listening" : "quiet",
            mouthOpen: String(format: "%.2f", parameters.mouthOpen),
            headTilt: String(format: "%.1f", parameters.headTilt)
        )
    }

    private func readoutItem(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(palette.secondaryText)
            Text(value)
                .foregroundStyle(palette.primaryText)
        }
        .frame(minWidth: 72)
    }

    private struct Values {
        var coreState = MotionState.idle.label
        var inputState = "quiet"
        var mouthOpen = "0.00"
        var headTilt = "0.0"
    }
}

private struct TrilobiteDebugView: View {
    let trilobite: TrilobiteEngine
    let palette: CastorPalette
    @State private var input = TrilobiteInputSnapshot.inactive

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("trilobite Engine")
                    .fontWeight(.semibold)
                Spacer()
                Text(input.microphoneEnabled ? "audio react on" : "audio react off")
                Text(input.cameraEnabled ? "cam on" : "cam off")
            }
            .foregroundStyle(palette.secondaryText)

            AudioLevelMeter(
                level: input.audioLevel,
                trackColor: palette.meterTrack,
                fillColor: palette.meterFill
            )
            .frame(height: 8)

            HStack(spacing: 12) {
                debugItem("audioLevel", String(format: "%.2f", input.audioLevel))
                debugItem("faceDetected", input.faceDetected ? "true" : "false")
                debugItem("gazeX", String(format: "%.1f", input.gazeX))
                debugItem("gazeY", String(format: "%.1f", input.gazeY))
                debugItem(
                    "face Vision",
                    String(
                        format: "%.1fms %@",
                        input.faceAnalysisDurationMilliseconds,
                        input.faceAnalysisFitsSevenHertzBudget ? "7Hz ok" : "over"
                    )
                )
            }
        }
        .font(.caption.monospaced())
        .padding(12)
        .frame(maxWidth: 430)
        .castorGlassSurface(
            palette: palette,
            isElevated: false
        )
        .task {
            while !Task.isCancelled {
                input = trilobite.snapshot
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func debugItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(palette.secondaryText)
            Text(value)
                .foregroundStyle(palette.primaryText)
        }
        .frame(minWidth: 72, alignment: .leading)
    }
}

private enum ExperienceMode: String, CaseIterable, Identifiable {
    case aiSetup
    case rigging

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aiSetup:
            "Setting with AI"
        case .rigging:
            "Rigging"
        }
    }
}

#Preview {
    ContentView(core: HesitateCore(), trilobite: TrilobiteEngine())
}
