#if os(Windows)
import CDesktopUI
import CastorCore
import Foundation
import PetRuntime

/// No command/helper is required for local chat; both services remain optional.
enum WindowsConversationFlow {
    static func settings(_ existing: DesktopPreferences) throws -> DesktopPreferences? {
        var edited = existing
        // Preview this dialog's language while editing; discard/cancel restores the saved UI language.
        defer { castor_set_ui_language(existing.displayLanguage == .japanese ? 1 : 0) }
        while true {
            let language = edited.displayLanguage
            castor_set_ui_language(language == .japanese ? 1 : 0)
            func S(_ key: String, _ arguments: [String: String] = [:]) -> String {
                CastorSettingsStrings.text(key, language: language, arguments: arguments)
            }
            func state(_ value: Bool) -> String { S(value ? "common.on" : "common.off") }
            func brain(_ value: DesktopPreferences.Brain) -> String {
                switch value {
                case .local: return S("desktop.settings.brain.local")
                case .codex: return "Codex"
                case .claudeCode: return "Claude Code"
                }
            }
            guard let item = try WindowsRiggingFlow.option(title: S("desktop.settings.title"), items: [
                S("desktop.settings.provider", ["provider": edited.provider == .lmStudio ? "LM Studio" : "Ollama"]),
                S("desktop.settings.endpoint", ["endpoint": edited.endpoint]),
                S("desktop.settings.model", ["model": edited.model]), S("desktop.settings.personality"),
                S("desktop.settings.automatic_turn", ["オン/オフ": state(edited.automaticTurn), "On/Off": state(edited.automaticTurn)]),
                S("desktop.settings.wide_head", ["オン/オフ": state(edited.widerHeadMovement), "On/Off": state(edited.widerHeadMovement)]),
                S("desktop.settings.opacity", ["percentage": "\(Int(edited.petOpacity * 100))%"]),
                S("desktop.settings.scale", ["percentage": "\(Int(edited.scale * 100))%"]),
                S("desktop.settings.system_tts", ["オン/オフ": state(edited.systemTTSEnabled), "On/Off": state(edited.systemTTSEnabled)]),
                S("desktop.settings.choose_voice"), S("desktop.settings.brain", ["selectedBrain.rawValue": brain(edited.selectedBrain)]),
                S("desktop.settings.automatic_routing", ["オン/オフ": state(edited.automaticRouting), "On/Off": state(edited.automaticRouting)]),
                S("desktop.settings.automatic_external_brain", ["externalBrain.rawValue": brain(edited.externalBrain)]),
                S("desktop.settings.codex_endpoint"), S("desktop.settings.claude_endpoint"), S("desktop.settings.workspace"),
                S("desktop.settings.evasion", ["オン/オフ": state(edited.evasionEnabled), "On/Off": state(edited.evasionEnabled)]),
                S("desktop.settings.evasion_style", ["style.label": S("desktop.settings.evasion_style.\(edited.evasionStyle.rawValue)")]),
                S("desktop.settings.language", ["language": language.nativeLabel]),
                S("desktop.settings.button_dodge", ["state": state(edited.buttonDodgeEnabled)]),
                S("desktop.settings.microphone", ["state": state(edited.microphoneEnabled)]),
                (language == .japanese ? "Neural TTS（失敗時は標準音声）: ":"Neural TTS (system voice fallback): ")+state(edited.neuralTTSEnabled),
                language == .japanese ? "音声認識の状態とマイク設定" : "Speech recognition status and microphone privacy",
                S("desktop.settings.save_close"), S("desktop.settings.discard_close")
            ]) else { return nil }
            switch item {
            case 0:
                guard let provider = try WindowsRiggingFlow.option(title: S("desktop.settings.provider.title"), items: ["LM Studio", "Ollama"]) else { continue }
                edited.provider = provider == 0 ? .lmStudio : .ollama
            case 1:
                guard let value = try WindowsRiggingFlow.text(title: S("desktop.settings.endpoint.title"), value: edited.endpoint) else { continue }
                _ = try DesktopConversation.endpoint(value)
                if edited.provider == .lmStudio { edited.lmStudioEndpoint = value } else { edited.ollamaEndpoint = value }
            case 2:
                let settings = edited
                guard let models = try WindowsRiggingFlow.work(text: S("desktop.settings.models.loading"), operation: {
                    try await DesktopConversation.models(preferences: settings)
                }) else { continue }
                guard !models.isEmpty else { throw DesktopConversation.ConversationError.noModel }
                let names = models.map { model in model.name + (model.parameterSizeLabel.map { " (\($0))" } ?? "") + (model.isSmallModel ? S("desktop.settings.models.small_suffix") : "") }
                guard let selected = try WindowsRiggingFlow.option(title: S("desktop.settings.models.choose"), items: names) else { continue }
                edited.model = models[selected].name
            case 3:
                if let personality = try WindowsRiggingFlow.text(title: S("desktop.settings.personality.title"), value: edited.personality) { edited.personality = personality }
            case 4: edited.automaticTurn.toggle()
            case 5: edited.widerHeadMovement.toggle()
            case 6:
                if let opacity = try WindowsRiggingFlow.option(title: S("desktop.settings.opacity.title"), items: ["100%", "80%", "60%", "40%", "20%"]) { edited.petOpacity = [1, 0.8, 0.6, 0.4, 0.2][opacity] }
            case 7:
                if let size = try WindowsRiggingFlow.option(title: S("desktop.settings.scale.title"), items: ["50%", "75%", "100%", "125%", "150%", "200%"]) { edited.scale = [0.5, 0.75, 1, 1.25, 1.5, 2][size] }
            case 8: edited.systemTTSEnabled.toggle()
            case 9:
                let voices = try WindowsVoiceFlow.voices()
                guard let index = try WindowsRiggingFlow.option(title: S("desktop.settings.voice.title"), items: [S("desktop.settings.voice.system_default")] + voices.map(\.name)) else { continue }
                edited.systemVoice = index == 0 ? "" : voices[index - 1].id
            case 10:
                if let choice = try WindowsRiggingFlow.option(title: S("desktop.settings.brain.title"), items: [S("desktop.settings.brain.local"), "Codex", "Claude Code"]) { edited.selectedBrain = [.local, .codex, .claudeCode][choice] }
            case 11: edited.automaticRouting.toggle()
            case 12:
                if let choice = try WindowsRiggingFlow.option(title: S("desktop.settings.external_brain.title"), items: ["Codex", "Claude Code"]) { edited.externalBrain = choice == 0 ? .codex : .claudeCode }
            case 13:
                if let value = try WindowsRiggingFlow.text(title: S("desktop.settings.codex.url_title"), value: edited.codexEndpoint) { edited.codexEndpoint = value }
            case 14:
                if let value = try WindowsRiggingFlow.text(title: S("desktop.settings.claude.url_title"), value: edited.claudeEndpoint) { edited.claudeEndpoint = value }
            case 15:
                if let value = try WindowsRiggingFlow.text(title: S("desktop.settings.workspace.full_path"), value: edited.workspacePath) { edited.workspacePath = value }
            case 16: edited.evasionEnabled.toggle()
            case 17:
                let styles = EvasionStyle.allCases
                if let choice = try WindowsRiggingFlow.option(title: S("desktop.settings.evasion_style.title"), items: styles.map { S("desktop.settings.evasion_style.\($0.rawValue)") }) { edited.evasionStyle = styles[choice] }
            case 18:
                let languages = SettingsDisplayLanguage.allCases
                if let choice = try WindowsRiggingFlow.option(title: S("settings.language.label"), items: languages.map(\.nativeLabel)) { edited.displayLanguage = languages[choice] }
            case 19: edited.buttonDodgeEnabled.toggle()
            case 20:
                edited.microphoneEnabled.toggle()
                edited.microphoneSetupCompleted = true
            case 21:
                let ja=language == .japanese
                guard let action=try WindowsRiggingFlow.option(title:"Neural TTS",items:ja ?
                    ["使用する / 使用しない","接続先（localhost）","モデルID","声ID","声の指示","言語（auto/ja/en等）","速度","モデルを準備","導入GUIを開く","Qwen音声helperを開く"] :
                    ["Enable / Disable","Endpoint (localhost)","Model ID","Voice ID","Voice instruction","Language (auto/ja/en)","Speed","Prepare model","Open setup","Open Qwen speech helper"]) else {continue}
                switch action {
                case 0:edited.neuralTTSEnabled.toggle();if edited.neuralTTSEnabled {edited.systemTTSEnabled=true}
                case 1:if let value=try WindowsRiggingFlow.text(title:"Neural TTS URL",value:edited.neuralEndpoint) {
                    _ = try NeuralSpeechTransport(endpoint:URL(string:value) ?? URL(string:"http://invalid")!);edited.neuralEndpoint=value }
                case 2:if let value=try WindowsRiggingFlow.text(title:"Model ID",value:edited.neuralModel){edited.neuralModel=value}
                case 3:if let value=try WindowsRiggingFlow.text(title:"Voice ID",value:edited.neuralVoice){edited.neuralVoice=value}
                case 4:if let value=try WindowsRiggingFlow.text(title:ja ? "声の指示":"Voice instruction",value:edited.neuralInstruction){edited.neuralInstruction=value}
                case 5:if let value=try WindowsRiggingFlow.text(title:ja ? "言語コード":"Language code",value:edited.neuralLanguage){edited.neuralLanguage=value}
                case 6:if let value=try WindowsRiggingFlow.text(title:ja ? "速度（0.5〜2）":"Speed (0.5–2)",value:String(edited.neuralSpeed)),let speed=Double(value),speed.isFinite,(0.5...2).contains(speed){edited.neuralSpeed=speed}
                case 7:
                    let settings=edited
                    _ = try WindowsRiggingFlow.work(text:ja ? "音声モデルを準備しています。追加モデルは大きい場合があります。":"Preparing the voice model. Additional models can be large.",operation:{
                        try await NeuralSpeechTransport(endpoint:URL(string:settings.neuralEndpoint)!).preload(model:settings.neuralModel)
                    })
                case 8:try WindowsRiggingFlow.openSetup()
                case 9:try WindowsRiggingFlow.startSpeechHelper()
                default:break
                }
            case 22:
                let ja = language == .japanese
                if let action = try WindowsRiggingFlow.option(title: ja ? "音声認識" : "Speech recognition", items: ja ? ["認識エンジンと診断を表示", "Windowsのマイク設定を開く"] : ["Show recognizers and diagnostics", "Open Windows microphone privacy settings"]) {
                    if action == 0 {
                        _ = try WindowsRiggingFlow.text(title: ja ? "音声認識の状態" : "Recognition status", value: WindowsVoiceFlow.recognitionStatus(language: language), readOnly: true)
                    } else { _ = "ms-settings:privacy-microphone".withCString { castor_open_url($0) } }
                }
            case 23: return edited
            default: return nil
            }
        }
    }
    static func chat(preferences: DesktopPreferences, history: inout [OllamaChatMessage], initialPrompt: String = "") throws -> String? {
        func S(_ key: String) -> String { CastorSettingsStrings.text(key, language: preferences.displayLanguage) }
        guard let prompt = try WindowsRiggingFlow.text(title: S("desktop.chat.prompt.title"), value: initialPrompt),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let selected = WindowsAgentFlow.brain(prompt: prompt, preferences: preferences)
        let completed: String?
        if selected == .local {
            let snapshot = history
            completed = try WindowsRiggingFlow.work(text: S("desktop.chat.generating"), operation: {
                try await DesktopConversation.reply(prompt: prompt, history: snapshot, preferences: preferences)
            })
        } else { completed = try WindowsAgentFlow.run(prompt: prompt, preferences: preferences) }
        guard let reply = completed else { return nil }
        // Only completed responses enter history; cancel/failure leaves it untouched.
        history += [OllamaChatMessage(role: .user, content: prompt), OllamaChatMessage(role: .assistant, content: reply)]
        history = Array(history.suffix(20))
        _ = try WindowsRiggingFlow.text(title: S("desktop.chat.reply.title"), value: reply, readOnly: true)
        return reply
    }
}
#endif
