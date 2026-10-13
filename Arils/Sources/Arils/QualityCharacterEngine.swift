import AppKit
import Foundation
import simd

import ArilsCore
import ArilsMotion
import ArilsRig

public struct QualityRenderActivitySnapshot: Sendable, Equatable {
    public var activeRendererCount: Int
    public var totalRenderedFrames: UInt64

    public init(activeRendererCount: Int, totalRenderedFrames: UInt64) {
        self.activeRendererCount = activeRendererCount
        self.totalRenderedFrames = totalRenderedFrames
    }
}

/// Two-view companion to `CharacterEngine` for Arils-2D-Quality. Standard
/// Arils remains a separate, always available rendering mode.
@MainActor
public final class QualityCharacterEngine {
    public private(set) var archive: QualityAvatarArchive
    public let front: CharacterEngine
    public let side: CharacterEngine

    /// -1...1 view direction. The supplied side image is used only in its
    /// declared direction; the opposite direction stays frontal rather than
    /// silently mirroring asymmetric artwork.
    public var viewTurn: Float {
        get { storedViewTurn }
        set {
            storedViewTurn = Self.normalized(newValue)
            synchronizeManualTurnModel()
            updateViews()
        }
    }

    /// -1...1 vertical view direction (positive = up). Pitch is reconstructed
    /// from the frontal depth rig. It fades back to neutral while the supplied
    /// profile image crossfades in because that reference contains no reliable
    /// top/bottom geometry.
    public var viewPitch: Float {
        get { storedViewPitch }
        set {
            storedViewPitch = Self.normalized(newValue)
            synchronizeManualTurnModel()
            updateViews()
        }
    }

    /// When true (the default), `viewTurn` and `viewPitch` are driven
    /// automatically from the gaze target: the character turns toward a
    /// pointer or external gaze target and eases back to frontal when it
    /// returns to center or disappears (see
    /// `QualityTurnModel` for the dead zone/saturation behavior). Set false
    /// to drive both axes manually.
    public var automaticTurn = true {
        didSet {
            if automaticTurn != oldValue {
                // Manual control may have moved far from the model's last
                // value. Resume from the visible pose instead of snapping to
                // stale spring state on the first automatic tick.
                turnModel.snap(turn: viewTurn, pitch: viewPitch)
                updateTurnTask()
            }
        }
    }
    /// Chooses the Quality presentation without rebuilding the archive.
    /// `true`: depth-rig small turns then profile crossfade. `false`: classic
    /// front/profile 2D crossfade with the frontal depth rotation held at 0.
    public var hybrid3DEnabled = true {
        didSet {
            archive.preferredPresentationMode = hybrid3DEnabled ? .threeD : .twoD
            updateViews()
        }
    }
    public var isSpeaking = false {
        didSet { front.isSpeaking = isSpeaking; side.isSpeaking = isSpeaking }
    }
    public var energy: Float = 0.5 {
        didSet { front.energy = energy; side.energy = energy }
    }
    public var behavior: MotionBehavior = .idle {
        didSet { front.behavior = behavior; side.behavior = behavior }
    }
    public var hesitation: Float? {
        didSet { front.hesitation = hesitation; side.hesitation = hesitation }
    }
    public var listenerVoiceLevel: Float? {
        didSet { front.listenerVoiceLevel = listenerVoiceLevel; side.listenerVoiceLevel = listenerVoiceLevel }
    }
    public var externalGazeTarget: SIMD2<Float>? {
        get { storedExternalGazeTarget }
        set {
            storedExternalGazeTarget = Self.sanitizedGazeTarget(newValue)
            front.externalGazeTarget = storedExternalGazeTarget
            side.externalGazeTarget = storedExternalGazeTarget
        }
    }
    /// Camera face performance forwarded to both source views. In automatic
    /// mode its pose also steers the Quality view selection, so the final yaw
    /// override does not erase the tracking layer's intent.
    public var faceTrackingInput: FaceTrackingInput? {
        get { storedFaceTrackingInput }
        set {
            storedFaceTrackingInput = newValue
            front.faceTrackingInput = newValue
            side.faceTrackingInput = newValue
        }
    }
    public var faceTrackingBlend: Float {
        get { front.faceTrackingBlend }
        set {
            front.faceTrackingBlend = newValue
            side.faceTrackingBlend = newValue
        }
    }
    public var onTap: (() -> Void)? {
        didSet { wireTapHandlers() }
    }

