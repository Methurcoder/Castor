// Castor desktop pet for Windows (preview).
//
//     CastorPet.exe [CastorPet.json | avatar.arils] [--wide-head]
//
// Shows a pet rigged on a Mac in a transparent, always-on-top window:
// it breathes, blinks and looks at the pointer; moving the pointer over its
// head pets it. Drag to move it; right-click for the menu; hold Alt over it
// to see through it and click what it covers.

#if os(Windows)
import Foundation
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

    let player: PetPlayer
    var canvas: PetCanvas
    var hwnd: HWND?
    var screenDC: HDC?
    var memoryDC: HDC?
    var bitmap: HBITMAP?
    var bits: UnsafeMutableRawPointer?
    var isSeeingThrough = false
    let startTicks = GetTickCount64()

    init(player: PetPlayer, width: Int, height: Int) {
        self.player = player
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
        let x = workArea.right - Int32(canvas.width) - 28
        let y = workArea.bottom - Int32(canvas.height) - 12

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
        player.render(into: &canvas, time: time, opacity: isSeeingThrough ? 0.22 : 1)
        present()
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
        if UInt16(truncatingIfNeeded: wParam) == UInt16(menuQuit) {
            _ = DestroyWindow(hwnd)
        }
        return 0
    case wmDestroy:
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}

// MARK: - Entry

_ = SetProcessDPIAware()
let arguments = CommandLine.arguments.dropFirst()
let wideHeadMovement = arguments.contains("--wide-head")
let petPath = arguments.first { !$0.hasPrefix("--") }
    ?? PetSource.defaultFileURL(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
let player: PetPlayer
do {
    player = PetPlayer(
        archive: try PetSource.load(contentsOf: URL(fileURLWithPath: petPath)),
        wideHeadMovement: wideHeadMovement
    )
} catch {
    showError("Could not open \(petPath).\n\n\(error)\n\nCopy CastorPet.json from the Mac (see CastorDesktop/README.md) next to this program, or pass its path.")
    exit(1)
}

let scale = Double(GetDpiForSystem()) / 96
private let window = PetWindow(player: player, width: Int(260 * scale), height: Int(340 * scale))
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

#else
print("CastorPet is the Windows desktop pet. On macOS use the Castor app; to check the runtime here, run pet-snapshot.")
#endif
