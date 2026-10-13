import AppKit
import Arils
import Foundation
import simd

/// Three-view renderer built from normal Arils engines. The frontal drawing is
/// used at zero, and the authored left/right drawings are independently
/// cross-faded as `viewTurn` moves through -1...1.
@MainActor
public final class ThreeViewCharacterEngine {
    public let archive: ThreeViewRigArchive
    public let left: CharacterEngine
    public let front: CharacterEngine
    public let right: CharacterEngine

    public var viewTurn: Float = 0 {
        didSet {
            viewTurn = Self.normalized(viewTurn)
            updateContainers()
        }
    }

    /// Optional shoulder/elbow rotations applied to the independently drawn
    /// arm meshes in all three authored views.
    public var articulationPoseParameters = ArticulationPoseParameters() {
        didSet { updateContainers() }
    }

    public var isSpeaking = false {
        didSet { engines.forEach { $0.isSpeaking = isSpeaking } }
    }

    public var energy: Float = 0.5 {
        didSet { engines.forEach { $0.energy = energy } }
    }

    public var externalGazeTarget: SIMD2<Float>? {
        didSet { engines.forEach { $0.externalGazeTarget = externalGazeTarget } }
    }

    public var onTap: (() -> Void)? {
        didSet { engines.forEach { engine in engine.onTap = { [weak self] in self?.onTap?() } } }
    }

    private let containers = NSHashTable<ThreeViewContainerView>.weakObjects()
    private var engines: [CharacterEngine] { [left, front, right] }

    public init(
        archive: ThreeViewRigArchive,
        configuration: CharacterEngine.Configuration = CharacterEngine.Configuration()
    ) throws {
        guard let leftReference = archive.reference(for: .left) else {
            throw ThreeViewRigBuildError.missingReference(.left)
        }
        guard let frontReference = archive.reference(for: .front) else {
            throw ThreeViewRigBuildError.missingReference(.front)
        }
        guard let rightReference = archive.reference(for: .right) else {
            throw ThreeViewRigBuildError.missingReference(.right)
        }
        self.archive = archive
        self.left = CharacterEngine(
            avatar: try leftReference.avatar.makeAvatar(),
            configuration: configuration
        )
        self.front = CharacterEngine(
            avatar: try frontReference.avatar.makeAvatar(),
            configuration: configuration
        )
        self.right = CharacterEngine(
            avatar: try rightReference.avatar.makeAvatar(),
            configuration: configuration
        )
    }

    public convenience init(
        archiveData: Data,
        configuration: CharacterEngine.Configuration = CharacterEngine.Configuration()
    ) throws {
        try self.init(archive: ThreeViewRigArchive(data: archiveData), configuration: configuration)
    }

    public func makeView() -> NSView {
        let references = Dictionary(uniqueKeysWithValues: archive.references.map { ($0.role, $0) })
        let container = ThreeViewContainerView(
            leftView: left.makeView(),
            frontView: front.makeView(),
            rightView: right.makeView(),
            references: references,
            registration: archive.registration,
            articulationByRole: archive.articulationByRole ?? [:],
            crossViewArticulation: archive.crossViewArticulation
        )
        containers.add(container)
        container.update(
            turn: viewTurn,
            parameters: articulationPoseParameters
        )
        return container
    }

    public func pushSpeechSamples(_ samples: [Float], sampleRate: Double) {
        engines.forEach { $0.pushSpeechSamples(samples, sampleRate: sampleRate) }
    }

    public func pushSpeechLevel(_ level: Float) {
        engines.forEach { $0.pushSpeechLevel(level) }
    }

    private func updateContainers() {
        containers.allObjects.forEach {
            $0.update(
                turn: viewTurn,
                parameters: articulationPoseParameters
            )
        }
    }

    private static func normalized(_ value: Float) -> Float {
        value.isFinite ? min(max(value, -1), 1) : 0
    }
}

private final class ThreeViewContainerView: NSView {
    private let leftView: ReferenceCompositeView
    private let frontView: ReferenceCompositeView
    private let rightView: ReferenceCompositeView
    private let references: [ReferenceRole: ReferenceViewArchive]
    private let registration: ThreeViewRegistration
    private let articulationByRole: [ReferenceRole: ArticulationRigArchive]
    private let crossViewArticulation: CrossViewArticulationProfile?
    private var behindArmViews: [ReferenceRole: ArticulationMetalView] = [:]
    private var frontArmViews: [ReferenceRole: ArticulationMetalView] = [:]

