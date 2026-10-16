import ArilsPlayer
import Foundation
import Testing
@testable import PetRuntime

@Test func desktopDefaultsAndOldSettingsRemainCompatible() throws {
    let old = Data("{\"personality\":\"friendly\",\"lmStudioModel\":\"my-model\"}".utf8)
    let prefs = try JSONDecoder().decode(DesktopPreferences.self, from: old)
    #expect(prefs.personality == "friendly" && prefs.lmStudioModel == "my-model")
    #expect(prefs.selectedBrain == .local && !prefs.automaticRouting)
    #expect(prefs.scale == 1 && prefs.petOpacity == 1 && !prefs.systemTTSEnabled)
    #expect(try JSONDecoder().decode(DesktopPreferences.self, from: JSONEncoder().encode(prefs)) == prefs)
}
@Test func desktopSavePreservesPreviousSettingsOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("castor-preferences-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DesktopPreferenceStore(root: root)
    var original = DesktopPreferences(); original.personality = "hello"
    try store.save(original)
    var changed = original; changed.petOpacity = 0.4; changed.scale = 1.5
    try store.save(changed)
    #expect(try store.load() == changed)
    let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("PreferenceHistory"), includingPropertiesForKeys: nil)
    #expect(backups.count == 1)
    #expect(try JSONDecoder().decode(DesktopPreferences.self, from: Data(contentsOf: backups[0])) == original)
    var invalid = changed; invalid.lmStudioEndpoint = "https://example.com"
    #expect(throws: (any Error).self) { try store.save(invalid) }
    #expect(try store.load() == changed)
    invalid = changed; invalid.scale = 1e100
    #expect(throws: (any Error).self) { try store.save(invalid) }
    #expect(try store.load() == changed)
}
@Test func desktopConversationRejectsRemoteEndpointsAndCredentialURLs() {
    for endpoint in ["http://127.0.0.1:1234", "http://localhost:11434", "http://[::1]:1234"] {
        #expect((try? DesktopConversation.endpoint(endpoint)) != nil)
    }
    for endpoint in ["http://192.168.1.10:1234", "https://example.com", "file:///tmp/a", "http://user:password@localhost", "http://localhost?q=token", "http://localhost#x"] {
        #expect(throws: (any Error).self) { try DesktopConversation.endpoint(endpoint) }
    }
}
@Test func desktopCorruptSettingsAreNeverSilentlyReplaced() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("castor-corrupt-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Preferences.json")
    let bad = Data("{\"scale\":1e100}".utf8); try bad.write(to: file)
    #expect(throws: (any Error).self) { try DesktopPreferenceStore(root: root).load() }
    #expect(try Data(contentsOf: file) == bad)
}


@Test func qualityModePreferenceSurvivesRestartWithoutOverridingOldArchives() throws {
    let old = try JSONDecoder().decode(DesktopPreferences.self, from: Data("{}".utf8))
    #expect(old.qualityPresentationMode == nil)
    for mode in [QualityPresentationMode.twoD, .threeD] {
        var preferences = old; preferences.qualityPresentationMode = mode
        let encoded = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(DesktopPreferences.self, from: encoded).qualityPresentationMode == mode)
    }
}

@Test func naturalFaceMotionStartsOnEvenWhereTheBetaWasDeclined() throws {
    // v1.0.0 (d-beta) stored the beta as "naturalFaceMotion"; it is now on by
    // default under a new key, and can still be turned off.
    let old = Data(#"{"naturalFaceMotion": false, "naturalFaceMotionOffered": true}"#.utf8)
    var preferences = try JSONDecoder().decode(DesktopPreferences.self, from: old)
    #expect(preferences.naturalFaceMotion)
    preferences.naturalFaceMotion = false
    let reloaded = try JSONDecoder().decode(DesktopPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(!reloaded.naturalFaceMotion)
}
