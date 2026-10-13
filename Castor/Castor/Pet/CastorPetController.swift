import AppKit
import SwiftUI
import CastorCore

@MainActor
final class CastorPetController: NSObject, NSWindowDelegate {
    static let shared = CastorPetController()

    private var petWindow: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastEdgeDoubleClickAt = Date.distantPast
    private var compactFrameBeforeReader: NSRect?
    private let evasionPresentation = PetEvasionPresentation()
    private let evasionProvider: any PetEvasionWindowProviding = CGPetEvasionWindowProvider()
    private let evasionPolicy = PetEvasionPolicy()
    private var evasionState = PetEvasionStateMachine()
    private var evasionTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var homeFrame: NSRect?
    private var lastManualPlacementAt = Date.distantPast
    private var ignoreMoveNotificationsUntil = Date.distantPast
    private var isReaderExpanded = false
    private var fallbackMode: EvasionFallbackMode = .none
    private var hasEmittedSessionCue = false
    private var trilobite: TrilobiteEngine?
    // See-through and button-aware dodge (see PetPassThrough in CastorCore).
    private var passThroughTimer: Timer?
    private var isPassThroughActive = false
    private var dodge = PetDodgeStateMachine()
    private var isDodgeQueryInFlight = false
    private let pointerTargetClient = PointerTargetClient()

    private override init() {
        super.init()
    }

