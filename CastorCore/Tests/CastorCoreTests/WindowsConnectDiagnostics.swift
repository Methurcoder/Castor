import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CastorCore

/// Temporary: how a request to a closed loopback port ends on each system.
@Suite(.serialized) struct WindowsConnectDiagnostics {
    private func report(_ label: String, _ start: Date, _ outcome: String) {
        let line = "DIAG \(label): \(String(format: "%.2f", Date().timeIntervalSince(start)))s \(outcome)"
        print(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "error domain=\(ns.domain) code=\(ns.code) urlError=\((error as? URLError).map { "\($0.code.rawValue)" } ?? "nil") \(ns.localizedDescription)"
    }

    @Test func plainCompletionHandler() async {
        for url in ["http://127.0.0.1:9/health", "http://localhost:9/health", "http://127.0.0.1:4510/health"] {
            var request = URLRequest(url: URL(string: url)!)
            request.timeoutInterval = 10
            let start = Date()
            let outcome: String = await withCheckedContinuation { continuation in
                URLSession.shared.dataTask(with: request) { _, response, error in
                    continuation.resume(returning: error.map(describe) ?? "response \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }.resume()
            }
            report("completion \(url)", start, outcome)
        }
    }

    @Test func asyncData() async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9/health")!)
        request.timeoutInterval = 10
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            report("async data", start, "response \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch { report("async data", start, describe(error)) }
    }

    @Test func lineStreamPost() async {
        for timeout in [10.0, 86400.0] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:9/v1/turn")!)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            let start = Date()
            let task = Task { () -> String in
                do {
                    let (_, response) = try await HTTPLineStream.lines(for: request)
                    return "response \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                } catch { return describe(error) }
            }
            let watchdog = Task { try await Task.sleep(for: .seconds(25)); return "still waiting after 25s" }
            let outcome = await withTaskGroup(of: String.self) { group in
                group.addTask { await task.value }
                group.addTask { (try? await watchdog.value) ?? "watchdog cancelled" }
                let first = await group.next() ?? "none"
                watchdog.cancel()
                return first
            }
            report("line stream POST timeout=\(Int(timeout))", start, outcome)
            if outcome.hasPrefix("still waiting") { report("line stream", start, "abandoning hung request"); break }
        }
    }
}