    private let containers = NSHashTable<QualityAvatarContainerView>.weakObjects()
    private var storedViewTurn: Float = 0
    private var storedViewPitch: Float = 0
    private var storedExternalGazeTarget: SIMD2<Float>?
    private var storedFaceTrackingInput: FaceTrackingInput?
    private var turnModel = QualityTurnModel()
    private var turnTask: Task<Void, Never>?
    private static let turnTickInterval: TimeInterval = 1.0 / 30.0

    public init(
        archive: QualityAvatarArchive,
        configuration: CharacterEngine.Configuration = .init()
    ) throws {
        self.archive = archive
        self.front = CharacterEngine(avatar: try archive.front.makeAvatar(), configuration: configuration)
        self.side = CharacterEngine(avatar: try archive.side.makeAvatar(), configuration: configuration)
        self.turnModel.poseLimits = self.front.poseLimits
        self.hybrid3DEnabled = archive.preferredPresentationMode == .threeD
        wireTapHandlers()
        updateViews()
        updateTurnTask()
    }

    deinit {
        turnTask?.cancel()
    }

    public convenience init(
        archiveData: Data,
        configuration: CharacterEngine.Configuration = .init()
    ) throws {
        try self.init(archive: QualityAvatarArchive(data: archiveData), configuration: configuration)
    }

    public var sideBlend: Float {
        if hybrid3DEnabled {
            return QualityHybridTurnModel.profileBlend(
                viewTurn: viewTurn,
                sideDirection: archive.sideDirection,
                validatedPoseLimits: front.poseLimits
            )
        }
        let direction: Float = archive.sideDirection == .right ? 1 : -1
        return min(max(viewTurn * direction, 0), 1)
    }

    public func makeView() -> NSView {
        let container = QualityAvatarContainerView(
            frontView: front.makeView(),
            sideView: side.makeView(),
            registration: archive.registration,
            frontImageSize: CGSize(width: archive.front.rig.imageWidth, height: archive.front.rig.imageHeight),
            sideImageSize: CGSize(width: archive.side.rig.imageWidth, height: archive.side.rig.imageHeight)
        )
        containers.add(container)
        container.update(blend: sideBlend)
        return container
    }

    /// Current live-view activity. Sampling `totalRenderedFrames` twice gives
    /// actual renderer submissions per second without adding work per frame.
    public func renderActivitySnapshot() -> QualityRenderActivitySnapshot {
        containers.allObjects.reduce(
            QualityRenderActivitySnapshot(activeRendererCount: 0, totalRenderedFrames: 0)
        ) { total, container in
            let sample = container.renderActivitySnapshot()
            return QualityRenderActivitySnapshot(
                activeRendererCount: total.activeRendererCount + sample.activeRendererCount,
                totalRenderedFrames: total.totalRenderedFrames &+ sample.totalRenderedFrames
            )
        }
    }

    public func pushSpeechSamples(_ samples: [Float], sampleRate: Double) {
        front.pushSpeechSamples(samples, sampleRate: sampleRate)
        side.pushSpeechSamples(samples, sampleRate: sampleRate)
    }

    public func pushSpeechLevel(_ level: Float) {
        front.pushSpeechLevel(level)
        side.pushSpeechLevel(level)
    }

    public func playSpeechTimeline(_ timeline: LipSyncTimeline, clock: @escaping @MainActor () -> Double?) {
        front.playSpeechTimeline(timeline, clock: clock)
        side.playSpeechTimeline(timeline, clock: clock)
    }

    public func stopSpeechTimeline() {
        front.stopSpeechTimeline()
        side.stopSpeechTimeline()
    }

    /// Both views share one seed, so a micro-action stays in step across them.
    public func triggerMicroAction(_ kind: MicroActionLayer.Kind) {
        front.triggerMicroAction(kind)
        side.triggerMicroAction(kind)
    }

