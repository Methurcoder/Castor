import SwiftUI
import CastorCore

@main
struct CastorApp: App {
    @NSApplicationDelegateAdaptor(CastorAppDelegate.self) private var appDelegate
    @State private var core = HesitateCore()
    @State private var trilobite = TrilobiteEngine()
    @State private var ollama = OllamaSession()
    @AppStorage("Pomegranate.AppearanceMode")
    private var appearance: AppearanceMode = .system

    var body: some Scene {
        WindowGroup {
            ContentView(core: core, trilobite: trilobite)
                .onAppear {
                    CastorPetController.shared.setTrilobiteEngine(trilobite)
                }
        }
        .windowResizability(.contentSize)

        Settings {
            CastorSettingsView(core: core, trilobite: trilobite, ollama: ollama)
                .preferredColorScheme(appearance.preferredColorScheme)
        }
    }
}
