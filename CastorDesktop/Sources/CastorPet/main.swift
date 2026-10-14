// Castor desktop pet for Windows (preview).
//
//     CastorPet.exe [CastorPet.json | avatar.arils] [--wide-head]
//
// Plays saved pets and offers an initial local PNG-to-pet creation flow:
// it breathes, blinks and looks at the pointer; moving the pointer over its
// head pets it. Drag to move it; right-click for the menu; hold Alt over it
// to see through it and click what it covers.

#if os(Windows)
import Foundation
import CastorCore
import Dispatch
import ArilsPlayer
import PetRuntime
import WinSDK

// Win32 constants, spelled out: several are imported with types that differ
// between SDK versions, and these values never change.
private let wsPopup: DWORD = 0x8000_0000
private let wsExLayered: DWORD = 0x0008_0000
private let wsExTopmost: DWORD = 0x0000_0008
private let wsExToolWindow: DWORD = 0x0000_0080
private let wsExTransparent: DWORD = 0x0000_0020
private let wmDestroy: UINT = 0x0002
private let wmCommand: UINT = 0x0111
private let wmTimer: UINT = 0x0113
private let wmLButtonDown: UINT = 0x0201
private let wmRButtonUp: UINT = 0x0205
private let wmNCLButtonDown: UINT = 0x00A1
private let htCaption: WPARAM = 2
private let ulwAlpha: DWORD = 0x0000_0002
private let acSrcOver: BYTE = 0
private let acSrcAlpha: BYTE = 1
private let vkMenu: Int32 = 0x12
private let gwlExStyle: Int32 = -20
private let swShow: Int32 = 5
private let spiGetWorkArea: UINT = 0x0030
private let mfString: UINT = 0
private let tpmRightButton: UINT = 0x0002
private let mbOK: UINT = 0
private let mbIconError: UINT = 0x10
private let menuQuit: UINT_PTR = 1
private let menuNew: UINT_PTR = 2
private let menuOpen: UINT_PTR = 3
private let menuExport: UINT_PTR = 4
private let menuQuality2D: UINT_PTR = 5
private let menuQuality3D: UINT_PTR = 6
private let menuNewQuality: UINT_PTR = 7
private let menuGIF: UINT_PTR = 8
private let menuSettings: UINT_PTR = 9
private let menuChat: UINT_PTR = 10
private let menuClearChat: UINT_PTR = 11
private let menuListen: UINT_PTR = 12
private let wmExitSizeMove: UINT = 0x0232
private let frameMilliseconds: UINT = 33

private func wide(_ string: String) -> [WCHAR] {
    Array(string.utf16) + [0]
}

private func showError(_ text: String) {
    let body = wide(text)
    let caption = wide("Castor")
    _ = body.withUnsafeBufferPointer { b in
        caption.withUnsafeBufferPointer { c in
            MessageBoxW(nil, b.baseAddress, c.baseAddress, mbOK | mbIconError)
        }
    }
}

private final class PetWindow {
    static var shared: PetWindow?

    var player: PetPlayback
    var preferences: DesktopPreferences
    var chatHistory: [OllamaChatMessage] = []
    var currentAsset: PetAsset
    var canvas: PetCanvas
    var hwnd: HWND?
    var screenDC: HDC?
    var memoryDC: HDC?
    var bitmap: HBITMAP?
    var bits: UnsafeMutableRawPointer?
    var isSeeingThrough = false
    let startTicks = GetTickCount64()

    init(player: PetPlayback, asset: PetAsset, preferences: DesktopPreferences, width: Int, height: Int) {
        self.player = player
        self.currentAsset = asset
        self.preferences = preferences
        canvas = PetCanvas(width: width, height: height)
    }

