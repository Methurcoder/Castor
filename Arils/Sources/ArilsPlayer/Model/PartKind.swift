import Foundation

/// Semantic role of a rig part. The automatic pipeline emits a subset of these;
/// the rest exist so hand-authored or future rigs can use the same document.
public enum PartKind: String, Codable, Sendable, CaseIterable {
    /// The torso/base layer (full subject with the head zone inpainted out).
    case body
    /// Head cutout including hair on the scalp; eye/mouth holes are inpainted.
    case head
    /// Separately cut back hair (not produced by the v1 automatic pipeline,
    /// which animates back hair as a warp region on `body` instead).
    case hairBack
    /// Separately cut fringe (v1 automatic pipeline uses a warp region on `head`).
    case hairFront
    /// Viewer's left eye.
    case eyeLeft
    /// Viewer's right eye.
    case eyeRight
    case mouth
    /// Free slot for extra layers (ribbons, ears, props).
    case accessory
}
