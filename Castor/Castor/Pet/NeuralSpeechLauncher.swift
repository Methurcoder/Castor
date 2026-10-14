import AppKit
import Observation

/// Opens the packaged speech GUI through Launch Services; no shell or local pip.
@MainActor
@Observable
final class NeuralSpeechLauncher {
    static let shared = NeuralSpeechLauncher()
    private(set) var isLaunching = false
    private(set) var didOpenHelper = false
    private(set) var launchFailed = false
    @ObservationIgnored private var application: NSRunningApplication?
    var canStop: Bool { application?.isTerminated == false }

    static func helperURL(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.url(forResource: "CastorNeuralTTS", withExtension: "app") { return bundled }
        guard let home = NSHomeDirectoryForUser(NSUserName()) else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent("Applications/CastorNeuralTTS.app")
    }
    func start() async {
        guard !isLaunching else { return }
        isLaunching = true; launchFailed = false
        defer { isLaunching = false }
        guard let url = Self.helperURL() else { launchFailed = true; return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--start"]
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            didOpenHelper = true
        } catch { launchFailed = true }
    }
    func stop() {
        // Only the exact app returned by our user-requested launch is stopped.
        // An independently started speech service is never killed by port/PID.
        if application?.terminate() == true { didOpenHelper = false }
    }
}
