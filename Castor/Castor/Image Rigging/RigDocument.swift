import Foundation
import CastorCore
typealias RigDocument = CastorCore.RigDocument

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
