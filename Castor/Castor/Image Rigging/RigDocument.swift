import CoreGraphics
import Foundation

struct RigDocument: Codable, Equatable, Hashable {
    var version: Int
    var imageName: String?
    var imageSize: CGSize
    var parts: [RigPart]

    static func starter(imageName: String?, imageSize: CGSize) -> RigDocument {
        let aspectRatio = imageSize.width / max(imageSize.height, 1)
        let parts = aspectRatio < 0.9 ? portraitStarterParts() : squareStarterParts()

        return RigDocument(
            version: 1,
            imageName: imageName,
            imageSize: imageSize,
            parts: parts
        )
    }

    private static func portraitStarterParts() -> [RigPart] {
        [
            RigPart(kind: .body, normalizedRect: CGRect(x: 0.28, y: 0.54, width: 0.44, height: 0.40), shape: .ellipse, zIndex: 0),
            RigPart(kind: .head, normalizedRect: CGRect(x: 0.27, y: 0.33, width: 0.46, height: 0.34), shape: .ellipse, zIndex: 10),
            RigPart(kind: .hair, normalizedRect: CGRect(x: 0.24, y: 0.29, width: 0.52, height: 0.25), shape: .ellipse, zIndex: 20),
            RigPart(kind: .leftEye, normalizedRect: CGRect(x: 0.39, y: 0.46, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .rightEye, normalizedRect: CGRect(x: 0.53, y: 0.46, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .mouth, normalizedRect: CGRect(x: 0.45, y: 0.55, width: 0.10, height: 0.05), shape: .ellipse, zIndex: 35)
        ]
    }

    private static func squareStarterParts() -> [RigPart] {
        [
            RigPart(kind: .body, normalizedRect: CGRect(x: 0.30, y: 0.53, width: 0.40, height: 0.38), shape: .ellipse, zIndex: 0),
            RigPart(kind: .head, normalizedRect: CGRect(x: 0.28, y: 0.29, width: 0.44, height: 0.34), shape: .ellipse, zIndex: 10),
            RigPart(kind: .hair, normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.25), shape: .ellipse, zIndex: 20),
            RigPart(kind: .leftEye, normalizedRect: CGRect(x: 0.39, y: 0.43, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .rightEye, normalizedRect: CGRect(x: 0.53, y: 0.43, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .mouth, normalizedRect: CGRect(x: 0.45, y: 0.52, width: 0.10, height: 0.05), shape: .ellipse, zIndex: 35)
        ]
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decodeJSON(_ data: Data) throws -> RigDocument {
        try JSONDecoder().decode(RigDocument.self, from: data)
    }
}

/// Manual rectangle rigging is the legacy fallback for images Arils cannot rig yet. It stays
/// hidden behind Settings › General › Advanced until Arils is reliable enough to remove it.
enum ManualRiggingSettingsStore {
    static let enabledKey = "Pomegranate.Rigging.ManualEnabled.v1"
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

    /// A pet needs an Arils rig unless manual rigging is enabled, in which case the classic
    /// rig document alone is enough.
    static func canSavePet(
        hasImage: Bool,
        hasDocument: Bool,
        hasArilsRig: Bool,
        manualRiggingEnabled: Bool
    ) -> Bool {
        guard hasImage, hasDocument else {
            return false
        }
        return hasArilsRig || manualRiggingEnabled
    }
}
