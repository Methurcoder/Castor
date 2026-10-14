#if os(Windows)
import CastorCore
import Foundation
import PetRuntime

/// No command/helper is required for local chat; both services remain optional.
enum WindowsConversationFlow {
    static func settings(_ existing: DesktopPreferences) throws -> DesktopPreferences? {
        var edited = existing
        while true {
            guard let item = try WindowsRiggingFlow.option(title: "Castor - 設定（保存して閉じるまで適用しません）", items: [
                "会話サービス: \(edited.provider == .lmStudio ? "LM Studio" : "Ollama")",
                "ローカル接続先: \(edited.endpoint)", "モデル: \(edited.model)", "キャラクターの性格",
                "自動視点: \(edited.automaticTurn ? "オン" : "オフ")", "広い首振り: \(edited.widerHeadMovement ? "オン" : "オフ")",
                "ペットの不透明度: \(Int(edited.petOpacity * 100))%", "ペットの大きさ: \(Int(edited.scale * 100))%",
                "標準読み上げ: \(edited.systemTTSEnabled ? "オン" : "オフ")", "標準音声を選ぶ", "Brain: \(edited.selectedBrain.rawValue)",
                "自動ルーティング: \(edited.automaticRouting ? "オン" : "オフ")", "自動時の外部Brain: \(edited.externalBrain.rawValue)",
                "Codex App Server接続先", "Claude Code Bridge接続先", "操作対象フォルダ", "保存して閉じる", "変更を破棄して閉じる"
            ]) else { return nil }
            switch item {
            case 0:
                guard let provider = try WindowsRiggingFlow.option(title: "会話サービス", items: ["LM Studio", "Ollama"]) else { continue }
                edited.provider = provider == 0 ? .lmStudio : .ollama
            case 1:
                guard let value = try WindowsRiggingFlow.text(title: "ローカル接続先（http(s)://127.0.0.1 / localhost / [::1]）", value: edited.endpoint) else { continue }
                _ = try DesktopConversation.endpoint(value)
                if edited.provider == .lmStudio { edited.lmStudioEndpoint = value } else { edited.ollamaEndpoint = value }
            case 2:
                let settings = edited
                guard let models = try WindowsRiggingFlow.work(text: "ローカルサービスの会話用モデルを取得しています。", operation: {
                    try await DesktopConversation.models(preferences: settings)
                }) else { continue }
                guard !models.isEmpty else { throw DesktopConversation.ConversationError.noModel }
                let names = models.map { model in model.name + (model.parameterSizeLabel.map { " (\($0))" } ?? "") + (model.isSmallModel ? " — 7B未満の目安" : "") }
                guard let selected = try WindowsRiggingFlow.option(title: "会話用モデルを選択（小さなモデルも選べます）", items: names) else { continue }
                edited.model = models[selected].name
            case 3:
                if let personality = try WindowsRiggingFlow.text(title: "キャラクターの会話上の性格", value: edited.personality) { edited.personality = personality }
            case 4: edited.automaticTurn.toggle()
            case 5: edited.widerHeadMovement.toggle()
            case 6:
                if let opacity = try WindowsRiggingFlow.option(title: "ペットの不透明度", items: ["100%", "80%", "60%", "40%", "20%"]) { edited.petOpacity = [1, 0.8, 0.6, 0.4, 0.2][opacity] }
            case 7:
                if let size = try WindowsRiggingFlow.option(title: "ペットの大きさ", items: ["50%", "75%", "100%", "125%", "150%", "200%"]) { edited.scale = [0.5, 0.75, 1, 1.25, 1.5, 2][size] }
            case 8: edited.systemTTSEnabled.toggle()
            case 9:
                let voices = try WindowsVoiceFlow.voices()
                guard let index = try WindowsRiggingFlow.option(title: "Windows標準音声", items: ["システム既定"] + voices.map(\.name)) else { continue }
                edited.systemVoice = index == 0 ? "" : voices[index - 1].id
            case 10:
                if let choice = try WindowsRiggingFlow.option(title: "Brain（外部接続は送信時に行います）", items: ["ローカル会話", "Codex", "Claude Code"]) { edited.selectedBrain = [.local, .codex, .claudeCode][choice] }
            case 11: edited.automaticRouting.toggle()
            case 12:
                if let choice = try WindowsRiggingFlow.option(title: "操作依頼の転送先", items: ["Codex", "Claude Code"]) { edited.externalBrain = choice == 0 ? .codex : .claudeCode }
            case 13:
                if let value = try WindowsRiggingFlow.text(title: "Codex App Server（ローカルWebSocketのみ）", value: edited.codexEndpoint) { edited.codexEndpoint = value }
            case 14:
                if let value = try WindowsRiggingFlow.text(title: "Claude Code Bridge（ローカルHTTPのみ）", value: edited.claudeEndpoint) { edited.claudeEndpoint = value }
            case 15:
                if let value = try WindowsRiggingFlow.text(title: "操作対象フォルダのフルパス", value: edited.workspacePath) { edited.workspacePath = value }
            case 16:
                return edited
            default: return nil
            }
        }
    }
    static func chat(preferences: DesktopPreferences, history: inout [OllamaChatMessage], initialPrompt: String = "") throws -> String? {
        guard let prompt = try WindowsRiggingFlow.text(title: "Castor - 会話/操作依頼（転送先はBrain設定で選択）", value: initialPrompt),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let selected = WindowsAgentFlow.brain(prompt: prompt, preferences: preferences)
        let completed: String?
        if selected == .local {
            let snapshot = history
            completed = try WindowsRiggingFlow.work(text: "ローカルモデルが応答を生成しています。", operation: {
                try await DesktopConversation.reply(prompt: prompt, history: snapshot, preferences: preferences)
            })
        } else { completed = try WindowsAgentFlow.run(prompt: prompt, preferences: preferences) }
        guard let reply = completed else { return nil }
        // Only completed responses enter history; cancel/failure leaves it untouched.
        history += [OllamaChatMessage(role: .user, content: prompt), OllamaChatMessage(role: .assistant, content: reply)]
        history = Array(history.suffix(20))
        _ = try WindowsRiggingFlow.text(title: "Castor - 応答（選択してコピーできます）", value: reply, readOnly: true)
        return reply
    }
}
#endif
