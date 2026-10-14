import AppKit
import CastorCore
import Observation

/// Starts the local Codex app server and Claude Code bridge without Terminal,
/// through the bundled `CastorAgentLauncher` helper (see its main.swift for
/// why a helper is needed), and reports what the helper found.
@MainActor
@Observable
final class AgentLauncher {
    static let shared = AgentLauncher()

    static let codexEnabledKey = "Castor.AgentLauncher.Codex.Enabled"
    static let claudeCodeEnabledKey = "Castor.AgentLauncher.ClaudeCode.Enabled"

    private(set) var status: AgentLauncherStatus?
    private(set) var launchError: String?
    private var pollTimer: Timer?
    private var restartGeneration = 0

    private init() {}

    // MARK: - Preferences

    func isEnabled(_ service: AgentLauncherService) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: service))
    }

    func setEnabled(_ enabled: Bool, for service: AgentLauncherService) {
        UserDefaults.standard.set(enabled, forKey: key(for: service))
        Task { await restart() }
    }

    private func key(for service: AgentLauncherService) -> String {
        switch service {
        case .codex: Self.codexEnabledKey
        case .claudeCode: Self.claudeCodeEnabledKey
        }
    }

    // MARK: - Lifecycle

    /// Called at launch: brings up whatever the user turned on.
    func startEnabledServices() {
        guard AgentLauncherService.allCases.contains(where: isEnabled) else { return }
        Task { await restart() }
    }

    /// Re-applies the current settings: stops the helper, then starts it with
    /// the enabled services (or leaves it stopped if none are).
    func restart() async {
        restartGeneration += 1
        let generation = restartGeneration
        launchError = nil
        await stopHelper()
        guard generation == restartGeneration else { return }
        let preferences = CastorAgentPreferenceStore.current
        var arguments = ["--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        for service in AgentLauncherService.allCases where isEnabled(service) {
            let url = service == .codex ? preferences.codexServerURL : preferences.claudeCodeBridgeURL
            arguments += [service.argumentName, url]
        }
        guard arguments.count > 2 else {
            refreshStatus()
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent(AgentLauncherSupport.helperRelativePath)
        guard FileManager.default.fileExists(atPath: helper.path) else {
            launchError = "The agent launcher is missing from this build of Castor."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
            guard generation == restartGeneration else { return }
            startPolling()
        } catch {
            launchError = "Could not open the agent launcher: \(error.localizedDescription)"
        }
    }

    /// Stops the helper and the services it runs (also called when Castor quits).
    func stopHelper() async {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: AgentLauncherSupport.helperBundleIdentifier
        )
        for app in running { app.terminate() }
        for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(75))
        }
        for app in running where !app.isTerminated { app.forceTerminate() }
    }

    func stopHelperBeforeQuit() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: AgentLauncherSupport.helperBundleIdentifier) {
            app.terminate()
        }
    }

    // MARK: - Status

    var statusFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Castor/AgentLauncher/status.json")
    }

    func refreshStatus() {
        guard let statusFile, let data = try? Data(contentsOf: statusFile) else {
            status = nil
            return
        }
        status = AgentLauncherStatus.decode(data)
    }

    /// Polls the status file while the helper is getting ready, then slows down.
    func startPolling() {
        pollTimer?.invalidate()
        refreshStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    func summary(for service: AgentLauncherService) -> (text: String, isProblem: Bool) {
        if let launchError, isEnabled(service) {
            return (launchError, true)
        }
        guard isEnabled(service) else {
            return ("Off", false)
        }
        guard let status = status?.status(of: service) else {
            return ("Starting…", false)
        }
        switch status.state {
        case .starting: return ("Starting…", false)
        case .ready: return ("Running on this Mac", false)
        case .alreadyRunning: return ("Already running (started elsewhere)", false)
        case .missingTool:
            let install = service == .codex
                ? "Install the Codex CLI and sign in, then turn this on again."
                : "Install Claude Code and sign in, then turn this on again."
            return ("\(status.detail) \(install)", true)
        case .invalidAddress: return (status.detail, true)
        case .failed: return ("Stopped: \(status.detail)", true)
        case .stopped: return ("Stopped", false)
        }
    }
}
