#if os(Windows)
import CastorCore
import ArilsPlayer
import CDesktopUI
import Foundation
import PetRuntime
import WinSDK

class WindowsWorkCompletion {
    let lock = NSLock()
    var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func nativePoll() -> Int32 { isFinished ? 1 : 0 }
}
private final class WindowsWorkState<T>: WindowsWorkCompletion, @unchecked Sendable {
    private var result: Result<T, Error>?
    func complete(_ result: Result<T, Error>) { lock.lock(); defer { lock.unlock() }; self.result = result; finished = true }
    func value() -> Result<T, Error> { lock.lock(); defer { lock.unlock() }; return result! }
}

/// The native shell; model/mesh/PNG work stays in PetRuntime.
enum WindowsRiggingFlow {
    enum FlowError: LocalizedError {
        case dialogFailed, missingApplicationData
        var errorDescription: String? {
            switch self {
            case .dialogFailed: return "ファイル選択または補正画面を開けませんでした。Castorを再起動してお試しください。"
            case .missingApplicationData: return "ユーザー用の保存先を利用できませんでした。Windowsのアカウント設定を確認してください。"
            }
        }
    }

    static var directory: URL {
        get throws {
            guard let root = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !root.isEmpty else {
                throw FlowError.missingApplicationData
            }
            return URL(fileURLWithPath: root).appendingPathComponent("Castor", isDirectory: true)
        }
    }

