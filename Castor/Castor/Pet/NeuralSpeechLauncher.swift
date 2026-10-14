import AppKit
import CastorCore
import Observation

/// Opens the packaged speech GUI through Launch Services; no shell or local pip.
@MainActor
@Observable
final class NeuralSpeechLauncher {
    static let shared = NeuralSpeechLauncher()
    private(set) var isLaunching = false
    private(set) var didOpenHelper = false
    private(set) var launchFailed = false
    private(set) var stopFailed = false
    private(set) var canStop = false
    @ObservationIgnored private var application: NSRunningApplication?
    @ObservationIgnored private var controlFile: URL?
    @ObservationIgnored private var pollTimer: Timer?

    static func helperURL(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.url(forResource: "CastorNeuralTTS", withExtension: "app") { return bundled }
        guard let home = NSHomeDirectoryForUser(NSUserName()) else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent("Applications/CastorNeuralTTS.app")
    }
    func start() async {
        guard !isLaunching else { return }
        isLaunching = true; launchFailed = false; stopFailed = false
        defer { isLaunching = false }
        guard let url = Self.helperURL() else { launchFailed = true; return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        if let application, !canStop {
            for _ in 0..<25 where !application.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if application?.isTerminated == true { application = nil; controlFile = nil }
        // A helper opened elsewhere stays under its owner's control.
        if application == nil, !NSRunningApplication.runningApplications(withBundleIdentifier: "dev.castor.neuraltts").isEmpty {
            do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration); didOpenHelper = true }
            catch { launchFailed = true }
            canStop = false
            return
        }
        do {
            if controlFile == nil {
                guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw CocoaError(.fileNoSuchFile) }
                let file = NeuralSpeechHelperControl.file(directory: support.appendingPathComponent("Castor/NeuralSpeechControl", isDirectory: true), session: UUID())
                try NeuralSpeechHelperControl.write(.run, to: file)
                try NeuralSpeechHelperControl.writeOwner(.init(parentPID: ProcessInfo.processInfo.processIdentifier, helperPath: url.path), to: file)
                controlFile = file
                configuration.createsNewApplicationInstance = true
                configuration.arguments = ["--start"]
            }
            application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            didOpenHelper = true; canStop = true
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.application?.isTerminated == true else { return }
                    self.canStop = false; self.didOpenHelper = false
                    if let file = self.controlFile { NeuralSpeechHelperControl.remove(file) }
                    self.controlFile = nil; self.application = nil
                    self.pollTimer?.invalidate(); self.pollTimer = nil
                }
            }
        } catch {
            launchFailed = true; canStop = false
            if application == nil, let file = controlFile { NeuralSpeechHelperControl.remove(file); controlFile = nil }
        }
    }
    func stop() {
        // The helper reads only this launch's container control file and terminates itself.
        // No signal, Apple event or port-based shutdown targets another user's service.
        guard canStop, let controlFile else { return }
        do {
            try NeuralSpeechHelperControl.write(.stop, to: controlFile)
            canStop = false; didOpenHelper = false; stopFailed = false
        } catch { stopFailed = true }
    }
}
