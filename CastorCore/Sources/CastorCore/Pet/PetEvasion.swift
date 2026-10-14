import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Observation

public nonisolated enum EvasionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case cute
    case calm
    case cool
    case proud
    case robot

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cute: "Cute"
        case .calm: "Calm"
        case .cool: "Cool"
        case .proud: "Proud"
        case .robot: "Robot"
        }
    }
}

public nonisolated enum EvasionPathEasing: Equatable {
    case spring
    case easeInOut
    case linear
    case overdamped
}

public nonisolated enum EvasionBodyCue: Equatable, Sendable {
    case startledHop
    case bow
    case none
    case displeased
    case stabilized
}

public nonisolated enum EvasionGazeCue: Equatable {
    case none
    case obstructingWindow
}

public nonisolated enum EvasionSoundEffect: Equatable {
    case systemBeep
}

public nonisolated enum EvasionReturnManner: Equatable {
    case gentle
    case confident
    case slide
}

public nonisolated struct EvasionProfile: Equatable {
    public var anticipationDelay: TimeInterval
    public var movementDuration: TimeInterval
    public var pathEasing: EvasionPathEasing
    public var bodyCue: EvasionBodyCue
    public var gazeCue: EvasionGazeCue
    public var voiceLine: String?
    public var soundEffect: EvasionSoundEffect?
    public var returnManner: EvasionReturnManner

    public init(
        anticipationDelay: TimeInterval,
        movementDuration: TimeInterval,
        pathEasing: EvasionPathEasing,
        bodyCue: EvasionBodyCue,
        gazeCue: EvasionGazeCue,
        voiceLine: String? = nil,
        soundEffect: EvasionSoundEffect? = nil,
        returnManner: EvasionReturnManner
    ) {
        self.anticipationDelay = anticipationDelay
        self.movementDuration = movementDuration
        self.pathEasing = pathEasing
        self.bodyCue = bodyCue
        self.gazeCue = gazeCue
        self.voiceLine = voiceLine
        self.soundEffect = soundEffect
        self.returnManner = returnManner
    }
}

public nonisolated enum EvasionProfiles {
    public static func profile(for style: EvasionStyle) -> EvasionProfile {
        switch style {
        case .cute:
            EvasionProfile(
                anticipationDelay: 0.16,
                movementDuration: 0.48,
                pathEasing: .spring,
                bodyCue: .startledHop,
                gazeCue: .obstructingWindow,
                voiceLine: "わっ、ごめん！",
                soundEffect: nil,
                returnManner: .gentle
            )
        case .calm:
            EvasionProfile(
                anticipationDelay: 0.20,
                movementDuration: 0.52,
                pathEasing: .easeInOut,
                bodyCue: .bow,
                gazeCue: .obstructingWindow,
                voiceLine: nil,
                soundEffect: nil,
                returnManner: .gentle
            )
        case .cool:
            EvasionProfile(
                anticipationDelay: 0.08,
                movementDuration: 0.38,
                pathEasing: .linear,
                bodyCue: .none,
                gazeCue: .obstructingWindow,
                voiceLine: nil,
                soundEffect: nil,
                returnManner: .slide
            )
        case .proud:
            EvasionProfile(
                anticipationDelay: 0.28,
                movementDuration: 0.62,
                pathEasing: .overdamped,
                bodyCue: .displeased,
                gazeCue: .obstructingWindow,
                voiceLine: nil,
                soundEffect: nil,
                returnManner: .confident
            )
        case .robot:
            EvasionProfile(
                anticipationDelay: 0,
                movementDuration: 0.34,
                pathEasing: .linear,
                bodyCue: .stabilized,
                gazeCue: .obstructingWindow,
                voiceLine: nil,
                soundEffect: .systemBeep,
                returnManner: .slide
            )
        }
    }
}

