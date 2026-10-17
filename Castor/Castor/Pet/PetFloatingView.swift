import AppKit
import SwiftUI
import CastorCore

struct PetFloatingView: View {
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    private func L(_ source: String) -> String { CastorAppStrings.label(source, language: displayLanguage) }

    let asset: SavedPetCharacter
    let trilobite: TrilobiteEngine?
    let onClose: () -> Void
    let onReaderModeChange: (Bool) -> Void
    let evasionPresentation: PetEvasionPresentation
    private let cachedImage: NSImage?
    private let connection = CherryConnection()
    @State private var voice: PetVoiceConversation
    @State private var isPetTouched = false
    @State private var isReaderExpanded = false
    @State private var messageDraft = ""
    @State private var agentPreferences = CastorAgentPreferenceStore.current
    @State private var isWindowVisible = true
    @State private var copiedDiagnostic = false
    @FocusState private var isMessageFocused: Bool

    init(
        asset: SavedPetCharacter,
        trilobite: TrilobiteEngine? = nil,
        onClose: @escaping () -> Void,
        onReaderModeChange: @escaping (Bool) -> Void,
        evasionPresentation: PetEvasionPresentation
    ) {
        self.asset = asset
        self.trilobite = trilobite
        self.onClose = onClose
        self.onReaderModeChange = onReaderModeChange
        self.evasionPresentation = evasionPresentation
        self.cachedImage = asset.image
        self._voice = State(
            initialValue: PetVoiceConversation()
        )
    }

