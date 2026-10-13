import AppKit
import ScreenshotAnswerCore
import SwiftUI

@main
struct ScreenshotAnswerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ScreenshotAnswerPanel(model: model)
                .environment(\.locale, model.interfaceLanguage.locale)
        } label: {
            CastorMenuBarIcon(isRecording: model.isListeningToSystemAudio)
                .accessibilityLabel("Screenshot Answer")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct ScreenshotAnswerPanel: View {
    @ObservedObject var model: AppModel
    @State private var isRecognizedTextExpanded = false
    @State private var isAnswerExpanded = false
    @State private var isGenerationDetailsExpanded = false
    @State private var isShowingSettings = false

    private var language: InterfaceLanguage { model.interfaceLanguage }

    var body: some View {
        Group {
            if !model.hasChosenInterfaceLanguage {
                FirstLaunchLanguageView { model.chooseInterfaceLanguage($0) }
            } else if isShowingSettings {
                LanguageSettingsView(model: model) { isShowingSettings = false }
            } else {
                mainPanel
            }
        }
        .frame(width: 430, height: 650)
        .onChange(of: model.recognizedText) { _, _ in isRecognizedTextExpanded = false }
        .onChange(of: model.answer) { _, _ in isAnswerExpanded = false }
    }

    private var mainPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).lineLimit(2)
                    Spacer()
                }

                HStack {
                    Button(language.text("範囲を撮影して回答", "Capture Area and Answer"), systemImage: "viewfinder") {
                        model.captureSelection()
                    }
                    .keyboardShortcut("4", modifiers: [.control, .option, .command])
                    .disabled(model.isBusy)

                    Button(language.text("再確認", "Check Now"), systemImage: "arrow.clockwise") {
                        model.scanNow()
                    }
                    .help(language.text("保存先を今すぐ再確認", "Check the screenshot folder now"))
                }

                GroupBox(language.text("LM Studioモデル", "LM Studio Model")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("", selection: $model.selectedModel) {
                                if model.availableModels.isEmpty {
                                    Text(language.text("モデルなし", "No models")).tag("")
                                }
                                ForEach(model.availableModels, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)

                            Button(language.text("更新", "Refresh")) {
                                Task { await model.refreshModels() }
                            }
                        }

                        DisclosureGroup(
                            language.text("高速化の詳細", "Acceleration Details"),
                            isExpanded: $isGenerationDetailsExpanded
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker(language.text("方式", "Mode"), selection: $model.speculativeDecodingMode) {
                                    ForEach(SpeculativeDecodingMode.allCases) { mode in
                                        Text(mode.label(for: language)).tag(mode)
                                    }
                                }

                                if model.speculativeDecodingMode == .draftModel {
                                    Picker("Draft Model", selection: $model.selectedDraftModel) {
                                        if model.availableDraftModels.isEmpty {
                                            Text(language.text("互換モデルなし", "No compatible models")).tag("")
                                        }
                                        ForEach(model.availableDraftModels, id: \.self) { Text($0).tag($0) }
                                    }
                                    .disabled(model.availableDraftModels.isEmpty)

                                    Text(language.text(
                                        "メインモデルと語彙が互換する、小さいモデルを選んでください。",
                                        "Choose a smaller model with a vocabulary compatible with the main model."
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }

                                Text(language.text(
                                    "MTP / DSparkはモデル読込時の機能です。ここではLM Studio側で読み込んだ設定をそのまま使用します。",
                                    "MTP and DSpark are enabled when a model is loaded. This app uses the settings already loaded by LM Studio."
                                ))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.top, 5)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                Toggle(language.text("標準スクリーンショットを自動検出", "Automatically Detect Screenshots"), isOn: $model.monitorsScreenshots)
                Toggle(language.text("回答を画面左下に表示", "Show Answers at Bottom Left"), isOn: $model.showsAnswerPopup)
                Toggle(language.text("生成した回答を自動コピー", "Automatically Copy Answers"), isOn: $model.copiesAnswer)

                GroupBox(language.text("今流れている音声", "Currently Playing Audio")) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Picker(language.text("言語", "Language"), selection: $model.systemAudioLanguage) {
                                ForEach(SystemAudioLanguage.allCases) { audioLanguage in
                                    Text(audioLanguage.label(for: language)).tag(audioLanguage)
                                }
                            }
                            .frame(width: 170)
                            Spacer()
                            if model.isListeningToSystemAudio {
                                Label(model.systemAudioElapsedText, systemImage: "record.circle.fill")
                                    .foregroundStyle(.red)
                                    .monospacedDigit()
                            }
                        }

                        TextField(
                            language.text("例: 話者は何を主張していますか？", "Example: What is the speaker claiming?"),
                            text: $model.audioQuestion
                        )
                        .textFieldStyle(.roundedBorder)

                        Toggle(
                            language.text("複数話者を対話として整理（推定）", "Organize Multiple Speakers as Dialogue (Estimated)"),
                            isOn: $model.organizesMultipleSpeakers
                        )

                        HStack {
                            if model.isListeningToSystemAudio {
                                Button(language.text("停止して回答", "Stop and Answer"), systemImage: "stop.circle.fill") {
                                    model.stopSystemAudioAndAnswer()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            } else {
                                Button(language.text("音声を聞く", "Listen to Audio"), systemImage: "ear") {
                                    model.startSystemAudioListening()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isBusy || !model.supportsSystemAudioListening)
                            }

                            if !model.audioTranscript.isEmpty && !model.isListeningToSystemAudio {
                                Button(language.text("この音声に質問", "Ask About This Audio"), systemImage: "bubble.left.and.text.bubble.right") {
                                    model.answerAboutCapturedAudio()
                                }
                                .disabled(model.isBusy)
                            }
                        }

                        if !model.supportsSystemAudioListening {
                            Text(language.text("macOS 26以降で利用できます。", "Available on macOS 26 or later."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !model.audioTranscript.isEmpty {
                            ScrollView {
                                Text(model.audioTranscript)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 80)
                        } else {
                            Text(language.text(
                                "最大90秒。音声は保存せず、文字起こし後に破棄します。",
                                "Up to 90 seconds. Audio is not saved and is discarded after transcription."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(5)
                }

                if !model.recognizedText.isEmpty {
                    CollapsibleSection(
                        title: language.text("認識した問題", "Recognized Problem"),
                        language: language,
                        isExpanded: $isRecognizedTextExpanded
                    ) {
                        GroupBox {
                            ScrollView {
                                Text(model.recognizedText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 110)
                            .padding(6)
                        }
                    }
                }

                if !model.answer.isEmpty {
                    CollapsibleSection(
                        title: language.text("回答", "Answer"),
                        language: language,
                        isExpanded: $isAnswerExpanded
                    ) {
                        GroupBox {
                            ScrollView {
                                Text(model.answer)
                                    .font(.body.weight(.medium))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 150)
                            .padding(6)
                        }
                    }

                    HStack {
                        if model.canDescribeRecognizedContent {
                            Button(language.text("これは何？ 内容を説明", "What Is This? Explain"), systemImage: "questionmark.bubble") {
                                model.describeRecognizedContent()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button(language.text("回答をコピー", "Copy Answer"), systemImage: "doc.on.doc") {
                            model.copyAnswer()
                        }
                    }
                }

                Divider()
                HStack {
                    Button(language.text("保存先を開く", "Open Screenshot Folder")) {
                        model.openScreenshotDirectory()
                    }
                    Spacer()
                    Button { isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .help(language.text("設定", "Settings"))
                    .accessibilityLabel(language.text("設定", "Settings"))
                    Button(language.text("終了", "Quit")) {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct FirstLaunchLanguageView: View {
    let onSelect: (InterfaceLanguage) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
            VStack(spacing: 7) {
                Text("表示言語 / Display Language").font(.title2.bold())
                Text("後から設定で変更できます。\nYou can change this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button("日本語") { onSelect(.japanese) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(width: 190)
                Button("English") { onSelect(.english) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(width: 190)
            }
            Spacer()
        }
        .padding(32)
    }
}

private struct LanguageSettingsView: View {
    @ObservedObject var model: AppModel
    let onDone: () -> Void

    private var language: InterfaceLanguage { model.interfaceLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(language.text("設定", "Settings")).font(.title2.bold())
                Spacer()
                Button(language.text("完了", "Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }

            GroupBox(language.text("表示言語", "Display Language")) {
                Picker("", selection: Binding(
                    get: { model.interfaceLanguage },
                    set: { model.chooseInterfaceLanguage($0) }
                )) {
                    ForEach(InterfaceLanguage.allCases) { option in
                        Text(option.nativeName).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(6)
            }

            GroupBox(language.text("範囲撮影の保存", "Area Capture Storage")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $model.captureStorageMode) {
                        ForEach(CaptureStorageMode.allCases) { mode in
                            Text(mode.label(for: language)).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if model.captureStorageMode == .customFolder {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(model.customCaptureDirectoryDisplayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(language.text("選択…", "Choose…")) {
                                model.chooseCustomCaptureDirectory()
                            }
                        }
                    }

                    Text(language.text(
                        "「保存しない」では一時ファイルで解析し、処理後すぐに削除します。標準の⌘⇧4の保存先はmacOS側の設定のままです。",
                        "Do Not Save uses a temporary file and deletes it immediately after processing. The destination for standard ⌘⇧4 screenshots remains controlled by macOS."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            Text(language.text(
                "この設定はアプリの操作UIだけに適用されます。OCRの日英認識や、音声文字起こしの言語設定は変わりません。",
                "This changes only the app interface. It does not change Japanese/English OCR or the transcription language."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}

private struct CollapsibleSection<Content: View>: View {
    let title: String
    let language: InterfaceLanguage
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary.opacity(isHovering ? 0.62 : 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityValue(language.text(isExpanded ? "展開中" : "折りたたみ中", isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(language.text(
                isExpanded ? "クリックして折りたたみます" : "クリックして展開します",
                isExpanded ? "Click to collapse" : "Click to expand"
            ))

            if isExpanded {
                content.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
