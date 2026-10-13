import AppKit
import QuartzCore
import ScreenshotAnswerCore
import SwiftUI

@MainActor
final class AnswerOverlayWindowController {
    private let popupSize = CGSize(width: 430, height: 210)
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(
        answer: String,
        recognizedText: String,
        language: InterfaceLanguage,
        dismissAfter: TimeInterval = 20,
        onExplain: (() -> Void)? = nil,
        onCopy: @escaping () -> Void
    ) {
        dismissTask?.cancel()

        let targetScreen = OverlayWindowSupport.targetScreen()
        guard let targetScreen else { return }

        let panel = panel ?? OverlayWindowSupport.makePanel(
            contentSize: popupSize,
            transient: true
        )
        self.panel = panel

        panel.contentView = NSHostingView(
            rootView: AnswerOverlayCard(
                answer: answer,
                recognizedText: recognizedText,
                language: language,
                onExplain: onExplain,
                onCopy: onCopy,
                onClose: { [weak self] in self?.dismiss() }
            )
        )

        let finalFrame = AnswerOverlayPlacement.frame(
            in: targetScreen.visibleFrame,
            popupSize: popupSize
        )
        var initialFrame = finalFrame
        initialFrame.origin.y -= 14
        panel.setFrame(initialFrame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, dismissAfter) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func showFailure(_ message: String, language: InterfaceLanguage) {
        show(
            answer: message,
            recognizedText: language.text(
                "回答を生成できませんでした",
                "The answer could not be generated"
            ),
            language: language,
            dismissAfter: 20,
            onCopy: {}
        )
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel, panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    func dismissImmediately() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

}

private struct AnswerOverlayCard: View {
    let answer: String
    let recognizedText: String
    let language: InterfaceLanguage
    let onExplain: (() -> Void)?
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("Screenshot Answer")
                    .font(.headline)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(language.text("回答をコピー", "Copy answer"))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(language.text("閉じる", "Close"))
            }

            Text(recognizedText.replacingOccurrences(of: "\n", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            ScrollView {
                Text(answer)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onExplain {
                Button(language.text("これは何？ 内容を説明", "What Is This? Explain"), systemImage: "questionmark.bubble") {
                    onClose()
                    onExplain()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 430, height: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}
