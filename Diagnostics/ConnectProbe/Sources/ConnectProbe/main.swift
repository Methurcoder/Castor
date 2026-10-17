import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CastorCore

// Temporary: how requests to a closed loopback port end on this system.
setvbuf(stdout, nil, _IONBF, 0)
let started = Date()
func say(_ text: String) { print(String(format: "PROBE %6.2fs ", Date().timeIntervalSince(started)) + text) }
func describe(_ error: Error?) -> String {
    guard let error else { return "no error" }
    let ns = error as NSError
    return "error \(ns.domain) \(ns.code) \(ns.localizedDescription)"
}

/// Runs one probe without blocking the main thread; reports a hang after
/// `limit` seconds and moves on.
func probe(_ name: String, limit: Double = 20, _ body: @escaping (@escaping @Sendable (String) -> Void) -> Void) async {
    let start = Date()
    say("start \(name)")
    let outcome: String = await withCheckedContinuation { continuation in
        let once = NSLock()
        nonisolated(unsafe) var resumed = false
        let finish: @Sendable (String) -> Void = { text in
            once.lock(); defer { once.unlock() }
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: text)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) { finish("HUNG: nothing after \(Int(limit))s") }
        body(finish)
    }
    say(String(format: "end   %@ after %.2fs: %@", name, Date().timeIntervalSince(start), outcome))
}

for url in ["http://127.0.0.1:9/health", "http://localhost:9/health", "http://127.0.0.1:8765/"] {
    await probe("shared completion \(url) timeout=5") { finish in
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, response, error in
            finish(error != nil ? describe(error) : "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }.resume()
    }
}

await probe("own session completion 127.0.0.1:9 timeout=5") { finish in
    var request = URLRequest(url: URL(string: "http://127.0.0.1:9/health")!)
    request.timeoutInterval = 5
    let session = URLSession(configuration: .ephemeral)
    session.dataTask(with: request) { _, _, error in finish(describe(error)) }.resume()
}

for timeout in [5.0, 86400.0] {
    await probe("HTTPLineStream POST 127.0.0.1:9 timeout=\(Int(timeout))") { finish in
        var request = URLRequest(url: URL(string: "http://127.0.0.1:9/v1/turn")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = Data("{}".utf8)
        Task.detached {
            do {
                let (_, response) = try await HTTPLineStream.lines(for: request)
                finish("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            } catch { finish(describe(error)) }
        }
    }
}
say("all probes finished")
exit(0)
