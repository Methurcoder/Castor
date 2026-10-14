import CastorCore
import Foundation

/// Shares the Mac state machine/policy; caller supplies OS metadata, never pixels.
public final class DesktopEvasion {
    public var home: CGRect?
    public private(set) var state = PetEvasionStateMachine()
    public private(set) var ghost = false
    public private(set) var hidden = false
    public private(set) var visualScale: Float = 1
    private var lastManual = Date.distantPast
    private var lastPoll = Date.distantPast
    private let policy = PetEvasionPolicy()
    private var movement: (start: CGRect, end: CGRect, date: Date, duration: TimeInterval, easing: EvasionPathEasing)?

    public init() {}
    public func manualPlacement(frame: CGRect, now: Date = Date()) {
        home = frame; movement = nil; lastManual = now
        state.resetForManualPlacement(at: now); ghost = false; hidden = false; visualScale = 1
    }
    public func disable() { movement = nil; state.resetForManualPlacement(at: Date()); ghost = false; hidden = false; visualScale = 1 }
    public func update(frame: CGRect, pointer: CGPoint, screen: CGRect, workArea: CGRect,
                       windows: [PetEvasionWindow], focusedID: UInt32?, style: EvasionStyle,
                       now: Date = Date()) -> CGRect? {
        if home == nil { home = frame }
        if let movement {
            let fraction = min(max(now.timeIntervalSince(movement.date) / movement.duration, 0), 1)
            let eased = Self.easing(fraction, style: movement.easing)
            let result = CGRect(x: movement.start.minX + (movement.end.minX - movement.start.minX) * eased,
                                y: movement.start.minY + (movement.end.minY - movement.start.minY) * eased,
                                width: frame.width, height: frame.height)
            if fraction >= 1 { self.movement = nil; state.movementCompleted(at: now); visualScale = 1 }
            return result
        }
        guard now.timeIntervalSince(lastPoll) >= policy.pollingInterval else { return nil }
        lastPoll = now
        let focused = windows.first { $0.id == focusedID }
        let obstructed = focused.map { PetEvasionGeometry.isObstructed(petFrame: frame, by: $0.frame)
            && PetEvasionGeometry.isPointerRequestingSpace(around: frame, pointer: pointer) } ?? false
        let homeObstructed = focused.flatMap { focused in home.map {
            PetEvasionGeometry.isObstructed(petFrame: $0, by: focused.frame) && PetEvasionGeometry.isPointerRequestingSpace(around: $0, pointer: pointer)
        }} ?? false
        let occupied = focused.map { focused in windows.filter { $0.ownerPID == focused.ownerPID && $0.id != focused.id }.map(\.frame) } ?? []
        let target = obstructed ? PetEvasionGeometry.nearestAvailableFrame(for: frame, in: workArea,
                                     avoiding: occupied, avoidingPoint: pointer) : nil
        let fullscreen = focused.map { PetEvasionGeometry.isFullscreen($0.frame, on: screen) } ?? false
        let profile = EvasionProfiles.profile(for: style)
        let action = state.update(obstructed: obstructed, homeObstructed: homeObstructed, destination: target,
            focusedWindowIsFullscreen: fullscreen, manualPlacementProtected: now.timeIntervalSince(lastManual) < policy.manualPlacementProtection,
            profile: profile, policy: policy, now: now)
        ghost = false; hidden = false
        switch action {
        case .none: break
        case let .move(to: destination): movement = (frame, destination, now, profile.movementDuration, profile.pathEasing)
        case .returnHome:
            if let home {
                let duration: TimeInterval = profile.returnManner == .gentle ? 0.58 : profile.returnManner == .confident ? 0.48 : 0.36
                movement = (frame, home, now, duration, .easeInOut)
            }
        case .ghost: ghost = true
        case .hide: hidden = true
        }
        switch (style, state.phase) {
        case (.cute, .anticipating), (.cute, .evading): visualScale = 1.045
        case (.calm, .anticipating): visualScale = 0.985
        case (.robot, .anticipating), (.robot, .evading): visualScale = 0.995
        default: visualScale = 1
        }
        return nil
    }
    /// Same timing-function control points as the Mac panel animation.
    public static func easing(_ time: Double, style: EvasionPathEasing) -> CGFloat {
        if time<=0 {return 0};if time>=1 {return 1}
        if style == .linear { return CGFloat(time) }
        let points: (Double, Double, Double, Double)
        switch style {
        case .spring: points = (0.18, 0.88, 0.28, 1.18)
        case .easeInOut: points = (0.42, 0, 0.58, 1)
        case .overdamped: points = (0.12, 0.72, 0.22, 1)
        case .linear: return CGFloat(time)
        }
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1-t) * (1-t) * t * a + 3 * (1-t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 { let middle = (low + high) / 2; if cubic(middle, points.0, points.2) < time { low = middle } else { high = middle } }
        return CGFloat(cubic((low + high) / 2, points.1, points.3))
    }
}