    static func defaultPet() throws -> URL? {
        let root = try directory
        if let selected = try PortablePetLibrary(root: root).selectedFile() { return selected }
        let saved = root.appendingPathComponent("CastorPet.json")
        if FileManager.default.fileExists(atPath: saved.path) { return saved }
        let legacy = PetSource.defaultFileURL(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    static func remember(_ url: URL) throws {
        try PortablePetLibrary(root: directory).remember(url)
    }

    static func choose(kind: String, save: Bool = false) throws -> URL? {
        var path = [CChar](repeating: 0, count: 131072)
        let result = kind.withCString { kind in
            path.withUnsafeMutableBufferPointer { castor_choose_file(save ? 1 : 0, kind, $0.baseAddress, $0.count) }
        }
        if result < 0 { throw FlowError.dialogFailed }
        if result == 0 { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func openSetup() throws {
        var buffer=[WCHAR](repeating:0,count:32768)
        let length=buffer.withUnsafeMutableBufferPointer {GetModuleFileNameW(nil,$0.baseAddress,DWORD($0.count))}
        guard length>0,Int(length)<buffer.count else {throw FlowError.dialogFailed}
        let folder=URL(fileURLWithPath:String(decoding:buffer.prefix(Int(length)),as:UTF16.self)).deletingLastPathComponent()
        let setup=folder.appendingPathComponent("CastorSetup.exe")
        if FileManager.default.fileExists(atPath:setup.path) {
            guard setup.path.withCString({castor_launch_file($0)})>0 else {throw FlowError.dialogFailed}
        } else {
            guard "https://github.com/Methurcoder/Castor/releases/latest".withCString({castor_open_url($0)})>0 else {throw FlowError.dialogFailed}
        }
    }
    static func text(title: String, value: String = "", readOnly: Bool = false) throws -> String? {
        var output = [CChar](repeating: 0, count: 131072)
        let status = title.withCString { title in value.withCString { value in output.withUnsafeMutableBufferPointer {
            castor_edit_text(title, value, readOnly ? 1 : 0, $0.baseAddress, $0.count)
        }}}
        if status < 0 { throw FlowError.dialogFailed }
        return status == 0 ? nil : String(cString: output)
    }

    static func option(title: String, items: [String]) throws -> Int? {
        let result = title.withCString { title in items.joined(separator: "\n").withCString {
            castor_choose_option(title, $0)
        }}
        if result < 0 { throw FlowError.dialogFailed }
        return result == 0 ? nil : Int(result - 1)
    }

    /// Native progress UI keeps the main thread responsive. Cancellation never saves.
    static func work<T>(text: String, operation: @escaping @Sendable () async throws -> T) throws -> T? {
        let state = WindowsWorkState<T>()
        let task = Task.detached(priority: .userInitiated) {
            do { state.complete(.success(try await operation())) }
            catch { state.complete(.failure(error)) }
        }
        let opaque = Unmanaged.passUnretained(state).toOpaque()
        let status = text.withCString { castor_wait_work($0, { context in
            guard let context else { return 1 }
            return Unmanaged<WindowsWorkCompletion>.fromOpaque(context).takeUnretainedValue().nativePoll()
        }, opaque) }
        if status <= 0 {
            task.cancel()
            if status < 0 { throw FlowError.dialogFailed }
            return nil
        }
        return try state.value().get()
    }

    static func prepareImage(_ url: URL) throws -> PreparedPortableRig? {
        let source = try PortableRigImage(png: Data(contentsOf: url))
        do {
            return try work(text: "画像を解析しています。顔の推定結果は後で確認できます。") {
                try await LayeredRigging.prepare(source)
            }
        } catch LayeredRigging.RigError.selectSubject(let candidates) {
            let items = candidates.map { candidate in
                let r = candidate.normalizedBounds
                return "キャラクター \(candidate.id + 1) — X \(Int(r.minX * 100))%、Y \(Int(r.minY * 100))%、幅 \(Int(r.width * 100))%、高さ \(Int(r.height * 100))%"
            }
            guard let index = try option(title: "Castor - 作成する被写体を選択", items: items) else { return nil }
            let selected = candidates[index].id
            return try work(text: "選択したキャラクターを解析しています。") {
                try await LayeredRigging.prepare(source, selecting: selected)
            }
        }
    }

    static func review(_ prepared: PreparedPortableRig) throws -> PortableFaceLayout? {
        let image = prepared.preview
        var layout = LayeredRigging.markers(prepared.face.layout)
        let preferences=(try? DesktopPreferenceStore(root:directory).load()) ?? DesktopPreferences()
        do {
            if let suggestion=try WindowsAIAlignmentFlow.suggest(prepared,preferences:preferences) {
                _ = try text(title:preferences.displayLanguage == .japanese ? "AIの候補です。次の画像上で確認・補正してください。":"AI suggestion. Review and adjust it on the next image.",value:suggestion.explanation,readOnly:true)
                layout=LayeredRigging.markers(suggestion.layout)
            }
        } catch {
            _ = try text(title:preferences.displayLanguage == .japanese ? "AI候補を取得できませんでした。手動で補正できます。":"AI suggestion unavailable. You can adjust manually.",value:error.localizedDescription,readOnly:true)
        }
        var rectangles = layout.rectangles.flatMap { [Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)] }
        let status = image.rgba.withUnsafeBufferPointer { pixels in rectangles.withUnsafeMutableBufferPointer {
            castor_review_markers(pixels.baseAddress, Int32(image.width), Int32(image.height), $0.baseAddress)
        }}
        if status < 0 { throw FlowError.dialogFailed }
        guard status != 0 else { return nil }
        func rect(_ i: Int) -> CGRect {
            let n = i * 4
            return CGRect(x: CGFloat(rectangles[n]), y: CGFloat(rectangles[n + 1]),
                          width: CGFloat(rectangles[n + 2]), height: CGFloat(rectangles[n + 3]))
        }
        return PortableFaceLayout(head: rect(0), eyeLeft: rect(1), eyeRight: rect(2), mouth: rect(3))
    }

    static func startNewPet(quality: Bool? = nil) throws -> PetAsset? {
        let isQuality: Bool
        if let quality { isQuality = quality }
        else {
            guard let mode = try option(title: "Castor - 画像から作成", items: ["1枚から作成", "正面と横向きの2枚からQualityを作成"]) else { return nil }
            isQuality = mode == 1
        }
        guard let frontFile = try choose(kind: "image"), let front = try prepareImage(frontFile),
              let frontMarkers = try review(front) else { return nil }
        let asset: PetAsset
        if isQuality {
            guard let direction = try option(title: "横画像の顔が向いている方向（見る側基準）", items: ["右向き", "左向き"]),
                  let sideFile = try choose(kind: "image"), let side = try prepareImage(sideFile),
                  let sideMarkers = try review(side),
                  let archive = try work(text: "Qualityのレイヤー・隠面補修・深度と安全な可動範囲を作成しています。", operation: {
                      try await LayeredRigging.buildQuality(front: front, side: side,
                          frontMarkers: frontMarkers, sideMarkers: sideMarkers,
                          direction: direction == 0 ? .right : .left, sideFileName: sideFile.lastPathComponent)
                  }) else { return nil }
            if !archive.assessment.warnings.isEmpty {
                let message = archive.assessment.warnings.map(\.message).joined(separator: "\n\n") + "\n\nこの結果を保存しますか？"
                let body = Array(message.utf16) + [WCHAR(0)], title = Array("Castor - Quality確認".utf16) + [WCHAR(0)]
                let answer = body.withUnsafeBufferPointer { b in title.withUnsafeBufferPointer {
                    MessageBoxW(nil, b.baseAddress, $0.baseAddress, 0x01)
                }}
                guard answer == 1 else { return nil }
            }
            asset = .quality(archive)
        } else {
            guard let archive = try work(text: "頭・体・目・口のレイヤーと可動範囲を作成しています。", operation: {
                try LayeredRigging.build(front, markers: frontMarkers)
            }) else { return nil }
            asset = .standard(archive)
        }
        let data = try LayeredRigging.savedPetData(source: front.source, asset: asset)
        try PortablePetLibrary(root: directory).saveNew(data)
        return asset
    }

    static func shareGIF(asset: PetAsset) throws {
        guard let motion = try option(title: "Castor - GIFの動き", items: ["呼吸・瞬き", "きょろきょろ"]),
              let duration = try option(title: "Castor - GIFの長さ", items: ["3秒", "4秒", "5秒"]),
              let background = try option(title: "Castor - GIFの背景", items: ["白", "グレー", "淡い青"]) else { return }
        var options = PetGIFClipOptions()
        options.motion = motion == 0 ? .idle : .lookAround; options.duration = duration + 3
        options.background = [[255,255,255], [128,128,128], [220,235,255]][background]
        let configuration = options
        guard let result = try work(text: "ペットだけからGIFを生成しています。画面・カメラ・会話は取得しません。", operation: {
            try await PetGIFClip.make(asset: asset, options: configuration)
        }) else { return }
        let frames = result.frames.flatMap { $0.bgra }
        let choice = frames.withUnsafeBufferPointer {
            castor_preview_gif($0.baseAddress, Int32(result.frames.count), Int32(result.dimension), Int32(result.dimension), Int32(result.fps))
        }
        if choice < 0 { throw FlowError.dialogFailed }
        guard choice != 0, let file = try choose(kind: "gif", save: true) else { return }
        try result.data.write(to: file, options: .atomic)
        if choice == 2 {
            let body = Array("GIFは自動添付されません。保存したGIFを、Xの投稿画面で手動で添付してください。".utf16) + [WCHAR(0)]
            let title = Array("Castor - GIFを保存しました".utf16) + [WCHAR(0)]
            _ = body.withUnsafeBufferPointer { b in title.withUnsafeBufferPointer { MessageBoxW(nil, b.baseAddress, $0.baseAddress, 0) }}
            let status = PetGIFClip.sharingURL().absoluteString.withCString { castor_open_url($0) }
            if status < 0 { throw FlowError.dialogFailed }
        }
    }

    static func startup() throws -> (PetAsset, URL?)? {
        let title = Array("Castor".utf16) + [WCHAR(0)]
        let text = Array("新しく画像からペットを作りますか？\n\n「はい」: PNG画像から作成\n「いいえ」: 保存したペットを開く\n「キャンセル」: 終了\n\n作成機能はMacと共通のレイヤー処理を使用します。全機能共通化は開発中です。".utf16) + [WCHAR(0)]
        let choice = text.withUnsafeBufferPointer { body in title.withUnsafeBufferPointer {
            MessageBoxW(nil, body.baseAddress, $0.baseAddress, 0x03)
        }}
        if choice == 6 {
            guard let asset = try startNewPet() else { return nil }
            return (asset, nil)
        }
        if choice == 7 {
            guard let file = try choose(kind: "pet") else { return nil }
            let archive = try PetSource.loadAsset(contentsOf: file)
            try remember(file)
            return (archive, file)
        }
        return nil
    }
}
#endif
