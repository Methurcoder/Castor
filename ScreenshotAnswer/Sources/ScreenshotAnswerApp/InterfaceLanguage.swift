import Foundation
import ScreenshotAnswerCore

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case japanese
    case english

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .japanese: "日本語"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .japanese: Locale(identifier: "ja")
        case .english: Locale(identifier: "en")
        }
    }

    func text(_ japanese: String, _ english: String) -> String {
        switch self {
        case .japanese: japanese
        case .english: english
        }
    }

    func errorDescription(for error: Error) -> String {
        guard self == .english else { return error.localizedDescription }

        if let error = error as? ScreenshotAnswerError {
            switch error {
            case .unreadableImage:
                return "The image could not be read."
            case .noTextFound:
                return "No text was detected in the image."
            case .lmStudioEndpointMustBeLocal:
                return "The LM Studio endpoint must be localhost."
            case .lmStudioUnavailable:
                return "Could not connect to LM Studio. Start its Local Server on port 1234."
            case .noLMStudioModel:
                return "The LM Studio Local Server did not return an available model."
            case let .lmStudioRequestFailed(message):
                return "The LM Studio request failed: \(message)"
            case let .imageModelRequired(model):
                return "\(model) does not support image input. Select a vision model in LM Studio."
            case .invalidLMStudioResponse:
                return "LM Studio returned a response that could not be understood."
            case .emptyAnswer:
                return "LM Studio returned an empty answer."
            }
        }

        if let error = error as? SystemAudioCaptureError {
            switch error {
            case .requiresMacOS26:
                return "Local system-audio transcription requires macOS 26 or later."
            case .speechPermissionDenied:
                return "Speech Recognition permission is missing. Allow it in Privacy & Security settings."
            case .unsupportedLanguage:
                return "On-device transcription is unavailable for the selected language."
            case .speechModelUnavailable:
                return "The transcription model could not be prepared. Check the network connection and free space."
            case .noDisplay:
                return "No capturable display is available."
            case .notRunning:
                return "System audio is not being captured."
            case .noSpeechDetected:
                return "No speech was recognized. Check the volume and transcription language."
            }
        }

        return error.localizedDescription
    }
}

struct LocalizedInterfaceText: Equatable {
    let japanese: String
    let english: String

    func value(for language: InterfaceLanguage) -> String {
        language.text(japanese, english)
    }
}

enum CaptureStorageMode: String, CaseIterable, Identifiable {
    case screenshotFolder
    case customFolder
    case temporary

    var id: String { rawValue }

    func label(for language: InterfaceLanguage) -> String {
        switch self {
        case .screenshotFolder:
            language.text("macOSのスクリーンショット保存先", "macOS Screenshot Folder")
        case .customFolder:
            language.text("指定したフォルダ", "Custom Folder")
        case .temporary:
            language.text("保存しない", "Do Not Save")
        }
    }
}