public enum PetEvasionStyleStore {
    private static let importedStyleKey = "Pomegranate.Evasion.ImportedStyle"
    private static let userOverrideKey = "Pomegranate.Evasion.ImportedStyleUserOverride"

    public static var importedStyle: EvasionStyle {
        get {
            UserDefaults.standard.string(forKey: importedStyleKey)
                .flatMap(EvasionStyle.init(rawValue:)) ?? .calm
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: importedStyleKey)
        }
    }

    public static var hasUserOverride: Bool {
        UserDefaults.standard.bool(forKey: userOverrideKey)
    }

    public static func saveUserSelection(_ style: EvasionStyle) {
        importedStyle = style
        UserDefaults.standard.set(true, forKey: userOverrideKey)
    }

    @discardableResult
    public static func saveSuggestionIfAllowed(_ style: EvasionStyle) -> Bool {
        guard !hasUserOverride else { return false }
        importedStyle = style
        return true
    }
}

public enum PetEvasionSettingsStore {
    public static let enabledKey = "Pomegranate.Evasion.Enabled"
    public static let defaultEnabled = false

    public static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else {
                return defaultEnabled
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

public enum PetEvasionStyleClassifier {
    public static func suggestedStyle(for personality: String) async -> EvasionStyle {
        await suggestedStyle(for: personality, client: OllamaClient())
    }

    public static func suggestedStyle(for personality: String, client: OllamaClient) async -> EvasionStyle {
        guard let model = OllamaModelSelectionStore.selectedModel else {
            return .calm
        }

        let messages = [
            OllamaChatMessage(
                role: .system,
                content: "Classify the character into exactly one evasion style: cute, calm, cool, proud, or robot. Return that single word as the response."
            ),
            OllamaChatMessage(role: .user, content: String(personality.prefix(800)))
        ]

        do {
            let content = try await client.chat(model: model, messages: messages)
            let response = OllamaResponseParser.parse(content).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return EvasionStyle.allCases.first(where: { response.contains($0.rawValue) }) ?? .calm
        } catch {
            return .calm
        }
    }
}

/// A window that may obstruct the pet. `id` and `ownerPID` hold the platform's window number and
/// process ID (`CGWindowID` / `pid_t` on macOS); `frame` uses the pet panel's coordinate space.
public nonisolated struct PetEvasionWindow: Equatable {
    public var id: UInt32
    public var ownerPID: Int32
    public var frame: CGRect

    public init(id: UInt32, ownerPID: Int32, frame: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.frame = frame
    }
}

public protocol PetEvasionWindowProviding {
    func onScreenWindows() -> [PetEvasionWindow]
}

public nonisolated enum PetEvasionGeometry {
    public static func isObstructed(
        petFrame: CGRect,
        by focusedWindow: CGRect,
        overlapThreshold: CGFloat = 0.20
    ) -> Bool {
        guard petFrame.width > 0, petFrame.height > 0 else { return false }
        let intersection = petFrame.intersection(focusedWindow)
        let overlapRatio = intersection.isNull
            ? 0
            : intersection.width * intersection.height / (petFrame.width * petFrame.height)
        let center = CGPoint(x: petFrame.midX, y: petFrame.midY)
        return overlapRatio >= overlapThreshold || focusedWindow.contains(center)
    }

    public static func nearestAvailableFrame(
        for petFrame: CGRect,
        in screenFrame: CGRect,
        avoiding occupiedFrames: [CGRect],
        avoidingPoint: CGPoint? = nil,
        screenInset: CGFloat = 12,
        obstacleMargin: CGFloat = 8,
        pointClearance: CGFloat = 72
    ) -> CGRect? {
        let usable = screenFrame.insetBy(dx: screenInset, dy: screenInset)
        guard usable.width >= petFrame.width, usable.height >= petFrame.height else {
            return nil
        }

        var xOrigins = [usable.minX, usable.maxX - petFrame.width]
        var yOrigins = [usable.minY, usable.maxY - petFrame.height]
        for obstacle in occupiedFrames where obstacle.intersects(screenFrame) {
            xOrigins.append(obstacle.minX - petFrame.width - obstacleMargin)
            xOrigins.append(obstacle.maxX + obstacleMargin)
            yOrigins.append(obstacle.minY - petFrame.height - obstacleMargin)
            yOrigins.append(obstacle.maxY + obstacleMargin)
        }

        let minX = usable.minX
        let maxX = usable.maxX - petFrame.width
        let minY = usable.minY
        let maxY = usable.maxY - petFrame.height
        let candidates = xOrigins.flatMap { rawX in
            yOrigins.map { rawY in
                CGRect(
                    x: min(max(rawX, minX), maxX),
                    y: min(max(rawY, minY), maxY),
                    width: petFrame.width,
                    height: petFrame.height
                )
            }
        }

        let valid = candidates.filter { candidate in
            let clearsObstacles = occupiedFrames.allSatisfy { obstacle in
                let intersection = candidate.intersection(obstacle.insetBy(dx: -obstacleMargin, dy: -obstacleMargin))
                return intersection.isNull || intersection.width * intersection.height < 1
            }
            let clearsPoint = avoidingPoint.map {
                distance(from: $0, to: candidate) >= pointClearance
            } ?? true
            return clearsObstacles && clearsPoint
        }
        return valid.min { lhs, rhs in
            squaredDistance(from: petFrame.origin, to: lhs.origin)
                < squaredDistance(from: petFrame.origin, to: rhs.origin)
        }
    }

    public static func isFullscreen(_ windowFrame: CGRect, on screenFrame: CGRect) -> Bool {
        let intersection = windowFrame.intersection(screenFrame)
        guard !intersection.isNull, screenFrame.width > 0, screenFrame.height > 0 else { return false }
        let coverage = intersection.width * intersection.height / (screenFrame.width * screenFrame.height)
        return coverage >= 0.97
    }

    /// A focused window merely existing behind the floating panel is not enough intent to move
    /// the pet. The pointer must enter a small pressure ring around the panel. Once it enters the
    /// panel itself, pet interaction wins and evasion is suppressed.
    public static func isPointerRequestingSpace(
        around petFrame: CGRect,
        pointer: CGPoint,
        activationMargin: CGFloat = 52
    ) -> Bool {
        petFrame.insetBy(dx: -activationMargin, dy: -activationMargin).contains(pointer)
            && !petFrame.contains(pointer)
    }

    private static func squaredDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }


    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return sqrt(dx * dx + dy * dy)
    }
}

