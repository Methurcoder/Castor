import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Identical loopback speech payload on both OSes. Model/voice identifiers are
/// service values and are never translated or inferred from display labels.
public nonisolated struct NeuralSpeechPayload: Encodable, Sendable {
    public var model: String
    public var input: String
    public var instruct: String
    public var voice: String
    public var speed: Double
    public var langCode: String
    public var responseFormat = "wav"
    public var stream = false
    public init(model:String,input:String,instruct:String,voice:String,speed:Double,langCode:String,responseFormat:String="wav",stream:Bool=false) {
        self.model=model;self.input=input;self.instruct=instruct;self.voice=voice;self.speed=speed;self.langCode=langCode;self.responseFormat=responseFormat;self.stream=stream
    }
    private enum CodingKeys:String,CodingKey {case model,input,instruct,voice,speed;case langCode="lang_code";case responseFormat="response_format";case stream}
}

/// Optional local helper; failure stays recoverable by the platform's standard TTS.
public nonisolated struct NeuralSpeechTransport: Sendable {
    public static let defaultEndpoint = URL(string:"http://127.0.0.1:8000/v1/audio/speech")!
    public enum TransportError:LocalizedError {case invalidEndpoint,invalidRequest,invalidResponse
        public var errorDescription:String? {switch self {
        case .invalidEndpoint:"Neural TTSはlocalhostの音声helperにだけ接続できます。"
        case .invalidRequest:"Neural TTSの本文・声・モデル・速度を確認してください。"
        case .invalidResponse:"Neural TTSから有効な音声を受け取れませんでした。"
        }}
    }
    public let endpoint:URL
    private let session:URLSession
    public init(endpoint:URL=defaultEndpoint,session:URLSession = .shared) throws {
        guard let c=URLComponents(url:endpoint,resolvingAgainstBaseURL:false),
              ["http","https"].contains(c.scheme?.lowercased() ?? ""),
              ["localhost","127.0.0.1","::1","[::1]"].contains(c.host?.lowercased() ?? ""),
              c.user==nil,c.password==nil,c.query==nil,c.fragment==nil,c.path=="/v1/audio/speech" else {throw TransportError.invalidEndpoint}
        self.endpoint=endpoint;self.session=session
    }
    public func audio(for payload:NeuralSpeechPayload) async throws -> Data {
        try await response(for:payload).0
    }
    public func response(for payload:NeuralSpeechPayload,timeout:TimeInterval=120) async throws -> (Data,HTTPURLResponse) {
        guard !payload.input.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,payload.input.count<=8000,
              !payload.model.isEmpty,payload.model.count<=1024,!payload.voice.isEmpty,payload.voice.count<=256,
              payload.instruct.count<=4000,payload.langCode.count<=32,payload.speed.isFinite,(0.5...2).contains(payload.speed),
              payload.responseFormat=="wav",payload.stream==false else {throw TransportError.invalidRequest}
        var request=URLRequest(url:endpoint);request.httpMethod="POST";request.timeoutInterval=min(max(timeout,1),120)
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONEncoder().encode(payload)
        let local=localSession();defer {local.finishTasksAndInvalidate()}
        let requestID=UUID().uuidString
        request.setValue(requestID,forHTTPHeaderField:"X-Castor-Request-ID")
        let sending=request
        let (data,response)=try await withTaskCancellationHandler(operation:{try await local.data(for:sending)},onCancel:{
            Task.detached {try? await cancel(requestID:requestID)}
        })
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),!data.isEmpty,data.count<=64*1024*1024 else {throw TransportError.invalidResponse}
        _ = try WavePCM(data:data)
        try Task.checkCancellation();return (data,http)
    }
    /// These probes never launch a helper or prepare/download a model.
    private func serviceStatus() async throws -> [String:Any]? {
        var components=URLComponents(url:endpoint,resolvingAgainstBaseURL:false)!
        components.path="/v1/audio/status"
        var request=URLRequest(url:components.url!);request.timeoutInterval=1
        let local=localSession();defer {local.finishTasksAndInvalidate()}
        let(data,response)=try await local.data(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,data.count<=131072,
              let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {return nil}
        return object
    }
    public func isServiceAvailable() async throws -> Bool {
        try await serviceStatus() != nil
    }
    public func isModelReady(model:String) async throws -> Bool {
        guard let object = try await serviceStatus() else { return false }
        return object["model"] as? String == model && object["status"] as? String == "ready"
    }
    /// Called only after the user chooses Load, while the packaged helper starts.
    public func waitUntilAvailable() async throws {
        let deadline = Date().addingTimeInterval(90)
        repeat {
            try Task.checkCancellation()
            if (try? await isServiceAvailable()) == true { return }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        throw URLError(.timedOut)
    }
    public func preload(model:String) async throws {
        guard !model.isEmpty,model.count<=1024 else {throw TransportError.invalidRequest}
        var c=URLComponents(url:endpoint,resolvingAgainstBaseURL:false)!;c.path="/v1/audio/preload"
        var request=URLRequest(url:c.url!);request.httpMethod="POST";request.timeoutInterval=600
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONEncoder().encode(["model":model])
        let local=localSession();defer {local.finishTasksAndInvalidate()}
        let requestID=UUID().uuidString
        request.setValue(requestID,forHTTPHeaderField:"X-Castor-Request-ID")
        let sending=request
        let (_,response)=try await withTaskCancellationHandler(operation:{try await local.data(for:sending)},onCancel:{
            Task.detached {try? await cancel(requestID:requestID)}
        })
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {throw TransportError.invalidResponse}
        try Task.checkCancellation()
    }
    private func cancel(requestID:String) async throws {
        var c=URLComponents(url:endpoint,resolvingAgainstBaseURL:false)!;c.path="/v1/audio/cancel"
        var request=URLRequest(url:c.url!);request.httpMethod="POST";request.timeoutInterval=3
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody=try JSONEncoder().encode(["request_id":requestID])
        let local=localSession();defer {local.finishTasksAndInvalidate()}
        _ = try await local.data(for:request)
    }
    private func localSession()->URLSession {
        let configuration=session.configuration
        configuration.httpCookieStorage=nil;configuration.urlCache=nil;configuration.httpShouldSetCookies=false
        return URLSession(configuration:configuration,delegate:NeuralSpeechNoRedirect(),delegateQueue:nil)
    }

}

private nonisolated final class NeuralSpeechNoRedirect:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                    newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {completionHandler(nil)}
}