    private func wireTapHandlers() {
        front.onTap = { [weak self] in self?.onTap?() }
        side.onTap = { [weak self] in self?.onTap?() }
    }

    private func synchronizeManualTurnModel() {
        guard !automaticTurn else { return }
        turnModel.snap(turn: viewTurn, pitch: viewPitch)
    }

    private static func normalized(_ value: Float) -> Float {
        value.isFinite ? min(max(value, -1), 1) : 0
    }

    private static func sanitizedGazeTarget(_ target: SIMD2<Float>?) -> SIMD2<Float>? {
        guard let target, target.x.isFinite, target.y.isFinite else { return nil }
        return simd_clamp(target, SIMD2(-1, -1), SIMD2(1, 1))
    }

    // MARK: - Automatic turning

    private func updateTurnTask() {
        turnTask?.cancel()
        turnTask = nil
        guard automaticTurn else { return }
        turnTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.turnTickInterval * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                // Optional chaining keeps the strong reference scoped to this
                // statement rather than across the next suspension point.
                self?.tickAutomaticTurn()
            }
        }
    }

    private func tickAutomaticTurn() {
        // Both views track the pointer (hidden one included), so take whichever
        // engine currently sees a target; external targets are mirrored to both.
        let gaze = front.currentGazeTarget ?? side.currentGazeTarget
        let trackingWeight = Self.trackingWeight(
            input: storedFaceTrackingInput,
            blend: faceTrackingBlend
        )
        let poseTurn = storedFaceTrackingInput.flatMap {
            Self.normalizedTrackingAngle($0.yawDegrees, fullAt: 18)
        }
        let posePitch = storedFaceTrackingInput.flatMap {
            Self.normalizedTrackingAngle($0.pitchDegrees, fullAt: 12)
        }
        let gazeX = Self.mixedTrackingTarget(
            gaze: gaze?.x,
            pose: poseTurn,
            weight: trackingWeight
        )
        let gazeY = Self.mixedTrackingTarget(
            gaze: gaze?.y,
            pose: posePitch,
            weight: trackingWeight
        )
        let turn = turnModel.step(
            gazeX: gazeX,
            sideDirection: archive.sideDirection,
            deltaTime: Float(Self.turnTickInterval)
        )
        let pitch = turnModel.stepPitch(
            gazeY: gazeY,
            deltaTime: Float(Self.turnTickInterval)
        )
        if abs(turn - viewTurn) > 0.0005 {
            viewTurn = turn
        }
        if abs(pitch - viewPitch) > 0.0005 {
            viewPitch = pitch
        }
    }

    private static func trackingWeight(input: FaceTrackingInput?, blend: Float) -> Float {
        guard let input, input.confidence.isFinite, blend.isFinite else {
            return 0
        }
        return min(max(input.confidence, 0), 1) * min(max(blend, 0), 1)
    }

    private static func normalizedTrackingAngle(_ angle: Float, fullAt: Float) -> Float? {
        guard angle.isFinite, fullAt > 0 else {
            return nil
        }
        return min(max(angle / fullAt, -1), 1)
    }

    private static func mixedTrackingTarget(
        gaze: Float?,
        pose: Float?,
        weight: Float
    ) -> Float? {
        let finiteGaze = gaze.flatMap { $0.isFinite ? min(max($0, -1), 1) : nil }
        guard let pose, weight > 0 else {
            return finiteGaze
        }
        return min(max((finiteGaze ?? 0) * (1 - weight) + pose * weight, -1), 1)
    }

    private func updateViews() {
        // The depth rig owns the shared supported yaw range. Beyond 0.35
        // progress it stays at the limit while the supported profile image
        // fades in. Archive-build underpaint uses this same limit.
        if hybrid3DEnabled {
            let requestedYaw = viewTurn / 0.35 * SupportedHeadPose.maximumYawDegrees
            front.viewAngleXOverride = front.poseLimits.clampedYaw(requestedYaw)
            // Only the frontal archive has reconstructed depth. Attenuating
            // pitch as the profile fades in keeps its static neck registration
            // intact instead of feeding the same angle into a mismatched v1
            // translate/perspective warp.
            let pitchAvailability = 1 - sideBlend
            // Six degrees remains readable because the whole bounded face
            // plate now participates in pitch. Larger angles expose crown and
            // chin surfaces that neither input image contains and reintroduce
            // a compressed-cardboard appearance.
            let limits = front.poseLimits
            let requestedPitch = viewPitch >= 0
                ? viewPitch * limits.maximumPitchDegrees
                : -abs(viewPitch) * abs(limits.minimumPitchDegrees)
            front.viewAngleYOverride = requestedPitch * pitchAvailability
            // Suppress the profile engine's own gaze pitch while keeping its
            // idle and transient (e.g. sneeze) contributions.
            side.viewAngleYOverride = 0
            // The profile image is a target view, not another independently
            // yawing camera. Leaving its legacy perspectiveShift active drove
            // it a second time from the same gaze used by `viewTurn`.
            side.viewAngleXOverride = 0
        } else {
            // v2 uses real rotate3D, so classic 2D mode holds it frontal.
            // Legacy v1 archives retain their motion-generated angleX and
            // perspectiveShift exactly as they behaved before 3D existed.
            front.viewAngleXOverride = front.avatar.rig.formatVersion >= 2 ? 0 : nil
            front.viewAngleYOverride = nil
            side.viewAngleYOverride = nil
            side.viewAngleXOverride = 0
        }
        let blend = sideBlend
        for container in containers.allObjects {
            container.update(blend: blend)
        }
    }
}

