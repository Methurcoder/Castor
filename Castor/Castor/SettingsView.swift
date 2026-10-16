import AppKit
import SwiftUI
import Speech
import CastorCore

/// macOS 標準の Settings シーンに表示する設定画面。
/// General / Input / Voice / Brain のタブに分け、Form(.grouped) で Apple 標準の見た目に揃える。
struct CastorSettingsView: View {
    let core: HesitateCore
    let trilobite: TrilobiteEngine
    @Bindable var ollama: OllamaSession

    // Settings シーンの content はアプリ起動直後に構築されるため、
    // CoreAudio 列挙を伴う AudioInputSettings をここで即時生成すると
    // 起動(とテストランナー)がハングする。ウインドウ表示まで遅延させる。
    @State private var audioInputSettings: AudioInputSettings?
    @State private var neuralSpeechSettings: NeuralSpeechSettings?
    @State private var agentPreferences = CastorAgentPreferenceStore.current
    @State private var ollamaPrompt = ""
    @State private var isCodexDisclosurePresented = false
    @State private var isClaudeCodeDisclosurePresented = false
    @State private var isCheckingLaMa = false
    @State private var laMaStatusText: String?
    @State private var showLaMaSetupGuidance = false
    @AppStorage("Castor.SettingsDisplayLanguage")
    private var language: SettingsDisplayLanguage = .systemDefault
    @AppStorage("Pomegranate.AppearanceMode")
    private var appearance: AppearanceMode = .system
    @AppStorage("Pomegranate.Agent.CodexDisclosureAccepted.v1")
    private var hasAcceptedCodexDisclosure = false
    @AppStorage("Pomegranate.Agent.ClaudeCodeDisclosureAccepted.v1")
    private var hasAcceptedClaudeCodeDisclosure = false
    @AppStorage(PetEvasionSettingsStore.enabledKey)
    private var isPetEvasionEnabled = PetEvasionSettingsStore.defaultEnabled
    @AppStorage(AnimeFaceLandmarksSettingsStore.enabledKey)
    private var isAnimeFaceLandmarksEnabled = AnimeFaceLandmarksSettingsStore.defaultEnabled
    @AppStorage(LaMaInpaintingSettingsStore.enabledKey)
    private var isLaMaInpaintingEnabled = LaMaInpaintingSettingsStore.defaultEnabled
    @AppStorage(ManualRiggingSettingsStore.enabledKey)
    private var isManualRiggingEnabled = ManualRiggingSettingsStore.defaultEnabled
    @AppStorage(PetPassThroughSettingsStore.dodgeEnabledKey)
    private var isButtonDodgeEnabled = PetPassThroughSettingsStore.dodgeDefaultEnabled
    @State private var pointerHelperStatus: String?
    @AppStorage(WideHeadRangeSettingsStore.enabledKey)
    private var isWideHeadRangeEnabled = WideHeadRangeSettingsStore.defaultEnabled
    @AppStorage(NaturalFaceMotionSettingsStore.enabledKey)
    private var isNaturalFaceMotionEnabled = NaturalFaceMotionSettingsStore.defaultEnabled

    private func S(_ key: String, _ arguments: [String: String] = [:]) -> String {
        CastorSettingsStrings.text(key, language: language, arguments: arguments)
    }

    private func L(_ source: String) -> String {
        CastorSettingsStrings.label(source, language: language)
    }

