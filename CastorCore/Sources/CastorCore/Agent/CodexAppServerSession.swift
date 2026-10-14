import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

public nonisolated enum CodexJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: CodexJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var formattedForDisplay: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: self)
        }
        return text
    }

    public var identifierKey: String? {
        switch self {
        case .string(let value):
            return "s:\(value)"
        case .number(let value):
            return "n:\(value)"
        default:
            return nil
        }
    }
}

public nonisolated struct CodexApprovalRequest: Identifiable, Equatable, Sendable {
    public nonisolated enum Kind: Equatable, Sendable {
        case command
        case fileChange
        case permissions
    }

    public let id = UUID()
    public let requestID: CodexJSONValue
    public let kind: Kind
    public let title: String
    public let detail: String
    public let requestedPermissions: CodexJSONValue?

    public init(
        requestID: CodexJSONValue,
        kind: Kind,
        title: String,
        detail: String,
        requestedPermissions: CodexJSONValue?
    ) {
        self.requestID = requestID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.requestedPermissions = requestedPermissions
    }
}

public nonisolated enum CodexAppServerError: LocalizedError, Equatable {
    case invalidServerURL
    case nonLoopbackServer
    case notConnected
    case malformedResponse
    case server(String)
    case turnFailed(String)
    case disconnected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Enter a valid Codex App Server WebSocket URL."
        case .nonLoopbackServer:
            "For safety, Castor only connects to Codex App Server on this device."
        case .notConnected:
            "Codex App Server is not connected."
        case .malformedResponse:
            "Codex App Server returned an unreadable response."
        case .server(let message), .turnFailed(let message), .disconnected(let message):
            message
        }
    }
}

@MainActor
@Observable
public final class CodexAppServerSession {
    public private(set) var isConnected = false
    public private(set) var pendingApproval: CodexApprovalRequest?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectedURL: URL?
    private var nextRequestID: Int64 = 1
    private var pendingResponses: [String: CheckedContinuation<[String: CodexJSONValue], Error>] = [:]
    private var turnContinuation: CheckedContinuation<String, Error>?
    private var threadID: String?
    private var activeTurnID: String?
    private var threadConfigurationKey: String?
    private var responseBuffer = ""
    private var lastTurnError: String?

    private var deltaHandler: ((String) -> Void)?
    private var statusHandler: ((String) -> Void)?
    private var approvalHandler: ((CodexApprovalRequest?) -> Void)?

    public nonisolated static func isAllowedServerURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "ws" || url.scheme == "wss" else {
            return false
        }
        let host = url.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    public func send(
        prompt: String,
        serverURL: String,
        workspacePath: String,
        personalityInstruction: String,
        localImagePath: String? = nil,
        onDelta: @escaping (String) -> Void,
        onStatus: @escaping (String) -> Void,
        onApproval: @escaping (CodexApprovalRequest?) -> Void
    ) async throws -> String {
        deltaHandler = onDelta
        statusHandler = onStatus
        approvalHandler = onApproval
        responseBuffer = ""
        lastTurnError = nil

        try await connectIfNeeded(serverURL: serverURL)
        let activeThreadID = try await startThreadIfNeeded(
            workspacePath: workspacePath,
            personalityInstruction: personalityInstruction
        )

        statusHandler?("Codex is working...")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                turnContinuation = continuation
                Task { @MainActor in
                    do {
                        var input: [CodexJSONValue] = [
                            .object([
                                "type": .string("text"),
                                "text": .string(prompt),
                                "text_elements": .array([])
                            ])
                        ]
                        if let localImagePath, !localImagePath.isEmpty {
                            input.append(.object([
                                "type": .string("localImage"),
                                "path": .string(localImagePath)
                            ]))
                        }
                        let result = try await request(
                            method: "turn/start",
                            params: [
                                "threadId": .string(activeThreadID),
                                "input": .array(input)
                            ]
                        )
                        activeTurnID = result["turn"]?.objectValue?["id"]?.stringValue
                    } catch {
                        finishTurn(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.interruptActiveTurn()
            }
        }
    }

    public func resolveApproval(_ request: CodexApprovalRequest, approved: Bool) async throws {
        guard pendingApproval?.id == request.id else { return }

        try await sendEnvelope([
            "id": request.requestID,
            "result": .object(Self.approvalResult(for: request, approved: approved))
        ])
        pendingApproval = nil
        approvalHandler?(nil)
        statusHandler?(approved ? "Approved. Codex is continuing..." : "Declined. Codex is continuing...")
    }

    public static func approvalResult(
        for request: CodexApprovalRequest,
        approved: Bool,
        cancelsTurn: Bool = false
    ) -> [String: CodexJSONValue] {
        switch request.kind {
        case .command, .fileChange:
            return [
                "decision": .string(cancelsTurn ? "cancel" : (approved ? "accept" : "decline"))
            ]
        case .permissions:
            return [
                "permissions": approved && !cancelsTurn
                    ? (request.requestedPermissions ?? .object([:]))
                    : .object([:]),
                "scope": .string("turn")
            ]
        }
    }

    public static func permissionApprovalDetail(
        permissions: CodexJSONValue,
        cwd: String?,
        reason: String?
    ) -> String {
        var sections: [String] = []
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(reason)
        }
        if let cwd, !cwd.isEmpty {
            sections.append("Working directory:\n\(cwd)")
        }
        sections.append("Requested permissions:\n\(permissions.formattedForDisplay)")
        return sections.joined(separator: "\n\n")
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectedURL = nil
        isConnected = false
        threadID = nil
        threadConfigurationKey = nil
        failPendingWork(with: CodexAppServerError.disconnected("Codex App Server disconnected."))
    }

