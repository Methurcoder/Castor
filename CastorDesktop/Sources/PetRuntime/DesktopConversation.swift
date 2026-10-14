import CastorCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DesktopConversation {
    public enum ConversationError: LocalizedError {
        case invalidEndpoint, noModel, emptyMessage
        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "ローカルの接続先を確認してください。http(s)://127.0.0.1、localhost、[::1]だけを利用できます。"
            case .noModel: "設定からローカルモデルを選んでください。"
            case .emptyMessage: "1〜4000文字で会話を入力してください。"
            }
        }
    }
    public static func endpoint(_ text: String) throws -> URL {
        guard let c = URLComponents(string: text), let url = c.url,
              c.scheme == "http" || c.scheme == "https", c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(c.host?.lowercased() ?? ""),
              c.port == nil || (1...65535).contains(c.port!) else { throw ConversationError.invalidEndpoint }
        return url
    }
    /// The native UI commits a returned reply to history only after completion.
    /// Nothing is posted to an external agent by this conversational path.
    public static func reply(prompt: String, history: [OllamaChatMessage], preferences: DesktopPreferences) async throws -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 4000 else { throw ConversationError.emptyMessage }
        guard !preferences.model.isEmpty else { throw ConversationError.noModel }
        let url = try endpoint(preferences.endpoint)
        var messages = [OllamaChatMessage(role: .system, content:
            "あなたはCastorのローカル会話用ペットです。性格: \(preferences.personality)\n" +
            "通常会話だけを行ってください。ファイルやコマンド、アプリ操作を実行したと主張しないでください。" +
            "応答はresponseとmotion_state(idle/thinking/listening/surprised)を持つJSONを優先し、本文は短く自然にしてください。")]
        messages += Array(history.suffix(20)); messages.append(OllamaChatMessage(role: .user, content: prompt))
        let session = URLSession(configuration: .ephemeral, delegate: LocalRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let raw: String
        switch preferences.provider {
        case .lmStudio: raw = try await LMStudioClient(endpoint: url, session: session).chat(model: preferences.model, messages: messages)
        case .ollama: raw = try await OllamaClient(endpoint: url, session: session).chat(model: preferences.model, messages: messages)
        }
        try Task.checkCancellation()
        return OllamaResponseParser.parse(raw).text
    }
    public static func models(preferences: DesktopPreferences) async throws -> [OllamaModel] {
        let url = try endpoint(preferences.endpoint)
        let session = URLSession(configuration: .ephemeral, delegate: LocalRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        switch preferences.provider {
        case .lmStudio: return try await LMStudioClient(endpoint: url, session: session).models()
        case .ollama: return try await OllamaClient(endpoint: url, session: session).models()
        }
    }
}
private final class LocalRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, (try? DesktopConversation.endpoint(url.absoluteString)) != nil { completionHandler(request) }
        else { completionHandler(nil) }
    }
}
