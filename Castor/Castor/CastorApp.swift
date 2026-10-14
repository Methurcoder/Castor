import SwiftUI
import CastorCore

@main
struct CastorApp: App {
    @NSApplicationDelegateAdaptor(CastorAppDelegate.self) private var appDelegate
    @State private var core = HesitateCore()
    @State private var trilobite = TrilobiteEngine()
    @State private var ollama = OllamaSession()
    @AppStorage("Castor.SettingsDisplayLanguage")
    private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    @AppStorage("Pomegranate.AppearanceMode")
    private var appearance: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            ContentView(core: core, trilobite: trilobite)
                .environment(\.locale, Locale(identifier: displayLanguage.rawValue))
                .onAppear {
                    CastorPetController.shared.setTrilobiteEngine(trilobite)
                    trilobite.beginFirstRunMicrophoneSetup()
                }
        }
        .windowResizability(.contentSize)

        Settings {
            CastorSettingsView(core: core, trilobite: trilobite, ollama: ollama)
                .environment(\.locale, Locale(identifier: displayLanguage.rawValue))
                .preferredColorScheme(appearance.preferredColorScheme)
        }
    }
}
