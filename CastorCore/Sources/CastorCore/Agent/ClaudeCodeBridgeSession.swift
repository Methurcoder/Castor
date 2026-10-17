import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

public nonisolated struct ClaudeCodeApprovalRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let approvalID: String
    public let turnID: String
    public let toolName: String
    public let title: String
    public let detail: String

    public init(
        approvalID: String,
        turnID: String,
        toolName: String,
        title: String,
        detail: String
    ) {
        self.approvalID = approvalID
        self.turnID = turnID
        self.toolName = toolName
        self.title = title
        self.detail = detail
    }
}

public nonisolated enum ClaudeCodeBridgeError: LocalizedError, Equatable {
    case invalidBridgeURL
    case nonLoopbackBridge
    case malformedResponse
    case bridge(String)
    case disconnected(String)
    /// Nothing answers at the bridge address: the bridge is not running.
    case bridgeNotRunning

    public var errorDescription: String? {
        switch self {
        case .invalidBridgeURL:
            "Enter a valid Claude Code bridge HTTP URL."
        case .nonLoopbackBridge:
            "For safety, Castor only connects to the Claude Code bridge on this device."
        case .malformedResponse:
            "The Claude Code bridge returned an unreadable response."
        case .bridge(let message), .disconnected(let message):
            message
        case .bridgeNotRunning:
            (SettingsDisplayLanguage(rawValue: UserDefaults.standard.string(forKey: "Castor.SettingsDisplayLanguage") ?? "")
                ?? .systemDefault) == .japanese
                ? "Claude Code につながりませんでした。Claude Code bridge が起動していません。設定の「Castor から Claude Code bridge を起動」をオンにするか、bridge を起動してから、もう一度話しかけてください。"
                : "Could not reach Claude Code: the Claude Code bridge is not running. Turn on “Start the Claude Code Bridge with Castor” in Settings, or start the bridge, then talk again."
        }
    }

    /// The bridge address refused or could not be reached at all.
    static func isNotRunning(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return code == .cannotConnectToHost || code == .cannotFindHost
    }

    /// How long the health check waits. Foundation on Windows never reports
    /// a refused connection; it waits for the request's timeout, which for a
    /// turn is a day. The short check turns that into a few seconds.
    static let healthCheckTimeout: TimeInterval = 4
}

@MainActor
@Observable
public final class ClaudeCodeBridgeSession {
    public private(set) var pendingApproval: ClaudeCodeApprovalRequest?

    private var activeTurnID: String?
    private var activeBridgeURL: URL?
    private var sessionID: String?
    private var sessionConfigurationKey: String?
    private var responseBuffer = ""

    private var deltaHandler: ((String) -> Void)?
    private var statusHandler: ((String) -> Void)?
    private var approvalHandler: ((ClaudeCodeApprovalRequest?) -> Void)?

