import Foundation

/// Persistent form of a `RiggedAvatar`: rig JSON-compatible document plus
/// PNG-encoded textures, packed into one binary property list.
///
/// Rigging runs once per image; hosts should archive the result and reload it
/// on subsequent launches instead of re-running the pipeline. This type only
/// reads and writes the archive, so it works on every platform; turning the
/// PNGs into images is the host's job (`ArilsRig` adds CGImage conversion on
/// Apple platforms).
public struct AvatarArchive: Codable, Sendable {
    public var rig: AvatarRig
    public var texturePNGs: [String: Data]

    public init(rig: AvatarRig, texturePNGs: [String: Data]) {
        self.rig = rig
        self.texturePNGs = texturePNGs
    }

    public enum ArchiveError: Error {
        case textureEncodingFailed(partID: String)
        case textureDecodingFailed(partID: String)
    }

    /// Serializes to a single binary blob suitable for writing to disk.
    public func data() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public init(data: Data) throws {
        self = try PropertyListDecoder().decode(AvatarArchive.self, from: data)
    }

    /// The rig with parts from obsolete pipeline revisions removed, and the
    /// part IDs whose textures should be dropped with them.
    ///
    /// A briefly used automatic-rig revision duplicated a rectangular
    /// `neckForeground` strip above the moving head. It could contain hair
    /// and shoulder pixels and expose hard bands during a turn. Strip that
    /// obsolete generated part while loading so locally saved previews from
    /// that revision recover without requiring the source image again.
    public func repairedRig() -> (rig: AvatarRig, droppedPartIDs: Set<String>) {
        var repaired = rig
        var dropped: Set<String> = []
        if repaired.parts.contains(where: { $0.id == "neckForeground" }) {
            repaired.parts.removeAll { $0.id == "neckForeground" }
            dropped.insert("neckForeground")
        }
        return (repaired, dropped)
    }
}
