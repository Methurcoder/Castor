import Foundation

/// Shared between Castor and its agent launcher helper. The sandboxed app
/// cannot start `codex` or the Claude Code bridge itself (children would
/// inherit the sandbox and lose the user's CLI configuration and login), so
/// it opens a small unsandboxed helper app that runs them and reports back
/// through a status file in Castor's own container.
public nonisolated enum AgentLauncherService: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode

    /// Helper command-line flag carrying this service's listen URL.
    public var argumentName: String {
        switch self {
        case .codex: "--codex-listen"
        case .claudeCode: "--claude-listen"
        }
    }
}

public nonisolated struct AgentLauncherServiceStatus: Codable, Equatable, Sendable {
    public nonisolated enum State: String, Codable, Sendable {
        /// The process was started and is not yet accepting connections.
        case starting
        /// Accepting connections on its local address.
        case ready
        /// Something was already listening on the address, so nothing was started.
        case alreadyRunning
        /// The CLI (or Python for the Claude Code bridge) was not found.
        case missingTool
        /// The address is not on this Mac; the helper refuses to listen elsewhere.
        case invalidAddress
        /// The process exited or never became reachable.
        case failed
        case stopped
    }

    public var state: State
    public var detail: String

    public init(state: State, detail: String = "") {
        self.state = state
        self.detail = detail
    }
}

public nonisolated struct AgentLauncherStatus: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var helperProcessID: Int32
    public var services: [String: AgentLauncherServiceStatus]

    public init(updatedAt: Date, helperProcessID: Int32, services: [String: AgentLauncherServiceStatus]) {
        self.updatedAt = updatedAt
        self.helperProcessID = helperProcessID
        self.services = services
    }

    public func status(of service: AgentLauncherService) -> AgentLauncherServiceStatus? {
        services[service.rawValue]
    }

    public static func decode(_ data: Data) -> AgentLauncherStatus? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AgentLauncherStatus.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public nonisolated enum AgentLauncherSupport {
    public static let helperBundleIdentifier = "dev.pomegranate.prototype.AgentLauncher"
    public static let helperAppName = "CastorAgentLauncher.app"
    /// Location inside Castor.app.
    public static let helperRelativePath = "Contents/Library/Helpers/\(helperAppName)"

    /// Host and port of a listen URL, accepted only on this Mac's loopback
    /// interface: the services hand an agent the user's workspace, so they
    /// must never listen where another machine could reach them.
    public static func loopbackEndpoint(_ urlString: String) -> (host: String, port: Int)? {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["ws", "http"].contains(scheme),
              let host = components.host?.lowercased(),
              ["127.0.0.1", "localhost"].contains(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let port = components.port,
              (1024...65535).contains(port) else {
            return nil
        }
        return (host == "localhost" ? "127.0.0.1" : host, port)
    }

    /// `PATH` from the output of `env` run in the user's login shell, which
    /// is where Homebrew, npm, nvm and the Claude Code installer put their
    /// binaries. GUI apps do not inherit it.
    public static func path(fromEnvironmentOutput output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix("PATH=") }
            .map { String($0.dropFirst("PATH=".count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Directories where these CLIs are commonly installed, searched after
    /// the login shell's PATH (and on their own if the shell cannot be read).
    public static func fallbackDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    /// Joins search directories without duplicates, keeping the first occurrence.
    public static func searchPath(shellPath: String?, home: String) -> [String] {
        var seen = Set<String>()
        let ordered = (shellPath?.split(separator: ":").map(String.init) ?? []) + fallbackDirectories(home: home)
        return ordered.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// First executable named `name` in `directories`.
    public static func findExecutable(_ name: String, in directories: [String], fileManager: FileManager = .default) -> String? {
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
