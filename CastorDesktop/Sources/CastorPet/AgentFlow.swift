#if os(Windows)
import CastorCore
import CDesktopUI
import Foundation
import PetRuntime

/// Session state remains MainActor-isolated, with locked snapshots for native UI.
@MainActor private enum AgentSessions {
    static let codex = CodexAppServerSession()
    static let claude = ClaudeCodeBridgeSession()
}
final class WindowsAgentWork: WindowsWorkCompletion, @unchecked Sendable {
    private let resolver:@MainActor @Sendable(CastorAgentApprovalRequest,Bool) async throws -> Void
    init(resolver:@escaping @MainActor @Sendable(CastorAgentApprovalRequest,Bool) async throws -> Void = {request,approved in
        switch request {
        case let .codex(value):try await AgentSessions.codex.resolveApproval(value,approved:approved)
        case let .claudeCode(value):try await AgentSessions.claude.resolveApproval(value,approved:approved)
        }
    }) {self.resolver=resolver;super.init()}
    var result: Result<String, Error>?
    var status = "接続中..."
    var approval: CastorAgentApprovalRequest?
    var task: Task<Void, Never>?
    var cancelled = false
    private var presentedID: UUID?
    func update(status: String) { lock.lock(); self.status = String(status.prefix(240)); lock.unlock() }
    func update(approval: CastorAgentApprovalRequest?) { lock.lock(); self.approval = approval; lock.unlock() }
    func complete(_ result: Result<String, Error>) { lock.lock(); defer { lock.unlock() }; guard !finished else { return }; self.result = result; finished = true; task = nil }
    func cancel() { lock.lock(); cancelled = true; let job = task; lock.unlock(); job?.cancel() }
    func outcome() -> Result<String, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    override func nativePoll() -> Int32 {
        lock.lock(); let finished = finished, status = status, request = approval, cancelled = cancelled; lock.unlock()
        if finished || cancelled { return 1 }
        status.withCString { castor_update_work_text($0) }
        if let request, request.id != presentedID {
            presentedID = request.id
            do {
                guard try WindowsRiggingFlow.text(title: request.title, value: request.detail, readOnly: true) != nil,
                      let decision = try WindowsRiggingFlow.option(title: "操作の承認（内容を確認した今回だけ）", items: ["承認", "拒否", "処理全体をキャンセル"]) else { cancel(); return 1 }
                if decision == 2 { cancel(); return 1 }
                Task { @MainActor in
                    do {
                        try await self.resolver(request,decision == 0)
                    } catch { self.cancel(); self.complete(.failure(error)) }
                }
            } catch { cancel(); complete(.failure(error)); return 1 }
        }
        return 0
    }
}

enum WindowsAgentFlow {
    private static var hasExplainedExternalService = false
    enum AgentError: LocalizedError {
        case workspaceRequired
        var errorDescription: String? { "設定で操作対象のフォルダを選んでください。対象外のファイルや追加権限は実行前に個別承認します。" }
    }
    static func brain(prompt: String, preferences: DesktopPreferences) -> DesktopPreferences.Brain {
        if preferences.automaticRouting {
            return CastorAgentPreferences.promptNeedsExternalAgent(prompt) ? preferences.externalBrain : .local
        }
        return preferences.selectedBrain
    }
    static func run(prompt: String, preferences: DesktopPreferences) throws -> String? {
        var directory: ObjCBool = false
        guard !preferences.workspacePath.isEmpty,
              FileManager.default.fileExists(atPath: preferences.workspacePath, isDirectory: &directory), directory.boolValue else {
            throw AgentError.workspaceRequired
        }
        let selected = brain(prompt: prompt, preferences: preferences)
        guard selected != .local else { return nil }
        if !hasExplainedExternalService {
            guard let answer = try WindowsRiggingFlow.option(title: "送信内容: 入力文・性格・作業フォルダ。エージェントの設定により外部サービスへ送られます。", items: ["選択したエージェントへ送信する", "キャンセル"]), answer == 0 else { return nil }
            hasExplainedExternalService = true
        }
        let state = WindowsAgentWork()
        let job = Task { @MainActor in
            do {
                let result: String
                switch selected {
                case .codex:
                    result = try await AgentSessions.codex.send(prompt: prompt, serverURL: preferences.codexEndpoint,
                        workspacePath: preferences.workspacePath, personalityInstruction: preferences.personality,
                        onDelta: { _ in }, onStatus: { state.update(status: $0) },
                        onApproval: { state.update(approval: $0.map(CastorAgentApprovalRequest.codex)) })
                case .claudeCode:
                    result = try await AgentSessions.claude.send(prompt: prompt, bridgeURL: preferences.claudeEndpoint,
                        workspacePath: preferences.workspacePath, personalityInstruction: preferences.personality,
                        onDelta: { _ in }, onStatus: { state.update(status: $0) },
                        onApproval: { state.update(approval: $0.map(CastorAgentApprovalRequest.claudeCode)) })
                case .local: throw AgentError.workspaceRequired
                }
                try Task.checkCancellation(); state.complete(.success(result))
            } catch { state.complete(.failure(error)) }
        }
        state.lock.lock(); state.task = job; state.lock.unlock()
        let status = "選択した外部エージェントに接続しています。操作には個別承認が必要です。".withCString {
            castor_wait_work($0, { context in
                guard let context else { return 1 }
                return Unmanaged<WindowsWorkCompletion>.fromOpaque(context).takeUnretainedValue().nativePoll()
            }, Unmanaged.passUnretained(state).toOpaque())
        }
        if status <= 0 { state.cancel(); if status < 0 { throw WindowsRiggingFlow.FlowError.dialogFailed }; return nil }
        state.lock.lock(); let cancelled = state.cancelled; state.lock.unlock()
        if cancelled { return nil }
        return try state.outcome()?.get()
    }
}
#endif
