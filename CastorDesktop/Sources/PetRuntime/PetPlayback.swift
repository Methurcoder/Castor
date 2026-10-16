import ArilsCore
import ArilsPlayer
import Foundation

/// Standard/Quality playback used by the Windows shell and offline checks.
/// The archive, springs and neck registration are shared with the Mac engine.
public final class PetPlayback {
    public let asset: PetAsset
    public let front: PetPlayer
    public let side: PetPlayer?
    public var automaticTurn = true
    public var viewTurn: Float = 0
    public var viewPitch: Float = 0
    public var presentationMode: QualityPresentationMode
    public var parameterOverrides: [ParameterID: Float] = [:] {
        didSet { front.parameterOverrides = parameterOverrides; side?.parameterOverrides = parameterOverrides }
    }
    private var turnModel: QualityTurnModel
    private var lastTime: Double?
    private var frontCanvas: PetCanvas?
    private var sideCanvas: PetCanvas?
    private let manual: ManualPetRenderer?

    /// `naturalFaceMotion` (beta) lets the hair beside the head follow it; manual pets are unchanged.
    public init(asset: PetAsset, wideHeadMovement: Bool = false, naturalFaceMotion: Bool = false) {
        self.asset = asset
        if case let .manual(pet) = asset { manual = ManualPetRenderer(pet: pet) } else { manual = nil }
        let following: Bool = if case .manual = asset { false } else { naturalFaceMotion }
        front = PetPlayer(archive: asset.front, wideHeadMovement: wideHeadMovement, followingHair: following)
        if case let .quality(quality) = asset {
            side = PetPlayer(archive: quality.side, wideHeadMovement: wideHeadMovement)
            presentationMode = quality.preferredPresentationMode
        } else {
            side = nil
            presentationMode = .twoD
        }
        turnModel = QualityTurnModel(poseLimits: front.poseLimits)
    }

    public var sideBlend: Float {
        guard case let .quality(quality) = asset else { return 0 }
        let turn = viewTurn.isFinite ? min(max(viewTurn, -1), 1) : 0
        if presentationMode == .threeD {
            return QualityHybridTurnModel.profileBlend(viewTurn: turn, sideDirection: quality.sideDirection,
                                                       validatedPoseLimits: front.poseLimits)
        }
        return min(max(turn * (quality.sideDirection == .right ? 1 : -1), 0), 1)
    }

    private func register(width: Int, height: Int) {
        guard case let .quality(quality) = asset, let side else { return }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let frontSize = CGSize(width: front.rig.imageWidth, height: front.rig.imageHeight)
        let sideSize = CGSize(width: side.rig.imageWidth, height: side.rig.imageHeight)
        front.imageFrame = QualityRegistrationLayout.aspectFitRect(imageSize: frontSize, in: bounds)
        side.imageFrame = QualityRegistrationLayout.sideFrame(bounds: bounds, frontImageSize: frontSize,
                                                              sideImageSize: sideSize, registration: quality.registration)
    }

    public func pointerMoved(to point: SIMD2<Float>?, canvasWidth: Int, canvasHeight: Int, time: Double) {
        manual?.pointerMoved(point, control: front, width: canvasWidth, height: canvasHeight, time: time)
        register(width: canvasWidth, height: canvasHeight)
        front.pointerMoved(to: point, canvasWidth: canvasWidth, canvasHeight: canvasHeight, time: time)
        side?.pointerMoved(to: point, canvasWidth: canvasWidth, canvasHeight: canvasHeight, time: time)
    }

    public func render(into canvas: inout PetCanvas, time: Double, opacity: Float = 1) {
        if let manual { manual.render(into: &canvas, control: front, time: time, opacity: opacity); return }
        guard case let .quality(quality) = asset, let side else {
            front.render(into: &canvas, time: time, opacity: opacity)
            return
        }
        register(width: canvas.width, height: canvas.height)
        let dt = lastTime.map { Float(min(max(time - $0, 0), 0.1)) } ?? (1 / 30)
        lastTime = time
        if automaticTurn {
            let target = front.currentGazeTarget ?? side.currentGazeTarget
            viewTurn = turnModel.step(gazeX: target?.x, sideDirection: quality.sideDirection, deltaTime: dt)
            viewPitch = turnModel.stepPitch(gazeY: target?.y, deltaTime: dt)
        } else {
            viewTurn = viewTurn.isFinite ? min(max(viewTurn, -1), 1) : 0
            viewPitch = viewPitch.isFinite ? min(max(viewPitch, -1), 1) : 0
            turnModel.snap(turn: viewTurn, pitch: viewPitch)
        }
        let blend = sideBlend
        if presentationMode == .threeD {
            front.viewAngleXOverride = front.poseLimits.clampedYaw(
                viewTurn / 0.35 * ValidatedPoseLimits.legacyDefault.maximumYawDegrees)
            let magnitude = viewPitch < 0 ? abs(front.poseLimits.minimumPitchDegrees) : front.poseLimits.maximumPitchDegrees
            front.viewAngleYOverride = viewPitch * magnitude * (1 - blend)
            side.viewAngleXOverride = 0
            side.viewAngleYOverride = 0
        } else {
            front.viewAngleXOverride = front.rig.formatVersion >= 2 ? 0 : nil
            front.viewAngleYOverride = nil
            side.viewAngleXOverride = 0
            side.viewAngleYOverride = nil
        }
        if frontCanvas?.width != canvas.width || frontCanvas?.height != canvas.height {
            frontCanvas = PetCanvas(width: canvas.width, height: canvas.height)
            sideCanvas = PetCanvas(width: canvas.width, height: canvas.height)
        }
        // Advance both motion clocks, including the hidden view, so reappearing
        // does not restart a blink or spontaneous action.
        front.render(into: &frontCanvas!, time: time)
        side.render(into: &sideCanvas!, time: time)
        let fade = opacity.isFinite ? min(max(opacity, 0), 1) : 1
        // Mac stacks two NSViews with their own alpha. Match source-over,
        // including partially transparent hair, rather than a weighted RGB mix.
        for i in stride(from: 0, to: canvas.bgra.count, by: 4) {
            let sideAlpha = Float(sideCanvas!.bgra[i + 3]) / 255 * blend
            for c in 0..<4 {
                let f = Float(frontCanvas!.bgra[i + c]) * (1 - blend)
                let s = Float(sideCanvas!.bgra[i + c]) * blend
                canvas.bgra[i + c] = UInt8(min(max((s + f * (1 - sideAlpha)) * fade, 0), 255).rounded())
            }
        }
    }
}
