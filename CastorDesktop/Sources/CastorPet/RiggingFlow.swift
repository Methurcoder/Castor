#if os(Windows)
import ArilsPlayer
import CDesktopUI
import Foundation
import PetRuntime
import WinSDK

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

    static func startNewPet() throws -> AvatarArchive? {
        guard let input = try choose(kind: "image") else { return nil }
        let source = try PortableRigImage(png: Data(contentsOf: input))
        let draft = try PortableRigBuilder.prepare(source)
        var rectangles = draft.layout.rectangles.flatMap { [Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)] }
        let status = draft.image.rgba.withUnsafeBufferPointer { pixels in
            rectangles.withUnsafeMutableBufferPointer {
                castor_review_markers(pixels.baseAddress, Int32(draft.image.width), Int32(draft.image.height), $0.baseAddress)
            }
        }
        if status < 0 { throw FlowError.dialogFailed }
        guard status != 0 else { return nil }
        func rect(_ i: Int) -> CGRect {
            let n = i * 4
            return CGRect(x: CGFloat(rectangles[n]), y: CGFloat(rectangles[n + 1]),
                          width: CGFloat(rectangles[n + 2]), height: CGFloat(rectangles[n + 3]))
        }
        let layout = PortableFaceLayout(head: rect(0), eyeLeft: rect(1), eyeRight: rect(2), mouth: rect(3))
        let archive = try PortableRigBuilder.build(image: draft.image, layout: layout)
        let data = try PortableRigBuilder.savedPetData(image: source, archive: archive)
        try PortablePetLibrary(root: directory).saveNew(data)
        return archive
    }

    static func startup() throws -> (AvatarArchive, URL?)? {
        let title = Array("Castor".utf16) + [WCHAR(0)]
        let text = Array("新しく画像からペットを作りますか？\n\n「はい」: PNG画像から作成\n「いいえ」: 保存したペットを開く\n「キャンセル」: 終了\n\nWindowsの作成機能は2D試作です。Macとの全機能共通化は開発中です。".utf16) + [WCHAR(0)]
        let choice = text.withUnsafeBufferPointer { body in title.withUnsafeBufferPointer {
            MessageBoxW(nil, body.baseAddress, $0.baseAddress, 0x03)
        }}
        if choice == 6 {
            guard let archive = try startNewPet() else { return nil }
            return (archive, nil)
        }
        if choice == 7 {
            guard let file = try choose(kind: "pet") else { return nil }
            let archive = try PetSource.load(contentsOf: file)
            try remember(file)
            return (archive, file)
        }
        return nil
    }
}
#endif
