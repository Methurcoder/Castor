import ArilsPlayer
import Foundation
import CastorCore

/// Keeps the complete asset, including the profile view and its registration.
public enum PetAsset: Sendable {
    case standard(AvatarArchive)
    case quality(QualityAvatarArchive)
    case manual(ManualPet)

    public var front: AvatarArchive {
        switch self {
        case let .standard(archive): archive
        case let .quality(archive): archive.front
        case let .manual(pet): pet.controlArchive
        }
    }

    public func data() throws -> Data {
        switch self {
        case let .standard(archive): try archive.data()
        case let .quality(archive): try archive.data()
        case let .manual(pet): try pet.data()
        }
    }
}

/// Loads saved Castor JSON or a bare single/two-view binary Arils archive.
public enum PetSource {
    public static func defaultFileURL(in directory: URL) -> URL {
        let current = directory.appendingPathComponent("CastorPet.json")
        let legacy = directory.appendingPathComponent("PomegranatePet.json")
        if !FileManager.default.fileExists(atPath: current.path),
           FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    public enum LoadError: Error, CustomStringConvertible, LocalizedError {
        case noArilsAvatar
        case unreadable(String)
        public var description: String {
            switch self {
            case .noArilsAvatar: "Arilsの保存データがありません。画像からペットを作成するか、Arils形式のペットを選んでください。"
            case let .unreadable(reason): "ペットを読み込めませんでした: \(reason)"
            }
        }
        public var errorDescription: String? { description }
    }

    private struct SavedPet: Decodable {
        var arilsArchiveData: Data?
        var qualityArchiveData: Data?
        var document: RigDocument?
        var imageData: Data?
    }

    public static func loadAsset(contentsOf url: URL) throws -> PetAsset {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw LoadError.unreadable(error.localizedDescription) }
        return try loadAsset(data: data)
    }

    public static func loadAsset(data: Data) throws -> PetAsset {
        if let quality = try? QualityAvatarArchive(data: data) {
            return try validated(quality)
        }
        if let archive = try? AvatarArchive(data: data) { return .standard(archive) }
        guard let saved = try? JSONDecoder().decode(SavedPet.self, from: data) else {
            throw LoadError.unreadable("Castor JSON / Arils archiveの形式ではありません。")
        }
        // Mac prefers Quality. A broken profile must be reported, never hidden
        // by falling back to an unrelated/older single-view archive.
        if let qualityData = saved.qualityArchiveData {
            do { return try validated(QualityAvatarArchive(data: qualityData)) }
            catch { throw LoadError.unreadable("Quality保存データが不完全または破損しています。") }
        }
        if let archiveData = saved.arilsArchiveData {
            guard let archive = try? AvatarArchive(data: archiveData) else {
                throw LoadError.unreadable("Arils保存データが破損しています。")
            }
            return .standard(archive)
        }
        if let document = saved.document, let imageData = saved.imageData {
            do { return .manual(try ManualPet(document: document, source: PortableRigImage(png: imageData))) }
            catch { throw LoadError.unreadable(error.localizedDescription) }
        }
        throw LoadError.noArilsAvatar
    }

    private static func validated(_ quality: QualityAvatarArchive) throws -> PetAsset {
        let r = quality.registration
        guard quality.formatVersion == QualityAvatarArchive.currentFormatVersion,
              [r.frontNeck.x, r.frontNeck.y, r.sideNeck.x, r.sideNeck.y, r.sideScale].allSatisfy(\.isFinite),
              r.sideScale > 0, r.sideScale <= 100,
              quality.front.rig.imageWidth > 0, quality.front.rig.imageHeight > 0,
              quality.side.rig.imageWidth > 0, quality.side.rig.imageHeight > 0 else {
            throw LoadError.unreadable("Qualityの形式または首位置・画像サイズを確認してください。")
        }
        return .quality(quality)
    }

    /// Explicit compatibility API for callers that only need the front view.
    /// Desktop playback uses loadAsset so Quality is never flattened.
    public static func load(contentsOf url: URL) throws -> AvatarArchive {
        try arilsFront(loadAsset(contentsOf: url))
    }
    public static func load(data: Data) throws -> AvatarArchive {
        try arilsFront(loadAsset(data: data))
    }
    private static func arilsFront(_ asset: PetAsset) throws -> AvatarArchive {
        if case .manual = asset { throw LoadError.unreadable("手動リグはCastor JSONとして保存してください。") }
        return asset.front
    }

}
