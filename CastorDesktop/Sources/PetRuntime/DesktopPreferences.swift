import ArilsPlayer
import CastorCore
import Foundation

/// Desktop settings are separate from versioned app files. Old Mac keys and
/// existing pet archives are retained; this DTO is the Windows host's store.
public struct DesktopPreferences: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable { case lmStudio, ollama }
    public enum Brain: String, Codable, Sendable { case local, codex, claudeCode }
    public var displayLanguage: SettingsDisplayLanguage = .systemDefault
    public var buttonDodgeEnabled = false
    public var microphoneEnabled = false
    public var microphoneSetupCompleted = false
    public var selectedBrain: Brain = .local
    public var automaticRouting = false
    public var externalBrain: Brain = .codex
    public var codexEndpoint = "ws://127.0.0.1:4500"
    public var claudeEndpoint = "http://127.0.0.1:4510"
    public var workspacePath = ""
    public var provider: Provider = .lmStudio
    public var lmStudioEndpoint = "http://127.0.0.1:1234"
    public var ollamaEndpoint = "http://127.0.0.1:11434"
    public var lmStudioModel = ""
    public var ollamaModel = ""
    public var personality = "穏やかで少し不器用なデスクトップの相棒。日本語で短く自然に会話する。"
    public var widerHeadMovement = false
    /// Beta: hair beside the head follows it (applied to the pet as it loads).
    public var naturalFaceMotion = false
    /// Whether the one-time offer to try `naturalFaceMotion` was shown.
    public var naturalFaceMotionOffered = false
    public var automaticTurn = true
    public var qualityPresentationMode:QualityPresentationMode?
    public var evasionEnabled = false
    public var evasionStyle: EvasionStyle = .calm
    public var petOpacity: Float = 1
    public var scale: Double = 1
    public var positionX: Int32?
    public var positionY: Int32?
    public var systemTTSEnabled = false
    public var systemVoice = ""
    public var neuralTTSEnabled = false
    public var neuralEndpoint = "http://127.0.0.1:8000/v1/audio/speech"
    public var neuralModel = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
    public var neuralVoice = "Ryan"
    public var neuralInstruction = "Speak gently, naturally, and a little hesitantly."
    public var neuralLanguage = "auto"
    public var neuralSpeed = 1.0
    public init() {}
    public var endpoint: String { provider == .lmStudio ? lmStudioEndpoint : ollamaEndpoint }
    public var model: String {
        get { provider == .lmStudio ? lmStudioModel : ollamaModel }
        set { if provider == .lmStudio { lmStudioModel = newValue } else { ollamaModel = newValue } }
    }
    /// Schema additions decode by overlaying defaults, rather than resetting
    /// an older preferences file or losing user-defined personality/models.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: Keys.self)
        displayLanguage = try values.decodeIfPresent(SettingsDisplayLanguage.self, forKey: .displayLanguage) ?? displayLanguage
        buttonDodgeEnabled = try values.decodeIfPresent(Bool.self, forKey: .buttonDodgeEnabled) ?? buttonDodgeEnabled
        microphoneEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? microphoneEnabled
        microphoneSetupCompleted = try values.decodeIfPresent(Bool.self, forKey: .microphoneSetupCompleted) ?? microphoneSetupCompleted
        selectedBrain = try values.decodeIfPresent(Brain.self, forKey: .selectedBrain) ?? selectedBrain
        externalBrain = try values.decodeIfPresent(Brain.self, forKey: .externalBrain) ?? externalBrain
        automaticRouting = try values.decodeIfPresent(Bool.self, forKey: .automaticRouting) ?? automaticRouting
        codexEndpoint = try values.decodeIfPresent(String.self, forKey: .codexEndpoint) ?? codexEndpoint
        claudeEndpoint = try values.decodeIfPresent(String.self, forKey: .claudeEndpoint) ?? claudeEndpoint
        workspacePath = try values.decodeIfPresent(String.self, forKey: .workspacePath) ?? workspacePath
        provider = try values.decodeIfPresent(Provider.self, forKey: .provider) ?? provider
        lmStudioEndpoint = try values.decodeIfPresent(String.self, forKey: .lmStudioEndpoint) ?? lmStudioEndpoint
        ollamaEndpoint = try values.decodeIfPresent(String.self, forKey: .ollamaEndpoint) ?? ollamaEndpoint
        lmStudioModel = try values.decodeIfPresent(String.self, forKey: .lmStudioModel) ?? lmStudioModel
        ollamaModel = try values.decodeIfPresent(String.self, forKey: .ollamaModel) ?? ollamaModel
        personality = try values.decodeIfPresent(String.self, forKey: .personality) ?? personality
        widerHeadMovement = try values.decodeIfPresent(Bool.self, forKey: .widerHeadMovement) ?? widerHeadMovement
        naturalFaceMotion = try values.decodeIfPresent(Bool.self, forKey: .naturalFaceMotion) ?? naturalFaceMotion
        naturalFaceMotionOffered = try values.decodeIfPresent(Bool.self, forKey: .naturalFaceMotionOffered) ?? naturalFaceMotionOffered
        evasionEnabled = try values.decodeIfPresent(Bool.self, forKey: .evasionEnabled) ?? evasionEnabled
        evasionStyle = try values.decodeIfPresent(EvasionStyle.self, forKey: .evasionStyle) ?? evasionStyle
        automaticTurn = try values.decodeIfPresent(Bool.self, forKey: .automaticTurn) ?? automaticTurn
        qualityPresentationMode = try values.decodeIfPresent(QualityPresentationMode.self,forKey:.qualityPresentationMode)
        petOpacity = try values.decodeIfPresent(Float.self, forKey: .petOpacity) ?? petOpacity
        scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        positionX = try values.decodeIfPresent(Int32.self, forKey: .positionX)
        positionY = try values.decodeIfPresent(Int32.self, forKey: .positionY)
        systemTTSEnabled = try values.decodeIfPresent(Bool.self, forKey: .systemTTSEnabled) ?? systemTTSEnabled
        systemVoice = try values.decodeIfPresent(String.self, forKey: .systemVoice) ?? systemVoice
        neuralTTSEnabled = try values.decodeIfPresent(Bool.self,forKey:.neuralTTSEnabled) ?? neuralTTSEnabled
        neuralEndpoint = try values.decodeIfPresent(String.self,forKey:.neuralEndpoint) ?? neuralEndpoint
        neuralModel = try values.decodeIfPresent(String.self,forKey:.neuralModel) ?? neuralModel
        neuralVoice = try values.decodeIfPresent(String.self,forKey:.neuralVoice) ?? neuralVoice
        neuralInstruction = try values.decodeIfPresent(String.self,forKey:.neuralInstruction) ?? neuralInstruction
        neuralLanguage = try values.decodeIfPresent(String.self,forKey:.neuralLanguage) ?? neuralLanguage
        neuralSpeed = try values.decodeIfPresent(Double.self,forKey:.neuralSpeed) ?? neuralSpeed
    }
    private enum Keys: String, CodingKey {
        case qualityPresentationMode
        case neuralTTSEnabled,neuralEndpoint,neuralModel,neuralVoice,neuralInstruction,neuralLanguage,neuralSpeed
        case displayLanguage, buttonDodgeEnabled, microphoneEnabled, microphoneSetupCompleted
        case selectedBrain, externalBrain, automaticRouting, codexEndpoint, claudeEndpoint, workspacePath
        case evasionEnabled, evasionStyle
        case naturalFaceMotion, naturalFaceMotionOffered
        case provider, lmStudioEndpoint, ollamaEndpoint, lmStudioModel, ollamaModel, personality,
             widerHeadMovement, automaticTurn, petOpacity, scale, positionX, positionY, systemTTSEnabled, systemVoice
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(qualityPresentationMode,forKey:.qualityPresentationMode)
        try c.encode(neuralTTSEnabled,forKey:.neuralTTSEnabled);try c.encode(neuralEndpoint,forKey:.neuralEndpoint)
        try c.encode(neuralModel,forKey:.neuralModel);try c.encode(neuralVoice,forKey:.neuralVoice)
        try c.encode(neuralInstruction,forKey:.neuralInstruction);try c.encode(neuralLanguage,forKey:.neuralLanguage)
        try c.encode(neuralSpeed,forKey:.neuralSpeed)
        try c.encode(displayLanguage, forKey: .displayLanguage)
        try c.encode(buttonDodgeEnabled, forKey: .buttonDodgeEnabled)
        try c.encode(microphoneEnabled, forKey: .microphoneEnabled)
        try c.encode(microphoneSetupCompleted, forKey: .microphoneSetupCompleted)
        try c.encode(selectedBrain, forKey: .selectedBrain); try c.encode(externalBrain, forKey: .externalBrain)
        try c.encode(evasionEnabled, forKey: .evasionEnabled); try c.encode(evasionStyle, forKey: .evasionStyle)
        try c.encode(automaticRouting, forKey: .automaticRouting)
        try c.encode(codexEndpoint, forKey: .codexEndpoint); try c.encode(claudeEndpoint, forKey: .claudeEndpoint)
        try c.encode(workspacePath, forKey: .workspacePath)
        try c.encode(provider, forKey: .provider)
        try c.encode(lmStudioEndpoint, forKey: .lmStudioEndpoint); try c.encode(ollamaEndpoint, forKey: .ollamaEndpoint)
        try c.encode(lmStudioModel, forKey: .lmStudioModel); try c.encode(ollamaModel, forKey: .ollamaModel)
        try c.encode(personality, forKey: .personality)
        try c.encode(widerHeadMovement, forKey: .widerHeadMovement); try c.encode(automaticTurn, forKey: .automaticTurn)
        try c.encode(naturalFaceMotion, forKey: .naturalFaceMotion); try c.encode(naturalFaceMotionOffered, forKey: .naturalFaceMotionOffered)
        try c.encode(petOpacity, forKey: .petOpacity); try c.encode(scale, forKey: .scale)
        try c.encodeIfPresent(positionX, forKey: .positionX); try c.encodeIfPresent(positionY, forKey: .positionY)
        try c.encode(systemTTSEnabled, forKey: .systemTTSEnabled); try c.encode(systemVoice, forKey: .systemVoice)
    }
}

