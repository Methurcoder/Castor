import ArilsPlayer
import ArilsRigPortable
import CStbImage
import Foundation

/// Applies the "more natural face motion" beta to a stored archive: decodes
/// the head and body textures, lets `FollowingHair` add the side hair layer,
/// and stores the changed textures back as PNG. The archive is returned
/// unchanged when nothing follows the head or a texture cannot be read.
enum FollowingHairArchive {
    static func apply(to archive: AvatarArchive) -> AvatarArchive {
        let rig = archive.rig
        guard let head = rig.firstPart(ofKind: .head), let bodyID = head.parentID,
              let headLayer = bitmap(archive.texturePNGs[head.id]),
              let bodyLayer = bitmap(archive.texturePNGs[bodyID]),
              let result = FollowingHair.apply(rig: rig, layers: [head.id: headLayer, bodyID: bodyLayer]) else { return archive }
        var textures = archive.texturePNGs
        // Without side hair only the neck and shoulders follow; the body
        // texture is then unchanged.
        if let side = result.layers[SideHairRegion.partID] {
            guard let body = result.layers[bodyID] else { return archive }
            textures[bodyID] = png(body)
            textures[SideHairRegion.partID] = png(side)
        }
        return AvatarArchive(rig: result.rig, texturePNGs: textures)
    }

    /// PNG (straight alpha) to a premultiplied bitmap.
    private static func bitmap(_ data: Data?) -> Bitmap? {
        guard let data else { return nil }
        var width: Int32 = 0, height: Int32 = 0, channels: Int32 = 0
        let decoded: UnsafeMutablePointer<UInt8>? = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return stbi_load_from_memory(base, Int32(raw.count), &width, &height, &channels, 4)
        }
        guard let decoded, width > 0, height > 0 else { return nil }
        defer { stbi_image_free(decoded) }
        var pixels = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        for i in 0..<(Int(width) * Int(height)) {
            let a = UInt16(decoded[i * 4 + 3])
            for c in 0..<3 { pixels[i * 4 + c] = UInt8((UInt16(decoded[i * 4 + c]) * a + 127) / 255) }
            pixels[i * 4 + 3] = UInt8(a)
        }
        return Bitmap(width: Int(width), height: Int(height), pixels: pixels)
    }

    /// A premultiplied bitmap to PNG (straight alpha).
    private static func png(_ bitmap: Bitmap) -> Data {
        var rgba = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        for i in 0..<(bitmap.width * bitmap.height) {
            let a = bitmap.pixels[i * 4 + 3]
            guard a > 0 else { continue }
            for c in 0..<3 { rgba[i * 4 + c] = UInt8(min(255, (UInt16(bitmap.pixels[i * 4 + c]) * 255 + UInt16(a) / 2) / UInt16(a))) }
            rgba[i * 4 + 3] = a
        }
        return PortablePNG.encode(width: bitmap.width, height: bitmap.height, rgba: rgba)
    }
}
