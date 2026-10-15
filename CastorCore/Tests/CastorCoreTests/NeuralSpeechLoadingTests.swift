import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CastorCore

@Suite(.serialized)
struct NeuralSpeechLoadingTests {
    @Test func statusAndWaitNeverDownloadOrLoadAModel() async throws {
        let fixture = NeuralLoadFixture(responses: [(200, #"{"status":"idle","model":null}"#)])
        let (transport, session) = try fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        #expect(try await transport.isServiceAvailable())
        #expect(try await !transport.isModelReady(model: "qwen"))
        try await transport.waitUntilAvailable()
        #expect(fixture.routes == Array(repeating: "GET /v1/audio/status", count: 3))
    }

    @Test func preloadIsSentOnlyWhenExplicitlyRequested() async throws {
        let fixture = NeuralLoadFixture(responses: [(200, #"{"status":"idle","model":null}"#)])
        let (transport, session) = try fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        #expect(fixture.routes.isEmpty)
        #expect(try await transport.isServiceAvailable())
        #expect(fixture.routes == ["GET /v1/audio/status"])
        try await transport.preload(model: "qwen")
        #expect(fixture.routes == ["GET /v1/audio/status", "POST /v1/audio/preload"])
    }

    @Test func helperStartupRetriesWithoutPreparingAModel() async throws {
        let fixture = NeuralLoadFixture(responses: [(503, "{}"), (200, #"{"status":"idle","model":null}"#)])
        let (transport, session) = try fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        try await transport.waitUntilAvailable()
        #expect(fixture.routes == Array(repeating: "GET /v1/audio/status", count: 2))
    }

    @Test func cancellingStartupDoesNotStartAModelDownload() async throws {
        let fixture = NeuralLoadFixture(responses: [(503, "{}")])
        let (transport, session) = try fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let task = Task { try await transport.waitUntilAvailable() }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.routes.allSatisfy { $0 == "GET /v1/audio/status" })
    }

    @Test func onlyTheReadySelectedModelIsUsed() async throws {
        let fixture = NeuralLoadFixture(responses: [(200, #"{"status":"ready","model":"qwen"}"#)])
        let (transport, session) = try fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        #expect(try await transport.isModelReady(model: "qwen"))
        #expect(try await !transport.isModelReady(model: "other"))
        #expect(fixture.routes.allSatisfy { $0 == "GET /v1/audio/status" })
    }
}

private nonisolated final class NeuralLoadFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private var recorded: [String] = []
    private var port: Int?
    init(responses: [(Int, String)]) { replies = responses }
    var routes: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func response(for request: URLRequest) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append("\(request.httpMethod ?? "GET") \(request.url!.path)")
        let response = replies[0]
        if replies.count > 1 { replies.removeFirst() }
        return response
    }
    func transport() throws -> (NeuralSpeechTransport, URLSession) {
        let value = NeuralLoadURLProtocol.install(self); port = value
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeuralLoadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (try NeuralSpeechTransport(endpoint: URL(string: "http://127.0.0.1:\(value)/v1/audio/speech")!, session: session), session)
    }
    func remove() { if let port { NeuralLoadURLProtocol.remove(port) } }
}

private nonisolated final class NeuralLoadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [Int: NeuralLoadFixture] = [:]
    nonisolated(unsafe) private static var nextPort = 45000
    static func install(_ fixture: NeuralLoadFixture) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextPort += 1; fixtures[nextPort] = fixture; return nextPort
    }
    static func remove(_ port: Int) { lock.lock(); defer { lock.unlock() }; fixtures.removeValue(forKey: port) }
    private static func fixture(_ request: URLRequest) -> NeuralLoadFixture? {
        lock.lock(); defer { lock.unlock() }; return fixtures[request.url?.port ?? -1]
    }
    override class func canInit(with request: URLRequest) -> Bool { fixture(request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture(request) else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let (status, body) = fixture.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
