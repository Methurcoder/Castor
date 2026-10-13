import AppKit
import SwiftUI
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

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalTab
            }
            Tab("Input", systemImage: "camera") {
                inputTab
            }
            Tab("Voice", systemImage: "speaker.wave.2") {
                voiceTab
            }
            Tab("Brain", systemImage: "brain") {
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
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Section {
                Toggle(isOn: $isPetEvasionEnabled) {
                    HStack(spacing: 7) {
                        Text("Pet Evasion")
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
            } footer: {
                Text("When another app covers the pet, it can move aside as your pointer approaches. Off by default while this behavior is in beta. Whatever this setting, hold Option over the pet to see through it and click what it covers.")
            }

            Section {
                Toggle(isOn: $isLaMaInpaintingEnabled) {
                    HStack(spacing: 7) {
                        Text("LaMa Underpaint")
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
                        Button("Check local service") {
                            checkLaMaAvailability()
                        }
                        .disabled(isCheckingLaMa)

                        if isCheckingLaMa {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let laMaStatusText {
                            Text(laMaStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if showLaMaSetupGuidance {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("The local helper may not be installed or running.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("If it is not installed, run this from the repository root:")
                                .font(.caption)
                            Text(LaMaInpaintingSetupGuidance.bootstrapCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text("Then start the local service:")
                                .font(.caption)
                            Text(LaMaInpaintingSetupGuidance.startCommand)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            } footer: {
                Text("Uses the optional LaMa helper only while a new Arils avatar is built. It is off by default, sends images only to 127.0.0.1, and falls back to the standard repair if the helper is unavailable.")
            }

            Section {
                Toggle(isOn: $isAnimeFaceLandmarksEnabled) {
                    HStack(spacing: 7) {
                        Text("Anime Face Landmarks")
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }

                if isAnimeFaceLandmarksEnabled && !AnimeFaceLandmarksSettingsStore.modelsAreInstalled {
                    Text("The model files are not in this build. Face review uses the built-in estimator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Places the head, eye, and mouth markers in face review with an anime-trained landmark model that runs on this Mac. Nothing is sent anywhere; turn it off to use the built-in estimator.")
            }

            Section {
                Toggle("Manual rigging", isOn: $isManualRiggingEnabled)
            } header: {
                Text("Advanced")
            } footer: {
                Text("Shows the legacy rectangle rig editor in Rigging, for images Arils cannot rig yet. Pets can then be saved without an Arils rig.")
            }

            Section {
                Toggle(isOn: $isButtonDodgeEnabled) {
                    HStack(spacing: 7) {
                        Text("Button-aware dodge")
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
                        Button("Check local helper") {
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
                            Text(pointerHelperStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Set up and start the helper from the repository root:")
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
                Text("When your pointer moves onto the pet over a button or other control of another app, the pet slides aside so you can click it, then returns. Knowing what is underneath needs a local helper with Accessibility permission, because the sandboxed app cannot look at other apps itself. The helper reports only the kind of control, never its text, and listens on 127.0.0.1 only.")
            }

            Section {
                Toggle(isOn: $isWideHeadRangeEnabled) {
                    HStack(spacing: 7) {
                        Text("Wider head movement")
                        Text("BETA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
            } footer: {
                Text("Arils pets turn and tilt their head about twice as far toward what they look at, and the body follows. A single picture has nothing behind the head, so edges or a gap can show at the far end of a turn.")
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
                laMaStatusText = LaMaInpaintingSetupGuidance.unavailableStatus(
                    errorDescription: error.localizedDescription
                )
                showLaMaSetupGuidance = true
            }
        }
    }

    // MARK: - Input

    @ViewBuilder
    private var inputTab: some View {
        if let audioInputSettings {
            InputSettingsPane(trilobite: trilobite, audioInputSettings: audioInputSettings)
        } else {
            ProgressView()
                .frame(height: 380)
        }
    }

    // MARK: - Voice

    @ViewBuilder
    private var voiceTab: some View {
        if let neuralSpeechSettings {
            VoiceSettingsPane(neuralSpeechSettings: neuralSpeechSettings)
        } else {
            ProgressView()
                .frame(height: 220)
        }
    }

    // MARK: - Brain

    private var brainTab: some View {
        Form {
            Section {
                Picker("Routing", selection: $agentPreferences.routingPolicy) {
                    ForEach(CastorAgentRoutingPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .pickerStyle(.segmented)

                if agentPreferences.routingPolicy == .manual {
                    Picker("Brain for the next message", selection: $agentPreferences.selectedBrain) {
                        ForEach(CastorBrain.allCases) { brain in
                            Text(brain.isImplemented ? brain.label : "\(brain.label) · Soon")
                                .tag(brain)
                                .disabled(!brain.isImplemented)
                        }
                    }
                } else {
                    Picker("External agent", selection: $agentPreferences.automaticExternalBrain) {
                        ForEach(CastorBrain.allCases.filter { $0 != .onDevice }) { brain in
                            Text(brain.isImplemented ? brain.label : "\(brain.label) · Soon")
                                .tag(brain)
                                .disabled(!brain.isImplemented)
                        }
                    }
                }
            } header: {
                Text("Castor brain")
            } footer: {
                if agentPreferences.routingPolicy == .manual {
                    Text("Keep conversations local, or let an external agent act through Castor.")
                } else {
                    Text("Everyday chat stays on-device. Requests involving files, apps, commands, or development are sent to the selected external agent.")
                }
            }

            Section {
                TextField("Server URL", text: $agentPreferences.codexServerURL, prompt: Text("ws://127.0.0.1:4500"))

                LabeledContent("Run Codex locally before using external mode.") {
                    Button {
                        if hasAcceptedCodexDisclosure {
                            copyCodexStartCommand()
                        } else {
                            isCodexDisclosurePresented = true
                        }
                    } label: {
                        Label("Copy start command", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                .alert(
                    "Connect Castor to Codex?",
                    isPresented: $isCodexDisclosurePresented
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button("I Understand and Copy") {
                        hasAcceptedCodexDisclosure = true
                        copyCodexStartCommand()
                    }
                } message: {
                    Text(
                        "Codex may send your messages, selected workspace context, and command or file-operation details to OpenAI services. This can use Codex plan or API tokens, and data handling follows your Codex and OpenAI settings. On-device mode does not use this Codex connection. Copying the command does not connect until you run it and choose Codex in Castor."
                    )
                }
            } header: {
                Text("Codex App Server")
            }

            Section {
                TextField(
                    "Bridge URL",
                    text: $agentPreferences.claudeCodeBridgeURL,
                    prompt: Text("http://127.0.0.1:4510")
                )

                LabeledContent("Run the local bridge before choosing Claude Code.") {
                    Button {
                        if hasAcceptedClaudeCodeDisclosure {
                            copyClaudeCodeStartCommand()
                        } else {
                            isClaudeCodeDisclosurePresented = true
                        }
                    } label: {
                        Label("Copy start command", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                .alert(
                    "Connect Castor to Claude Code?",
                    isPresented: $isClaudeCodeDisclosurePresented
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button("I Understand and Copy") {
                        hasAcceptedClaudeCodeDisclosure = true
                        copyClaudeCodeStartCommand()
                    }
                } message: {
                    Text(
                        "Claude Code may send your messages and selected workspace context to Anthropic services and can use your Claude plan or API billing. The local bridge asks Castor before unresolved commands or file operations run. On-device mode does not use this connection. Copying the command does not connect until you run it and choose Claude Code in Castor."
                    )
                }
            } header: {
                Text("Claude Code Bridge")
            } footer: {
                Text("Requires an installed and authenticated Claude Code CLI. The bridge listens only on this Mac and does not store API credentials.")
            }

            Section {
                HStack {
                    TextField("Workspace folder", text: $agentPreferences.workspacePath)
                    Button("Choose...") {
                        chooseAgentWorkspace()
                    }
                }
            } header: {
                Text("External agent workspace")
            } footer: {
                Text("Codex and Claude Code receive this folder as their working directory. Choose only a workspace you intend to share with the selected service.")
            }

            localAISection
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }

    private var localAISection: some View {
        Section {
            LabeledContent("Status") {
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
                        ollama.connectionState == .connected ? "Refresh" : "Connect",
                        systemImage: "bolt.horizontal.circle"
                    )
                }
                .disabled(ollama.connectionState == .connecting || ollama.isLoading)

                if ollama.models.isEmpty {
                    Text("Start LM Studio or Ollama and install a model to continue.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $ollama.selectedModel) {
                        ForEach(ollama.models) { model in
                            Text(
                                model.name
                                    + (model.parameterSizeLabel.map { " • \($0)" } ?? " • Size unknown")
                                    + (model.isSmallModel ? " — For conversation; may be inaccurate" : "")
                            )
                            .tag(Optional(model.name))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            if let model = ollama.models.first(where: { $0.name == ollama.selectedModel }), model.isSmallModel {
                Label("Below about 7B parameters: suited to casual conversation; answers may be inaccurate. Size is only a rough guide.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if ollama.activeProvider == .lmStudio {
                LabeledContent("Acceleration") {
                    Text("Managed by LM Studio")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("Say something to Castor", text: $ollamaPrompt)
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
                .accessibilityLabel("Send to local AI")
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
            Text("Local AI")
        } footer: {
            Text(
                "LM Studio at \(ollama.lmStudioEndpoint.absoluteString) • Ollama at \(ollama.ollamaEndpoint.absoluteString)\nLM Studio is preferred when both have conversational models. DFlash, DSpark, and MTP follow the model's load settings in LM Studio when supported."
            )
        }
    }

    private var ollamaStatusLabel: String {
        switch ollama.connectionState {
        case .disconnected:
            "Not connected"
        case .connecting:
            "Connecting"
        case .connected:
            ollama.activeProvider.map { "Connected — \($0.label)" } ?? "Connected"
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
        panel.title = "Choose the workspace Castor may give to external agents"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            agentPreferences.workspacePath = url.path
        }
    }
}

private struct InputSettingsPane: View {
    let trilobite: TrilobiteEngine
    @Bindable var audioInputSettings: AudioInputSettings

    var body: some View {
        Form {
            Section {
                Toggle("Camera input", isOn: Binding(
                    get: { trilobite.snapshot.cameraEnabled },
                    set: { trilobite.setCameraEnabled($0) }
                ))
            } footer: {
                Text("Permission: \(trilobite.snapshot.cameraPermission.label)")
            }

            Section {
                Toggle("Ambient audio reactions", isOn: Binding(
                    get: { trilobite.snapshot.microphoneEnabled },
                    set: { trilobite.setMicrophoneEnabled($0) }
                ))

                Picker("Microphone", selection: $audioInputSettings.selectedDeviceUID) {
                    ForEach(audioInputSettings.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: audioInputSettings.selectedDeviceUID) {
                    trilobite.setAudioInputDevice(uid: audioInputSettings.selectedDeviceUID)
                }

                LabeledContent("Level") {
                    AudioLevelMeter(
                        level: trilobite.snapshot.audioLevel,
                        trackColor: Color.primary.opacity(0.10),
                        fillColor: .accentColor
                    )
                    .frame(width: 180, height: 6)
                }
            } footer: {
                Text("Microphone permission: \(trilobite.snapshot.microphonePermission.label)\nThis toggle controls always-on audio-level reactions. Voice chat uses the selected microphone only while the mic button is active.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }
}

private struct VoiceSettingsPane: View {
    @Bindable var neuralSpeechSettings: NeuralSpeechSettings

    var body: some View {
        Form {
            Section {
                Picker("Neural voice", selection: $neuralSpeechSettings.voiceEngine) {
                    ForEach(NeuralVoiceEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }

                if neuralSpeechSettings.isPreparingQwen {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing Qwen 0.6B...")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = neuralSpeechSettings.preparationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text(neuralSpeechSettings.voiceEngine.detail)
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}
