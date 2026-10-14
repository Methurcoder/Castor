import Observation
import SwiftUI
import CastorCore

struct VoiceSelectionView: View {
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    private func L(_ source: String) -> String { CastorAppStrings.label(source, language: displayLanguage) }

    let characterName: String
    let palette: CastorPalette
    let refreshPetOnApply: Bool
    let onDismiss: () -> Void

    @State private var selectedPreset: PetVoicePreset
    @State private var speakingRate: Double
    @State private var customPersonality: String
    @State private var selectedEvasionStyle: EvasionStyle
    @State private var preview = VoicePreviewController()
    @State private var hasUnsavedChanges = false
    @State private var personalityWasEdited = false
    @State private var evasionStyleWasEdited = false

    init(
        characterName: String,
        palette: CastorPalette,
        refreshPetOnApply: Bool = true,
        onDismiss: @escaping () -> Void
    ) {
        self.characterName = characterName
        self.palette = palette
        self.refreshPetOnApply = refreshPetOnApply
        self.onDismiss = onDismiss
        _selectedPreset = State(
            initialValue: PetVoiceSelectionStore.selectedPreset()
        )
        _speakingRate = State(
            initialValue: PetVoiceSelectionStore.speakingRate()
        )
        _customPersonality = State(initialValue: PetPersonalityStore.customPersonality)
        _selectedEvasionStyle = State(initialValue: PetEvasionStyleStore.importedStyle)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 22) {
                VStack(spacing: 5) {
                    Text(L("\(characterName)の声を選んでね"))
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(L("声を選び、短いサンプルで確かめてから適用できます"))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                    Text(L("このキャラクターは人格も自由に設定できます"))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText.opacity(0.82))
                }

