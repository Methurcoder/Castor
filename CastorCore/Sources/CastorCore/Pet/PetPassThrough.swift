import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Getting at what the floating pet covers.
///
/// Two ways, both decided here and applied by the platform window host:
///
/// - **Hold-to-see-through** (always on): while the pass-through modifier
///   (Option on macOS) is held with the pointer over the pet, the pet turns
///   faint and lets clicks reach the window underneath. Nothing about other
///   apps is inspected, so no permission is needed.
/// - **Button-aware dodge** (beta): when the pointer enters the pet and the
///   control underneath (in the covered app) is clickable, the pet slides
///   just far enough to uncover the pointer, and slides back once the pointer
///   has left that spot for a moment. Knowing what is underneath needs the
///   platform's accessibility API, which a sandboxed app cannot use, so a
///   separate local helper answers (see `PointerTargetClient`).
///
/// Hovering over the pet without either signal stays a pet interaction
/// (stroking it), which is why neither path triggers on dwell alone.
public nonisolated enum PetPassThroughGeometry {
    /// The pet frame moved the shortest way (left, right, down or up) so that
    /// `point` lies at least `margin` outside it, staying inside `visible`.
    /// Nil when the point is not covered or no direction fits.
    public static func uncoveringFrame(
        for frame: CGRect,
        uncovering point: CGPoint,
        within visible: CGRect,
        margin: CGFloat = 28
    ) -> CGRect? {
        guard frame.contains(point) else { return nil }
        let shifts: [(dx: CGFloat, dy: CGFloat)] = [
            (point.x + margin - frame.minX, 0),      // move right
            (point.x - margin - frame.maxX, 0),      // move left
            (0, point.y + margin - frame.minY),      // move up (y grows upward on macOS)
            (0, point.y - margin - frame.maxY),      // move down
        ]
        let candidates = shifts
            .map { frame.offsetBy(dx: $0.dx, dy: $0.dy) }
            .filter { visible.contains($0) && !$0.insetBy(dx: -margin + 1, dy: -margin + 1).contains(point) }
        return candidates.min { lhs, rhs in
            distance(lhs.origin, frame.origin) < distance(rhs.origin, frame.origin)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Roles that mean "the user is probably about to click this". Accessibility
/// role names as reported by macOS (`AXButton` …); the helper also reports
/// whether the element offers a press action, which covers custom controls.
public nonisolated enum PointerTargetRoles {
    public static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXLink", "AXTab", "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle",
        "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXIncrementor",
        "AXSegmentedControl", "AXDockItem",
    ]

    public static func isActionable(role: String?, hasPressAction: Bool) -> Bool {
        hasPressAction || role.map(actionable.contains) ?? false
    }
}

public nonisolated struct PetDodgePolicy: Equatable {
    /// How long the uncovered spot must be free of the pointer before the pet
    /// returns.
    public var returnDelay: TimeInterval = 1.6
    /// Radius around the uncovered spot that counts as "still using it".
    public var spotRadius: CGFloat = 40
    /// A manual move cancels any pending return for this long.
    public var manualPlacementProtection: TimeInterval = 60

    public init() {}
}

/// The button-aware dodge as a small state machine: settled → dodged → back.
public nonisolated struct PetDodgeStateMachine: Equatable {
    public nonisolated enum Action: Equatable {
        case none
        case move(to: CGRect)
        case returnTo(CGRect)
    }

    public private(set) var home: CGRect?
    public private(set) var spot: CGPoint?
    private var spotFreeSince: Date?
    private var pointerWasInside = false

    public init() {}

    public var isDodged: Bool { home != nil }

    /// Call when the pointer enters the pet (`entered`), with what the helper
    /// found underneath, or every tick otherwise (`underneathIsActionable` nil).
    public mutating func update(
        pointer: CGPoint,
        petFrame: CGRect,
        visible: CGRect,
        underneathIsActionable: Bool?,
        buttonsPressed: Bool,
        policy: PetDodgePolicy = PetDodgePolicy(),
        now: Date
    ) -> Action {
        defer { pointerWasInside = petFrame.contains(pointer) }

        if let home, let spot {
            let dx = pointer.x - spot.x
            let dy = pointer.y - spot.y
            let nearSpot = (dx * dx + dy * dy).squareRoot() <= policy.spotRadius
            if nearSpot || buttonsPressed {
                spotFreeSince = nil
                return .none
            }
            if let since = spotFreeSince {
                guard now.timeIntervalSince(since) >= policy.returnDelay else { return .none }
                self.home = nil
                self.spot = nil
                spotFreeSince = nil
                return .returnTo(home)
            }
            spotFreeSince = now
            return .none
        }

        guard underneathIsActionable == true, !buttonsPressed,
              let target = PetPassThroughGeometry.uncoveringFrame(for: petFrame, uncovering: pointer, within: visible)
        else { return .none }
        home = petFrame
        spot = pointer
        spotFreeSince = nil
        return .move(to: target)
    }

    /// True on the tick the pointer crosses into the pet: the moment to ask
    /// what lies underneath.
    public func isEntering(pointer: CGPoint, petFrame: CGRect) -> Bool {
        !pointerWasInside && petFrame.contains(pointer)
    }

    /// The user dragged the pet: forget the dodge, do not pull it back.
    public mutating func cancelForManualPlacement() {
        home = nil
        spot = nil
        spotFreeSince = nil
    }
}

public enum PetPassThroughSettingsStore {
    /// Button-aware dodge (beta, needs the local pointer-target helper).
    public static let dodgeEnabledKey = "Pomegranate.PassThrough.ButtonDodge"
    public static let dodgeDefaultEnabled = false

    public static var isDodgeEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: dodgeEnabledKey) != nil else { return dodgeDefaultEnabled }
            return UserDefaults.standard.bool(forKey: dodgeEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: dodgeEnabledKey) }
    }
}
