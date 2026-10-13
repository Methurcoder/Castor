import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the local pointer-target helper (`scripts/pointer_target_server.py`
/// on macOS), which reports what control of another app lies at a screen
/// point. Used only by the beta button-aware dodge; any failure reads as
/// "unknown" so the pet simply stays put.
public struct PointerTargetClient: Sendable {
    public struct Target: Decodable, Equatable, Sendable {
        public var role: String?
        public var subrole: String?
        public var hasPress: Bool
        public var enabled: Bool?

        enum CodingKeys: String, CodingKey {
            case role, subrole
            case hasPress = "has_press"
            case enabled
        }

        public var isActionable: Bool {
            enabled != false && PointerTargetRoles.isActionable(role: role, hasPressAction: hasPress)
        }
    }

    public static let defaultPort = 8126
    public var baseURL: URL
    /// The answer is only useful before the click lands.
    public var timeout: TimeInterval = 0.25

    public init(baseURL: URL = URL(string: "http://127.0.0.1:\(PointerTargetClient.defaultPort)")!) {
        self.baseURL = baseURL
    }

    /// `point` uses the accessibility convention: global, top-left origin.
    public func target(at point: CGPoint, inProcess pid: Int32) async -> Target? {
        var components = URLComponents(url: baseURL.appendingPathComponent("target"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "x", value: String(Double(point.x))),
            URLQueryItem(name: "y", value: String(Double(point.y))),
            URLQueryItem(name: "pid", value: String(pid)),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Target.self, from: data)
    }

    /// "ready", "needs-accessibility-permission", or nil when not running.
    public func health() async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["status"] as? String
    }
}
