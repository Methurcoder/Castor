import AppKit
import Arils
import Foundation
import ImageIO

enum LaMaInpaintingSettingsStore {
    static let enabledKey = "Pomegranate.Arils.LaMaInpainting.Enabled.v1"
    static let defaultEnabled = false

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else {
                return defaultEnabled
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

enum LaMaInpaintingSetupGuidance {
    static let bootstrapCommand = "scripts/bootstrap-lama-inpainting.sh"
    static let startCommand = "scripts/start-lama-inpainting.sh"

    static func unavailableStatus(errorDescription: String) -> String {
        "Unavailable: \(errorDescription)"
    }
}

struct LaMaInpaintingReport: Equatable, Sendable {
    var attempts = 0
    var successes = 0
    var failures = 0
    var lastFailure: String?

    var usedFallback: Bool { failures > 0 }
}

enum LaMaInpaintingError: LocalizedError, Equatable {
    case invalidEndpoint
    case pngEncodingFailed
    case invalidResponse
    case server(status: Int, message: String)
    case invalidOutputSize

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "LaMa endpoint must be a loopback HTTP address."
        case .pngEncodingFailed:
            "Could not encode the inpainting input as PNG."
        case .invalidResponse:
            "LaMa returned an unreadable response."
        case let .server(status, message):
            "LaMa server error \(status): \(message)"
        case .invalidOutputSize:
            "LaMa returned an image with a different size."
        }
    }
}

/// Loopback-only client for the optional Python LaMa helper. The class records
/// failures because Arils deliberately falls back instead of failing the whole
/// avatar build when this beta service is unavailable.
final class LaMaInpaintingClient: OcclusionInpaintingProviding, @unchecked Sendable {
    static let defaultEndpoint = URL(string: "http://127.0.0.1:8123/v1/inpaint")!

    private let endpoint: URL
    private let session: URLSession
    private let reportLock = NSLock()
    private var mutableReport = LaMaInpaintingReport()

    init(endpoint: URL = defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    var report: LaMaInpaintingReport {
        reportLock.withLock { mutableReport }
    }

    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        let host = url.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    func inpaint(_ request: OcclusionInpaintingRequest) async throws -> CGImage {
        recordAttempt()
        do {
            guard Self.isAllowedEndpoint(endpoint) else {
                throw LaMaInpaintingError.invalidEndpoint
            }
            guard let imagePNG = Self.pngData(from: request.sourceImage),
                  let maskPNG = Self.pngData(from: request.maskImage) else {
                throw LaMaInpaintingError.pngEncodingFailed
            }

            let payload = InpaintingPayload(
                image: imagePNG.base64EncodedString(),
                mask: maskPNG.base64EncodedString()
            )
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 180
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LaMaInpaintingError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw LaMaInpaintingError.server(
                    status: httpResponse.statusCode,
                    message: Self.serverMessage(from: data)
                )
            }
            guard let result = Self.cgImage(from: data) else {
                throw LaMaInpaintingError.invalidResponse
            }
            guard result.width == request.sourceImage.width,
                  result.height == request.sourceImage.height else {
                throw LaMaInpaintingError.invalidOutputSize
            }
            recordSuccess()
            return result
        } catch {
            recordFailure(error.localizedDescription)
            throw error
        }
    }

    func availability() async throws -> String {
        guard Self.isAllowedEndpoint(endpoint),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LaMaInpaintingError.invalidEndpoint
        }
        components.path = "/"
        components.query = nil
        guard let healthURL = components.url else {
            throw LaMaInpaintingError.invalidEndpoint
        }
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let payload = try? JSONDecoder().decode(HealthPayload.self, from: data) else {
            throw LaMaInpaintingError.invalidResponse
        }
        return payload.status
    }

    private func recordAttempt() {
        reportLock.withLock { mutableReport.attempts += 1 }
    }

    private func recordSuccess() {
        reportLock.withLock { mutableReport.successes += 1 }
    }

    private func recordFailure(_ description: String) {
        reportLock.withLock {
            mutableReport.failures += 1
            mutableReport.lastFailure = description
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func serverMessage(from data: Data) -> String {
        if let error = try? JSONDecoder().decode(ServerErrorPayload.self, from: data) {
            return error.error
        }
        return String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
    }

    private struct InpaintingPayload: Encodable {
        var image: String
        var mask: String
    }

    private struct HealthPayload: Decodable {
        var status: String
    }

    private struct ServerErrorPayload: Decodable {
        var error: String
    }
}