public nonisolated struct PetEvasionPolicy: Equatable {
    public var returnDelay: TimeInterval = 8
    public var cooldown: TimeInterval = 15
    public var manualPlacementProtection: TimeInterval = 5 * 60
    public var pollingInterval: TimeInterval = 0.5

    public init(
        returnDelay: TimeInterval = 8,
        cooldown: TimeInterval = 15,
        manualPlacementProtection: TimeInterval = 5 * 60,
        pollingInterval: TimeInterval = 0.5
    ) {
        self.returnDelay = returnDelay
        self.cooldown = cooldown
        self.manualPlacementProtection = manualPlacementProtection
        self.pollingInterval = pollingInterval
    }
}

public nonisolated enum PetEvasionPhase: Equatable, Sendable {
    case settled
    case anticipating
    case evading
    case displaced
    case returning
}

public nonisolated enum PetEvasionAction: Equatable {
    case none
    case move(to: CGRect)
    case returnHome
    case ghost
    case hide
}

public nonisolated struct PetEvasionStateMachine {
    public private(set) var phase: PetEvasionPhase = .settled
    public private(set) var phaseStartedAt = Date.distantPast
    private var clearSince: Date?
    private var lastEvasionAt: Date?

    public mutating func update(
        obstructed: Bool,
        homeObstructed: Bool = false,
        destination: CGRect?,
        focusedWindowIsFullscreen: Bool,
        manualPlacementProtected: Bool,
        profile: EvasionProfile,
        policy: PetEvasionPolicy,
        now: Date
    ) -> PetEvasionAction {
        if obstructed {
            clearSince = nil
            if focusedWindowIsFullscreen {
                return .hide
            }
            if manualPlacementProtected || destination == nil {
                return .ghost
            }
        }

        switch phase {
        case .settled:
            guard obstructed, let destination else { return .none }
            phase = .anticipating
            phaseStartedAt = now
            if profile.anticipationDelay <= 0 {
                phase = .evading
                lastEvasionAt = now
                return .move(to: destination)
            }
            return .none

        case .anticipating:
            guard obstructed, let destination else {
                phase = .settled
                phaseStartedAt = now
                return .none
            }
            guard now.timeIntervalSince(phaseStartedAt) >= profile.anticipationDelay else {
                return .none
            }
            phase = .evading
            phaseStartedAt = now
            lastEvasionAt = now
            return .move(to: destination)

        case .evading, .returning:
            return .none

        case .displaced:
            if obstructed, let destination {
                phase = .anticipating
                phaseStartedAt = now
                if profile.anticipationDelay <= 0 {
                    phase = .evading
                    lastEvasionAt = now
                    return .move(to: destination)
                }
                return .none
            }
            guard !obstructed else { return .none }
            guard !homeObstructed else {
                clearSince = nil
                return .none
            }
            if clearSince == nil {
                clearSince = now
                return .none
            }
            guard let clearSince,
                  now.timeIntervalSince(clearSince) >= policy.returnDelay,
                  now.timeIntervalSince(lastEvasionAt ?? .distantPast) >= policy.cooldown else {
                return .none
            }
            phase = .returning
            phaseStartedAt = now
            return .returnHome
        }
    }

    public mutating func movementCompleted(at now: Date) {
        switch phase {
        case .evading:
            phase = .displaced
        case .returning:
            phase = .settled
            clearSince = nil
        default:
            return
        }
        phaseStartedAt = now
    }

    public mutating func resetForManualPlacement(at now: Date) {
        phase = .settled
        phaseStartedAt = now
        clearSince = nil
        lastEvasionAt = nil
    }

    public init() {}
}

