import CastorCore
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
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = CastorAppStrings.label("GIFを作ってXで共有", language: SettingsDisplayLanguage(rawValue: UserDefaults.standard.string(forKey: "Castor.SettingsDisplayLanguage") ?? "") ?? .systemDefault)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let contentSize = NSSize(width: 490, height: 650)
        // Keep SwiftUI's ScrollView measurements out of the window's size contract.
        // Controller sizingOptions alone did not prevent a title-bar-only window.
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        let hosting = NSHostingView(rootView: PetGIFShareView(asset: asset))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        window.contentMinSize = NSSize(width: 490, height: 600)
        window.setContentSize(contentSize)
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // A delayed notification from a replaced window must not clear the new one.
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        closingWindow.contentView = nil
        window = nil
    }
}

private struct PetGIFShareView: View {
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    private func L(_ source: String) -> String { CastorAppStrings.label(source, language: displayLanguage) }

    let asset: SavedPetCharacter
    @State private var motion: PetGIFOptions.Motion = .idle
    @State private var duration = 4
    @State private var background = Color.white
    @State private var result: PetGIFResult?
    @State private var savedURL: URL?
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var error: String?
    @State private var status: String?
    @State private var generationID: UUID?

    private var isWorking: Bool { task != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("うちの子をGIFに")).font(.title2.bold())
                Text(L("ペットだけを、選んだ動きで書き出します。"))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker(L("動き"), selection: $motion) {
                        ForEach(PetGIFOptions.Motion.allCases) { Text(L($0.rawValue)).tag($0) }
                    }
                    Picker(L("長さ"), selection: $duration) {
                        ForEach(3...5, id: \.self) { Text(L("\($0)秒")).tag($0) }
                    }.frame(width: 115)
                }.disabled(isWorking)
                ColorPicker(L("背景色"), selection: $background, supportsOpacity: false)
                    .disabled(isWorking)
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    if let result {
                        AnimatedGIFPreview(data: result.data).padding(12)
                    } else {
                        ContentUnavailableView(L("GIFプレビュー"), systemImage: "photo.on.rectangle.angled",
                            description: Text(L("「プレビューを作成」で動きを確認できます。")))
                    }
                    if isWorking {
                        VStack {
                            ProgressView(value: progress)
                            Text(L("GIFを作成中… \(Int(progress * 100))%"))
                                .font(.caption).monospacedDigit()
                        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(30)
                    }
                }.frame(height: 280)
                HStack {
                    if isWorking {
                        Button(L("キャンセル")) {
                            task?.cancel()
                            status = "GIFの作成を停止しました。"
                        }
                    } else {
                        Button(L(result == nil ? "プレビューを作成" : "プレビューを作り直す"), action: generate)
                    }
                    Spacer()
                    if let result {
                        Text(L("\(result.dimension) × \(result.dimension) · \(result.framesPerSecond)fps · ") +
                             ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(L(error)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let status { Text(L(status)).font(.callout).foregroundStyle(.secondary) }
                Label(L(PetGIFSharing.manualAttachmentNotice), systemImage: "paperclip")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                if let savedURL {
                    HStack {
                        Label(savedURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .font(.callout).lineLimit(1)
                        Spacer()
                        Button(L("GIFの場所を表示")) { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
                    }
                }
                HStack {
                    Spacer()
                    Button(L("GIFを保存してXを開く"), action: saveAndOpenX)
                        .buttonStyle(.borderedProminent)
                        .disabled(result == nil || isWorking)
                        .accessibilityHint(L(PetGIFSharing.manualAttachmentNotice))
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: motion) { invalidatePreview() }
        .onChange(of: duration) { invalidatePreview() }
        .onChange(of: background) { invalidatePreview() }
        .onDisappear { invalidatePreview() }
    }

    private func invalidatePreview() {
        task?.cancel()
        generationID = nil
        task = nil
        status = nil
        result = nil
        savedURL = nil
        error = nil
    }

    private func generate() {
        error = nil
        status = nil
        savedURL = nil
        progress = 0
        let id = UUID()
        generationID = id
        let options = PetGIFOptions(motion: motion, duration: duration, background: NSColor(background))
        task = Task { @MainActor in
            defer {
                if generationID == id {
                    task = nil
                    generationID = nil
                }
            }
            do {
                let generated = try await PetGIFExporter.make(asset: asset, options: options) {
                    if generationID == id { progress = $0 }
                }
                try Task.checkCancellation()
                guard generationID == id else { return }
                result = generated
            } catch is CancellationError {
                // A changed setting or closed window silently invalidates the old job.
                // Only the explicit Cancel button supplies a neutral status message.
            } catch {
                if generationID == id { self.error = error.localizedDescription }
            }
        }
    }

    private func saveAndOpenX() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "Castor-pet.gif"
        panel.canCreateDirectories = true
        panel.message = L(PetGIFSharing.manualAttachmentNotice)
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
