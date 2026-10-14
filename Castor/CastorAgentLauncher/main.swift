// CastorAgentLauncher: starts the local Codex app server and the Claude Code
// bridge for Castor, so nobody has to open Terminal.
//
// Castor is sandboxed; processes it spawns inherit the sandbox and cannot read
// the user's CLI configuration or login. Castor therefore opens this bundled,
// unsandboxed helper through Launch Services:
//
//     CastorAgentLauncher --parent-pid PID [--codex-listen URL] [--claude-listen URL]
//
// The helper only listens on this Mac's loopback interface, writes its status
// to Castor's own container, and stops its services and quits when Castor quits.

import AppKit
import CastorCore
import Darwin

private final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private var parentPID: pid_t?
    private var requests: [(AgentLauncherService, String)] = []
    private var processes: [AgentLauncherService: Process] = [:]
    private var statuses: [String: AgentLauncherServiceStatus] = [:]
    private var watchdog: Timer?
    private var searchDirectories: [String] = []

    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private lazy var supportDirectory = URL(fileURLWithPath: home)
        .appendingPathComponent("Library/Containers/dev.pomegranate.prototype/Data/Library/Application Support/Castor/AgentLauncher", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments(Array(CommandLine.arguments.dropFirst()))
        guard let parentPID, parentPID > 1,
              NSRunningApplication(processIdentifier: parentPID)?.bundleIdentifier == "dev.pomegranate.prototype" else {
            NSApp.terminate(nil);return
        }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        for (service, _) in requests {
            statuses[service.rawValue] = .init(state: .starting, detail: "Looking for the command…")
        }
        writeStatus()

        // Quit with Castor so no server outlives the app that uses it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let parentPID = self.parentPID else { return }
            if kill(parentPID, 0) != 0, errno == ESRCH {
                NSApp.terminate(nil)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let directories = AgentLauncherSupport.searchPath(shellPath: Self.loginShellPath(), home: self.home)
            DispatchQueue.main.async {
                self.searchDirectories = directories
                for (service, url) in self.requests {
                    self.start(service, listen: url)
                }
                if self.requests.isEmpty {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for (service, process) in processes where process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            statuses[service.rawValue] = .init(state: .stopped)
        }
        for (key, status) in statuses where status.state == .starting || status.state == .ready {
            statuses[key] = .init(state: .stopped)
        }
        writeStatus()
    }

    // MARK: - Arguments

    private func parseArguments(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            if argument == "--parent-pid", let value, let pid = pid_t(value) {
                parentPID = pid
                index += 2
            } else if let service = AgentLauncherService.allCases.first(where: { $0.argumentName == argument }), let value {
                requests.removeAll { $0.0 == service }
                requests.append((service, value))
                index += 2
            } else {
                index += 1
            }
        }
    }

    // MARK: - Services

    private func start(_ service: AgentLauncherService, listen url: String) {
        guard let endpoint = AgentLauncherSupport.loopbackEndpoint(url),
              URL(string:url)?.scheme == (service == .codex ? "ws" : "http") else {
            update(service, .invalidAddress, "Only 127.0.0.1 or localhost with a port of 1024 or above is allowed.")
            return
        }
        if Self.isListening(port: endpoint.port) {
            update(service, .alreadyRunning, "Something is already listening on port \(endpoint.port).")
            return
        }

        let executable: String
        let arguments: [String]
        switch service {
        case .codex:
            guard let codex = AgentLauncherSupport.findExecutable("codex", in: searchDirectories) else {
                update(service, .missingTool, "Codex CLI was not found.")
                return
            }
            executable = codex
            arguments = ["app-server", "--listen", url]
        case .claudeCode:
            guard let claude = AgentLauncherSupport.findExecutable("claude", in: searchDirectories) else {
                update(service, .missingTool, "Claude Code CLI was not found.")
                return
            }
            guard let python = usablePython() else {
                update(service, .missingTool, "Python 3 was not found. Install the Command Line Tools (xcode-select --install) or Python 3.")
                return
            }
            guard let script = Bundle.main.url(forResource: "claude_code_bridge", withExtension: "py") else {
                update(service, .failed, "The bridge script is missing from this build.")
                return
            }
            executable = python
            arguments = [script.path, "--listen", url, "--claude-path", claude]
        }

        let log = supportDirectory.appendingPathComponent("\(service.rawValue).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchDirectories.joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.processes[service] === finished else { return }
                self.processes[service] = nil
                let tail = Self.tail(of: log)
                self.update(service, .failed, "Exited (\(finished.terminationStatus)). \(tail)")
            }
        }
        do {
            try process.run()
        } catch {
            update(service, .failed, "Could not start \(executable): \(error.localizedDescription)")
            return
        }
        processes[service] = process
        update(service, .starting, executable)
        waitUntilReachable(service, port: endpoint.port, deadline: Date().addingTimeInterval(20))
    }

    private func waitUntilReachable(_ service: AgentLauncherService, port: Int, deadline: Date) {
        guard let process = processes[service], process.isRunning else { return }
        if Self.isListening(port: port) {
            update(service, .ready, process.executableURL?.path ?? "")
            return
        }
        guard Date() < deadline else {
            process.terminate()
            update(service, .failed, "Did not start listening on port \(port).")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.waitUntilReachable(service, port: port, deadline: deadline)
        }
    }

    /// A Python 3 that will run without prompting. `/usr/bin/python3` is only
    /// a stub (it offers to install the Command Line Tools) unless a
    /// developer directory is selected.
    private func usablePython() -> String? {
        let candidates = searchDirectories.compactMap {
            AgentLauncherSupport.findExecutable("python3", in: [$0])
        }
        for candidate in candidates {
            if candidate == "/usr/bin/python3" {
                guard Self.run("/usr/bin/xcode-select", ["-p"], timeout: 3)?.status == 0 else { continue }
            }
            return candidate
        }
        return nil
    }

    private func update(_ service: AgentLauncherService, _ state: AgentLauncherServiceStatus.State, _ detail: String) {
        statuses[service.rawValue] = .init(state: state, detail: detail)
        writeStatus()
    }

    private func writeStatus() {
        let status = AgentLauncherStatus(
            updatedAt: Date(),
            helperProcessID: getpid(),
            services: statuses
        )
        guard let data = try? status.encoded() else { return }
        try? data.write(to: supportDirectory.appendingPathComponent("status.json"), options: .atomic)
    }

    // MARK: - Helpers

    /// PATH as the user's login shell sets it up (Homebrew, npm, nvm, the
    /// Claude Code installer). GUI apps start with a minimal PATH.
    private static func loginShellPath() -> String? {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        // fish exposes PATH as a list; joining explicitly preserves colons.
        let command = URL(fileURLWithPath: shell).lastPathComponent == "fish"
            ? #"printf 'PATH=%s\n' (string join : $PATH)"#
            : #"printf 'PATH=%s\n' "$PATH""#
        guard let output = run(shell, ["-l", "-i", "-c", command], timeout: 8)?.output else {
            return nil
        }
        return AgentLauncherSupport.path(fromEnvironmentOutput: output)
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var collected = Data()
        let reader = pipe.fileHandleForReading
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        collected.append(reader.readDataToEndOfFile())
        return (process.terminationStatus, String(decoding: collected, as: UTF8.self))
    }

    private static func isListening(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func tail(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
    }
}

private let delegate = LauncherDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.delegate = delegate
application.run()