public nonisolated struct EvasionMotionCue: Sendable {
    public var style: EvasionStyle
    public var bodyCue: EvasionBodyCue
    public var phase: PetEvasionPhase
    public var elapsed: TimeInterval
    public var gazeTarget: CGPoint?

    public init(
        style: EvasionStyle,
        bodyCue: EvasionBodyCue,
        phase: PetEvasionPhase,
        elapsed: TimeInterval,
        gazeTarget: CGPoint? = nil
    ) {
        self.style = style
        self.bodyCue = bodyCue
        self.phase = phase
        self.elapsed = elapsed
        self.gazeTarget = gazeTarget
    }
}

@MainActor
@Observable
public final class PetEvasionPresentation {
    public var style: EvasionStyle = .calm
    public var phase: PetEvasionPhase = .settled
    public var phaseStartedAt = Date.distantPast
    public var obstructingWindowGaze: CGPoint?
    public var cueSequence = 0
    public var cueVoiceLine: String?
    public var cueSoundEffect: EvasionSoundEffect?

    public func motionCue(at date: Date) -> EvasionMotionCue? {
        guard phase != .settled else { return nil }
        let profile = EvasionProfiles.profile(for: style)
        return EvasionMotionCue(
            style: style,
            bodyCue: profile.bodyCue,
            phase: phase,
            elapsed: max(0, date.timeIntervalSince(phaseStartedAt)),
            gazeTarget: profile.gazeCue == .obstructingWindow ? obstructingWindowGaze : nil
        )
    }

    public init() {}
}
