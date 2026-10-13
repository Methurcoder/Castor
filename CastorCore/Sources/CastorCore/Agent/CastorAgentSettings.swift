import Foundation

public enum CastorAgentRoutingPolicy: String, CaseIterable, Identifiable {
    case manual
    case automatic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .manual:
            "Choose each time"
        case .automatic:
            "Let Castor decide"
        }
    }
}

public enum CastorBrain: String, CaseIterable, Identifiable {
    case onDevice
    case codex
    case claudeCode
    case antigravity

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .onDevice:
            "On-device"
        case .codex:
            "Codex"
        case .claudeCode:
            "Claude Code"
        case .antigravity:
            "Antigravity"
        }
    }

    public var shortLabel: String {
        switch self {
        case .onDevice:
            "LOCAL"
        case .codex:
            "CODEX"
        case .claudeCode:
            "CLAUDE"
        case .antigravity:
            "AGY"
        }
    }

    public var isImplemented: Bool {
        self == .onDevice || self == .codex || self == .claudeCode
    }
}

public enum CastorAgentApprovalRequest: Identifiable, Equatable, Sendable {
    case codex(CodexApprovalRequest)
    case claudeCode(ClaudeCodeApprovalRequest)

    public var id: UUID {
        switch self {
        case .codex(let request):
            request.id
        case .claudeCode(let request):
            request.id
        }
    }

    public var title: String {
        switch self {
        case .codex(let request):
            request.title
        case .claudeCode(let request):
            request.title
        }
    }

    public var detail: String {
        switch self {
        case .codex(let request):
            request.detail
        case .claudeCode(let request):
            request.detail
        }
    }
}

public struct CastorAgentPreferences: Equatable {
    public var routingPolicy: CastorAgentRoutingPolicy
    public var selectedBrain: CastorBrain
    public var automaticExternalBrain: CastorBrain
    public var codexServerURL: String
    public var claudeCodeBridgeURL: String
    public var workspacePath: String

    public func resolvedBrain(for prompt: String) -> CastorBrain {
        switch routingPolicy {
        case .manual:
            return selectedBrain.isImplemented ? selectedBrain : .onDevice
        case .automatic:
            guard Self.promptNeedsExternalAgent(prompt) else {
                return .onDevice
            }
            return automaticExternalBrain.isImplemented ? automaticExternalBrain : .codex
        }
    }

    public static func promptNeedsExternalAgent(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let japaneseSignals = [
            "ファイル", "フォルダ", "ターミナル", "コマンド", "実行して",
            "開いて", "クリック", "操作して", "修正して", "実装して", "テストして"
        ]
        if japaneseSignals.contains(where: normalized.contains) {
            return true
        }

        // Match complete English words. Plain substring matching makes everyday prompts such as
        // "latest news" or "a contest result" accidentally match "test" and leave the device.
        let englishSignals = [
            "code", "repository", "repo", "terminal", "command", "run", "open",
            "click", "edit", "implement", "build", "test", "debug", "browser", "desktop"
        ]
        let words = Set(
            normalized
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        return englishSignals.contains(where: words.contains)
    }

    public init(
        routingPolicy: CastorAgentRoutingPolicy,
        selectedBrain: CastorBrain,
        automaticExternalBrain: CastorBrain,
        codexServerURL: String,
        claudeCodeBridgeURL: String,
        workspacePath: String
    ) {
        self.routingPolicy = routingPolicy
        self.selectedBrain = selectedBrain
        self.automaticExternalBrain = automaticExternalBrain
        self.codexServerURL = codexServerURL
        self.claudeCodeBridgeURL = claudeCodeBridgeURL
        self.workspacePath = workspacePath
    }
}

public enum CastorAgentPreferenceStore {
    private static let routingPolicyKey = "Pomegranate.Agent.RoutingPolicy"
    private static let selectedBrainKey = "Pomegranate.Agent.SelectedBrain"
    private static let automaticExternalBrainKey = "Pomegranate.Agent.AutomaticExternalBrain"
    private static let codexServerURLKey = "Pomegranate.Agent.CodexServerURL"
    private static let claudeCodeBridgeURLKey = "Pomegranate.Agent.ClaudeCodeBridgeURL"
    private static let workspacePathKey = "Pomegranate.Agent.WorkspacePath"

    public static var current: CastorAgentPreferences {
        get {
            let defaults = UserDefaults.standard
            let routingPolicy = defaults.string(forKey: routingPolicyKey)
                .flatMap(CastorAgentRoutingPolicy.init(rawValue:)) ?? .manual
            let selectedBrain = defaults.string(forKey: selectedBrainKey)
                .flatMap(CastorBrain.init(rawValue:)) ?? .onDevice
            let automaticExternalBrain = defaults.string(forKey: automaticExternalBrainKey)
                .flatMap(CastorBrain.init(rawValue:)) ?? .codex

            return CastorAgentPreferences(
                routingPolicy: routingPolicy,
                selectedBrain: selectedBrain,
                automaticExternalBrain: automaticExternalBrain,
                codexServerURL: defaults.string(forKey: codexServerURLKey)
                    ?? "ws://127.0.0.1:4500",
                claudeCodeBridgeURL: defaults.string(forKey: claudeCodeBridgeURLKey)
                    ?? "http://127.0.0.1:4510",
                workspacePath: defaults.string(forKey: workspacePathKey) ?? ""
            )
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.routingPolicy.rawValue, forKey: routingPolicyKey)
            defaults.set(newValue.selectedBrain.rawValue, forKey: selectedBrainKey)
            defaults.set(newValue.automaticExternalBrain.rawValue, forKey: automaticExternalBrainKey)
            defaults.set(newValue.codexServerURL, forKey: codexServerURLKey)
            defaults.set(newValue.claudeCodeBridgeURL, forKey: claudeCodeBridgeURLKey)
            defaults.set(newValue.workspacePath, forKey: workspacePathKey)
        }
    }
}

public enum PetPersonalityStore {
    private static let customPersonalityKey = "Pomegranate.Personality.Imported"
    private static let defaultCustomPersonality = "A gentle, slightly hesitant desktop companion who is curious, kind, and concise."

    public static var customPersonality: String {
        get {
            let stored = UserDefaults.standard.string(forKey: customPersonalityKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return defaultCustomPersonality
        }
        set {
            let sanitized = String(
                newValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(800)
            )
            UserDefaults.standard.set(
                sanitized.isEmpty ? defaultCustomPersonality : sanitized,
                forKey: customPersonalityKey
            )
        }
    }
}
