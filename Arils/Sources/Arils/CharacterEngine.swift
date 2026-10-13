import AppKit
import CoreGraphics
import Foundation
import simd

import ArilsCore
import ArilsMotion
import ArilsRender
import ArilsRig

/// The one-object API for hosts: rig an image (or load an archive), get a
/// view, feed it the outside world.
///
///     let engine = try await CharacterEngine.make(image: cgImage)
///     someWindow.contentView = engine.makeView()   // or AvatarView(engine:) in SwiftUI
///     engine.isSpeaking = true
///     engine.pushSpeechSamples(pcm, sampleRate: 24_000)
///
/// The engine wires the three subsystems together but owns almost no logic
/// itself: rigging lives behind `RiggingPipeline`, per-frame motion in
/// `MotionController`, drawing in `AvatarMetalView`/`MetalAvatarRenderer`.
/// Any of the three can be replaced without touching the others.
@MainActor
public final class CharacterEngine {
    public struct Configuration: Sendable {
        /// Seed for all stochastic motion; same seed → same animation.
        public var motionSeed: UInt64
        public var preferredFramesPerSecond: Int
        /// Mean seconds between spontaneous sneezes; `.infinity` disables them.
        public var sneezeInterval: Double
        /// Motion temperament (hesitation, snappiness, fidgeting, shyness...).
        public var personality: MotionPersonality
        /// Spontaneous glances, weight shifts, sighs, yawns, and dozing off.
        public var microActionsEnabled: Bool
        /// Lets the head turn and tilt beyond the range the archive build
        /// validated (`ExtendedHeadRange`). Edges the image does not contain
        /// can show at the extremes.
        public var extendedHeadRange: Bool

        public init(
            motionSeed: UInt64 = 0x0A71_15EE_D5EE_D001,
            preferredFramesPerSecond: Int = 60,
            sneezeInterval: Double = 240,
            personality: MotionPersonality = .standard,
            microActionsEnabled: Bool = true,
            extendedHeadRange: Bool = false
        ) {
            self.motionSeed = motionSeed
            self.preferredFramesPerSecond = preferredFramesPerSecond
            self.sneezeInterval = sneezeInterval
            self.personality = personality
            self.microActionsEnabled = microActionsEnabled
            self.extendedHeadRange = extendedHeadRange
        }
    }

    /// The opt-in wider head range: gaze drives the head this much harder,
    /// and host-driven poses may go this far past the validated limits.
    public enum ExtendedHeadRange {
        public static let headTurnGain: Float = 2
        public static let poseLimitFactor: Float = 1.5
    }

    public let avatar: RiggedAvatar
    public let configuration: Configuration

    /// The head pose range this engine allows: the archive's validated
    /// limits, widened when `extendedHeadRange` is on.
    public var poseLimits: ValidatedPoseLimits {
        configuration.extendedHeadRange
            ? avatar.rig.validatedPoseLimits.scaled(by: ExtendedHeadRange.poseLimitFactor)
            : avatar.rig.validatedPoseLimits
    }

    /// True while the character is speaking (drives the mouth fallback and
    /// tells lip sync to expect audio).
    public var isSpeaking = false
    /// Arousal 0...1; scales idle-motion amplitude and breathing rate.
    public var energy: Float = 0.5
    /// What the character is doing in the conversation (posture, gaze
    /// strategy, blink rate, gestures). Changes are carried out hesitantly.
    public var behavior: MotionBehavior = .idle
    /// Momentary unsureness 0...1 (nil = the personality's resting value),
    /// e.g. from a low-confidence reply.
    public var hesitation: Float?
    /// 0...1 level of the user's voice while listening, for backchannel nods
    /// at the user's pauses (nil = unknown; nods follow a gentle schedule).
    public var listenerVoiceLevel: Float?
    /// Optional external gaze target, normalized -1...1 (x right, y up),
    /// e.g. from a camera face position. Takes precedence over the pointer.
    public var externalGazeTarget: SIMD2<Float>?
    /// Latest local face-landmark sample supplied by the host. The motion
    /// controller treats it as a secondary bias, never as an ownership
    /// override for authored blink, gaze, lip sync, or idle motion.
    public var faceTrackingInput: FaceTrackingInput?
    /// 0...1 camera-performance contribution. The conservative default keeps
    /// Arils motion visible while making a tracked face readable.
    public var faceTrackingBlend: Float {
        get { storedFaceTrackingBlend }
        set {
            storedFaceTrackingBlend = newValue.isFinite
                ? min(max(newValue, 0), 1)
                : 0
        }
    }
    /// Optional renderer-facing yaw override in degrees. Quality uses this to
    /// make manual and automatic hybrid turns drive the v2 depth rig exactly;
    /// Standard engines leave it nil and retain motion-generated yaw.
    public var viewAngleXOverride: Float?
    /// Optional host-driven pitch in degrees (positive = up). It replaces the
    /// gaze layer's head-pitch contribution while preserving idle drift and
    /// transient motion such as sneezes.
    public var viewAngleYOverride: Float?
    /// Called when the user clicks the character without dragging. The engine
    /// view consumes mouse events, so hosts hook tap-to-interact here.
    public var onTap: (() -> Void)?

