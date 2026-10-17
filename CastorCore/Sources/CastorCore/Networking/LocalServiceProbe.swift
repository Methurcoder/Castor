import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Checks that a local service (Ollama, LM Studio, the Claude Code bridge,
/// the Codex App Server) is listening before a request that may take long.
///
/// Foundation on Windows never reports a refused connection: a request to a
/// closed loopback port waits for its whole timeout (measured on the Windows
/// runner), and conversation requests allow minutes, turns a day. A short
/// request first turns a stopped service into a clear message in seconds.
/// On Mac and Linux a refusal is reported at once.
public nonisolated enum LocalServiceProbe {
    public static let timeout: TimeInterval = 4

    /// The error means nothing is listening at the address.
    public static func isNotRunning(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return code == .cannotConnectToHost || code == .cannotFindHost || code == .timedOut
    }

    /// Whether anything answers at `url`. Any HTTP answer, even an error
    /// status or a closed connection, means the service is running; only a
    /// refusal, an unknown host or no answer in time means it is not.
    public static func isRunning(_ url: URL, timeout: TimeInterval = timeout, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let failure: Error? = await withCheckedContinuation { continuation in
            session.dataTask(with: request) { _, _, error in continuation.resume(returning: error) }.resume()
        }
        return failure.map { !isNotRunning($0) } ?? true
    }

    static func displayLanguageIsJapanese() -> Bool {
        (SettingsDisplayLanguage(rawValue: UserDefaults.standard.string(forKey: "Castor.SettingsDisplayLanguage") ?? "")
            ?? .systemDefault) == .japanese
    }
}
