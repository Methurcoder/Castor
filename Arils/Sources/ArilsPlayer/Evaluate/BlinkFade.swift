import Foundation

import ArilsCore

/// Opacity of an eye layer while it closes.
///
/// An automatic eye closes by squashing its cutout to a thin strip. At full
/// opacity that strip is the whole eye — iris, lashes and lid — averaged into a
/// dark band, which reads as a shadow under the eye rather than a closed lid.
/// Fading the strip as it thins lets the inpainted skin underneath show
/// through, leaving a light line where the lid meets.
///
/// Only eyes that are nearly shut fade, so half-lidded or sleepy eyes (which
/// other layers lower to about 0.65) keep their full colour. The fade is a
/// render-time rule: saved rigs are unchanged and older characters get it too.
public enum BlinkFade {
    /// Openness at which a closing eye starts to fade.
    public static let fadeStart: Float = 0.4
    /// Openness at and below which the eye is drawn at `closedOpacity`.
    public static let fadeEnd: Float = 0.05
    /// Opacity multiplier of a fully closed eye.
    public static let closedOpacity: Float = 0.4

    /// The openness parameter that closes this part, if it is an automatic eye.
    public static func parameter(for part: AvatarPart) -> ParameterID? {
        guard part.kind == .eyeLeft || part.kind == .eyeRight else { return nil }
        for op in part.deformations {
            if case let .scale(parameter, _, _, gainY) = op,
               parameter == .eyeLeftOpen || parameter == .eyeRightOpen,
               gainY > 0 {
                return parameter
            }
        }
        return nil
    }

    /// Opacity multiplier for an eye at `openness` (1 = rest, 0 = closed).
    public static func multiplier(openness: Float) -> Float {
        guard openness.isFinite else { return 1 }
        let t = Interpolation.smoothstep(fadeEnd, fadeStart, openness)
        return closedOpacity + (1 - closedOpacity) * t
    }

    /// Opacity to draw `part` with under `parameters`.
    public static func opacity(
        base: Float,
        parameter: ParameterID?,
        parameters: [ParameterID: Float]
    ) -> Float {
        guard let parameter else { return base }
        return base * multiplier(openness: parameters[parameter] ?? 1)
    }
}
