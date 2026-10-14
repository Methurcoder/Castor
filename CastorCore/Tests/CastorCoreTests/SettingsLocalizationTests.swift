import Foundation
import Testing
@testable import CastorCore

@Test func settingsCatalogHasBothLanguagesAndUnknownLabelsKeepTheirValues() {
    for key in CastorSettingsStrings.keys {
        for language in SettingsDisplayLanguage.allCases {
            let translated = CastorSettingsStrings.text(key, language: language)
            #expect(!translated.isEmpty && translated != key)
        }
    }
    #expect(CastorSettingsStrings.text("future.setting", language: .english, fallback: "Original label") == "Original label")
    #expect(CastorSettingsStrings.label("model/日本語{detail}", language: .english) == "model/日本語{detail}")
    #expect(CastorSettingsStrings.label("Choose each time", language: .japanese) == "毎回選ぶ")
}

@Test func settingsInterpolationPreservesIDsAndNeverReinterpretsValues() {
    let model = "model/{provider}/日本語"
    #expect(CastorSettingsStrings.text("desktop.settings.model", language: .english, arguments: ["model": model, "provider": "changed"]) == "Model: " + model)
    #expect(CastorSettingsStrings.label("Stopped: detail {model}", language: .japanese) == "停止: detail {model}")
    #expect(CastorSettingsStrings.label("Unavailable: http://localhost:1234", language: .english) == "Unavailable: http://localhost:1234")
}

@Test func settingsDisclosuresRetainDestinationsBillingAndApproval() {
    let codex = CastorSettingsStrings.text("settings.codex.disclosure.body", language: .japanese)
    #expect(codex.contains("OpenAI") && codex.contains("API") && codex.contains("ワークスペース"))
    let claude = CastorSettingsStrings.text("settings.claude.disclosure.body", language: .english)
    #expect(claude.contains("Anthropic") && claude.contains("API charges") && claude.contains("approval") && claude.contains("On-device"))
    #expect(SettingsDisplayLanguage.japanese.rawValue == "ja" && SettingsDisplayLanguage.english.rawValue == "en")
}

@Test func settingsInitialLanguageFollowsOSWithoutPrompting() {
    #expect(SettingsDisplayLanguage.preferred(for: ["ja-JP", "en-US"]) == .japanese)
    #expect(SettingsDisplayLanguage.preferred(for: ["JA_jp"]) == .japanese)
    #expect(SettingsDisplayLanguage.preferred(for: ["en-US", "ja-JP"]) == .english)
    #expect(SettingsDisplayLanguage.preferred(for: ["fr-FR"]) == .english)
    #expect(SettingsDisplayLanguage.preferred(for: []) == .english)
}
