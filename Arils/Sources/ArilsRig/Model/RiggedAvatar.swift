import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import ArilsRigPortable

/// A rig paired with the extracted per-part textures — the ready-to-render unit.
///
/// `@unchecked Sendable`: `CGImage` is immutable after creation, so sharing
/// across isolation domains is safe even though it doesn't declare Sendable.
public struct RiggedAvatar: @unchecked Sendable {
    public var rig: AvatarRig
    /// Part ID → texture (the pixels for that part's `rect`, straight or
    /// premultiplied alpha as produced by the pipeline).
    public var textures: [String: CGImage]

    public init(rig: AvatarRig, textures: [String: CGImage]) {
        self.rig = rig
        self.textures = textures
    }
}

/// CGImage conversion for `AvatarArchive` (Apple platforms).
extension AvatarArchive {
    public init(avatar: RiggedAvatar) throws {
        var pngs: [String: Data] = [:]
        for (partID, image) in avatar.textures {
            guard let data = Self.pngData(from: image) else {
                throw ArchiveError.textureEncodingFailed(partID: partID)
            }
            pngs[partID] = data
        }
        self.init(rig: avatar.rig, texturePNGs: pngs)
    }

    public func makeAvatar() throws -> RiggedAvatar {
        let (repairedRig, dropped) = repairedRig()
        var textures: [String: CGImage] = [:]
        for (partID, data) in texturePNGs where !dropped.contains(partID) {
            guard let image = Self.image(fromPNG: data) else {
                throw ArchiveError.textureDecodingFailed(partID: partID)
            }
            textures[partID] = image
        }
        return RiggedAvatar(rig: repairedRig, textures: textures)
    }

    // MARK: - PNG helpers

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func image(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

public extension RiggedAvatar {
    /// This avatar with the "more natural face motion" beta applied (see
    /// `FollowingHair`), or unchanged when it has no side hair to move.
    func withFollowingHair() -> RiggedAvatar {
        guard let head = rig.firstPart(ofKind: .head), let bodyID = head.parentID,
              let headImage = textures[head.id], let bodyImage = textures[bodyID],
              let headLayer = Bitmap(image: headImage), let bodyLayer = Bitmap(image: bodyImage),
              let result = FollowingHair.apply(rig: rig, layers: [head.id: headLayer, bodyID: bodyLayer]),
              let body = result.layers[bodyID]?.cgImage(),
              let side = result.layers[SideHairRegion.partID]?.cgImage() else { return self }
        var textures = textures
        textures[bodyID] = body
        textures[SideHairRegion.partID] = side
        return RiggedAvatar(rig: result.rig, textures: textures)
    }
}
