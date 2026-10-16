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
import CDesktopUI
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
private let menuManual: UINT_PTR = 13
private let menuEditManual: UINT_PTR = 14
private let menuLibrary: UINT_PTR = 15
private let wmExitSizeMove: UINT = 0x0232
/// Sent by a second launch (Start menu, setup's Launch) to the running Castor: show the Castor window,
/// on the settings page when wParam is 1.
private let wmShowCastor: UINT = 0x8000 + 50
private var singleInstance: HANDLE?
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
    var automaticPreferenceSaveAllowed=true
    var microphoneErrorShown=false
    let evasion = DesktopEvasion()
    let buttonDodge = DesktopButtonDodge()
    private var lastMetadataTick: Double = -1
    private var nearbyWindows: [PetEvasionWindow] = []
    private var focusedWindowID: UInt32?
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
        if preferences.evasionEnabled || preferences.buttonDodgeEnabled {
            if time - lastMetadataTick >= 0.5 {
                lastMetadataTick = time
                var records = [CastorWindowMetadata](repeating: CastorWindowMetadata(), count: 512)
                let count = records.withUnsafeMutableBufferPointer { castor_window_metadata($0.baseAddress, $0.count) }
                if count >= 0 {
                    nearbyWindows = records.prefix(Int(count)).map { PetEvasionWindow(id: $0.id, ownerPID: $0.pid,
                        frame: CGRect(x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height))) }
                    focusedWindowID = records.prefix(Int(count)).first { $0.focused != 0 }?.id
                }
            }
            var monitor = [Int32](repeating: 0, count: 4), work = monitor
            let result = monitor.withUnsafeMutableBufferPointer { m in work.withUnsafeMutableBufferPointer {
                castor_monitor_bounds(Int32(frame.left + (frame.right-frame.left)/2), Int32(frame.top + (frame.bottom-frame.top)/2), m.baseAddress, $0.baseAddress)
            }}
            if result > 0 {
                func rect(_ v: [Int32]) -> CGRect { CGRect(x: Int(v[0]), y: Int(v[1]), width: Int(v[2]), height: Int(v[3])) }
                let current = CGRect(x: Int(frame.left), y: Int(frame.top), width: canvas.width, height: canvas.height)
                let point=CGPoint(x:Int(cursor.x),y:Int(cursor.y))
                let pixelX=Int(cursor.x-frame.left),pixelY=Int(cursor.y-frame.top)
                let onPet=pixelX>=0 && pixelY>=0 && pixelX<canvas.width && pixelY<canvas.height && canvas.bgra[(pixelY*canvas.width+pixelX)*4+3]>16
                var actionable: Bool?
                if preferences.buttonDodgeEnabled,onPet,let target=nearbyWindows.first(where:{$0.frame.contains(point)}) {
                    let value=castor_pointer_actionable(target.id,Int32(cursor.x),Int32(cursor.y))
                    if value>=0 {actionable=value>0}
                }
                var moved=buttonDodge.update(frame:current,pointer:point,visible:rect(work),actionable:actionable,
                    buttonsPressed:GetAsyncKeyState(1)<0 || GetAsyncKeyState(2)<0,enabled:preferences.buttonDodgeEnabled)
                if !buttonDodge.active && preferences.evasionEnabled {
                    moved=evasion.update(frame:current,pointer:point,screen:rect(monitor),workArea:rect(work),
                        windows:nearbyWindows,focusedID:focusedWindowID,style:preferences.evasionStyle)
                } else {evasion.disable()}
                if let moved {
                    _ = SetWindowPos(hwnd,nil,Int32(moved.minX.rounded()),Int32(moved.minY.rounded()),0,0,0x0001|0x0004|0x0010)
                    _ = GetWindowRect(hwnd,&frame)
                }
            }
        } else { evasion.disable();buttonDodge.disable() }
        var microphoneLevel: Float=0
        let microphoneStatus=castor_microphone_level(&microphoneLevel)
        let playbackLevel=castor_wave_level()
        player.front.playbackSpeechEnergy=playbackLevel>=0 ? playbackLevel:nil
        player.side?.playbackSpeechEnergy=player.front.playbackSpeechEnergy
        player.front.microphoneEnabled=preferences.microphoneEnabled && microphoneStatus==1
        player.side?.microphoneEnabled=player.front.microphoneEnabled
        player.front.microphoneLevel=microphoneLevel;player.side?.microphoneLevel=microphoneLevel
        if preferences.microphoneEnabled,microphoneStatus<0,!microphoneErrorShown {
            microphoneErrorShown=true;preferences.microphoneEnabled=false;castor_microphone_enable(0)
            if automaticPreferenceSaveAllowed {try? DesktopPreferenceStore(root:WindowsRiggingFlow.directory).save(preferences)}
            let japanese=preferences.displayLanguage == .japanese
            let detail=microphoneStatus == -1
                ? (japanese ? "マイクの使用が許可されていません。Windows設定のマイクでデスクトップアプリのアクセスを許可し、Castorの設定でマイクをオンにしてください。文字会話は使えます。":"Microphone access was denied. Allow desktop apps in Windows Microphone settings, then turn on Microphone in Castor Settings. Text chat remains available.")
                : (japanese ? "マイクを利用できません。接続とWindowsの入力設定を確認してから、Castorの設定でマイクをオンにしてください。文字会話は使えます。":"The microphone is unavailable. Check your input device and Windows input settings, then enable it in Castor Settings. Text chat remains available.")
            let options=japanese ? "Windowsのマイク設定を開く\n後で":"Open Windows microphone settings\nLater"
            let choice=detail.withCString {title in options.withCString {castor_choose_option(title,$0)}}
            if choice==1 {_ = castor_open_microphone_settings()}
        }
        let local = SIMD2(Float(cursor.x - frame.left), Float(cursor.y - frame.top))
        let inside = local.x >= 0 && local.y >= 0 && local.x < Float(canvas.width) && local.y < Float(canvas.height)

        // Hold Alt over the pet to see through it and click what it covers.
        let altHeld = GetAsyncKeyState(vkMenu) < 0
        setSeeingThrough((altHeld && inside) || evasion.ghost || evasion.hidden)

        player.front.visualScale = evasion.visualScale; player.side?.visualScale = evasion.visualScale
        player.pointerMoved(to: local, canvasWidth: canvas.width, canvasHeight: canvas.height, time: time)
        player.render(into: &canvas, time: time, opacity: preferences.petOpacity * (evasion.hidden ? 0 : evasion.ghost ? 0.15 : isSeeingThrough ? 0.22 : 1))
        if preferences.microphoneEnabled,microphoneStatus==1 {
            // Visible orange recording indicator; GIF rendering uses a separate canvas.
            for y in max(0,canvas.height-17)..<max(0,canvas.height-7) {for x in max(0,canvas.width-17)..<max(0,canvas.width-7) {
                let dx=x-(canvas.width-12),dy=y-(canvas.height-12)
                if dx*dx+dy*dy<=16 {let i=(y*canvas.width+x)*4;canvas.bgra[i]=24;canvas.bgra[i+1]=150;canvas.bgra[i+2]=255;canvas.bgra[i+3]=255}
            }}
        }
        present()
    }

    func setQualityMode(_ mode:QualityPresentationMode) throws {
        var updated=preferences;updated.qualityPresentationMode=mode
        if automaticPreferenceSaveAllowed {try DesktopPreferenceStore(root:WindowsRiggingFlow.directory).save(updated)}
        preferences=updated;player.presentationMode=mode
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
        automaticPreferenceSaveAllowed=true;microphoneErrorShown=false
        castor_microphone_enable(updated.microphoneEnabled ? 1:0)
        castor_set_ui_language(updated.displayLanguage == .japanese ? 1 : 0)
        let mode = player.presentationMode
        player = PetPlayback(asset: currentAsset, wideHeadMovement: updated.widerHeadMovement)
        player.presentationMode = updated.qualityPresentationMode ?? mode; player.automaticTurn = updated.automaticTurn
        _ = SetWindowPos(hwnd, nil, 0, 0, Int32(width), Int32(height), 0x0002 | 0x0004)
        tick()
    }
    func rememberPosition() {
        var frame = RECT()
        if GetWindowRect(hwnd, &frame) {
            buttonDodge.manualPlacement()
            evasion.manualPlacement(frame: CGRect(x: Int(frame.left), y: Int(frame.top), width: canvas.width, height: canvas.height))
            preferences.positionX = frame.left; preferences.positionY = frame.top
            guard automaticPreferenceSaveAllowed else {return}
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

    func show(_ asset: PetAsset) {
        currentAsset = asset
        player = PetPlayback(asset: asset, wideHeadMovement: preferences.widerHeadMovement)
        player.automaticTurn = preferences.automaticTurn
        player.presentationMode = preferences.qualityPresentationMode ?? player.presentationMode
        tick()
    }

    func showMenu() {
        guard let hwnd, let menu = CreatePopupMenu() else { return }
        let japanese=preferences.displayLanguage == .japanese
        for (id, title) in [(menuNew, japanese ? "1枚から新しいペットを作る":"Create a pet from one image"), (menuLibrary, japanese ? "ペット一覧（作ったペットを選ぶ）":"My Pets (choose a saved pet)"), (menuNewQuality, japanese ? "2枚からQualityを作る":"Create Quality from two images"),
                            (menuManual, japanese ? "手動リグを作る":"Create a manual rig"), (menuOpen, japanese ? "ファイルからペットを開く":"Open a pet file"), (menuExport, japanese ? "ペットを書き出す":"Export pet"), (menuGIF, japanese ? "GIFを作ってXで共有":"Create GIF and share on X"), (menuChat, japanese ? "ローカル会話":"Chat / Request an action"), (menuSettings, japanese ? "設定・モデル・性格":"Settings / Models / Personality"), (menuClearChat, japanese ? "会話履歴を消す":"Clear conversation"), (menuListen, japanese ? "マイクから会話する（確認して送信）":"Speak (review before sending)")] {
            let title = wide(title)
            _ = title.withUnsafeBufferPointer { AppendMenuW(menu, mfString, id, $0.baseAddress) }
        }
        if case .manual = currentAsset {
            let label = wide(japanese ? "手動リグを編集":"Edit manual rig")
            _ = label.withUnsafeBufferPointer { AppendMenuW(menu, mfString, menuEditManual, $0.baseAddress) }
        }
        if case .quality = currentAsset {
            for (id, title) in [(menuQuality2D, japanese ? "Quality: 2Dクロスフェード":"Quality: 2D crossfade"), (menuQuality3D, japanese ? "Quality: 3D＋横画像":"Quality: 3D + side reference")] {
                let label = wide(title)
                _ = label.withUnsafeBufferPointer { AppendMenuW(menu, mfString, id, $0.baseAddress) }
            }
        }
        let quit = wide(CastorSettingsStrings.text("desktop.menu.close",language:preferences.displayLanguage))
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
                if command == UInt16(menuQuality2D) { try window.setQualityMode(.twoD) }
                if command == UInt16(menuQuality3D) { try window.setQualityMode(.threeD) }
                if command == UInt16(menuGIF) {
                    var asset = window.currentAsset
                    if case var .quality(quality) = asset { quality.preferredPresentationMode = window.player.presentationMode; asset = .quality(quality) }
                    try WindowsRiggingFlow.shareGIF(asset: asset)
                }
                // Settings open on the creation window's settings page; the native list remains without WebView2.
                if command == UInt16(menuSettings), !openCreationWindow(language: window.preferences.displayLanguage, view: "settings", unavailable: {
                    do { if let window = PetWindow.shared, let updated = try WindowsConversationFlow.settings(window.preferences) { try window.applyPreferences(updated) } }
                    catch { showError(error.localizedDescription) }
                }), let updated = try WindowsConversationFlow.settings(window.preferences) { try window.applyPreferences(updated) }
                if command == UInt16(menuChat) || command == UInt16(menuListen) {
                    var prompt = ""
                    if command == UInt16(menuListen) {
                        castor_microphone_enable(0)
                        defer {castor_microphone_enable(window.preferences.microphoneEnabled ? 1:0)}
                        window.player.front.behavior = .listening;window.player.side?.behavior = .listening
                        defer {window.player.front.behavior = .idle;window.player.side?.behavior = .idle}
                        guard let heard = try WindowsVoiceFlow.recognize(language: window.preferences.displayLanguage) else { return 0 }
                        prompt = heard
                    }
                    if let reply = try WindowsConversationFlow.chat(preferences: window.preferences, history: &window.chatHistory, initialPrompt: prompt), window.preferences.systemTTSEnabled {
                        window.player.front.isSpeaking = true; window.player.side?.isSpeaking = true
                        defer { window.player.front.isSpeaking = false; window.player.side?.isSpeaking = false }
                        try WindowsVoiceFlow.speak(reply, preferences: window.preferences)
                    }
                }
                if command == UInt16(menuClearChat) { window.chatHistory.removeAll() }
                var asset: PetAsset?
                if command == UInt16(menuManual) { asset = try WindowsManualRiggingFlow.edit(language: window.preferences.displayLanguage) }
                if command == UInt16(menuEditManual), case let .manual(pet) = window.currentAsset {
                    asset = try WindowsManualRiggingFlow.edit(pet, language: window.preferences.displayLanguage)
                }
                if command == UInt16(menuLibrary), !openCreationWindow(language: window.preferences.displayLanguage, view: "library", unavailable: legacyNewPet) {
                    asset = try WindowsRiggingFlow.startNewPet(quality: false)
                }
                if command == UInt16(menuNew), !openCreationWindow(language: window.preferences.displayLanguage, unavailable: legacyNewPet) {
                    asset = try WindowsRiggingFlow.startNewPet(quality: false)
                }
                if command == UInt16(menuNewQuality) { asset = try WindowsRiggingFlow.startNewPet(quality: true) }
                if command == UInt16(menuOpen), let url = try WindowsRiggingFlow.choose(kind: "pet") {
                    asset = try PetSource.loadAsset(contentsOf: url)
                    try WindowsRiggingFlow.remember(url)
                }
                let exportKind: String
                if case .manual = window.currentAsset { exportKind = "json" } else { exportKind = "archive" }
                if command == UInt16(menuExport), let url = try WindowsRiggingFlow.choose(kind: exportKind, save: true) {
                    var exported = window.currentAsset
                    if case var .quality(quality) = exported {
                        quality.preferredPresentationMode = window.player.presentationMode
                        exported = .quality(quality)
                    }
                    try exported.data().write(to: url, options: .atomic)
                }
                if let asset { window.show(asset) }
            } catch { showError("処理を完了できませんでした。既存のペットと保存データは保持しています。\n\n\(error.localizedDescription)") }
        }
        return 0
    case wmShowCastor:
        if let window = PetWindow.shared,
           !openCreationWindow(language: window.preferences.displayLanguage, view: wParam == 1 ? "settings" : "library", unavailable: {}) {
            window.showMenu()
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

// MARK: - Creation window

/// The Mac-style creation window. New pets replace the one on the desktop;
/// before the pet window exists (first launch) they go to `firstPet`.
private func openCreationWindow(language: SettingsDisplayLanguage, view: String? = nil, firstPet: ((PetAsset) -> Void)? = nil,
                                unavailable: @escaping () -> Void) -> Bool {
    CreationWindow.open(language: language, view: view, onCreated: { asset in
        if let window = PetWindow.shared { window.show(asset) } else { firstPet?(asset) }
    }, onSettings: creationSettings, onUnavailable: unavailable, currentPreferences: {
        PetWindow.shared?.preferences ?? ((try? DesktopPreferenceStore(root: WindowsRiggingFlow.directory).load()) ?? DesktopPreferences())
    }, applyPreferences: { updated in
        if let window = PetWindow.shared { try window.applyPreferences(updated) }
        else { try DesktopPreferenceStore(root: WindowsRiggingFlow.directory).save(updated) }
        castor_set_ui_language(updated.displayLanguage == .japanese ? 1 : 0)
    })
}

/// The native dialogs, for systems without the WebView2 Runtime.
private func legacyNewPet() {
    do { if let asset = try WindowsRiggingFlow.startNewPet(quality: false) { PetWindow.shared?.show(asset) } }
    catch { showError("処理を完了できませんでした。既存のペットと保存データは保持しています。\n\n\(error.localizedDescription)") }
}

private func creationSettings() -> SettingsDisplayLanguage? {
    do {
        if let window = PetWindow.shared {
            guard let updated = try WindowsConversationFlow.settings(window.preferences) else { return nil }
            try window.applyPreferences(updated)
            return updated.displayLanguage
        }
        let store = DesktopPreferenceStore(root: try WindowsRiggingFlow.directory)
        guard let updated = try WindowsConversationFlow.settings((try? store.load()) ?? DesktopPreferences()) else { return nil }
        try store.save(updated)
        castor_set_ui_language(updated.displayLanguage == .japanese ? 1 : 0)
        return updated.displayLanguage
    } catch {
        showError(error.localizedDescription)
        return nil
    }
}

/// First launch: the creation window until a pet is saved (nil when it is
/// closed). Without WebView2 the native dialogs ask instead.
private func firstPet(language: SettingsDisplayLanguage) throws -> PetAsset? {
    var created: PetAsset?
    var unavailable = false
    guard openCreationWindow(language: language, firstPet: { created = $0 }, unavailable: { unavailable = true }) else {
        return try WindowsRiggingFlow.startup()?.0
    }
    var message = MSG()
    while created == nil, !unavailable, CreationWindow.isOpen, GetMessageW(&message, nil, 0, 0) {
        _ = TranslateMessage(&message)
        _ = DispatchMessageW(&message)
    }
    if unavailable { return try WindowsRiggingFlow.startup()?.0 }
    return created
}

// MARK: - Entry

/// After an update the running Castor is an older version in another folder.
/// It is asked to close (its pet window quits on WM_CLOSE in every version),
/// so this launch replaces it instead of only bringing it forward. False when
/// the running Castor is this same executable, or it did not close in time.
private func replaceOtherVersion(_ running: HWND) -> Bool {
    var processID: DWORD = 0
    _ = GetWindowThreadProcessId(running, &processID)
    let access = DWORD(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */) | DWORD(0x0010_0000 /* SYNCHRONIZE */)
    guard processID != 0, processID != GetCurrentProcessId(), let process = OpenProcess(access, false, processID) else { return false }
    defer { CloseHandle(process) }
    var theirs = [WCHAR](repeating: 0, count: 32768)
    var theirLength = DWORD(theirs.count)
    var ours = [WCHAR](repeating: 0, count: 32768)
    let ourLength = GetModuleFileNameW(nil, &ours, DWORD(ours.count))
    guard QueryFullProcessImageNameW(process, 0, &theirs, &theirLength), ourLength > 0 else { return false }
    let theirPath = String(decoding: theirs.prefix(Int(theirLength)), as: UTF16.self).lowercased()
    let ourPath = String(decoding: ours.prefix(Int(ourLength)), as: UTF16.self).lowercased()
    guard theirPath != ourPath else { return false }
    _ = PostMessageW(running, 0x0010 /* WM_CLOSE */, 0, 0)
    return WaitForSingleObject(process, 8000) == 0 /* WAIT_OBJECT_0 */
}

private func runNativeApplication() {
_ = SetProcessDPIAware()
let arguments = CommandLine.arguments.dropFirst()
let wideHeadMovement = arguments.contains("--wide-head")
let openingFile = arguments.contains { !$0.hasPrefix("--") }
let startView = arguments.contains("--settings") ? "settings" : "library"
// One Castor per sign-in: launching it again brings the running one's window forward instead of a second pet.
// A Castor from another folder (the version before an update) is closed and replaced instead.
if !openingFile {
    singleInstance = wide("Local\\CastorPet").withUnsafeBufferPointer { CreateMutexW(nil, false, $0.baseAddress) }
    let alreadyRunning = GetLastError() == 183 /* ERROR_ALREADY_EXISTS */
    let running = wide("CastorPetWindow").withUnsafeBufferPointer({ FindWindowW($0.baseAddress, nil) })
    let creating = wide("CastorCreationWindow").withUnsafeBufferPointer({ FindWindowW($0.baseAddress, nil) })
    if let other = running ?? creating, replaceOtherVersion(other) {
        // The older version has quit; start this one normally.
    } else if alreadyRunning {
        _ = AllowSetForegroundWindow(DWORD.max)   // ASFW_ANY: let the running Castor come to the front
        if let running {
            _ = PostMessageW(running, wmShowCastor, startView == "settings" ? 1 : 0, 0)
        } else if let creating {
            _ = ShowWindow(creating, 9 /* SW_RESTORE */)
            _ = SetForegroundWindow(creating)
        }
        exit(0)
    }
}
var showWindowAtStart = false
var preferences = DesktopPreferences()
var preferenceSaveAllowed=true
do { preferences = try DesktopPreferenceStore(root: WindowsRiggingFlow.directory).load() }
catch {preferenceSaveAllowed=false; showError("設定を読み込めませんでした。元の設定ファイルは保持し、この起動では既定値を使います。\n\n\(error.localizedDescription)") }
if wideHeadMovement { preferences.widerHeadMovement = true }
castor_set_ui_language(preferences.displayLanguage == .japanese ? 1 : 0)
let asset: PetAsset
do {
    if let path = arguments.first(where: { !$0.hasPrefix("--") }) {
        asset = try PetSource.loadAsset(contentsOf: URL(fileURLWithPath: path))
    } else if let saved = try WindowsRiggingFlow.defaultPet() {
        asset = try PetSource.loadAsset(contentsOf: saved)
        // A plain launch shows the Castor window too, so its pages are found without the pet's menu.
        showWindowAtStart = !arguments.contains("--pet-only")
    } else {
        guard let created = try firstPet(language: preferences.displayLanguage) else { exit(0) }
        asset = created
        // Settings may have changed in the creation window; keep them.
        if preferenceSaveAllowed, let saved = try? DesktopPreferenceStore(root: WindowsRiggingFlow.directory).load() {
            preferences = saved
            if wideHeadMovement { preferences.widerHeadMovement = true }
        }
    }
} catch {
    showError("ペットを開けませんでした。既存データは変更していません。\n\n\(error.localizedDescription)")
    exit(1)
}
let player = PetPlayback(asset: asset, wideHeadMovement: preferences.widerHeadMovement)
player.automaticTurn = preferences.automaticTurn
player.presentationMode = preferences.qualityPresentationMode ?? player.presentationMode

let scale = Double(GetDpiForSystem()) / 96 * preferences.scale
let window = PetWindow(player: player, asset: asset, preferences: preferences, width: Int(260 * scale), height: Int(340 * scale))
window.automaticPreferenceSaveAllowed=preferenceSaveAllowed
if !preferences.microphoneSetupCompleted && preferenceSaveAllowed {
    let japanese=preferences.displayLanguage == .japanese
    let text=japanese ? "マイクを有効にしますか？音量への反応は端末内だけで処理します。音声チャットはマイクボタンを押して確認してから送信します。後で設定から変更できます。":"Enable the microphone? Audio-level reactions stay on this device. Voice chat starts only when you press the microphone button and review your message. You can change this in Settings later."
    let options=japanese ? "許可してオンにする\n今は使わない":"Allow and turn on\nNot now"
    preferences.microphoneSetupCompleted=true
    preferences.microphoneEnabled=text.withCString {title in options.withCString {castor_choose_option(title,$0)}}==1
    do {try DesktopPreferenceStore(root:WindowsRiggingFlow.directory).save(preferences);window.preferences=preferences}
    catch {showError(error.localizedDescription);window.preferences.microphoneEnabled=false}
}
castor_microphone_enable(window.preferences.microphoneEnabled ? 1:0)
PetWindow.shared = window
guard window.create() else {
    showError("Could not create the pet window.")
    exit(1)
}
if showWindowAtStart {
    _ = openCreationWindow(language: window.preferences.displayLanguage, view: startView, unavailable: {})
}
// Installs made by an older setup only have the "Castor" entry; refresh it so "Castor Settings" appears too.
if WindowsRiggingFlow.installedVersion() != nil, let folder = try? WindowsRiggingFlow.applicationFolder() {
    let executable = folder.appendingPathComponent("CastorPet.exe").path
    _ = executable.withCString { file in folder.deletingLastPathComponent().path.withCString { castor_pet_shortcut(file, $0, 0) } }
}

var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    _ = TranslateMessage(&message)
    _ = DispatchMessageW(&message)
}

}

// MainActor services use the primary dispatcher. Win32 windows and all shell
// state stay on one dedicated native thread; callbacks never mutate it elsewhere.
// The creation window (WebView2) needs this thread to be a COM single-threaded
// apartment; dispatch's worker threads are already multithreaded.
if castor_start_ui_thread({ _ in runNativeApplication(); exit(0) }, nil) != 1 {
    DispatchQueue.global(qos: .userInteractive).async {
        runNativeApplication()
        exit(0)
    }
}
dispatchMain()

#else
print("CastorPet is the Windows desktop pet. On macOS use the Castor app; to check the runtime here, run pet-snapshot.")
#endif
