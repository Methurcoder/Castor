import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A separate ordinary window so the small, nonactivating floating panel stays usable.
@MainActor
final class PetGIFShareWindow: NSObject, NSWindowDelegate {
    static let shared = PetGIFShareWindow()
    private var window: NSWindow?

    func show(asset: SavedPetCharacter) {
        // Replacing the previous hosting view cancels its in-progress export.
        window?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "GIFを作って投稿する"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: PetGIFShareView(asset: asset))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

private struct PetGIFShareView: View {
    let asset: SavedPetCharacter
    @State private var motion: PetGIFOptions.Motion = .idle
    @State private var duration = 4
    @State private var background = Color.white
    @State private var result: PetGIFResult?
    @State private var savedURL: URL?
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var error: String?

    private var isWorking: Bool { task != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("うちの子をGIFに").font(.title2.bold())
                Text("ペットだけを、選んだ動きで書き出します。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("動き", selection: $motion) {
                        ForEach(PetGIFOptions.Motion.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("長さ", selection: $duration) {
                        ForEach(3...5, id: \.self) { Text("\($0)秒").tag($0) }
                    }.frame(width: 115)
                }.disabled(isWorking)
                ColorPicker("背景色", selection: $background, supportsOpacity: false)
                    .disabled(isWorking)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    if let result {
                        AnimatedGIFPreview(data: result.data).padding(12)
                    } else {
                        ContentUnavailableView("GIFプレビュー", systemImage: "photo.on.rectangle.angled",
                            description: Text("「プレビューを作成」で動きを確認できます。"))
                    }
                    if isWorking {
                        VStack {
                            ProgressView(value: progress)
                            Text("GIFを作成中… \(Int(progress * 100))%")
                                .font(.caption).monospacedDigit()
                        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(30)
                    }
                }.frame(height: 280)
                HStack {
                    if isWorking {
                        Button("キャンセル") { task?.cancel() }
                    } else {
                        Button(result == nil ? "プレビューを作成" : "プレビューを作り直す", action: generate)
                    }
                    Spacer()
                    if let result {
                        Text("\(result.dimension) × \(result.dimension) · \(result.framesPerSecond)fps · " +
                             ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                Label(PetGIFSharing.manualAttachmentNotice, systemImage: "paperclip")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                if let savedURL {
                    HStack {
                        Label(savedURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .font(.callout).lineLimit(1)
                        Spacer()
                        Button("GIFの場所を表示") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                    }
                }
                HStack {
                    Spacer()
                    Button("GIFを保存してXを開く", action: saveAndOpenX)
                        .buttonStyle(.borderedProminent)
                        .disabled(result == nil || isWorking)
                        .accessibilityHint(PetGIFSharing.manualAttachmentNotice)
                }
            }
            .padding(22)
        }
        .frame(width: 490)
        .onChange(of: motion) { invalidatePreview() }
        .onChange(of: duration) { invalidatePreview() }
        .onChange(of: background) { invalidatePreview() }
        .onDisappear { task?.cancel() }
    }

    private func invalidatePreview() {
        task?.cancel()
        result = nil
        savedURL = nil
        error = nil
    }

    private func generate() {
        error = nil
        savedURL = nil
        progress = 0
        let options = PetGIFOptions(motion: motion, duration: duration, background: NSColor(background))
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let generated = try await PetGIFExporter.make(asset: asset, options: options) { progress = $0 }
                try Task.checkCancellation()
                result = generated
            } catch is CancellationError {
                error = "GIFの作成をキャンセルしました。"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func saveAndOpenX() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "Castor-pet.gif"
        panel.canCreateDirectories = true
        panel.message = PetGIFSharing.manualAttachmentNotice
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try result.data.write(to: url, options: .atomic)
            savedURL = url
            error = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
            guard let postURL = PetGIFSharing.postURL, NSWorkspace.shared.open(postURL) else {
                error = "GIFは保存できました。Xを開けなかったため、ブラウザから投稿画面を開いて添付してください。"
                return
            }
        } catch {
            self.error = "GIFを保存できませんでした: \(error.localizedDescription)"
        }
    }
}

private struct AnimatedGIFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        if context.coordinator.data != data {
            view.image = NSImage(data: data)
            context.coordinator.data = data
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var data: Data? }
}