public struct DesktopPreferenceStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    private var file: URL { root.appendingPathComponent("Preferences.json") }
    public func load() throws -> DesktopPreferences {
        guard FileManager.default.fileExists(atPath: file.path) else { return DesktopPreferences() }
        let preferences = try JSONDecoder().decode(DesktopPreferences.self, from: Data(contentsOf: file))
        try validate(preferences)
        return preferences
    }
    private func validate(_ preferences: DesktopPreferences) throws {
        guard preferences.scale.isFinite, (0.5...3).contains(preferences.scale),
              preferences.petOpacity.isFinite, (0.2...1).contains(preferences.petOpacity),
              preferences.personality.count <= 8000 else { throw StoreError.invalidPreferences }
        _ = try NeuralSpeechTransport(endpoint:URL(string:preferences.neuralEndpoint) ?? URL(string:"http://invalid")!)
        guard preferences.neuralSpeed.isFinite,(0.5...2).contains(preferences.neuralSpeed),
              !preferences.neuralModel.isEmpty,preferences.neuralModel.count<=1024,
              !preferences.neuralVoice.isEmpty,preferences.neuralVoice.count<=256,
              preferences.neuralInstruction.count<=4000,preferences.neuralLanguage.count<=32 else {throw StoreError.invalidPreferences}
        // Validate local endpoints before writing; cancel/invalid input keeps the old file.
        _ = try DesktopConversation.endpoint(preferences.lmStudioEndpoint)
        _ = try DesktopConversation.endpoint(preferences.ollamaEndpoint)
        guard CodexAppServerSession.isAllowedServerURL(preferences.codexEndpoint),
              ClaudeCodeBridgeSession.isAllowedBridgeURL(preferences.claudeEndpoint) else { throw StoreError.invalidPreferences }
    }
    public func save(_ preferences: DesktopPreferences) throws {
        try validate(preferences)
        let data = try JSONEncoder().encode(preferences)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            let backups = root.appendingPathComponent("PreferenceHistory", isDirectory: true)
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try Data(contentsOf: file).write(to: backups.appendingPathComponent("Preferences-\(UUID().uuidString).json"), options: .withoutOverwriting)
        }
        try data.write(to: file, options: .atomic)
    }
    public enum StoreError: LocalizedError {
        case invalidPreferences
        public var errorDescription: String? { "表示設定・性格の長さを確認してください。既存の設定は保持しています。" }
    }
}