private final class QualityAvatarContainerView: NSView {
    private let frontView: NSView
    private let sideView: NSView
    private let registration: QualityViewRegistration
    private let frontImageSize: CGSize
    private let sideImageSize: CGSize

    init(
        frontView: NSView,
        sideView: NSView,
        registration: QualityViewRegistration,
        frontImageSize: CGSize,
        sideImageSize: CGSize
    ) {
        self.frontView = frontView
        self.sideView = sideView
        self.registration = registration
        self.frontImageSize = frontImageSize
        self.sideImageSize = sideImageSize
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(frontView)
        addSubview(sideView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("QualityAvatarContainerView does not support NSCoder") }

    // `registration.frontNeck`/`sideNeck` are normalized image coordinates
    // with Y down; flipping the container to match means subview frames can
    // be reasoned about directly in that same top-left-origin space below.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        frontView.frame = bounds
        sideView.frame = QualityRegistrationLayout.sideFrame(
            bounds: bounds,
            frontImageSize: frontImageSize,
            sideImageSize: sideImageSize,
            registration: registration
        )
    }

    func update(blend: Float) {
        let clamped = CGFloat(min(max(blend, 0), 1))
        // Resume before making a view visible; pause only when its alpha is
        // effectively zero. During the transition both views remain live.
        setRenderingEnabled(clamped < 0.999, in: frontView)
        setRenderingEnabled(clamped > 0.001, in: sideView)
        frontView.alphaValue = 1 - clamped
        sideView.alphaValue = clamped
        needsLayout = true
    }

    private func setRenderingEnabled(_ enabled: Bool, in view: NSView) {
        if let metalView = view as? AvatarMetalView {
            metalView.isRenderingEnabled = enabled
        }
        for child in view.subviews {
            setRenderingEnabled(enabled, in: child)
        }
    }

    func renderActivitySnapshot() -> QualityRenderActivitySnapshot {
        let views = metalViews(in: self)
        return QualityRenderActivitySnapshot(
            activeRendererCount: views.filter { $0.isRenderingEnabled && !$0.isPaused }.count,
            totalRenderedFrames: views.reduce(0) { $0 &+ $1.renderedFrameCount }
        )
    }

    private func metalViews(in view: NSView) -> [AvatarMetalView] {
        var result: [AvatarMetalView] = []
        if let metalView = view as? AvatarMetalView {
            result.append(metalView)
        }
        for child in view.subviews {
            result.append(contentsOf: metalViews(in: child))
        }
        return result
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        sideView.alphaValue > 0.5 ? sideView.hitTest(convert(point, to: sideView)) : frontView.hitTest(convert(point, to: frontView))
    }
}
