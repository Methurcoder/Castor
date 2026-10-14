#if os(Windows)
import CDesktopUI
import Foundation
import PetRuntime

/// Speech starts only from a user action/selected setting; cancellation purges SAPI.
enum WindowsVoiceFlow {
    enum VoiceError: LocalizedError {
        case unavailable, recognitionUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: "Windows標準音声を利用できませんでした。Windowsに音声が導入されているか確認してください。"
            case .recognitionUnavailable: "音声認識できませんでした。Windowsの音声認識エンジンと、デスクトップアプリのマイク許可を確認してください。認識は最大20秒で停止します。"
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
    static func speak(_ text: String, voice: String) throws {
        _ = try WindowsRiggingFlow.work(text: "Windows標準音声で読み上げています。キャンセルすると停止します。", operation: {
            let status = text.withCString { text in voice.withCString { voice in
                castor_system_speak(text, voice, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            }}
            if status < 0 { throw VoiceError.unavailable }
            try Task.checkCancellation()
        })
    }
    static func recognize() throws -> String? {
        try WindowsRiggingFlow.work(text: "マイクから聞き取っています（最大20秒）。認識後に内容を確認・編集できます。", operation: {
            var buffer = [CChar](repeating: 0, count: 131072)
            let status = buffer.withUnsafeMutableBufferPointer {
                castor_system_recognize($0.baseAddress, $0.count, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            }
            if status < 0 { throw VoiceError.recognitionUnavailable }
            try Task.checkCancellation()
            return String(cString: buffer)
        })
    }
}
#endif