    private let controller: MotionController
    private nonisolated let lipSyncAnalyzer = LipSyncAnalyzer()
    private var speechTimeline: LipSyncTimeline?
    private var speechClock: (@MainActor () -> Double?)?
    private var storedFaceTrackingBlend: Float = 0.65

    // Pointer/petting state fed by the view.
    private var hoverImagePoint: SIMD2<Float>?
    private var isDragging = false
    private var dragImagePoint: SIMD2<Float>?
    private var dragVelocity = SIMD2<Float>.zero
    private var lastDragEventAt: Double = -.greatestFiniteMagnitude

    // Cached rig geometry for input mapping.
    private let imageSize: SIMD2<Float>
    private let headRect: CGRect

    // MARK: - Creation

    public init(avatar: RiggedAvatar, configuration: Configuration = Configuration()) {
        self.avatar = avatar
        self.configuration = configuration
        self.imageSize = SIMD2(Float(avatar.rig.imageWidth), Float(avatar.rig.imageHeight))
        self.headRect = avatar.rig.firstPart(ofKind: .head)?.rect
            ?? CGRect(
                x: 0, y: 0,
                width: CGFloat(avatar.rig.imageWidth),
                height: CGFloat(avatar.rig.imageHeight) / 2
            )

        var motionConfiguration = MotionController.Configuration(
            seed: configuration.motionSeed,
            sneezeInterval: configuration.sneezeInterval,
            personality: configuration.personality,
            microActionsEnabled: configuration.microActionsEnabled,
            headTurnGain: configuration.extendedHeadRange ? ExtendedHeadRange.headTurnGain : 1
        )
        motionConfiguration.swayChannels = avatar.rig.physics.channels.map { channel in
            SwayChannelSettings(
                output: channel.output,
                frequency: channel.frequency,
                dampingRatio: channel.dampingRatio,
                headDrive: channel.headDrive,
                breeze: channel.breeze
            )
        }
        self.controller = MotionController(
            descriptors: avatar.rig.parameters,
            configuration: motionConfiguration
        )
    }

    /// Auto-rigs `image` (one-time cost; archive the result via `archiveData()`
    /// and reload with `init(archiveData:)` on later launches).
    public static func make(
        image: CGImage,
        configuration: Configuration = Configuration(),
        pipeline: any RiggingPipeline = AutoRigPipeline()
    ) async throws -> CharacterEngine {
        let avatar = try await pipeline.makeAvatar(from: image)
        return CharacterEngine(avatar: avatar, configuration: configuration)
    }

    public convenience init(archiveData: Data, configuration: Configuration = Configuration()) throws {
        let archive = try AvatarArchive(data: archiveData)
        self.init(avatar: try archive.makeAvatar(), configuration: configuration)
    }

    public func archiveData() throws -> Data {
        try AvatarArchive(avatar: avatar).data()
    }

    // MARK: - View