    func create() -> Bool {
        let instance = GetModuleHandleW(nil)
        let className = wide("CastorPetWindow")
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = petWindowProc
        windowClass.hInstance = instance
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
        let registered = className.withUnsafeBufferPointer { name -> ATOM in
            windowClass.lpszClassName = name.baseAddress
            return RegisterClassExW(&windowClass)
        }
        guard registered != 0 else { return false }

        // Bottom-right of the primary work area.
        var workArea = RECT()
        _ = SystemParametersInfoW(spiGetWorkArea, 0, &workArea, 0)
        let virtualLeft = GetSystemMetrics(76), virtualTop = GetSystemMetrics(77)
        let virtualRight = virtualLeft + GetSystemMetrics(78), virtualBottom = virtualTop + GetSystemMetrics(79)
        let x = max(virtualLeft - Int32(canvas.width) + 32, min(preferences.positionX ?? (workArea.right - Int32(canvas.width) - 28), virtualRight - 32))
        let y = max(virtualTop - Int32(canvas.height) + 32, min(preferences.positionY ?? (workArea.bottom - Int32(canvas.height) - 12), virtualBottom - 32))

        let title = wide("Castor")
        hwnd = className.withUnsafeBufferPointer { name in
            title.withUnsafeBufferPointer { titleBuffer in
                CreateWindowExW(
                    wsExLayered | wsExTopmost | wsExToolWindow,
                    name.baseAddress, titleBuffer.baseAddress,
                    wsPopup,
                    x, y, Int32(canvas.width), Int32(canvas.height),
                    nil, nil, instance, nil
                )
            }
        }
        guard let hwnd else { return false }

        screenDC = GetDC(nil)
        memoryDC = CreateCompatibleDC(screenDC)
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = LONG(canvas.width)
        info.bmiHeader.biHeight = -LONG(canvas.height) // top-down rows
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = 0 // BI_RGB
        bitmap = CreateDIBSection(screenDC, &info, 0, &bits, nil, 0)
        guard bitmap != nil, bits != nil else { return false }
        _ = SelectObject(memoryDC, bitmap)

        _ = ShowWindow(hwnd, swShow)
        _ = SetTimer(hwnd, 1, frameMilliseconds, nil)
        tick()
        return true
    }

    func tick() {
        guard let hwnd else { return }
        let time = Double(GetTickCount64() - startTicks) / 1000

        var cursor = POINT()
        var frame = RECT()
        _ = GetCursorPos(&cursor)
        _ = GetWindowRect(hwnd, &frame)
        let local = SIMD2(Float(cursor.x - frame.left), Float(cursor.y - frame.top))
        let inside = local.x >= 0 && local.y >= 0 && local.x < Float(canvas.width) && local.y < Float(canvas.height)

        // Hold Alt over the pet to see through it and click what it covers.
        let altHeld = GetAsyncKeyState(vkMenu) < 0
        setSeeingThrough(altHeld && inside)

        player.pointerMoved(to: local, canvasWidth: canvas.width, canvasHeight: canvas.height, time: time)
        player.render(into: &canvas, time: time, opacity: preferences.petOpacity * (isSeeingThrough ? 0.22 : 1))
        present()
    }

    func applyPreferences(_ updated: DesktopPreferences) throws {
        // Allocate before releasing the current bitmap, so failure keeps the old view.
        let scale = Double(GetDpiForSystem()) / 96 * updated.scale
        let width = Int(260 * scale), height = Int(340 * scale)
        var info = BITMAPINFO(); info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = LONG(width); info.bmiHeader.biHeight = -LONG(height)
        info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32
        var newBits: UnsafeMutableRawPointer?
        guard let newBitmap = CreateDIBSection(screenDC, &info, 0, &newBits, nil, 0), let newBits else { throw WindowsRiggingFlow.FlowError.dialogFailed }
        do { try DesktopPreferenceStore(root: WindowsRiggingFlow.directory).save(updated) }
        catch { _ = DeleteObject(newBitmap); throw error }
        _ = SelectObject(memoryDC, newBitmap)
        if let bitmap { _ = DeleteObject(bitmap) }
        bitmap = newBitmap; bits = newBits; canvas = PetCanvas(width: width, height: height)
        preferences = updated
        let mode = player.presentationMode
        player = PetPlayback(asset: currentAsset, wideHeadMovement: updated.widerHeadMovement)
        player.presentationMode = mode; player.automaticTurn = updated.automaticTurn
        _ = SetWindowPos(hwnd, nil, 0, 0, Int32(width), Int32(height), 0x0002 | 0x0004)
        tick()
    }
    func rememberPosition() {
        var frame = RECT()
        if GetWindowRect(hwnd, &frame) {
            preferences.positionX = frame.left; preferences.positionY = frame.top
            do { try DesktopPreferenceStore(root: WindowsRiggingFlow.directory).save(preferences) }
            catch { showError("位置を保存できませんでした。既存の保存設定は保持しています。\n\n\(error.localizedDescription)") }
        }
    }