    func startEdgeDoubleClickMonitor() {
        guard localMonitor == nil, globalMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseDown(event)
            }
        }
    }

    /// Supplies the app-owned local input engine to future and existing pet
    /// views. The snapshot itself remains permission-gated by TrilobiteEngine.
    func setTrilobiteEngine(_ engine: TrilobiteEngine) {
        trilobite = engine
        if let asset = PetCharacterStore.load(), petWindow != nil {
            petWindow?.contentView = makeContentView(for: asset)
        }
    }

    func showPet() {
        guard let asset = PetCharacterStore.load(), asset.image != nil else {
            return
        }

        if let petWindow {
            setReaderExpanded(false)
            evasionPresentation.style = asset.resolvedEvasionStyle
            petWindow.contentView = makeContentView(for: asset)
            petWindow.orderFrontRegardless()
            startPassThroughMonitoring()
            if PetEvasionSettingsStore.isEnabled {
                startEvasionMonitoring()
                evaluateEvasion()
            } else {
                disableActiveEvasion()
            }
            return
        }

        let startingFrame = initialFrame()
        let panel = PetPanel(
            contentRect: startingFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        evasionPresentation.style = asset.resolvedEvasionStyle
        panel.contentView = makeContentView(for: asset)

        petWindow = panel
        homeFrame = startingFrame
        evasionState.resetForManualPlacement(at: Date())
        syncEvasionPresentation()
        panel.orderFrontRegardless()
        startPassThroughMonitoring()
        if PetEvasionSettingsStore.isEnabled {
            startEvasionMonitoring()
        }
    }

    func hidePet() {
        petWindow?.close()
        petWindow = nil
        compactFrameBeforeReader = nil
        homeFrame = nil
        stopEvasionMonitoring()
        stopPassThroughMonitoring()
        fallbackMode = .none
        isReaderExpanded = false
        hasEmittedSessionCue = false
    }

    func setEvasionEnabled(_ isEnabled: Bool) {
        PetEvasionSettingsStore.isEnabled = isEnabled
        if isEnabled {
            guard petWindow != nil else { return }
            startEvasionMonitoring()
            evaluateEvasion()
        } else {
            stopEvasionMonitoring()
            disableActiveEvasion()
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.clickCount == 2, isNearScreenEdge(NSEvent.mouseLocation) else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastEdgeDoubleClickAt) > 0.35 else {
            return
        }
        lastEdgeDoubleClickAt = now

        showPet()
    }

    private func isNearScreenEdge(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let frame = screen.frame
            let threshold: CGFloat = 18
            let isInsideScreen = frame.contains(point)
            let isNearEdge = abs(point.x - frame.minX) <= threshold
                || abs(frame.maxX - point.x) <= threshold
                || abs(point.y - frame.minY) <= threshold
                || abs(frame.maxY - point.y) <= threshold
            return isInsideScreen && isNearEdge
        }
    }

    private func initialFrame() -> NSRect {
        let size = NSSize(width: 260, height: 340)
        let mouseLocation = NSEvent.mouseLocation
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 80, y: 80, width: 900, height: 700)
        let fallback = NSRect(
            x: visibleFrame.maxX - size.width - 28,
            y: visibleFrame.minY + 32,
            width: size.width,
            height: size.height
        )
        guard let savedOrigin = PetHomePositionStore.load() else {
            return fallback
        }
        let saved = NSRect(origin: savedOrigin, size: size)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) }) else {
            return fallback
        }
        return clamped(saved, inside: screen.visibleFrame)
    }

    private func setReaderExpanded(_ isExpanded: Bool) {
        guard let petWindow else {
            return
        }

        self.isReaderExpanded = isExpanded
        restorePanelAppearance()
        let targetFrame: NSRect
        if isExpanded {
            compactFrameBeforeReader = petWindow.frame
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(petWindow.frame) })
                ?? NSScreen.main
            targetFrame = screen?.frame ?? petWindow.frame
            petWindow.isMovableByWindowBackground = false
        } else {
            targetFrame = compactFrameBeforeReader ?? initialFrame()
            compactFrameBeforeReader = nil
            petWindow.isMovableByWindowBackground = true
        }

        setFrame(targetFrame, for: petWindow, animated: false)
        if !isExpanded {
            evaluateEvasion()
        }
    }

    private func makeContentView(for asset: SavedPetCharacter) -> NSHostingView<PetFloatingView> {
        let hostingView = NSHostingView(
            rootView: PetFloatingView(
                asset: asset,
                trilobite: trilobite,
                onClose: { [weak self] in
                    self?.hidePet()
                },
                onReaderModeChange: { [weak self] isExpanded in
                    self?.setReaderExpanded(isExpanded)
                },
                evasionPresentation: evasionPresentation
            )
        )
        // The panel owns its compact/full-screen frame. Allowing NSHostingView to
        // resize the window from the root view's intrinsic size can re-enter the
        // AppKit constraint update cycle while the panel frame is changing.
        hostingView.sizingOptions = []
        return hostingView
    }

    private func startEvasionMonitoring() {
        guard evasionTimer == nil else { return }
        evasionTimer = Timer.scheduledTimer(withTimeInterval: evasionPolicy.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateEvasion()
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        let notifications: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        workspaceObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.evaluateEvasion()
                }
            }
        }
    }

    private func stopEvasionMonitoring() {
        evasionTimer?.invalidate()
        evasionTimer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private func evaluateEvasion(now: Date = Date()) {
        guard PetEvasionSettingsStore.isEnabled,
              let panel = petWindow,
              !isReaderExpanded else {
            return
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.main
        guard let screen else { return }

        let windows = evasionProvider.onScreenWindows()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let panelWindowID = CGWindowID(panel.windowNumber)
        let candidates = windows.filter { $0.id != panelWindowID && $0.ownerPID != ownPID }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedWindow = frontmostPID.flatMap { pid in
            candidates.first(where: { $0.ownerPID == pid && $0.frame.intersects(screen.frame) })
        }
        let pointer = NSEvent.mouseLocation
        let rawObstruction = focusedWindow.map {
            PetEvasionGeometry.isObstructed(petFrame: panel.frame, by: $0.frame)
        } ?? false
        let pointerRequestsSpace = PetEvasionGeometry.isPointerRequestingSpace(
            around: panel.frame,
            pointer: pointer
        )
        let obstructed = rawObstruction && pointerRequestsSpace
        let homeObstructed = focusedWindow.flatMap { focusedWindow in
            homeFrame.map {
                PetEvasionGeometry.isObstructed(petFrame: $0, by: focusedWindow.frame)
                    && PetEvasionGeometry.isPointerRequestingSpace(around: $0, pointer: pointer)
            }
        } ?? false
        // The focused window is deliberately not an obstacle for destination selection. A
        // maximized browser has no literal free rectangle, but moving to a corner away from the
        // pointer is still useful because the pet floats above that window.
        let occupiedFrames = focusedWindow.map { focused in
            candidates.filter {
                $0.ownerPID == focused.ownerPID
                    && $0.id != focused.id
                    && $0.frame.intersects(screen.visibleFrame)
            }.map(\.frame)
        } ?? []
        let destination = obstructed
            ? PetEvasionGeometry.nearestAvailableFrame(
                for: panel.frame,
                in: screen.visibleFrame,
                avoiding: occupiedFrames,
                avoidingPoint: pointer
            )
            : nil
        let isFullscreen = focusedWindow.map {
            PetEvasionGeometry.isFullscreen($0.frame, on: screen.frame)
        } ?? false
        let isManualPlacementProtected = now.timeIntervalSince(lastManualPlacementAt)
            < evasionPolicy.manualPlacementProtection

        if let focusedWindow {
            let dx = focusedWindow.frame.midX - panel.frame.midX
            let dy = focusedWindow.frame.midY - panel.frame.midY
            evasionPresentation.obstructingWindowGaze = CGPoint(
                x: max(-10, min(10, dx / max(screen.frame.width, 1) * 20)),
                y: max(-8, min(8, -dy / max(screen.frame.height, 1) * 16))
            )
        } else {
            evasionPresentation.obstructingWindowGaze = nil
        }

        if !obstructed || (destination != nil && !isManualPlacementProtected && !isFullscreen) {
            restorePanelAppearance()
        }

        let priorPhase = evasionState.phase
        let action = evasionState.update(
            obstructed: obstructed,
            homeObstructed: homeObstructed,
            destination: destination,
            focusedWindowIsFullscreen: isFullscreen && destination == nil,
            manualPlacementProtected: isManualPlacementProtected,
            profile: EvasionProfiles.profile(for: evasionPresentation.style),
            policy: evasionPolicy,
            now: now
        )
        syncEvasionPresentation()
        if priorPhase == .settled,
           (evasionState.phase == .anticipating || evasionState.phase == .evading) {
            emitSessionCueIfNeeded()
        }

        switch action {
        case .none:
            break
        case let .move(destination):
            animatePanel(to: destination, returning: false)
        case .returnHome:
            guard let homeFrame else { return }
            animatePanel(to: homeFrame, returning: true)
        case .ghost:
            applyGhostMode()
        case .hide:
            applyHiddenMode()
        }
    }

    private func animatePanel(to targetFrame: NSRect, returning: Bool) {
        guard let panel = petWindow else { return }
        let profile = EvasionProfiles.profile(for: evasionPresentation.style)
        let duration: TimeInterval
        if returning {
            switch profile.returnManner {
            case .gentle: duration = 0.58
            case .confident: duration = 0.48
            case .slide: duration = 0.36
            }
        } else {
            duration = profile.movementDuration
        }
        ignoreMoveNotificationsUntil = Date().addingTimeInterval(duration + 0.2)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timingFunction(for: returning ? .easeInOut : profile.pathEasing)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.evasionState.movementCompleted(at: Date())
                self.syncEvasionPresentation()
                self.evaluateEvasion()
            }
        }
    }

    private func timingFunction(for easing: EvasionPathEasing) -> CAMediaTimingFunction {
        switch easing {
        case .spring:
            CAMediaTimingFunction(controlPoints: 0.18, 0.88, 0.28, 1.18)
        case .easeInOut:
            CAMediaTimingFunction(name: .easeInEaseOut)
        case .linear:
            CAMediaTimingFunction(name: .linear)
        case .overdamped:
            CAMediaTimingFunction(controlPoints: 0.12, 0.72, 0.22, 1.0)
        }
    }

    private func setFrame(_ frame: NSRect, for panel: NSPanel, animated: Bool) {
        ignoreMoveNotificationsUntil = Date().addingTimeInterval(animated ? 0.5 : 0.15)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func applyGhostMode() {
        guard let panel = petWindow, fallbackMode != .ghost else { return }
        fallbackMode = .ghost
        panel.alphaValue = 0.15
        panel.ignoresMouseEvents = true
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func applyHiddenMode() {
        guard let panel = petWindow, fallbackMode != .hidden else { return }
        fallbackMode = .hidden
        panel.orderOut(nil)
    }

    private func restorePanelAppearance() {
        guard let panel = petWindow, fallbackMode != .none else { return }
        fallbackMode = .none
        panel.alphaValue = isPassThroughActive ? Self.passThroughAlpha : 1
        panel.ignoresMouseEvents = isPassThroughActive
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func disableActiveEvasion() {
        let now = Date()
        evasionState.resetForManualPlacement(at: now)
        restorePanelAppearance()
        syncEvasionPresentation()
        guard let panel = petWindow, let homeFrame, panel.frame != homeFrame else { return }
        setFrame(homeFrame, for: panel, animated: true)
    }

    private func syncEvasionPresentation() {
        evasionPresentation.phase = evasionState.phase
        evasionPresentation.phaseStartedAt = evasionState.phaseStartedAt
    }

    private func emitSessionCueIfNeeded() {
        guard !hasEmittedSessionCue else { return }
        let profile = EvasionProfiles.profile(for: evasionPresentation.style)
        guard profile.voiceLine != nil || profile.soundEffect != nil else { return }
        hasEmittedSessionCue = true
        evasionPresentation.cueVoiceLine = profile.voiceLine
        evasionPresentation.cueSoundEffect = profile.soundEffect
        evasionPresentation.cueSequence += 1
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              panel === petWindow,
              !isReaderExpanded,
              Date() >= ignoreMoveNotificationsUntil else {
            return
        }
        let now = Date()
        homeFrame = panel.frame
        lastManualPlacementAt = now
        PetHomePositionStore.save(panel.frame.origin)
        evasionState.resetForManualPlacement(at: now)
        dodge.cancelForManualPlacement()
        restorePanelAppearance()
        syncEvasionPresentation()
    }

    // MARK: - See-through and button-aware dodge

    private static let passThroughAlpha: CGFloat = 0.22

    private func startPassThroughMonitoring() {
        guard passThroughTimer == nil else { return }
        // Reading the pointer and modifier state is cheap and needs no
        // permission; 20 Hz keeps the see-through responsive.
        passThroughTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePassThrough()
            }
        }
    }

    private func stopPassThroughMonitoring() {
        passThroughTimer?.invalidate()
        passThroughTimer = nil
        isPassThroughActive = false
        dodge = PetDodgeStateMachine()
    }

    private func updatePassThrough() {
        guard let panel = petWindow, panel.isVisible, !isReaderExpanded else { return }
        let pointer = NSEvent.mouseLocation

        // Hold Option over the pet to see through it and click what it covers.
        let wantsSeeThrough = NSEvent.modifierFlags.contains(.option) && panel.frame.contains(pointer)
        if wantsSeeThrough != isPassThroughActive {
            isPassThroughActive = wantsSeeThrough
            if fallbackMode == .none {
                panel.alphaValue = wantsSeeThrough ? Self.passThroughAlpha : 1
                panel.ignoresMouseEvents = wantsSeeThrough
            }
        }

        guard PetPassThroughSettingsStore.isDodgeEnabled, !isPassThroughActive else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let buttonsPressed = NSEvent.pressedMouseButtons != 0

        if dodge.isEntering(pointer: pointer, petFrame: panel.frame), !dodge.isDodged, !buttonsPressed,
           !isDodgeQueryInFlight, let pid = processUnderPet(at: pointer, excluding: panel) {
            isDodgeQueryInFlight = true
            let accessibilityPoint = CGPoint(x: pointer.x, y: mainScreenTop() - pointer.y)
            Task { @MainActor in
                let target = await pointerTargetClient.target(at: accessibilityPoint, inProcess: pid)
                isDodgeQueryInFlight = false
                guard let target, target.isActionable,
                      let panel = petWindow, panel.frame.contains(NSEvent.mouseLocation) else { return }
                applyDodge(dodge.update(
                    pointer: NSEvent.mouseLocation, petFrame: panel.frame, visible: visible,
                    underneathIsActionable: true, buttonsPressed: NSEvent.pressedMouseButtons != 0, now: Date()
                ))
            }
        }
        applyDodge(dodge.update(
            pointer: pointer, petFrame: panel.frame, visible: visible,
            underneathIsActionable: nil, buttonsPressed: buttonsPressed, now: Date()
        ))
    }

    private func applyDodge(_ action: PetDodgeStateMachine.Action) {
        guard let panel = petWindow else { return }
        let target: NSRect
        switch action {
        case .none: return
        case let .move(to): target = to
        case let .returnTo(home): target = home
        }
        ignoreMoveNotificationsUntil = Date().addingTimeInterval(0.45)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1.0)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// The app whose window lies under the pet at `point` (front to back).
    private func processUnderPet(at point: NSPoint, excluding panel: NSPanel) -> Int32? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let panelID = CGWindowID(panel.windowNumber)
        return evasionProvider.onScreenWindows().first {
            $0.id != panelID && $0.ownerPID != ownPID && $0.frame.contains(point)
        }?.ownerPID
    }

    private func mainScreenTop() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    private func clamped(_ frame: NSRect, inside visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }
}

private enum EvasionFallbackMode {
    case none
    case ghost
    case hidden
}

private enum PetHomePositionStore {
    private static let xKey = "Pomegranate.Pet.HomeX"
    private static let yKey = "Pomegranate.Pet.HomeY"

    static func load() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: xKey) != nil, defaults.object(forKey: yKey) != nil else {
            return nil
        }
        return NSPoint(x: defaults.double(forKey: xKey), y: defaults.double(forKey: yKey))
    }

    static func save(_ origin: NSPoint) {
        UserDefaults.standard.set(origin.x, forKey: xKey)
        UserDefaults.standard.set(origin.y, forKey: yKey)
    }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
