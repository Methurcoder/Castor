import CastorCore
import Foundation
import Testing
@testable import PetRuntime

@Test func desktopLanguageRoundTripPreservesUserValuesAndOldPreferences() throws {
    let old = Data(#"{"personality":"custom English reply","lmStudioModel":"model/日本語","systemVoice":"voice-id"}"#.utf8)
    var preferences = try JSONDecoder().decode(DesktopPreferences.self, from: old)
    #expect(preferences.displayLanguage == .systemDefault && !preferences.buttonDodgeEnabled)
    #expect(!preferences.microphoneEnabled && !preferences.microphoneSetupCompleted)
    preferences.microphoneEnabled = true
    preferences.microphoneSetupCompleted = true
    preferences.displayLanguage = .english
    preferences.buttonDodgeEnabled = true
    let roundTrip = try JSONDecoder().decode(DesktopPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(roundTrip == preferences)
    #expect(roundTrip.personality == "custom English reply" && roundTrip.lmStudioModel == "model/日本語" && roundTrip.systemVoice == "voice-id")
}

@Test func unsupportedStoredLanguageFailsWithoutOverwritingSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("castor-language-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Preferences.json")
    let original = Data(#"{"displayLanguage":"fr","personality":"keep me"}"#.utf8)
    try original.write(to: file)
    #expect(throws: (any Error).self) { try DesktopPreferenceStore(root: root).load() }
    #expect(try Data(contentsOf: file) == original)
}
