import AppKit
import Metal
import MetalKit
import simd

import ArilsCore
import ArilsRig

/// A drag over the view, reported in source-image pixel coordinates so the
/// engine can hit-test against rig geometry without knowing view math.
public struct AvatarDragEvent: Sendable, Equatable {
    public enum Phase: Sendable {
        case began
        case moved
        case ended
    }

    public var phase: Phase
    /// Position in source-image pixels (y down, matching rig space).
    public var imagePoint: SIMD2<Float>
    /// Velocity in image pixels per second.
    public var velocity: SIMD2<Float>
}

/// The AppKit host view: owns the Metal renderer, tracks the mouse, and pulls
/// one parameter frame per drawn frame from `parameterProvider`.
///
/// Deliberately passive — it knows nothing about motion. The umbrella
/// `CharacterEngine` plugs the motion controller in via the provider closure
/// and consumes hover/drag events for gaze and petting.
public final class AvatarMetalView: MTKView {
    /// Called once per frame with the current media time; returns the resolved
    /// parameters to render.
    public var parameterProvider: ((Double) -> [ParameterID: Float])?
    /// Hover position in source-image pixels, nil when the pointer leaves.
    public var onHoverChanged: ((SIMD2<Float>?) -> Void)?
    /// Press-drag strokes (petting input).
    public var onDrag: ((AvatarDragEvent) -> Void)?
    /// A click that never turned into a drag (host apps use this for
    /// tap-to-interact, since this view consumes mouse events).
    public var onTap: (() -> Void)?
    /// Quality containers disable a fully transparent view so a hidden
    /// front/profile renderer does not keep submitting 60 FPS Metal work.
    /// Window occlusion and this explicit gate are combined; neither can
    /// accidentally resume the other one's paused view.
    public var isRenderingEnabled = true {
        didSet { refreshPausedState() }
    }
    /// Monotonic render-submission counter used by diagnostics and demos.
    /// It deliberately avoids callbacks in the hot path.
    public private(set) var renderedFrameCount: UInt64 = 0

    private var renderer: MetalAvatarRenderer?
    private let imageSize: SIMD2<Float>
    private var activeTrackingArea: NSTrackingArea?
    private var lastDragPoint: SIMD2<Float>?
    private var lastDragTimestamp: TimeInterval = 0
    private var dragTravel: Float = 0
    /// `nonisolated(unsafe)`: only written on MainActor; read once in deinit
    /// after all MainActor work has ceased, so the access cannot race.
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?

    public init(avatar: RiggedAvatar) throws {
        self.imageSize = SIMD2(Float(avatar.rig.imageWidth), Float(avatar.rig.imageHeight))
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)

        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        layer?.isOpaque = false

        if let device {
            renderer = try MetalAvatarRenderer(
                device: device,
                avatar: avatar,
                colorPixelFormat: colorPixelFormat
            )
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("AvatarMetalView does not support NSCoder")
    }

    public override var isFlipped: Bool { true }

    // MARK: - Frame loop

    public override func draw(_ dirtyRect: NSRect) {
        guard let renderer,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable else {
            return
        }
        let parameters = parameterProvider?(CACurrentMediaTime()) ?? [:]
        renderer.draw(
            parameters: parameters,
            renderPassDescriptor: descriptor,
            drawable: drawable,
            drawableSize: drawableSize
        )
        renderedFrameCount &+= 1
    }

    // MARK: - Power: pause rendering while the window is invisible

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        guard let window else {
            refreshPausedState()
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let self, notification.object is NSWindow else { return }
            MainActor.assumeIsolated {
                self.refreshPausedState()
            }
        }
        refreshPausedState()
    }

    private func refreshPausedState() {
        guard isRenderingEnabled else {
            isPaused = true
            return
        }
        guard let window else {
            isPaused = true
            return
        }
        isPaused = !window.occlusionState.contains(.visible)
    }

    deinit {
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Coordinate mapping

    /// View point (flipped coordinates) → source-image pixels via the same
    /// centered aspect-fit the renderer uses.
    public func imagePoint(fromViewPoint point: CGPoint) -> SIMD2<Float> {
        let viewW = Float(bounds.width)
        let viewH = Float(bounds.height)
        guard viewW > 0, viewH > 0, imageSize.x > 0, imageSize.y > 0 else { return .zero }
        let fit = min(viewW / imageSize.x, viewH / imageSize.y)
        let originX = (viewW - imageSize.x * fit) / 2
        let originY = (viewH - imageSize.y * fit) / 2
        return SIMD2(
            (Float(point.x) - originX) / fit,
            (Float(point.y) - originY) / fit
        )
    }

    // MARK: - Mouse tracking

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let activeTrackingArea {
            removeTrackingArea(activeTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            // Floating pet panels deliberately do not steal key-window focus.
            // Keep gaze/petting hover active there as well as in the editor.
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        activeTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onHoverChanged?(imagePoint(fromViewPoint: point))
    }

    public override func mouseExited(with event: NSEvent) {
        onHoverChanged?(nil)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = imagePoint(fromViewPoint: convert(event.locationInWindow, from: nil))
        lastDragPoint = point
        lastDragTimestamp = event.timestamp
        dragTravel = 0
        onDrag?(AvatarDragEvent(phase: .began, imagePoint: point, velocity: .zero))
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(fromViewPoint: convert(event.locationInWindow, from: nil))
        let dt = Float(event.timestamp - lastDragTimestamp)
        let velocity: SIMD2<Float>
        if let last = lastDragPoint, dt > 0.0005 {
            velocity = (point - last) / dt
        } else {
            velocity = .zero
        }
        if let last = lastDragPoint {
            dragTravel += simd_distance(point, last)
        }
        lastDragPoint = point
        lastDragTimestamp = event.timestamp
        onDrag?(AvatarDragEvent(phase: .moved, imagePoint: point, velocity: velocity))
        // Dragging also updates the hover/gaze position.
        onHoverChanged?(point)
    }

    public override func mouseUp(with event: NSEvent) {
        let point = imagePoint(fromViewPoint: convert(event.locationInWindow, from: nil))
        lastDragPoint = nil
        onDrag?(AvatarDragEvent(phase: .ended, imagePoint: point, velocity: .zero))
        // A press that never traveled is a tap (threshold in image pixels).
        if dragTravel < max(4, imageSize.x * 0.01) {
            onTap?()
        }
    }
}