    var body: some View {
        TabView {
            Tab(S("settings.tab.general"), systemImage: "gearshape") {
                generalTab
            }
            Tab(S("settings.tab.input"), systemImage: "camera") {
                inputTab
            }
            Tab(S("settings.tab.voice"), systemImage: "speaker.wave.2") {
                voiceTab
            }
            Tab(S("settings.tab.brain"), systemImage: "brain") {
                brainTab
            }
        }
        .frame(width: 560)
        .tint(CastorBrand.accent)
        .onAppear {
            trilobite.refreshAuthorizationState()
            if audioInputSettings == nil {
                audioInputSettings = AudioInputSettings()
            } else {
                audioInputSettings?.refresh()
            }
            if neuralSpeechSettings == nil {
                neuralSpeechSettings = NeuralSpeechSettings()
            } else {
                neuralSpeechSettings?.refresh()
            }
            agentPreferences = CastorAgentPreferenceStore.current
        }
        .onChange(of: agentPreferences) {
            CastorAgentPreferenceStore.current = agentPreferences
        }
        .onChange(of: isPetEvasionEnabled) {
            CastorPetController.shared.setEvasionEnabled(isPetEvasionEnabled)
        }
        .onChange(of: isLaMaInpaintingEnabled) {
            laMaStatusText = nil
            showLaMaSetupGuidance = false
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Picker(S("settings.language.label"), selection: $language) {
                ForEach(SettingsDisplayLanguage.allCases, id: \.rawValue) { language in
                    Text(language.nativeLabel).tag(language)
                }
            }
            Text(S("settings.language.help"))
                .font(.caption).foregroundStyle(.secondary)

            Picker(S("settings.appearance.label"), selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(L(mode.label)).tag(mode)
                }
            }

            Section {
                Toggle(isOn: $isPetEvasionEnabled) {
                    HStack(spacing: 7) {
                        Text(S("settings.evasion.label"))
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
            } footer: {
                Text(S("settings.evasion.help"))
            }

            Section {
                Toggle(isOn: $isLaMaInpaintingEnabled) {
                    HStack(spacing: 7) {
                        Text(S("settings.lama.label"))
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }

                if isLaMaInpaintingEnabled {
                    HStack {
                        Button(S("settings.lama.check")) {
                            checkLaMaAvailability()
                        }
                        .disabled(isCheckingLaMa)

                        if isCheckingLaMa {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let laMaStatusText {
                            Text(L(laMaStatusText))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if showLaMaSetupGuidance {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(S("settings.lama.missing"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(S("settings.lama.install_help"))
                                .font(.caption)
                            Text(LaMaInpaintingSetupGuidance.bootstrapCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text(S("settings.lama.start_help"))
                                .font(.caption)
                            Text(LaMaInpaintingSetupGuidance.startCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            } footer: {
                Text(S("settings.lama.help"))
            }

            Section {
                Toggle(isOn: $isAnimeFaceLandmarksEnabled) {
                    HStack(spacing: 7) {
                        Text(S("settings.face_landmarks.label"))
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }

                if isAnimeFaceLandmarksEnabled && !AnimeFaceLandmarksSettingsStore.modelsAreInstalled {
                    Text(S("settings.face_landmarks.model_missing"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(S("settings.face_landmarks.help"))
            }

            Section {
                Toggle(S("settings.manual_rigging.label"), isOn: $isManualRiggingEnabled)
            } header: {
                Text(S("settings.advanced.heading"))
            } footer: {
                Text(S("settings.manual_rigging.help"))
            }

            Section {
                Toggle(isOn: $isButtonDodgeEnabled) {
                    HStack(spacing: 7) {
                        Text(S("settings.button_dodge.label"))
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
                if isButtonDodgeEnabled {
                    HStack {
                        Button(S("settings.button_dodge.check")) {
                            Task { @MainActor in
                                switch await PointerTargetClient().health() {
                                case "ready": pointerHelperStatus = "Ready"
                                case "needs-accessibility-permission":
                                    pointerHelperStatus = "Running; allow it in System Settings › Privacy & Security › Accessibility"
                                default: pointerHelperStatus = "Not running"
                                }
                            }
                        }
                        if let pointerHelperStatus {
                            Text(L(pointerHelperStatus))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(S("settings.helper.setup_help"))
                            .font(.caption)
                        Text("scripts/bootstrap-pointer-target.sh")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("scripts/start-pointer-target.sh")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } footer: {
                Text(S("settings.button_dodge.help"))
            }

            Section {
                Toggle(isOn: $isWideHeadRangeEnabled) {
                    HStack(spacing: 7) {
                        Text(S("settings.wide_head.label"))
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
            } footer: {
                Text(S("settings.wide_head.help"))
            }

            Section {
                Toggle(S("settings.natural_face.label"), isOn: $isNaturalFaceMotionEnabled)
            } footer: {
                Text(S("settings.natural_face.help"))
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }

    private func checkLaMaAvailability() {
        isCheckingLaMa = true
        laMaStatusText = nil
        showLaMaSetupGuidance = false
        Task { @MainActor in
            defer { isCheckingLaMa = false }
            do {
                let status = try await LaMaInpaintingClient().availability()
                switch status {
                case "ready":
                    laMaStatusText = "Ready"
                case "loading":
                    laMaStatusText = "Loading model…"
                default:
                    laMaStatusText = "Service online; model loads on first use"
                }
            } catch {
                laMaStatusText = "Unavailable: \(error.localizedDescription)"
                showLaMaSetupGuidance = true
            }
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var inputTab: some View {
        if let audioInputSettings {
            InputSettingsPane(language: language, trilobite: trilobite, audioInputSettings: audioInputSettings)
        } else {
            ProgressView()
                .frame(height: 380)
        }
    }

    // MARK: - Voice

    @ViewBuilder
    private var voiceTab: some View {
        if let neuralSpeechSettings {
            VoiceSettingsPane(language: language, neuralSpeechSettings: neuralSpeechSettings)
        } else {
            ProgressView()
                .frame(minHeight: 390)
        }
    }

    // MARK: - Brain

    private var brainTab: some View {
        Form {
            Section {
                Picker(S("settings.agent.routing"), selection: $agentPreferences.routingPolicy) {
                    ForEach(CastorAgentRoutingPolicy.allCases) { policy in
                        Text(L(policy.label)).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                if agentPreferences.routingPolicy == .manual {
                    Picker(S("settings.agent.next_brain"), selection: $agentPreferences.selectedBrain) {
                        ForEach(CastorBrain.allCases) { brain in
                            Text(L(brain.label) + (brain.isImplemented ? "" : " " + S("settings.agent.coming_soon_suffix")))
                                .tag(brain)
                                .disabled(!brain.isImplemented)
                        }
                    }
                } else {
                    Picker(S("settings.agent.external_brain"), selection: $agentPreferences.automaticExternalBrain) {
                        ForEach(CastorBrain.allCases.filter { $0 != .onDevice }) { brain in
                            Text(L(brain.label) + (brain.isImplemented ? "" : " " + S("settings.agent.coming_soon_suffix")))
                                .tag(brain)
                                .disabled(!brain.isImplemented)
                        }
                    }
                }
            } header: {
                Text(S("settings.agent.section"))
            } footer: {
                if agentPreferences.routingPolicy == .manual {
                    Text(S("settings.agent.routing.manual_help"))
                } else {
                    Text(S("settings.agent.routing.automatic_help"))
                }
            }

            Section {
                TextField(S("settings.codex.url"), text: $agentPreferences.codexServerURL, prompt: Text("ws://127.0.0.1:4500"))

                AgentLauncherRow(
                    language: language,
                    service: .codex,
                    title: S("settings.codex.start"),
                    hasAcceptedDisclosure: hasAcceptedCodexDisclosure,
                    requestDisclosure: { isCodexDisclosurePresented = true },
                    copyCommand: copyCodexStartCommand
                )
                .alert(
                    S("settings.codex.disclosure.title"),
                    isPresented: $isCodexDisclosurePresented
                ) {
                    Button(S("common.cancel"), role: .cancel) {}
                    Button(S("settings.agent.disclosure.confirm")) {
                        hasAcceptedCodexDisclosure = true
                        AgentLauncher.shared.setEnabled(true, for: .codex)
                    }
                } message: {
                    Text(
                        S("settings.codex.disclosure.body")
                    )
                }
            } header: {
                Text(S("settings.codex.section"))
            } footer: {
                Text(S("settings.codex.help"))
            }

            Section {
                TextField(
                    S("settings.claude.url"),
                    text: $agentPreferences.claudeCodeBridgeURL,
                    prompt: Text("http://127.0.0.1:4510")
                )

                AgentLauncherRow(
                    language: language,
                    service: .claudeCode,
                    title: S("settings.claude.start"),
                    hasAcceptedDisclosure: hasAcceptedClaudeCodeDisclosure,
                    requestDisclosure: { isClaudeCodeDisclosurePresented = true },
                    copyCommand: copyClaudeCodeStartCommand
                )
                .alert(
                    S("settings.claude.disclosure.title"),
                    isPresented: $isClaudeCodeDisclosurePresented
                ) {
                    Button(S("common.cancel"), role: .cancel) {}
                    Button(S("settings.agent.disclosure.confirm")) {
                        hasAcceptedClaudeCodeDisclosure = true
                        AgentLauncher.shared.setEnabled(true, for: .claudeCode)
                    }
                } message: {
                    Text(
                        S("settings.claude.disclosure.body")
                    )
                }
            } header: {
                Text(S("settings.claude.section"))
            } footer: {
                Text(S("settings.claude.help"))
            }

            Section {
                HStack {
                    TextField(S("settings.agent.workspace"), text: $agentPreferences.workspacePath)
                    Button(S("settings.agent.workspace.choose")) {
                        chooseAgentWorkspace()
                    }
                }
            } header: {
                Text(S("settings.agent.workspace.section"))
            } footer: {
                Text(S("settings.agent.workspace.help"))
            }

            localAISection
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }

    private var localAISection: some View {
        Section {
            LabeledContent(S("settings.local_ai.status")) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ollamaStatusColor)
                        .frame(width: 7, height: 7)
                    Text(ollamaStatusLabel)
                }
            }

            HStack {
                Button {
                    Task {
                        await ollama.connect()
                    }
                } label: {
                    Label(
                        ollama.connectionState == .connected ? S("settings.local_ai.refresh") : S("settings.local_ai.connect"),
                        systemImage: "bolt.horizontal.circle"
                    )
                }
                .disabled(ollama.connectionState == .connecting || ollama.isLoading)

                if ollama.models.isEmpty {
                    Text(S("settings.local_ai.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(S("settings.local_ai.model"), selection: $ollama.selectedModel) {
                        ForEach(ollama.models) { model in
                            Text(
                                model.name
                                    + (model.parameterSizeLabel.map { " • \($0)" } ?? S("settings.local_ai.size_unknown_suffix"))
                                    + (model.isSmallModel ? S("settings.local_ai.small_model_suffix") : "")
                            )
                            .tag(Optional(model.name))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            if let model = ollama.models.first(where: { $0.name == ollama.selectedModel }), model.isSmallModel {
                Label(S("settings.local_ai.small_model_notice"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if ollama.activeProvider == .lmStudio {
                LabeledContent(S("settings.local_ai.acceleration")) {
                    Text(S("settings.local_ai.acceleration_managed"))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField(S("settings.local_ai.prompt"), text: $ollamaPrompt)
                    .onSubmit {
                        sendToLocalAI()
                    }

                Button {
                    sendToLocalAI()
                } label: {
                    if ollama.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    ollamaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || ollama.selectedModel == nil
                        || ollama.isLoading
                )
                .accessibilityLabel(S("settings.local_ai.send"))
            }

            if let errorMessage = ollama.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !ollama.responseText.isEmpty {
                Text(ollama.responseText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text(S("settings.local_ai.section"))
        } footer: {
            Text(
                S("settings.local_ai.help", ["ollama.lmStudioEndpoint.absoluteString": ollama.lmStudioEndpoint.absoluteString, "ollama.ollamaEndpoint.absoluteString": ollama.ollamaEndpoint.absoluteString])
            )
        }
    }

    private var ollamaStatusLabel: String {
        switch ollama.connectionState {
        case .disconnected:
            S("settings.local_ai.disconnected")
        case .connecting:
            S("settings.local_ai.connecting")
        case .connected:
            ollama.activeProvider.map { S("settings.local_ai.connected_provider", ["provider": $0.label]) } ?? S("settings.local_ai.connected_plain")
        }
    }

    private var ollamaStatusColor: Color {
        switch ollama.connectionState {
        case .disconnected:
            .secondary
        case .connecting:
            .orange
        case .connected:
            .green
        }
    }

    private func sendToLocalAI() {
        let prompt = ollamaPrompt
        ollamaPrompt = ""
        Task {
            await ollama.send(
                prompt,
                to: core,
                personalityInstruction: PetPersonalityStore.customPersonality
            )
        }
    }

    private func copyCodexStartCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "codex app-server --listen \(shellQuoted(agentPreferences.codexServerURL))",
            forType: .string
        )
    }

    private func copyClaudeCodeStartCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "python3 scripts/claude_code_bridge.py --listen \(shellQuoted(agentPreferences.claudeCodeBridgeURL))",
            forType: .string
        )
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func chooseAgentWorkspace() {
        let panel = NSOpenPanel()
        panel.title = S("settings.agent.workspace.dialog_title")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            agentPreferences.workspacePath = url.path
        }
    }
}

private struct InputSettingsPane: View {
    let language: SettingsDisplayLanguage
    let trilobite: TrilobiteEngine
    @Bindable var audioInputSettings: AudioInputSettings
    @AppStorage("Castor.Input.SpeechLanguage") private var speechLanguage = "auto"
    @AppStorage("Castor.SpeechInput.LastDiagnostic") private var lastSpeechDiagnostic = ""
    @State private var speechPermission = SFSpeechRecognizer.authorizationStatus()

    private func S(_ key: String, _ arguments: [String: String] = [:]) -> String {
        CastorSettingsStrings.text(key, language: language, arguments: arguments)
    }

    private func L(_ source: String) -> String {
        CastorSettingsStrings.label(source, language: language)
    }

    var body: some View {
        Form {
            Section {
                Toggle(S("settings.input.camera"), isOn: Binding(
                    get: { trilobite.snapshot.cameraEnabled },
                    set: { trilobite.setCameraEnabled($0) }
                ))
            } footer: {
                Text(S("settings.input.camera_permission", ["cameraPermission.label": L(trilobite.snapshot.cameraPermission.label)]))
            }

            Section {
                Toggle(S("settings.input.ambient_audio"), isOn: Binding(
                    get: { trilobite.snapshot.microphoneEnabled },
                    set: { trilobite.setMicrophoneEnabled($0) }
                ))

                if trilobite.snapshot.microphonePermission == .denied {
                    Button(S("settings.input.microphone_open_settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text(S("settings.input.microphone_denied_help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker(S("settings.input.microphone"), selection: $audioInputSettings.selectedDeviceUID) {
                    ForEach(audioInputSettings.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: audioInputSettings.selectedDeviceUID) {
                    trilobite.setAudioInputDevice(uid: audioInputSettings.selectedDeviceUID)
                }

                LabeledContent(S("settings.input.level")) {
                    AudioLevelMeter(
                        level: trilobite.snapshot.audioLevel,
                        trackColor: Color.primary.opacity(0.10),
                        fillColor: .accentColor
                    )
                    .frame(width: 180, height: 6)
                }
            } footer: {
                Text(S("settings.input.microphone_help", ["microphonePermission.label": L(trilobite.snapshot.microphonePermission.label)]))
            }
            Section(language == .japanese ? "音声認識" : "Speech recognition") {
                LabeledContent(language == .japanese ? "許可" : "Permission") {
                    Text(speechPermission == .authorized ? (language == .japanese ? "許可済み" : "Allowed")
                        : speechPermission == .notDetermined ? (language == .japanese ? "未確認（会話開始時に確認します）" : "Not requested (asked when listening starts)")
                        : (language == .japanese ? "拒否・制限されています" : "Denied or restricted"))
                }
                Picker(language == .japanese ? "認識する言語" : "Recognition language", selection: $speechLanguage) {
                    Text(language == .japanese ? "システムの優先言語" : "System preferred language").tag("auto")
                    Text("日本語").tag("ja-JP")
                    Text("English").tag("en-US")
                }
                Button(language == .japanese ? "音声認識の許可設定を開く" : "Open speech recognition privacy settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") { NSWorkspace.shared.open(url) }
                }
                if !lastSpeechDiagnostic.isEmpty {
                    Text(lastSpeechDiagnostic).font(.caption.monospaced()).textSelection(.enabled)
                    Text(language == .japanese ? "診断コードに録音や認識した文章は含みません。" : "Diagnostics contain no recording or transcript.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .task {
            while !Task.isCancelled {
                speechPermission = SFSpeechRecognizer.authorizationStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

private struct VoiceSettingsPane: View {
    let language: SettingsDisplayLanguage
    @Bindable var neuralSpeechSettings: NeuralSpeechSettings
    @State private var speechLauncher = NeuralSpeechLauncher.shared

    private func S(_ key: String, _ arguments: [String: String] = [:]) -> String {
        CastorSettingsStrings.text(key, language: language, arguments: arguments)
    }

    private func L(_ source: String) -> String {
        CastorSettingsStrings.label(source, language: language)
    }

    var body: some View {
        Form {
            Section {
                Picker(S("settings.voice.engine"), selection: $neuralSpeechSettings.voiceEngine) {
                    ForEach(NeuralVoiceEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label(neuralSpeechSettings.isQwenReady
                        ? (language == .japanese ? "Qwen 3 TTSで話します（helper接続中）" : "Qwen 3 TTS is ready (helper connected)")
                        : S("settings.voice.qwen_offer"), systemImage: neuralSpeechSettings.isQwenReady ? "checkmark.circle.fill" : "waveform")
                        .font(.headline)
                    if !neuralSpeechSettings.isQwenReady {
                        Text(S("settings.voice.qwen_load_help"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(S("settings.voice.qwen_load")) {
                            neuralSpeechSettings.prepareQwen()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(neuralSpeechSettings.isPreparingQwen || speechLauncher.isLaunching)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CastorBrand.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                if speechLauncher.canStop {
                    Button(language == .japanese ? "Qwen音声を停止" : "Stop Qwen speech") {
                        neuralSpeechSettings.resetQwenReadiness(stopping: true)
                        speechLauncher.stop()
                    }
                    .disabled(neuralSpeechSettings.isPreparingQwen)
                }
                if speechLauncher.stopFailed {
                    Label(language == .japanese
                        ? "停止要求を送れませんでした。音声helperの画面で停止してください。"
                        : "Could not send the stop request. Stop in the speech helper window.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if speechLauncher.launchFailed {
                    Label(language == .japanese
                        ? "音声helperを開けませんでした。導入GUIで取得・修復してください。"
                        : "Could not open the speech helper. Install or repair it using Setup.",
                        systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if speechLauncher.didOpenHelper {
                    Text(language == .japanese
                        ? "音声helperを開きました。OSの確認が出た場合は、手元で開くことを許可してください。"
                        : "Speech helper opened. If the OS asks, allow it to open on this device.")
                        .foregroundStyle(.secondary)
                }
                Button(language == .japanese ? "Neural TTSの導入GUIを開く":"Open Neural TTS setup") {
                    if let setup=Bundle.main.url(forResource:"CastorSetup",withExtension:"app") {
                        NSWorkspace.shared.open(setup)
                    } else {
                        let alert=NSAlert()
                        alert.messageText=language == .japanese ? "導入GUIは配布候補に同梱されます":"Setup is included in distribution candidates"
                        alert.informativeText=language == .japanese ? "この開発用ビルドには導入GUIがありません。配布Releaseが用意されたらCastorSetupから追加helperを取得できます。":"This development build has no bundled setup. Once a distribution Release is available, use CastorSetup to get the optional helper."
                        alert.addButton(withTitle:language == .japanese ? "配布ページを開く":"Open release page")
                        alert.addButton(withTitle:language == .japanese ? "閉じる":"Close")
                        if alert.runModal() == .alertFirstButtonReturn {NSWorkspace.shared.open(URL(string:"https://github.com/Methurcoder/Castor/releases/latest")!)}
                    }
                }
                if neuralSpeechSettings.isPreparingQwen {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(S("settings.voice.preparing"))
                        Button(language == .japanese ? "キャンセル" : "Cancel") { neuralSpeechSettings.cancelPreparation() }
                            .foregroundStyle(.secondary)
                    }
                } else if let error = neuralSpeechSettings.preparationError {
                    Label(language == .japanese
                        ? "Qwenを準備できませんでした。音声helperの起動、接続、空き容量を確認して再試行してください。"
                        : error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(L(neuralSpeechSettings.voiceEngine.detail))
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 390)
        .task {
            while !Task.isCancelled {
                await neuralSpeechSettings.refreshQwenReadiness()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

/// One switch that starts a local agent service through `AgentLauncher`,
/// with its status. Copying the Terminal command stays available for people
/// who prefer to run it themselves.
private struct AgentLauncherRow: View {
    let language: SettingsDisplayLanguage
    let service: AgentLauncherService
    let title: String
    let hasAcceptedDisclosure: Bool
    let requestDisclosure: () -> Void
    let copyCommand: () -> Void
    @State private var launcher = AgentLauncher.shared

    private func S(_ key: String, _ arguments: [String: String] = [:]) -> String {
        CastorSettingsStrings.text(key, language: language, arguments: arguments)
    }

    private func L(_ source: String) -> String {
        CastorSettingsStrings.label(source, language: language)
    }

    var body: some View {
        let summary = launcher.summary(for: service)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: Binding(
                get: { launcher.isEnabled(service) },
                set: { enabled in
                    if enabled && !hasAcceptedDisclosure {
                        requestDisclosure()
                    } else {
                        launcher.setEnabled(enabled, for: service)
                    }
                }
            ))
            HStack(spacing: 8) {
                Circle()
                    .fill(summary.isProblem ? Color.orange : (launcher.isEnabled(service) ? Color.green : Color.secondary.opacity(0.4)))
                    .frame(width: 7, height: 7)
                Text(L(summary.text))
                    .font(.caption)
                    .foregroundStyle(summary.isProblem ? .primary : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if launcher.isEnabled(service) {
                    Button(S("settings.agent.restart")) { Task { await launcher.restart() } }
                        .controlSize(.small)
                }
                Button(S("settings.agent.copy_command"), action: copyCommand)
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
        .onAppear { launcher.startPolling() }
    }
}