    /// Creates a rendering view wired to this engine. Multiple views share the
    /// same motion state. Returns a plain empty view if Metal is unavailable.
    public func makeView() -> NSView {
        guard let view = try? AvatarMetalView(avatar: avatar) else {
            return NSView()
        }
        view.preferredFramesPerSecond = configuration.preferredFramesPerSecond
        view.parameterProvider = { [weak self] time in
            self?.parameters(at: time) ?? [:]
        }
        view.onHoverChanged = { [weak self] point in
            self?.hoverImagePoint = point
        }
        view.onDrag = { [weak self] event in
            self?.handleDrag(event)
        }
        view.onTap = { [weak self] in
            self?.onTap?()
        }
        return view
    }

    // MARK: - Per-frame

    /// Resolves one parameter frame. Rendering views call this automatically;
    /// call it directly when driving a custom renderer.
    public func parameters(at time: Double) -> [ParameterID: Float] {
        var values = controller.update(at: time, inputs: currentInputs(at: time))
        if let viewAngleXOverride, viewAngleXOverride.isFinite {
            values[.angleX] = poseLimits.clampedYaw(viewAngleXOverride)
        }
        return values
    }

    /// Makes the character sneeze on the next frame (they also sneeze
    /// spontaneously; see `Configuration.sneezeInterval`).
    public func triggerSneeze() {
        controller.requestSneeze()
    }

    /// Starts a micro-action (yawn, doze, glance...) on the next frame.
    public func triggerMicroAction(_ kind: MicroActionLayer.Kind) {
        controller.requestMicroAction(kind)
    }

    /// The gaze target the motion system currently sees: the external target
    /// if set, else the pointer hovering the view, normalized -1...1 around
    /// the head (x right, y up). nil when nothing is being watched. Exposed so
    /// wrappers (the Quality two-view engine) can derive behavior — like
    /// turning toward whatever the character is looking at.
    public var currentGazeTarget: SIMD2<Float>? {
        sanitizedExternalGazeTarget ?? hoverImagePoint.map(gazeTarget(fromImagePoint:))
    }

    // MARK: - Audio

    /// Feed speech PCM (safe from an audio thread).
    public nonisolated func pushSpeechSamples(_ samples: [Float], sampleRate: Double) {
        lipSyncAnalyzer.push(samples: samples, sampleRate: sampleRate)
    }

    /// Feed a pre-normalized 0...1 playback level (meter-only hosts).
    public nonisolated func pushSpeechLevel(_ level: Float) {
        lipSyncAnalyzer.push(level: level)
    }

    /// Precomputes the mouth track for a speech clip (the accurate path for
    /// TTS: centred analysis, per-clip gain, stop closures, slight lead).
    public nonisolated func makeSpeechTimeline(samples: [Float], sampleRate: Double) -> LipSyncTimeline {
        LipSyncTimeline.analyze(samples: samples, sampleRate: sampleRate)
    }

    /// Drives the mouth from `timeline` while `isSpeaking`, indexed by
    /// `clock` — the playback position in seconds (e.g. `AVAudioPlayer.currentTime`
    /// plus output latency), or nil when playback has stopped. Live pushed
    /// audio is ignored while a timeline plays.
    public func playSpeechTimeline(_ timeline: LipSyncTimeline, clock: @escaping @MainActor () -> Double?) {
        speechTimeline = timeline
        speechClock = clock
    }

    /// Returns lip sync to live pushed audio.
    public func stopSpeechTimeline() {
        speechTimeline = nil
        speechClock = nil
    }

    /// Offline analysis of a whole clip for sample-exact sync (see
    /// `LipSyncAnalyzer.analyzeTimeline`).
    public nonisolated func analyzeSpeechTimeline(
        samples: [Float],
        sampleRate: Double,
        frameRate: Double = 60
    ) -> [LipSyncFrame] {
        lipSyncAnalyzer.analyzeTimeline(samples: samples, sampleRate: sampleRate, frameRate: frameRate)
    }

    // MARK: - Input mapping

    private func currentInputs(at time: Double) -> MotionInputs {
        MotionInputs(
            pointer: sanitizedExternalGazeTarget ?? hoverImagePoint.map(gazeTarget(fromImagePoint:)),
            isSpeaking: isSpeaking,
            lipSync: isSpeaking ? currentLipSyncFrame() : nil,
            petting: currentPetting(at: time),
            energy: energy,
            headPitch: viewAngleYOverride.flatMap { value in
                value.isFinite ? poseLimits.clampedPitch(value) : nil
            },
            faceTracking: faceTrackingInput,
            faceTrackingBlend: storedFaceTrackingBlend,
            behavior: behavior,
            hesitation: hesitation.flatMap { $0.isFinite ? $0 : nil },
            listenerVoiceLevel: listenerVoiceLevel.flatMap { $0.isFinite ? $0 : nil }
        )
    }