    private func connectIfNeeded(serverURL: String) async throws {
        guard let url = URL(string: serverURL),
              url.scheme == "ws" || url.scheme == "wss" else {
            throw CodexAppServerError.invalidServerURL
        }
        guard Self.isAllowedServerURL(serverURL) else {
            throw CodexAppServerError.nonLoopbackServer
        }

        if isConnected, connectedURL == url, socket != nil {
            return
        }
        disconnect()

        statusHandler?("Connecting to Codex App Server...")
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        connectedURL = url
        task.resume()
        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop()
        }

        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": .object([
                    "name": .string("castor"),
                    "title": .string("Castor"),
                    "version": .string("0.1.0")
                ])
            ]
        )
        try await sendEnvelope(["method": .string("initialized")])
        isConnected = true
        statusHandler?("Connected to Codex.")
    }

    private func startThreadIfNeeded(
        workspacePath: String,
        personalityInstruction: String
    ) async throws -> String {
        let trimmedWorkspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let configurationKey = "\(trimmedWorkspace)|\(personalityInstruction)"
        if let threadID, threadConfigurationKey == configurationKey {
            return threadID
        }

        var params: [String: CodexJSONValue] = [
            "approvalPolicy": .string("on-request"),
            "approvalsReviewer": .string("user"),
            "sandbox": .string("read-only"),
            "personality": .string("friendly"),
            "developerInstructions": .string("""
            You are speaking and acting through the Castor desktop companion.
            \(personalityInstruction)
            Keep user-facing answers concise unless the user asks for detail.
            Never expose hidden reasoning. Use short visible progress updates instead.
            Ask for approval before commands, file changes, network access, or desktop actions.
            """)
        ]
        if !trimmedWorkspace.isEmpty {
            params["cwd"] = .string(trimmedWorkspace)
        }

        let result = try await request(method: "thread/start", params: params)
        guard let newThreadID = result["thread"]?.objectValue?["id"]?.stringValue else {
            throw CodexAppServerError.malformedResponse
        }
        threadID = newThreadID
        threadConfigurationKey = configurationKey
        return newThreadID
    }

    private func request(
        method: String,
        params: [String: CodexJSONValue]
    ) async throws -> [String: CodexJSONValue] {
        let requestID = nextRequestID
        nextRequestID += 1
        let idValue = CodexJSONValue.number(Double(requestID))
        let key = idValue.identifierKey!

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[key] = continuation
            Task { @MainActor in
                do {
                    try await sendEnvelope([
                        "id": idValue,
                        "method": .string(method),
                        "params": .object(params)
                    ])
                } catch {
                    pendingResponses.removeValue(forKey: key)?.resume(throwing: error)
                }
            }
        }
    }

    private func sendEnvelope(_ envelope: [String: CodexJSONValue]) async throws {
        guard let socket else { throw CodexAppServerError.notConnected }
        let data = try JSONEncoder().encode(CodexJSONValue.object(envelope))
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAppServerError.malformedResponse
        }
        try await socket.send(.string(text))
    }

    private func receiveLoop() async {
        guard let socket else { return }
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let payload):
                    data = payload
                @unknown default:
                    continue
                }

                guard case .object(let envelope) = try JSONDecoder().decode(CodexJSONValue.self, from: data) else {
                    continue
                }
                handleEnvelope(envelope)
            }
        } catch {
            guard !Task.isCancelled else { return }
            isConnected = false
            failPendingWork(
                with: CodexAppServerError.disconnected(
                    "Codex App Server connection closed: \(error.localizedDescription)"
                )
            )
        }
    }

    private func handleEnvelope(_ envelope: [String: CodexJSONValue]) {
        if let method = envelope["method"]?.stringValue {
            if envelope["id"] != nil {
                handleServerRequest(method: method, envelope: envelope)
            } else {
                handleNotification(method: method, params: envelope["params"]?.objectValue ?? [:])
            }
            return
        }

        guard let id = envelope["id"], let key = id.identifierKey,
              let continuation = pendingResponses.removeValue(forKey: key) else {
            return
        }
        if let error = envelope["error"]?.objectValue {
            let message = error["message"]?.stringValue ?? "Codex App Server request failed."
            continuation.resume(throwing: CodexAppServerError.server(message))
        } else if let result = envelope["result"]?.objectValue {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: CodexAppServerError.malformedResponse)
        }
    }

    private func handleServerRequest(method: String, envelope: [String: CodexJSONValue]) {
        guard let requestID = envelope["id"] else { return }
        let params = envelope["params"]?.objectValue ?? [:]
        let reason = params["reason"]?.stringValue

        let request: CodexApprovalRequest?
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"]?.stringValue ?? "Run a command"
            let cwd = params["cwd"]?.stringValue
            request = CodexApprovalRequest(
                requestID: requestID,
                kind: .command,
                title: "Allow this command?",
                detail: [command, cwd.map { "in \($0)" }, reason].compactMap { $0 }.joined(separator: "\n"),
                requestedPermissions: nil
            )
        case "item/fileChange/requestApproval":
            request = CodexApprovalRequest(
                requestID: requestID,
                kind: .fileChange,
                title: "Allow file changes?",
                detail: reason ?? "Codex wants to change files in the selected workspace.",
                requestedPermissions: nil
            )
        case "item/permissions/requestApproval":
            let permissions = params["permissions"] ?? .object([:])
            request = CodexApprovalRequest(
                requestID: requestID,
                kind: .permissions,
                title: "Grant additional access?",
                detail: Self.permissionApprovalDetail(
                    permissions: permissions,
                    cwd: params["cwd"]?.stringValue,
                    reason: reason
                ),
                requestedPermissions: permissions
            )
        default:
            request = nil
        }

        if let request {
            pendingApproval = request
            approvalHandler?(request)
            statusHandler?("Waiting for your approval...")
        } else {
            Task { @MainActor in
                try? await sendEnvelope([
                    "id": requestID,
                    "error": .object([
                        "code": .number(-32601),
                        "message": .string("Castor does not support this Codex request yet.")
                    ])
                ])
            }
        }
    }

    private func handleNotification(method: String, params: [String: CodexJSONValue]) {
        switch method {
        case "turn/started":
            activeTurnID = params["turn"]?.objectValue?["id"]?.stringValue
            statusHandler?("Codex is thinking...")
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue {
                responseBuffer += delta
                deltaHandler?(responseBuffer)
            }
        case "item/completed":
            if let item = params["item"]?.objectValue,
               item["type"]?.stringValue == "agentMessage",
               item["phase"]?.stringValue == "final_answer",
               let text = item["text"]?.stringValue,
               !text.isEmpty {
                responseBuffer = text
                deltaHandler?(text)
            }
        case "item/started":
            if let item = params["item"]?.objectValue {
                switch item["type"]?.stringValue {
                case "commandExecution":
                    statusHandler?("Codex is running a command...")
                case "fileChange":
                    statusHandler?("Codex is preparing file changes...")
                case "mcpToolCall":
                    statusHandler?("Codex is using a connected tool...")
                default:
                    break
                }
            }
        case "error":
            let willRetry = params["willRetry"]?.boolValue ?? false
            let message = params["error"]?.objectValue?["message"]?.stringValue
                ?? "Codex encountered an error."
            lastTurnError = message
            statusHandler?(willRetry ? "Codex is retrying..." : message)
        case "turn/completed":
            let turn = params["turn"]?.objectValue
            let status = turn?["status"]?.stringValue ?? "failed"
            let errorMessage = turn?["error"]?.objectValue?["message"]?.stringValue
                ?? lastTurnError
                ?? "Codex could not complete the request."
            if status == "completed" {
                finishTurn(with: .success(responseBuffer))
            } else {
                finishTurn(with: .failure(CodexAppServerError.turnFailed(errorMessage)))
            }
        default:
            break
        }
    }

    private func interruptActiveTurn() async {
        let approval = pendingApproval
        let interruptedThreadID = threadID
        let interruptedTurnID = activeTurnID
        pendingApproval = nil
        approvalHandler?(nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let approval {
                try? await sendEnvelope([
                    "id": approval.requestID,
                    "result": .object(
                        Self.approvalResult(
                            for: approval,
                            approved: false,
                            cancelsTurn: true
                        )
                    )
                ])
            }
            if let interruptedThreadID, let interruptedTurnID {
                _ = try? await request(
                    method: "turn/interrupt",
                    params: [
                        "threadId": .string(interruptedThreadID),
                        "turnId": .string(interruptedTurnID)
                    ]
                )
            }
        }
        finishTurn(with: .failure(CancellationError()))
    }

    private func finishTurn(with result: Result<String, Error>) {
        guard let continuation = turnContinuation else { return }
        turnContinuation = nil
        activeTurnID = nil
        pendingApproval = nil
        approvalHandler?(nil)
        continuation.resume(with: result)
    }

    private func failPendingWork(with error: Error) {
        for continuation in pendingResponses.values {
            continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()
        finishTurn(with: .failure(error))
    }

    public init() {}
}