    var body: some View {
        Group {
            if isReaderExpanded {
                expandedReader
            } else {
                compactPet
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
        .contextMenu {
            Button {
                PetGIFShareWindow.shared.show(asset: asset)
            } label: {
                Label(L("GIFを作ってXで共有"), systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(L("ペットを閉じる"), action: onClose)
        }

        .background(
            WindowOcclusionObserver { isVisible in
                isWindowVisible = isVisible
            }
        )
        .onDisappear {
            voice.cancel()
        }
        .onAppear {
            agentPreferences = CastorAgentPreferenceStore.current
        }
        .onChange(of: agentPreferences) {
            CastorAgentPreferenceStore.current = agentPreferences
        }
        .onChange(of: evasionPresentation.cueSequence) {
            if evasionPresentation.cueSoundEffect == .systemBeep {
                NSSound.beep()
            }
            if let line = evasionPresentation.cueVoiceLine {
                voice.speakEvasionCue(line)
            }
        }
    }

    /// Chooses how often the floating pet's motion timeline redraws, trading animation
    /// smoothness for CPU/GPU usage when the pet is not being actively watched or interacted
    /// with. Because every motion value in `CherryConnection`/`petParameters` is a pure function
    /// of absolute time, switching cadence (or pausing/resuming) never causes a visual jump —
    /// the next tick just resumes the same continuous curve at the new wall-clock time.
    private var petTimelineSchedule: AnimationTimelineSchedule {
        guard isWindowVisible else {
            return .animation(minimumInterval: nil, paused: true)
        }

        let isActive = voice.isActive || isPetTouched || voice.pendingApproval != nil
        return .animation(minimumInterval: isActive ? nil : 1.0 / 30.0, paused: false)
    }

    private var compactPet: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    // Imported characters saved with the Arils engine render
                    // through it directly: the engine drives its own display
                    // loop, so it lives outside the TimelineView motion path.
                    // The two-view Quality archive wins over the standard one.
                    if let qualityArchiveData = asset.qualityArchiveData {
                        QualityArilsPetView(
                            archiveData: qualityArchiveData,
                            voice: voice,
                            trilobite: trilobite,
                            isWindowVisible: isWindowVisible,
                            onTap: {
                                NSApp.activate(ignoringOtherApps: true)
                                voice.toggle()
                            }
                        )
                        .frame(width: 190, height: 230)
                        .scaleEffect(characterScale, anchor: .bottom)
                        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: characterScale)
                    } else if let arilsArchiveData = asset.arilsArchiveData {
                        ArilsPetView(
                            archiveData: arilsArchiveData,
                            voice: voice,
                            trilobite: trilobite,
                            isWindowVisible: isWindowVisible,
                            onTap: {
                                NSApp.activate(ignoringOtherApps: true)
                                voice.toggle()
                            }
                        )
                        .frame(width: 190, height: 230)
                        .scaleEffect(characterScale, anchor: .bottom)
                        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: characterScale)
                    } else {
                        TimelineView(petTimelineSchedule) { context in
                            let parameters = petParameters(at: context.date, touched: isPetTouched)

                            if let image = cachedImage, let document = asset.document {
                                RiggedCharacterRenderer(
                                    image: image,
                                    document: document,
                                    parameters: parameters
                                )
                                .frame(width: 190, height: 230)
                                .scaleEffect(characterScale, anchor: .bottom)
                                .animation(.spring(response: 0.28, dampingFraction: 0.58), value: characterScale)
                            }
                        }
                    }

                    if voice.isActive || isPetTouched {
                        Image(systemName: voiceIndicatorSymbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(voice.isListening ? Color.red.opacity(0.94) : Color.white.opacity(0.88))
                            .symbolEffect(.pulse, isActive: voice.isActive)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                            .offset(y: 5)
                            .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .center)))
                    }
                }
                .frame(width: 210, height: 238)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                        isPetTouched = isHovering
                    }
                }
                .onTapGesture {
                    // Arils pets report their own taps (and tell them apart
                    // from drags); handling the click here too toggled the
                    // voice twice, starting and at once stopping listening.
                    guard asset.arilsArchiveData == nil, asset.qualityArchiveData == nil else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    voice.toggle()
                }

                if voice.pendingApproval != nil {
                    approvalPanel(compact: true)
                } else if voice.hasResponse {
                    SpokenResponseReader(
                        segments: voice.responseSegments,
                        segmentIndex: voice.currentResponseSegmentIndex,
                        progress: { voice.currentResponseSegmentProgress },
                        isSpeaking: voice.isSpeaking,
                        isExpanded: false,
                        onToggleExpanded: toggleReaderMode
                    )
                    .frame(width: 238, height: 82)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.50)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.20), lineWidth: 1))
                    .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if isPetTouched || voice.isActive || voice.phase == .failed {
                    HStack(spacing: 7) {
                        Image(systemName: voiceIndicatorSymbol)
                            .foregroundStyle(voice.isListening ? Color.red.opacity(0.92) : Color.white.opacity(0.82))

                        Text(localizedVoiceCaption)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(voice.phase == .thinking || voice.phase == .failed ? 3 : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentTransition(.identity)
                            .animation(nil, value: voice.caption)

                        if let code = failureDiagnostic {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                copiedDiagnostic = true
                            } label: {
                                Image(systemName: copiedDiagnostic ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.88))
                            .help(displayLanguage == .japanese ? "診断コードをコピー（録音や認識した文章は含みません）" : "Copy the diagnostic code (no recording or transcript)")
                            .accessibilityLabel(displayLanguage == .japanese ? "診断コードをコピー" : "Copy diagnostic code")
                            .onChange(of: code) { copiedDiagnostic = false }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: 238)
                    .frame(minHeight: 38)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.42)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.20), lineWidth: 1))
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 14)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Circle().fill(.black.opacity(0.48)))
            .padding(8)
        }
        .onHover { isHovering in
            withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                isPetTouched = isHovering
            }
        }
    }

    private var expandedReader: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: voice.isSpeaking ? "speaker.wave.2.fill" : "text.alignleft")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Castor")
                        .font(.headline)
                    Spacer()
                    Text(L(responseStatusLabel))
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 34)
                .padding(.top, 24)

                SpokenResponseReader(
                    segments: voice.responseSegments,
                    segmentIndex: voice.currentResponseSegmentIndex,
                    progress: { voice.currentResponseSegmentProgress },
                    isSpeaking: voice.isSpeaking,
                    isExpanded: true,
                    onToggleExpanded: toggleReaderMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if voice.pendingApproval != nil {
                    approvalPanel(compact: false)
                }

                generationStatusPanel

                brainSelector
                expandedComposer
            }
            .frame(maxWidth: 920, maxHeight: .infinity)
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func approvalPanel(compact: Bool) -> some View {
        if let approval = voice.pendingApproval {
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                Label(L(approval.title), systemImage: "hand.raised.fill")
                    .font(.system(size: compact ? 11 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))

                if compact {
                    Text(approval.detail)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(3)
                } else {
                    ScrollView {
                        Text(approval.detail)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.64))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }

                HStack(spacing: 8) {
                    Button(L("Deny")) {
                        voice.resolvePendingApproval(approved: false)
                    }
                    .buttonStyle(.bordered)

                    if compact {
                        Button(L("Review details")) {
                            toggleReaderMode()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.92))
                        .foregroundStyle(.black.opacity(0.88))
                    } else {
                        Button(L("Allow once")) {
                            voice.resolvePendingApproval(approved: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.92))
                        .foregroundStyle(.black.opacity(0.88))
                    }
                }
                .controlSize(compact ? .mini : .regular)
            }
            .padding(compact ? 9 : 14)
            .frame(width: compact ? 238 : nil, alignment: .leading)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: compact ? 10 : 16, style: .continuous))
            .background(RoundedRectangle(cornerRadius: compact ? 10 : 16).fill(Color.orange.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 16).stroke(Color.orange.opacity(0.42), lineWidth: 1))
            .padding(.horizontal, compact ? 0 : 34)
        }
    }

    private var brainSelector: some View {
        HStack(spacing: 10) {
            Label(
                L(agentPreferences.routingPolicy == .automatic ? "Auto" : "Brain"),
                systemImage: agentPreferences.routingPolicy == .automatic ? "wand.and.stars" : "brain.head.profile"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.58))

            if agentPreferences.routingPolicy == .manual {
                Picker(L("Brain"), selection: $agentPreferences.selectedBrain) {
                    ForEach(CastorBrain.allCases.filter(\.isImplemented)) { brain in
                        Text(L(brain.label)).tag(brain)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            } else {
                Text(L("Castor will keep chat local and call \(agentPreferences.automaticExternalBrain.label) for actions."))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }

            Spacer()

            Text(L(voice.activeBrain.shortLabel))
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.white.opacity(0.54))
        }
        .padding(.horizontal, 34)
    }

    @ViewBuilder
    private var generationStatusPanel: some View {
        if voice.phase == .thinking {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.86))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L(voice.generationStatus.isEmpty ? "Generating a reply..." : voice.generationStatus))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.90))

                    if !voice.transcript.isEmpty {
                        Text(L("Sent: \(voice.transcript)"))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(L("Castor is composing a short answer."))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.42))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.14), lineWidth: 1))
            .padding(.horizontal, 34)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var expandedComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button(action: {
                NSApp.activate(ignoringOtherApps: true)
                voice.toggle()
            }) {
                Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .symbolEffect(.pulse, isActive: voice.isListening)
            }
            .buttonStyle(.plain)
            .foregroundStyle(voice.isListening ? Color.red.opacity(0.94) : Color.white.opacity(0.88))
            .background(Circle().fill(voice.isListening ? Color.red.opacity(0.18) : Color.white.opacity(0.08)))
            .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
            .disabled(voice.phase == .thinking)
            .help(voice.isListening ? L("Finish voice message") : L("Start voice message"))

            TextField(L("Message Castor"), text: $messageDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1...4)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, 2)
                .padding(.vertical, 8)
                .focused($isMessageFocused)
                .disabled(!voice.canAcceptTextInput)
                .onSubmit(submitMessageDraft)

            Button(action: composerButtonAction) {
                Image(systemName: composerButtonSymbol)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(composerButtonForeground)
            .background(Circle().fill(composerButtonBackground))
            .overlay(Circle().stroke(.white.opacity(canUseComposerButton ? 0 : 0.14), lineWidth: 1))
            .disabled(!canUseComposerButton)
            .help(voice.canStopResponseGeneration ? L("Stop response") : L("Send message"))
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
        .padding(.horizontal, 34)
        .padding(.bottom, 26)
        .onAppear {
            isMessageFocused = true
        }
    }

    private func toggleReaderMode() {
        isReaderExpanded.toggle()
        onReaderModeChange(isReaderExpanded)
    }

    private func submitMessageDraft() {
        let prompt = messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, voice.canAcceptTextInput else {
            return
        }

        voice.submitText(prompt)
    }

    private func composerButtonAction() {
        if voice.canStopResponseGeneration {
            voice.stopResponseGeneration()
        } else {
            submitMessageDraft()
        }
    }

    private func petParameters(at date: Date, touched: Bool) -> MotionParameters {
        let context = MotionContext(
            touched: touched,
            isSpeaking: voice.isSpeaking,
            isListening: voice.isListening,
            speechEnergy: voice.isSpeaking ? voice.speechPlaybackEnergy : nil,
            evasionCue: evasionPresentation.motionCue(at: date)
        )
        return connection.parameters(
            from: voice.core.snapshot,
            trilobite: trilobite?.snapshot ?? .inactive,
            context: context,
            at: date
        )
    }

    private var characterScale: CGFloat {
        let evasionScale: CGFloat = switch (evasionPresentation.style, evasionPresentation.phase) {
        case (.cute, .anticipating), (.cute, .evading): 1.045
        case (.calm, .anticipating): 0.985
        case (.robot, .anticipating), (.robot, .evading): 0.995
        default: 1.0
        }
        if voice.isListening {
            return (1.02 + CGFloat(voice.listeningLevel) * 0.06) * evasionScale
        }
        return (isPetTouched ? 1.045 : 1.0) * evasionScale
    }

    private var voiceIndicatorSymbol: String {
        switch voice.phase {
        case .idle:
            "mic.fill"
        case .listening:
            "waveform"
        case .thinking:
            "ellipsis"
        case .speaking:
            "speaker.wave.2.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var canSubmitMessage: Bool {
        !messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && voice.canAcceptTextInput
    }

    private var canUseComposerButton: Bool {
        voice.canStopResponseGeneration || canSubmitMessage
    }

    private var composerButtonSymbol: String {
        voice.canStopResponseGeneration ? "stop.fill" : "arrow.up"
    }

    private var composerButtonForeground: Color {
        if voice.canStopResponseGeneration {
            return .white.opacity(0.94)
        }
        return canSubmitMessage ? Color.black.opacity(0.88) : Color.white.opacity(0.28)
    }

    private var composerButtonBackground: Color {
        if voice.canStopResponseGeneration {
            return Color.red.opacity(0.72)
        }
        return canSubmitMessage ? Color.white.opacity(0.92) : Color.white.opacity(0.08)
    }

    /// Replies, recognized speech and provider errors are content, even when they match a UI label.
    private var localizedVoiceCaption: String {
        let caption = voice.caption
        if voice.phase == .failed {
            guard voice.errorIsAppMessage else { return caption }
            var message = caption
            if failureDiagnostic != nil, let open = caption.range(of: "\n[", options: .backwards) {
                message = String(caption[..<open.lowerBound])
            }
            return SpeechInputMessages.localized(message, language: displayLanguage)
        }
        if voice.phase == .speaking || caption.hasPrefix("“") { return caption }
        return L(caption)
    }

    /// The speech diagnostic code an app-owned failure ends with, shown as a copy button instead of
    /// text, because the 238pt caption cannot fit it.
    private var failureDiagnostic: String? {
        let caption = voice.caption
        guard voice.phase == .failed, voice.errorIsAppMessage, caption.hasSuffix("]"),
              let open = caption.range(of: "\n[", options: .backwards) else { return nil }
        let code = caption[open.upperBound..<caption.index(before: caption.endIndex)]
        return code.hasPrefix("SI") ? String(code) : nil
    }

    private var responseStatusLabel: String {
        let emotion = L(voice.responseEmotion.rawValue.uppercased())
        let intensity = Int((voice.responseEmotionIntensity * 100).rounded())
        let engine = L(voice.isUsingNeuralVoice ? "NEURAL" : "SYSTEM")
        let brain = L(voice.activeBrain.shortLabel)
        return voice.isSpeaking
            ? "\(brain) · \(engine) · \(emotion) \(intensity)%"
            : "\(brain) · \(emotion) \(intensity)%"
    }
}

/// Invisible helper that locates the hosting `NSWindow` once it is attached and reports whether
/// the window is at least partially visible (`occlusionState.contains(.visible)`), so
/// `PetFloatingView` can stop redrawing its motion timeline while fully hidden behind other
/// windows or on an inactive Space. Uses `NSWindow.didChangeOcclusionStateNotification` rather
/// than polling.
private struct WindowOcclusionObserver: NSViewRepresentable {
    let onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindowAvailable = { window in
            context.coordinator.observe(window: window, onVisibilityChange: onVisibilityChange)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var observer: NSObjectProtocol?

        func observe(window: NSWindow, onVisibilityChange: @escaping (Bool) -> Void) {
            guard observer == nil else {
                return
            }

            // `observe` is reached from `viewDidMoveToWindow`, which can run inside a SwiftUI
            // view update — defer the initial report so the `@State` write never happens
            // mid-update.
            DispatchQueue.main.async { [weak window] in
                guard let window else {
                    return
                }
                onVisibilityChange(window.occlusionState.contains(.visible))
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                guard let window else {
                    return
                }
                onVisibilityChange(window.occlusionState.contains(.visible))
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private final class TrackingView: NSView {
        var onWindowAvailable: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowAvailable?(window)
            }
        }
    }
}