    private func currentLipSyncFrame() -> LipSyncFrame? {
        if let speechTimeline, let speechClock {
            // While a timeline is attached, silence means a closed mouth —
            // never the procedural flap meant for audio-less speech.
            let closed = LipSyncFrame(open: 0, form: 0, smoothing: LipSyncTimeline.frameSmoothing)
            guard let position = speechClock(), position.isFinite else {
                return closed
            }
            return speechTimeline.frame(at: position) ?? closed
        }
        return lipSyncAnalyzer.currentFrame()
    }

    /// Image pixels → gaze target normalized around the head center.
    private func gazeTarget(fromImagePoint point: SIMD2<Float>) -> SIMD2<Float> {
        Self.normalizedGazeTarget(
            imagePoint: point,
            headCenter: SIMD2(Float(headRect.midX), Float(headRect.midY)),
            imageSize: imageSize
        )
    }

    /// Pure mapping used by the view and regression tests. Each direction is
    /// normalized by its own distance from the head center to the image edge,
    /// so a head near the top of a full-body image can still look fully up.
    nonisolated static func normalizedGazeTarget(
        imagePoint point: SIMD2<Float>,
        headCenter center: SIMD2<Float>,
        imageSize: SIMD2<Float>
    ) -> SIMD2<Float> {
        guard point.x.isFinite, point.y.isFinite,
              center.x.isFinite, center.y.isFinite,
              imageSize.x > 0, imageSize.y > 0 else { return .zero }
        let xSpan = point.x < center.x ? center.x : imageSize.x - center.x
        let ySpan = point.y < center.y ? center.y : imageSize.y - center.y
        return simd_clamp(
            SIMD2(
                (point.x - center.x) / max(1, xSpan),
                (center.y - point.y) / max(1, ySpan) // image y down → gaze y up
            ),
            SIMD2(-1, -1),
            SIMD2(1, 1)
        )
    }

    private var sanitizedExternalGazeTarget: SIMD2<Float>? {
        guard let target = externalGazeTarget,
              target.x.isFinite, target.y.isFinite else { return nil }
        return simd_clamp(target, SIMD2(-1, -1), SIMD2(1, 1))
    }

    private func handleDrag(_ event: AvatarDragEvent) {
        switch event.phase {
        case .began, .moved:
            // Petting only counts on the head (generously padded).
            let petZone = headRect.insetBy(dx: -headRect.width * 0.15, dy: -headRect.height * 0.15)
            let inside = petZone.contains(CGPoint(
                x: CGFloat(event.imagePoint.x),
                y: CGFloat(event.imagePoint.y)
            ))
            isDragging = inside
            dragImagePoint = event.imagePoint
            dragVelocity = event.velocity
            lastDragEventAt = CACurrentMediaTime()
        case .ended:
            isDragging = false
            dragImagePoint = nil
            dragVelocity = .zero
        }
    }

    private func currentPetting(at time: Double) -> PettingInput? {
        guard isDragging, let point = dragImagePoint else { return nil }
        let halfWidth = Float(headRect.width) / 2
        let halfHeight = Float(headRect.height) / 2
        guard halfWidth > 0, halfHeight > 0 else { return nil }

        // Velocity information decays while the hand rests in place
        // (mouseDragged only fires on movement).
        let staleness = Float(max(0, CACurrentMediaTime() - lastDragEventAt))
        let decay = exp(-staleness * 8)

        let position = simd_clamp(
            SIMD2(
                (point.x - Float(headRect.midX)) / halfWidth,
                (Float(headRect.midY) - point.y) / halfHeight
            ),
            SIMD2(-1, -1),
            SIMD2(1, 1)
        )
        let velocity = SIMD2(
            dragVelocity.x / halfWidth,
            -dragVelocity.y / halfHeight
        ) * decay
        return PettingInput(position: position, velocity: velocity)
    }
}
