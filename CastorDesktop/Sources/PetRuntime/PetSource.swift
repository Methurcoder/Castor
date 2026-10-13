import ArilsPlayer
import Foundation

/// Where a pet comes from on platforms that cannot rig yet: the macOS app's
/// saved pet (`CastorPet.json`, which embeds the Arils archive), or a
/// bare Arils archive (`.arils`, a binary property list).
public enum PetSource {
    /// Prefer the successor filename while still accepting an existing exported pet.
    public static func defaultFileURL(in directory: URL) -> URL {
        let current = directory.appendingPathComponent("CastorPet.json")
        let legacy = directory.appendingPathComponent("PomegranatePet.json")
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return current
    }

    public enum LoadError: Error, CustomStringConvertible {
        case noArilsAvatar
        case unreadable(String)

        public var description: String {
            switch self {
            case .noArilsAvatar:
                "The file has no Arils avatar. Build the pet with Arils on the Mac first."
            case let .unreadable(reason):
                "The file could not be read: \(reason)"
            }
        }
    }

    /// The fields of the Mac app's `SavedPetCharacter` this host uses.
    private struct SavedPet: Decodable {
        var arilsArchiveData: Data?
        var qualityArchiveData: Data?
    }

    /// The front view of a two-image Quality archive.
    private struct QualityFront: Decodable {
        var front: AvatarArchive
    }

    public static func load(contentsOf url: URL) throws -> AvatarArchive {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(error.localizedDescription)
        }
        return try load(data: data)
    }

    public static func load(data: Data) throws -> AvatarArchive {
        if let archive = try? AvatarArchive(data: data) {
            return archive
        }
        guard let saved = try? JSONDecoder().decode(SavedPet.self, from: data) else {
            throw LoadError.unreadable("neither a Castor pet file nor an Arils archive")
        }
        // Quality pets keep their single-image archive too when present; the
        // front view of a Quality archive is the fallback.
        if let archiveData = saved.arilsArchiveData, let archive = try? AvatarArchive(data: archiveData) {
            return archive
        }
        if let qualityData = saved.qualityArchiveData,
           let quality = try? PropertyListDecoder().decode(QualityFront.self, from: qualityData) {
            return quality.front
        }
        throw LoadError.noArilsAvatar
    }
}
