#if os(Windows)
import CastorCore
import CDesktopUI
import Foundation
import PetRuntime

/// Speech starts only from a user action/selected setting; cancellation purges SAPI.
enum WindowsVoiceFlow {
    enum VoiceError: LocalizedError {
        case unavailable
        case recognitionFailed(String, SettingsDisplayLanguage)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Windows標準音声を利用できませんでした。Windowsに音声が導入されているか確認してください。"
            case .recognitionFailed(let diagnostic, let language):
                (language == .japanese
                    ? "音声を文字にできませんでした。Windowsの認識エンジンの言語と、デスクトップアプリのマイク許可を確認してください。最大20秒で停止します。"
                    : "Speech could not be transcribed. Check the Windows recognizer language and microphone access for desktop apps. Listening stops after 20 seconds.") + "\n[" + diagnostic + "]"
            }
        }
    }
    static func voices() throws -> [(name: String, id: String)] {
        var buffer = [CChar](repeating: 0, count: 131072)
        let status = buffer.withUnsafeMutableBufferPointer { castor_system_voices($0.baseAddress, $0.count) }
        guard status > 0 else { throw VoiceError.unavailable }
        return String(cString: buffer).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
    }
    /// `user`: what the person said this turn, read with the reply by the optional feeling model.
    static func speak(_ text:String,preferences:DesktopPreferences,user:String?=nil) throws {
        guard preferences.neuralTTSEnabled else {try speak(text,voice:preferences.systemVoice);return}
        do {
            _ = try WindowsRiggingFlow.work(text:preferences.displayLanguage == .japanese ?
                "Neural TTSで生成・再生しています。キャンセルで停止します。":"Generating and playing Neural TTS. Cancel to stop.",operation:{
                let transport=try NeuralSpeechTransport(endpoint:URL(string:preferences.neuralEndpoint)!)
                guard try await transport.isModelReady(model:preferences.neuralModel) else {throw VoiceError.unavailable}
                let instruct=DesktopFeelings.instruction(base:preferences.neuralInstruction,reply:text,user:user)
                let payload=NeuralSpeechPayload(model:preferences.neuralModel,input:text,instruct:instruct,
                    voice:preferences.neuralVoice,speed:preferences.neuralSpeed,langCode:preferences.neuralLanguage)
                let wav=try WavePCM(data:await transport.audio(for:payload))
                let status=wav.samples.withUnsafeBufferPointer {
                    castor_play_pcm($0.baseAddress,$0.count,Int32(wav.channels),Int32(wav.sampleRate),
                        { _ in Task<Never,Never>.isCancelled ? 1:0 },nil)
                }
                if status<0 {throw VoiceError.unavailable}
                try Task.checkCancellation()
            })
        } catch is CancellationError {return}
        catch {
            // Recover to an installed system voice without requiring a model/helper.
            try speak(text,voice:preferences.systemVoice)
        }
    }
    static func speak(_ text: String, voice: String) throws {
        _ = try WindowsRiggingFlow.work(text: "Windows標準音声で読み上げています。キャンセルすると停止します。", operation: {
            let status = text.withCString { text in voice.withCString { voice in
                castor_system_speak(text, voice, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            }}
            if status < 0 { throw VoiceError.unavailable }
            try Task.checkCancellation()
        })
    }
    static func recognitionStatus(language: SettingsDisplayLanguage) -> String {
        var buffer = [CChar](repeating: 0, count: 131072)
        let count = buffer.withUnsafeMutableBufferPointer { castor_system_recognizers($0.baseAddress, $0.count) }
        let names = count > 0 ? String(cString: buffer).split(separator: "\n").map { $0.split(separator: "\t").first.map(String.init) ?? "" }.joined(separator: "\n") : ""
        let message = language == .japanese
            ? "認識エンジン（Windowsの設定言語を使用）:\n" + (names.isEmpty ? "未検出" : names) + "\n\nマイク許可はここでは判定できません。Windows設定のプライバシーとセキュリティ → マイク → デスクトップアプリのアクセスを確認してください。"
            : "Recognition engines (Windows language settings):\n" + (names.isEmpty ? "None detected" : names) + "\n\nMicrophone permission cannot be determined here. Check Windows Settings → Privacy & security → Microphone → Desktop app access."
        return message + "\n\n" + (UserDefaults.standard.string(forKey: "Castor.SpeechInput.LastDiagnostic") ?? "")
    }
    static func recognize(language: SettingsDisplayLanguage) throws -> String? {
        try WindowsRiggingFlow.work(text: language == .japanese
            ? "マイクから聞き取っています（最大20秒）。認識後に内容を確認・編集できます。"
            : "Listening (up to 20 seconds). You can review and edit the transcript.", operation: {
            try Task.checkCancellation()
            guard castor_microphone_suspend(3000) == 1 else {
                let code = "SAPI1 stage=microphone_release end=timeout"
                UserDefaults.standard.set(code, forKey: "Castor.SpeechInput.LastDiagnostic")
                throw VoiceError.recognitionFailed(code, language)
            }
            try Task.checkCancellation()
            var buffer = [CChar](repeating: 0, count: 131072)
            var diagnostic = [CChar](repeating: 0, count: 1024)
            let status = buffer.withUnsafeMutableBufferPointer { output in
                diagnostic.withUnsafeMutableBufferPointer { detail in
                    castor_system_recognize_diagnostic(output.baseAddress, output.count, detail.baseAddress, detail.count,
                        { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
                }
            }
            let code = String(cString: diagnostic)
            UserDefaults.standard.set(code, forKey: "Castor.SpeechInput.LastDiagnostic")
            try Task.checkCancellation()
            if status == 0 { throw CancellationError() }
            guard status > 0, !String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceError.recognitionFailed(code, language)
            }
            return String(cString: buffer)
        })
    }
}
#endif