    func setSeeingThrough(_ on: Bool) {
        guard on != isSeeingThrough, let hwnd else { return }
        isSeeingThrough = on
        let style = DWORD(truncatingIfNeeded: GetWindowLongPtrW(hwnd, gwlExStyle))
        let updated = on ? style | wsExTransparent : style & ~wsExTransparent
        _ = SetWindowLongPtrW(hwnd, gwlExStyle, LONG_PTR(Int32(bitPattern: updated)))
    }

    func present() {
        guard let hwnd, let bits else { return }
        canvas.bgra.withUnsafeBytes { source in
            bits.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        var frame = RECT()
        _ = GetWindowRect(hwnd, &frame)
        var destination = POINT(x: frame.left, y: frame.top)
        var size = SIZE(cx: LONG(canvas.width), cy: LONG(canvas.height))
        var origin = POINT(x: 0, y: 0)
        var blend = BLENDFUNCTION(BlendOp: acSrcOver, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: acSrcAlpha)
        _ = UpdateLayeredWindow(hwnd, screenDC, &destination, &size, memoryDC, &origin, 0, &blend, ulwAlpha)
    }

    func showMenu() {
        guard let hwnd, let menu = CreatePopupMenu() else { return }
        for (id, title) in [(menuNew, "1枚から新しいペットを作る"), (menuNewQuality, "2枚からQualityを作る"),
                            (menuOpen, "保存したペットを開く"), (menuExport, "Arils形式で書き出す"), (menuGIF, "GIFを作ってXで共有"), (menuChat, "ローカル会話"), (menuSettings, "設定・モデル・性格"), (menuClearChat, "会話履歴を消す"), (menuListen, "マイクから会話する（確認して送信）")] {
            let title = wide(title)
            _ = title.withUnsafeBufferPointer { AppendMenuW(menu, mfString, id, $0.baseAddress) }
        }
        if case .quality = currentAsset {
            for (id, title) in [(menuQuality2D, "Quality: 2Dクロスフェード"), (menuQuality3D, "Quality: 3D＋横画像")] {
                let label = wide(title)
                _ = label.withUnsafeBufferPointer { AppendMenuW(menu, mfString, id, $0.baseAddress) }
            }
        }
        let quit = wide("Quit Castor")
        _ = quit.withUnsafeBufferPointer { AppendMenuW(menu, mfString, menuQuit, $0.baseAddress) }
        var cursor = POINT()
        _ = GetCursorPos(&cursor)
        _ = SetForegroundWindow(hwnd)
        _ = TrackPopupMenu(menu, tpmRightButton, cursor.x, cursor.y, 0, hwnd, nil)
        _ = DestroyMenu(menu)
    }
}

private func petWindowProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch message {
    case wmTimer:
        PetWindow.shared?.tick()
        return 0
    case wmLButtonDown:
        // Drag anywhere on the pet to move it.
        _ = ReleaseCapture()
        _ = SendMessageW(hwnd, wmNCLButtonDown, htCaption, 0)
        return 0
    case wmRButtonUp:
        PetWindow.shared?.showMenu()
        return 0
    case wmCommand:
        let command = UInt16(truncatingIfNeeded: wParam)
        if command == UInt16(menuQuit) { _ = DestroyWindow(hwnd) }
        else if let window = PetWindow.shared {
            // Keep the existing pet intact while dialogs are open or if creation fails.
            // Native modal UI pumps messages; the existing pet keeps animating.
            do {
                if command == UInt16(menuQuality2D) { window.player.presentationMode = .twoD }
                if command == UInt16(menuQuality3D) { window.player.presentationMode = .threeD }
                if command == UInt16(menuGIF) {
                    var asset = window.currentAsset
                    if case var .quality(quality) = asset { quality.preferredPresentationMode = window.player.presentationMode; asset = .quality(quality) }
                    try WindowsRiggingFlow.shareGIF(asset: asset)
                }
                if command == UInt16(menuSettings), let updated = try WindowsConversationFlow.settings(window.preferences) { try window.applyPreferences(updated) }
                if command == UInt16(menuChat) || command == UInt16(menuListen) {
                    var prompt = ""
                    if command == UInt16(menuListen) {
                        guard let heard = try WindowsVoiceFlow.recognize() else { return 0 }
                        prompt = heard
                    }
                    if let reply = try WindowsConversationFlow.chat(preferences: window.preferences, history: &window.chatHistory, initialPrompt: prompt), window.preferences.systemTTSEnabled {
                        window.player.front.isSpeaking = true; window.player.side?.isSpeaking = true
                        defer { window.player.front.isSpeaking = false; window.player.side?.isSpeaking = false }
                        try WindowsVoiceFlow.speak(reply, voice: window.preferences.systemVoice)
                    }
                }
                if command == UInt16(menuClearChat) { window.chatHistory.removeAll() }
                var asset: PetAsset?
                if command == UInt16(menuNew) { asset = try WindowsRiggingFlow.startNewPet(quality: false) }
                if command == UInt16(menuNewQuality) { asset = try WindowsRiggingFlow.startNewPet(quality: true) }
                if command == UInt16(menuOpen), let url = try WindowsRiggingFlow.choose(kind: "pet") {
                    asset = try PetSource.loadAsset(contentsOf: url)
                    try WindowsRiggingFlow.remember(url)
                }
                if command == UInt16(menuExport), let url = try WindowsRiggingFlow.choose(kind: "archive", save: true) {
                    var exported = window.currentAsset
                    if case var .quality(quality) = exported {
                        quality.preferredPresentationMode = window.player.presentationMode
                        exported = .quality(quality)
                    }
                    try exported.data().write(to: url, options: .atomic)
                }
                if let asset {
                    window.currentAsset = asset
                    window.player = PetPlayback(asset: asset, wideHeadMovement: window.preferences.widerHeadMovement)
                    window.player.automaticTurn = window.preferences.automaticTurn
                    window.tick()
                }
            } catch { showError("処理を完了できませんでした。既存のペットと保存データは保持しています。\n\n\(error.localizedDescription)") }
        }
        return 0
    case wmExitSizeMove:
        PetWindow.shared?.rememberPosition()
        return 0
    case wmDestroy:
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

// MARK: - Entry

private func runNativeApplication() {
_ = SetProcessDPIAware()
let arguments = CommandLine.arguments.dropFirst()
let wideHeadMovement = arguments.contains("--wide-head")
let asset: PetAsset
do {
    if let path = arguments.first(where: { !$0.hasPrefix("--") }) {
        asset = try PetSource.loadAsset(contentsOf: URL(fileURLWithPath: path))
    } else if let saved = try WindowsRiggingFlow.defaultPet() {
        asset = try PetSource.loadAsset(contentsOf: saved)
    } else {
        guard let result = try WindowsRiggingFlow.startup() else { exit(0) }
        asset = result.0
    }
} catch {
    showError("ペットを開けませんでした。既存データは変更していません。\n\n\(error.localizedDescription)")
    exit(1)
}
var preferences = DesktopPreferences()
do { preferences = try DesktopPreferenceStore(root: WindowsRiggingFlow.directory).load() }
catch { showError("設定を読み込めませんでした。元の設定ファイルは保持し、この起動では既定値を使います。\n\n\(error.localizedDescription)") }
if wideHeadMovement { preferences.widerHeadMovement = true }
let player = PetPlayback(asset: asset, wideHeadMovement: preferences.widerHeadMovement)
player.automaticTurn = preferences.automaticTurn

let scale = Double(GetDpiForSystem()) / 96 * preferences.scale
let window = PetWindow(player: player, asset: asset, preferences: preferences, width: Int(260 * scale), height: Int(340 * scale))
PetWindow.shared = window
guard window.create() else {
    showError("Could not create the pet window.")
    exit(1)
}

var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    _ = TranslateMessage(&message)
    _ = DispatchMessageW(&message)
}

}

// MainActor services use the primary dispatcher. Win32 windows and all shell
// state stay on one dedicated native thread; callbacks never mutate it elsewhere.
DispatchQueue.global(qos: .userInteractive).async {
    runNativeApplication()
    exit(0)
}
dispatchMain()

#else
print("CastorPet is the Windows desktop pet. On macOS use the Castor app; to check the runtime here, run pet-snapshot.")
#endif
