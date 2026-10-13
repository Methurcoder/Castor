import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads an HTTP response body line by line as it arrives (server-sent
/// events, NDJSON). `URLSession.bytes(for:)` does this on Apple platforms but
/// does not exist in swift-corelibs-foundation (Linux, Windows), so there
/// the same stream is built from data-task delegate callbacks.
public enum HTTPLineStream {
    public static func lines(
        for request: URLRequest,
        session: URLSession = .shared
    ) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        #if canImport(Darwin)
        let (bytes, response) = try await session.bytes(for: request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, response)
        #else
        return try await DelegateLineReader(configuration: session.configuration).start(request)
        #endif
    }
}

#if !canImport(Darwin)
/// Delegate-driven reader for platforms without `URLSession.bytes`.
private final class DelegateLineReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var buffer = Data()
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var lineContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var session: URLSession?

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    func start(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            lock.lock()
            lineContinuation = continuation
            lock.unlock()
        }
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
            lock.lock()
            responseContinuation = continuation
            lock.unlock()
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            lineContinuation?.onTermination = { _ in task.cancel() }
            task.resume()
        }
        return (stream, response)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let continuation = responseContinuation
        responseContinuation = nil
        lock.unlock()
        continuation?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        let continuation = lineContinuation
        lock.unlock()
        for line in lines { continuation?.yield(line) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let rest = buffer
        buffer = Data()
        let responseContinuation = self.responseContinuation
        self.responseContinuation = nil
        let lineContinuation = self.lineContinuation
        self.lineContinuation = nil
        lock.unlock()
        if let error {
            responseContinuation?.resume(throwing: error)
            lineContinuation?.finish(throwing: error)
        } else {
            if !rest.isEmpty { lineContinuation?.yield(String(decoding: rest, as: UTF8.self)) }
            lineContinuation?.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
#endif
