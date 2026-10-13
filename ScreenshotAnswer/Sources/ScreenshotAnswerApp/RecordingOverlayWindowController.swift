import AppKit
import QuartzCore
import ScreenshotAnswerCore
import SwiftUI

@MainActor
final class RecordingOverlayWindowController {
    private let compactSize = CGSize(width: 360, height: 112)
    private let expandedSize = CGSize(width: 420, height: 288)
    private var panel: NSPanel?
    private var state: RecordingOverlayState?

    func show(
        elapsedText: String,
        language: String,
        interfaceLanguage: InterfaceLanguage,
        question: String,
        transcript: String,
        organizesMultipleSpeakers: Bool,
        onStop: @escaping () -> Void
    ) {
        let state = RecordingOverlayState(
            elapsedText: elapsedText,
            language: language,
            question: question,
            transcript: transcript,
            organizesMultipleSpeakers: organizesMultipleSpeakers
        )
        self.state = state

        let targetScreen = OverlayWindowSupport.targetScreen()
        guard let targetScreen else { return }
        let panel = panel ?? OverlayWindowSupport.makePanel(contentSize: compactSize)
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: RecordingOverlayCard(
                state: state,
                language: interfaceLanguage,
                onStop: onStop,
                onExpansionChanged: { [weak self] expanded in
                    self?.resize(expanded: expanded)
                }
            )
        )
        panel.setFrame(
            RecordingOverlayPlacement.frame(
                in: targetScreen.visibleFrame,
                popupSize: compactSize
            ),
            display: true
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func update(elapsedText: String? = nil, transcript: String? = nil) {
        if let elapsedText { state?.elapsedText = elapsedText }
        if let transcript { state?.transcript = transcript }
    }

    func dismiss() {
        guard let panel, panel.isVisible else {
            state = nil
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                panel?.orderOut(nil)
                self?.state = nil
            }
        }
    }

    private func resize(expanded: Bool) {
        guard let panel else { return }
        let newSize = expanded ? expandedSize : compactSize
        let oldFrame = panel.frame
        let newFrame = CGRect(
            x: oldFrame.maxX - newSize.width,
            y: oldFrame.maxY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

}

@MainActor
private final class RecordingOverlayState: ObservableObject {
    @Published var elapsedText: String
    @Published var transcript: String
    let language: String
    let question: String
    let organizesMultipleSpeakers: Bool

    init(
        elapsedText: String,
        language: String,
        question: String,
        transcript: String,
        organizesMultipleSpeakers: Bool
    ) {
        self.elapsedText = elapsedText
        self.language = language
        self.question = question
        self.transcript = transcript
        self.organizesMultipleSpeakers = organizesMultipleSpeakers
    }
}

private struct RecordingOverlayCard: View {
    @ObservedObject var state: RecordingOverlayState
    let language: InterfaceLanguage
    let onStop: () -> Void
    let onExpansionChanged: (Bool) -> Void
    @State private var isExpanded = false
    @State private var isDetailsHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(language.text("録音中", "Recording"), systemImage: "record.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(state.elapsedText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.red)
                Spacer(minLength: 8)
                Button(language.text("停止して回答", "Stop and Answer"), systemImage: "stop.circle.fill", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                    onExpansionChanged(isExpanded)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(language.text("詳細", "Details"))
                    Spacer()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary.opacity(isDetailsHovering ? 0.62 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isDetailsHovering = $0 }

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(language.text("言語: \(state.language)", "Language: \(state.language)"))
                        Spacer()
                        Text(state.organizesMultipleSpeakers
                            ? language.text("対話整理: オン（推定）", "Dialogue: On (Estimated)")
                            : language.text("対話整理: オフ", "Dialogue: Off"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !state.question.isEmpty {
                        Text(language.text("質問: \(state.question)", "Question: \(state.question)"))
                            .font(.caption)
                            .lineLimit(2)
                    }

                    ScrollView {
                        Text(
                            state.transcript.isEmpty
                                ? language.text("文字起こしを待っています…", "Waiting for transcription…")
                                : state.transcript
                        )
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 105)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}
