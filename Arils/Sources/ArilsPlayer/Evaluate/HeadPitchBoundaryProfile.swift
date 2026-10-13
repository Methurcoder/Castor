#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#endif
import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Rest-space pitch weights for a rectangular head layer.
///
/// The face keeps a broad full-strength band, while displacement falls to zero
/// at every edge where the head texture meets either the fixed body or the
/// background. Eye bounds locate the face band when available; hand-authored
/// rigs without eyes use a conservative centered fallback.
struct HeadPitchBoundaryProfile: Sendable {
    private let minX: Float
    private let maxX: Float
    private let minY: Float
    private let height: Float
    private let coreMinX: Float
    private let coreMaxX: Float

    init(head: AvatarPart, parts: [AvatarPart]) {
        minX = Float(head.rect.minX)
        maxX = Float(head.rect.maxX)
        minY = Float(head.rect.minY)
        height = Float(max(1, head.rect.height))

        let width = Float(max(1, head.rect.width))
        let eyes = parts.filter {
            $0.parentID == head.id && ($0.kind == .eyeLeft || $0.kind == .eyeRight)
        }
        if eyes.count >= 2 {
            let eyeMinX = eyes.map { Float($0.rect.minX) }.min() ?? minX + width * 0.22
            let eyeMaxX = eyes.map { Float($0.rect.maxX) }.max() ?? maxX - width * 0.22
            // Avoid an unusually narrow/wide estimate turning the fade into a
            // hard crease or moving long side hair at full pitch strength.
            coreMinX = minX + Interpolation.clamp((eyeMinX - minX) / width, 0.18...0.30) * width
            coreMaxX = minX + Interpolation.clamp((eyeMaxX - minX) / width, 0.70...0.82) * width
        } else {
            coreMinX = minX + width * 0.22
            coreMaxX = minX + width * 0.78
        }
    }

    /// Side and crown boundary weight. The neck taper is supplied separately
    /// because production pitch derives its band from the actual mouth position.
    func outerBoundaryWeight(at point: SIMD2<Float>) -> Float {
        let horizontal: Float
        if point.x <= minX || point.x >= maxX {
            horizontal = 0
        } else if point.x < coreMinX {
            horizontal = Interpolation.smoothstep(minX, coreMinX, point.x)
        } else if point.x > coreMaxX {
            horizontal = Interpolation.smoothstep(0, maxX - coreMaxX, maxX - point.x)
        } else {
            horizontal = 1
        }

        // Keep this band narrow: it closes background slits at the crop edge
        // without restoring the old whole-face vertical compression.
        let crownBand = height * 0.10
        let crown = Interpolation.smoothstep(0, crownBand, point.y - minY)
        return horizontal * crown
    }

    /// Complete bounded weight for the legacy head-pitch translation.
    func legacyWeight(at point: SIMD2<Float>, pivotY: Float) -> Float {
        let neckBand = height * 0.22
        let neck = Interpolation.smoothstep(0, neckBand, pivotY - point.y)
        return outerBoundaryWeight(at: point) * neck
    }
}