                voiceCarousel
                detailPanel
                personalityPanel
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 820, height: 780)
        .foregroundStyle(palette.primaryText)
        .background(voiceBackground)
        .onChange(of: selectedPreset) {
            preview.stop()
            hasUnsavedChanges = true
        }
        .onChange(of: speakingRate) {
            preview.stop()
            hasUnsavedChanges = true
        }
        .onChange(of: customPersonality) {
            hasUnsavedChanges = true
            personalityWasEdited = true
        }
        .onChange(of: selectedEvasionStyle) {
            hasUnsavedChanges = true
            evasionStyleWasEdited = true
        }
        .onDisappear {
            preview.stop()
        }
        .focusable()
        .onMoveCommand(perform: moveSelection)
    }

    private var personalityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("人格"), systemImage: "person.text.rectangle")
                    .font(.headline)
                Spacer()
                Text("\(customPersonality.count)/800")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.secondaryText)
            }

            TextEditor(text: $customPersonality)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 92)
                .padding(8)
                .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: customPersonality) {
                    if customPersonality.count > 800 {
                        customPersonality = String(customPersonality.prefix(800))
                    }
                }

            Text(L("会話と外部エージェントへの指示に使われます。パスワードや秘密情報は入れないでください。"))
                .font(.caption2)
                .foregroundStyle(palette.secondaryText.opacity(0.82))

            HStack {
                Label(L("場所を譲るとき"), systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.callout.weight(.semibold))
                Spacer()
                Picker(L("Evasion style"), selection: $selectedEvasionStyle) {
                    ForEach(EvasionStyle.allCases) { style in
                        Text(L(style.label)).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            Text(L("保存時に性格から候補を一度だけ提案します。ここで選んだ値は常に優先されます。"))
                .font(.caption2)
                .foregroundStyle(palette.secondaryText.opacity(0.82))
        }
        .padding(16)
        .castorGlassSurface(
            palette: palette,
            cornerRadius: 18,
            borderColor: selectedPreset.accent.color.opacity(0.28),
            isElevated: false
        )
    }

    private var header: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .castorGlassSurface(
                palette: palette,
                cornerRadius: 16,
                isElevated: false
            )
            .accessibilityLabel(L("Close voice selection"))

            Spacer()

            Text(L("VOICE"))
                .font(.caption.monospaced().weight(.semibold))
                .tracking(2.4)
                .foregroundStyle(palette.secondaryText)

            Spacer()

            Button(action: applySelection) {
                Text(L(hasUnsavedChanges ? "適用" : "適用済み"))
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 68)
            }
            .buttonStyle(.borderedProminent)
            .tint(selectedPreset.accent.color)
            .disabled(!hasUnsavedChanges)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var voiceCarousel: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(Array(PetVoicePreset.allCases.enumerated()), id: \.element.id) { index, preset in
                let distance = abs(index - selectedIndex)

                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        selectedPreset = preset
                    }
                } label: {
                    VStack(spacing: distance == 0 ? 11 : 8) {
                        VoiceOrb(
                            preset: preset,
                            isSelected: preset == selectedPreset,
                            isPlaying: preview.isPlaying && preset == selectedPreset
                        )
                        .frame(
                            width: orbSize(for: distance),
                            height: orbSize(for: distance)
                        )

                        VStack(spacing: 3) {
                            Text(preset.title)
                                .font(
                                    .system(
                                        size: distance == 0 ? 15 : 13,
                                        weight: distance == 0 ? .semibold : .medium,
                                        design: .rounded
                                    )
                                )
                                .lineLimit(1)

                            if distance == 0 {
                                Text(L(preset.subtitle))
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                    .transition(.opacity)
                            }
                        }
                        .frame(height: 39, alignment: .top)

                        Capsule()
                            .fill(
                                preset == selectedPreset
                                    ? preset.accent.color
                                    : Color.clear
                            )
                            .frame(width: 28, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .offset(y: distance == 0 ? -8 : CGFloat(min(distance, 2) * 8))
                    .opacity(distance >= 2 ? 0.68 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("\(preset.title), \(L(preset.subtitle))"))
            }
        }
        .frame(height: 190)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .castorGlassSurface(
            palette: palette,
            cornerRadius: 22,
            borderColor: selectedPreset.accent.color.opacity(0.30),
            isElevated: false
        )
    }

    private var detailPanel: some View {
        HStack(spacing: 22) {
            VoiceOrb(
                preset: selectedPreset,
                isSelected: true,
                isPlaying: preview.isPlaying
            )
            .frame(width: 108, height: 108)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedPreset.title)
                            .font(.title3.weight(.semibold))
                        Text(L(selectedPreset.detail))
                            .font(.callout)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button {
                        preview.toggle(
                            preset: selectedPreset,
                            speakingRate: speakingRate
                        )
                    } label: {
                        Image(systemName: preview.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(
                        Circle()
                            .fill(selectedPreset.accent.color.opacity(0.86))
                    )
                    .shadow(
                        color: selectedPreset.accent.color.opacity(0.24),
                        radius: 10,
                        y: 4
                    )
                    .accessibilityLabel(preview.isPlaying ? L("Stop voice sample") : L("Play voice sample"))
                }

                VoiceSampleWaveform(
                    accent: selectedPreset.accent.color,
                    isPlaying: preview.isPlaying
                )
                .frame(height: 28)

                HStack(spacing: 12) {
                    Image(systemName: "tortoise")
                        .foregroundStyle(palette.secondaryText)

                    Slider(value: $speakingRate, in: 0.8...1.2, step: 0.05)
                        .tint(selectedPreset.accent.color)

                    Image(systemName: "hare")
                        .foregroundStyle(palette.secondaryText)

                    Text(L("\(Int((speakingRate * 100).rounded()))%"))
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 38, alignment: .trailing)
                }

                Text(L("試聴にはローカルのNeural TTSを使用します。利用できない場合はシステム音声へ切り替わります。"))
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText.opacity(0.82))
            }
        }
        .padding(22)
        .castorGlassSurface(
            palette: palette,
            cornerRadius: 22,
            borderColor: selectedPreset.accent.color.opacity(0.38)
        )
    }

    private var selectedIndex: Int {
        PetVoicePreset.allCases.firstIndex(of: selectedPreset) ?? 0
    }

    private func orbSize(for distance: Int) -> CGFloat {
        switch distance {
        case 0:
            116
        case 1:
            91
        default:
            72
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let presets = PetVoicePreset.allCases
        let nextIndex: Int
        switch direction {
        case .left:
            nextIndex = max(selectedIndex - 1, presets.startIndex)
        case .right:
            nextIndex = min(selectedIndex + 1, presets.index(before: presets.endIndex))
        default:
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            selectedPreset = presets[nextIndex]
        }
    }

    private func applySelection() {
        preview.stop()
        PetVoiceSelectionStore.save(
            preset: selectedPreset,
            speakingRate: speakingRate
        )
        PetPersonalityStore.customPersonality = customPersonality
        if evasionStyleWasEdited {
            PetEvasionStyleStore.saveUserSelection(selectedEvasionStyle)
        } else {
            PetEvasionStyleStore.importedStyle = selectedEvasionStyle
        }
        try? PetCharacterStore.updateImportedEvasionStyle(selectedEvasionStyle)

        if personalityWasEdited,
           !evasionStyleWasEdited,
           !PetEvasionStyleStore.hasUserOverride {
            let personality = customPersonality
            Task { @MainActor in
                let suggestedStyle = await PetEvasionStyleClassifier.suggestedStyle(for: personality)
                guard PetEvasionStyleStore.saveSuggestionIfAllowed(suggestedStyle) else { return }
                try? PetCharacterStore.updateImportedEvasionStyle(suggestedStyle)
                if refreshPetOnApply {
                    CastorPetController.shared.showPet()
                }
            }
        }
        hasUnsavedChanges = false
        if refreshPetOnApply {
            CastorPetController.shared.showPet()
        }
        onDismiss()
    }

    private func close() {
        preview.stop()
        onDismiss()
    }

    private var voiceBackground: some View {
        ZStack {
            LinearGradient(
                colors: palette.background,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(selectedPreset.accent.color.opacity(0.11))
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .offset(x: 170, y: -120)

            Rectangle()
                .fill(.ultraThinMaterial.opacity(0.22))
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: selectedPreset)
    }
}

private struct VoiceOrb: View {
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    private func L(_ source: String) -> String { CastorAppStrings.label(source, language: displayLanguage) }

    let preset: PetVoicePreset
    let isSelected: Bool
    let isPlaying: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let accent = preset.accent.color

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                accent.opacity(0.54),
                                accent.opacity(0.20),
                                Color.black.opacity(0.46)
                            ],
                            center: UnitPoint(x: 0.34, y: 0.25),
                            startRadius: 1,
                            endRadius: size * 0.64
                        )
                    )

                Capsule()
                    .fill(accent.opacity(0.74))
                    .frame(width: size * 0.78, height: size * 0.24)
                    .blur(radius: size * 0.07)
                    .rotationEffect(.degrees(-24))
                    .offset(x: -size * 0.03, y: size * 0.10)

                Capsule()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: size * 0.58, height: size * 0.12)
                    .blur(radius: size * 0.045)
                    .rotationEffect(.degrees(18))
                    .offset(x: size * 0.08, y: -size * 0.02)

                Circle()
                    .fill(Color.white.opacity(0.48))
                    .frame(width: size * 0.16, height: size * 0.16)
                    .blur(radius: size * 0.035)
                    .offset(x: -size * 0.21, y: -size * 0.23)

                Circle()
                    .strokeBorder(Color.white.opacity(0.66), lineWidth: max(1, size * 0.012))

                Circle()
                    .strokeBorder(accent.opacity(isSelected ? 0.72 : 0.20), lineWidth: 2)
                    .padding(3)
            }
            .clipShape(Circle())
            .overlay {
                if isPlaying {
                    Circle()
                        .stroke(accent.opacity(0.42), lineWidth: 2)
                        .scaleEffect(1.14)
                        .transition(.opacity)
                }
            }
            .shadow(
                color: accent.opacity(isSelected ? 0.24 : 0.08),
                radius: isSelected ? 14 : 5,
                y: 5
            )
            .scaleEffect(isPlaying ? 1.025 : 1)
            .animation(
                isPlaying
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: isPlaying
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct VoiceSampleWaveform: View {
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    private func L(_ source: String) -> String { CastorAppStrings.label(source, language: displayLanguage) }

    let accent: Color
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<34, id: \.self) { index in
                Capsule()
                    .fill(accent.opacity(isPlaying ? 0.78 : 0.30))
                    .frame(
                        width: 3,
                        height: isPlaying
                            ? 7 + abs(sin(Double(index) * 1.37)) * 18
                            : 4 + abs(sin(Double(index) * 0.83)) * 8
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(
            isPlaying
                ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                : .easeOut(duration: 0.2),
            value: isPlaying
        )
    }
}

@MainActor
@Observable
private final class VoicePreviewController {
    private(set) var isPlaying = false
    private var output: PetSpeechOutput?

    func toggle(
        preset: PetVoicePreset,
        speakingRate: Double
    ) {
        if isPlaying {
            stop()
            return
        }

        let output = PetSpeechOutput(
            voiceProfile: preset.profile(speakingRateMultiplier: speakingRate)
        )
        self.output = output
        isPlaying = true
        output.speak(
            "こんにちは。今日は、どんなことを一緒に考えましょうか。",
            speech: OllamaSpeechMetadata(
                emotion: .happy,
                intensity: 0.36,
                speakingRate: 1,
                performanceNote: nil
            )
        ) { [weak self] in
            self?.isPlaying = false
            self?.output = nil
        }
    }

    func stop() {
        output?.stop()
        output = nil
        isPlaying = false
    }
}

private extension PetVoiceAccent {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}