    public nonisolated static func isAllowedBridgeURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "http" || components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        let host = components.host?.lowercased()
        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        let path = components.path
        return isLoopback && (path.isEmpty || path == "/")
    }

    public func send(
        prompt: String,
        bridgeURL: String,
        workspacePath: String,
        personalityInstruction: String,
        onDelta: @escaping (String) -> Void,
        onStatus: @escaping (String) -> Void,
        onApproval: @escaping (ClaudeCodeApprovalRequest?) -> Void
    ) async throws -> String {
        guard let baseURL = URL(string: bridgeURL),
              baseURL.scheme == "http" || baseURL.scheme == "https" else {
            throw ClaudeCodeBridgeError.invalidBridgeURL
        }
        guard Self.isAllowedBridgeURL(bridgeURL) else {
            throw ClaudeCodeBridgeError.nonLoopbackBridge
        }

        deltaHandler = onDelta
        statusHandler = onStatus
        approvalHandler = onApproval
        responseBuffer = ""
        pendingApproval = nil

        let trimmedWorkspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let configurationKey = "\(baseURL.absoluteString)|\(trimmedWorkspace)|\(personalityInstruction)"
        if sessionConfigurationKey != configurationKey {
            sessionID = nil
            sessionConfigurationKey = configurationKey
        }

        let turnID = UUID().uuidString
        activeTurnID = turnID
        activeBridgeURL = baseURL

        return try await withTaskCancellationHandler {
            defer {
                if activeTurnID == turnID {
                    activeTurnID = nil
                    pendingApproval = nil
                    approvalHandler?(nil)
                }
            }
            return try await performTurn(
                turnID: turnID,
                prompt: prompt,
                baseURL: baseURL,
                workspacePath: trimmedWorkspace,
                personalityInstruction: personalityInstruction
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cancelTurn(turnID: turnID, baseURL: baseURL)
            }
        }
    }

    public func resolveApproval(_ request: ClaudeCodeApprovalRequest, approved: Bool) async throws {
        guard pendingApproval?.id == request.id,
              let baseURL = activeBridgeURL else {
            return
        }
        let endpoint = baseURL.appending(path: "v1/approvals/\(request.approvalID)")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            ApprovalResponse(turnID: request.turnID, approved: approved)
        )
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try Self.validateHTTPResponse(response, data: data)
        pendingApproval = nil
        approvalHandler?(nil)
        statusHandler?(approved ? "Approved. Claude Code is continuing..." : "Declined. Claude Code is continuing...")
    }

    public func disconnect() {
        guard let turnID = activeTurnID, let baseURL = activeBridgeURL else {
            sessionID = nil
            sessionConfigurationKey = nil
            return
        }
        activeTurnID = nil
        pendingApproval = nil
        approvalHandler?(nil)
        sessionID = nil
        sessionConfigurationKey = nil
        Task { @MainActor [weak self] in
            await self?.cancelTurn(turnID: turnID, baseURL: baseURL)
        }
    }

    public static func approvalDetail(toolName: String, input: CodexJSONValue) -> String {
        let friendlyAction: String
        switch toolName {
        case "Bash":
            friendlyAction = "Claude Code wants to run a command."
        case "Edit", "Write", "NotebookEdit":
            friendlyAction = "Claude Code wants to change files."
        default:
            friendlyAction = "Claude Code wants to use \(toolName)."
        }
        return "\(friendlyAction)\n\nRequested input:\n\(input.formattedForDisplay)"
    }

    private func performTurn(
        turnID: String,
        prompt: String,
        baseURL: URL,
        workspacePath: String,
        personalityInstruction: String
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "v1/turn"))
        request.httpMethod = "POST"
        request.timeoutInterval = 24 * 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TurnRequest(
                turnID: turnID,
                prompt: prompt,
                workspacePath: workspacePath,
                personalityInstruction: personalityInstruction,
                sessionID: sessionID
            )
        )

        statusHandler?("Connecting to Claude Code bridge...")
        try await Self.checkBridgeIsRunning(baseURL)
        let lines: AsyncThrowingStream<String, Error>
        let response: URLResponse
        do {
            (lines, response) = try await HTTPLineStream.lines(for: request)
        } catch where ClaudeCodeBridgeError.isNotRunning(error) {
            throw ClaudeCodeBridgeError.bridgeNotRunning
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeCodeBridgeError.malformedResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in lines {
                body += line
            }
            let message = Self.bridgeErrorMessage(from: Data(body.utf8))
                ?? "Claude Code bridge returned HTTP \(httpResponse.statusCode)."
            throw ClaudeCodeBridgeError.bridge(message)
        }

        var receivedResult = false
        for try await line in lines {
            try Task.checkCancellation()
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(BridgeEvent.self, from: data) else {
                continue
            }
            switch event.type {
            case "status":
                if let message = event.message {
                    statusHandler?(message)
                }
            case "session":
                if let newSessionID = event.sessionID, !newSessionID.isEmpty {
                    sessionID = newSessionID
                }
            case "delta":
                if let text = event.text {
                    responseBuffer += text
                    deltaHandler?(responseBuffer)
                }
            case "approval":
                guard let approvalID = event.approvalID,
                      let toolName = event.toolName,
                      let input = event.input else {
                    throw ClaudeCodeBridgeError.malformedResponse
                }
                let approval = ClaudeCodeApprovalRequest(
                    approvalID: approvalID,
                    turnID: turnID,
                    toolName: toolName,
                    title: Self.approvalTitle(for: toolName),
                    detail: Self.approvalDetail(toolName: toolName, input: input)
                )
                pendingApproval = approval
                approvalHandler?(approval)
                statusHandler?("Waiting for your approval...")
            case "result":
                receivedResult = true
                let finalText = event.text ?? ""
                if !finalText.isEmpty {
                    responseBuffer = finalText
                    deltaHandler?(finalText)
                }
            case "error":
                throw ClaudeCodeBridgeError.bridge(event.message ?? "Claude Code could not complete the request.")
            default:
                continue
            }
        }

        guard receivedResult else {
            throw ClaudeCodeBridgeError.disconnected("The Claude Code bridge connection closed before the turn completed.")
        }
        return responseBuffer
    }

    private func cancelTurn(turnID: String, baseURL: URL) async {
        var request = URLRequest(url: baseURL.appending(path: "v1/turn/\(turnID)/cancel"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func approvalTitle(for toolName: String) -> String {
        switch toolName {
        case "Bash":
            "Allow this command?"
        case "Edit", "Write", "NotebookEdit":
            "Allow file changes?"
        default:
            "Allow \(toolName)?"
        }
    }

    /// Asks the bridge's /health with a short timeout before a turn. Any HTTP
    /// answer means something is listening; no answer in time means the
    /// bridge is not running.
    static func checkBridgeIsRunning(_ baseURL: URL, session: URLSession = .shared) async throws {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = ClaudeCodeBridgeError.healthCheckTimeout
        let failure: Error? = await withCheckedContinuation { continuation in
            session.dataTask(with: request) { _, _, error in continuation.resume(returning: error) }.resume()
        }
        guard let failure else { return }
        if ClaudeCodeBridgeError.isNotRunning(failure) || (failure as? URLError)?.code == .timedOut {
            throw ClaudeCodeBridgeError.bridgeNotRunning
        }
        throw failure
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeCodeBridgeError.malformedResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClaudeCodeBridgeError.bridge(
                bridgeErrorMessage(from: data) ?? "Claude Code bridge returned HTTP \(httpResponse.statusCode)."
            )
        }
    }

    private static func bridgeErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(BridgeErrorResponse.self, from: data))?.error
    }

    public init() {}
}

private struct TurnRequest: Encodable {
    let turnID: String
    let prompt: String
    let workspacePath: String
    let personalityInstruction: String
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case prompt
        case workspacePath = "workspace_path"
        case personalityInstruction = "personality_instruction"
        case sessionID = "session_id"
    }
}

private struct ApprovalResponse: Encodable {
    let turnID: String
    let approved: Bool

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case approved
    }
}

private struct BridgeEvent: Decodable {
    let type: String
    let message: String?
    let text: String?
    let sessionID: String?
    let approvalID: String?
    let toolName: String?
    let input: CodexJSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case message
        case text
        case sessionID = "session_id"
        case approvalID = "approval_id"
        case toolName = "tool_name"
        case input
    }
}

private struct BridgeErrorResponse: Decodable {
    let error: String
}