    init(
        leftView: NSView,
        frontView: NSView,
        rightView: NSView,
        references: [ReferenceRole: ReferenceViewArchive],
        registration: ThreeViewRegistration,
        articulationByRole: [ReferenceRole: ArticulationRigArchive],
        crossViewArticulation: CrossViewArticulationProfile?
    ) {
        self.leftView = ReferenceCompositeView(
            contentView: leftView,
            articulation: articulationByRole[.left]
        )
        self.frontView = ReferenceCompositeView(
            contentView: frontView,
            articulation: articulationByRole[.front]
        )
        self.rightView = ReferenceCompositeView(
            contentView: rightView,
            articulation: articulationByRole[.right]
        )
        self.references = references
        self.registration = registration
        self.articulationByRole = articulationByRole
        self.crossViewArticulation = crossViewArticulation
        super.init(frame: .zero)
        wantsLayer = true

        // Back copies are inserted below all repaired body views. Front copies
        // are inserted above them. A hidden front arm can therefore migrate
        // between the two surfaces before its alpha reaches zero.
        for (role, rig) in articulationByRole {
            let view = ArticulationMetalView(rig: rig)
            behindArmViews[role] = view
            addSubview(view)
        }
        addSubview(self.leftView)
        addSubview(self.frontView)
        addSubview(self.rightView)
        for (role, rig) in articulationByRole {
            let view = ArticulationMetalView(rig: rig)
            frontArmViews[role] = view
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard
            bounds.width > 0,
            bounds.height > 0,
            let frontReference = references[.front]
        else { return }

        let frontSize = CGSize(
            width: frontReference.avatar.rig.imageWidth,
            height: frontReference.avatar.rig.imageHeight
        )
        let baseScale = min(
            bounds.width / max(frontSize.width, 1),
            bounds.height / max(frontSize.height, 1)
        )
        let frontFrame = CGRect(
            x: bounds.midX - frontSize.width * baseScale * 0.5,
            y: bounds.midY - frontSize.height * baseScale * 0.5,
            width: frontSize.width * baseScale,
            height: frontSize.height * baseScale
        )
        frontView.frame = frontFrame
        behindArmViews[.front]?.frame = frontFrame
        frontArmViews[.front]?.frame = frontFrame

        let frontNeck = registration.views[.front]?.neck ?? SIMD2(0.5, 0.25)
        let target = CGPoint(
            x: frontFrame.minX + CGFloat(frontNeck.x) * frontFrame.width,
            y: frontFrame.maxY - CGFloat(frontNeck.y) * frontFrame.height
        )
        layoutSide(.left, view: leftView, baseScale: baseScale, targetNeck: target)
        layoutSide(.right, view: rightView, baseScale: baseScale, targetNeck: target)
    }

    func update(
        turn: Float,
        parameters: ArticulationPoseParameters
    ) {
        let weights = ThreeViewBlend.weights(for: turn)
        setRenderingEnabled(weights.front > 0.001, in: frontView)
        setRenderingEnabled(weights.left > 0.001, in: leftView)
        setRenderingEnabled(weights.right > 0.001, in: rightView)
        frontView.alphaValue = CGFloat(weights.front)
        leftView.alphaValue = CGFloat(weights.left)
        rightView.alphaValue = CGFloat(weights.right)
        leftView.isHidden = leftView.alphaValue < 0.001
        rightView.isHidden = rightView.alphaValue < 0.001
        frontView.isHidden = frontView.alphaValue < 0.001

        let armState = CrossViewArticulationBlend.state(
            viewTurn: turn,
            profile: crossViewArticulation,
            articulationByRole: articulationByRole
        )
        for (role, rig) in articulationByRole {
            let roleParameters = CrossViewArticulationParameterMapper.parameters(
                parameters,
                for: role,
                profile: crossViewArticulation
            )
            let behind = Dictionary(uniqueKeysWithValues: rig.parts.map {
                ($0.id, armState[role, $0.id].behindBody)
            })
            let front = Dictionary(uniqueKeysWithValues: rig.parts.map {
                ($0.id, armState[role, $0.id].inFrontOfBody)
            })
            behindArmViews[role]?.update(
                parameters: roleParameters,
                opacities: behind
            )
            frontArmViews[role]?.update(
                parameters: roleParameters,
                opacities: front
            )
        }
    }

    private func setRenderingEnabled(_ enabled: Bool, in view: NSView) {
        if let metalView = view as? AvatarMetalView {
            metalView.isRenderingEnabled = enabled
        }
        for child in view.subviews {
            setRenderingEnabled(enabled, in: child)
        }
    }

    private func layoutSide(
        _ role: ReferenceRole,
        view: NSView,
        baseScale: CGFloat,
        targetNeck: CGPoint
    ) {
        guard let reference = references[role] else { return }
        let registration = registration.views[role]
            ?? ReferenceViewRegistration(neck: SIMD2(0.5, 0.25), scaleRelativeToFront: 1)
        let scale = baseScale * CGFloat(registration.scaleRelativeToFront)
        let width = CGFloat(reference.avatar.rig.imageWidth) * scale
        let height = CGFloat(reference.avatar.rig.imageHeight) * scale
        view.frame = CGRect(
            x: targetNeck.x - CGFloat(registration.neck.x) * width,
            y: targetNeck.y - (1 - CGFloat(registration.neck.y)) * height,
            width: width,
            height: height
        )
        behindArmViews[role]?.frame = view.frame
        frontArmViews[role]?.frame = view.frame
    }
}

private final class ReferenceCompositeView: NSView {
    private let contentView: NSView
    private let patchView: ArticulationUnderpaintPatchView?

    init(contentView: NSView, articulation: ArticulationRigArchive?) {
        self.contentView = contentView
        self.patchView = articulation.flatMap(ArticulationUnderpaintPatchView.init(rig:))
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(contentView)
        if let patchView {
            addSubview(patchView)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        patchView?.frame = bounds
    }
}
