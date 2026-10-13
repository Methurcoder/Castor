import Foundation
#if canImport(simd)
import simd
#endif

import ArilsCore

/// Why a layer asks for a blink. The blink layer owns the decision (and its
/// random stream), so requests are suggestions with a cause, not commands.
enum BlinkCue: Sendable, Equatable {
    /// A gaze shift of this amplitude (normalized eye units) just started.
    case gazeShift(amplitude: Float)
    /// A spoken phrase ended (pause inside an utterance).
    case phraseBoundary
    /// The character finished speaking.
    case utteranceEnd
    /// The conversation behavior changed.
    case behaviorChange
    /// An action needs a blink right now (waking up, recovering from surprise).
    case forced
}

/// A brief look away (or toward a point), owned by the gaze layer once posted.
struct GlanceRequest: Sendable, Equatable {
    var start: Double
    var duration: Double
    /// Gaze target (normalized -1...1) to hold during the glance.
    var target: SIMD2<Float>
    /// How much of the original target still pulls during the glance.
    var residualAttention: Float = 0.1
}

/// Cross-layer signals for one controller. Layers run in a fixed order and
/// post cues here; consumers read them later in the same frame or on the
/// next one. Single-threaded by construction (the controller owns all layers
/// on one isolation domain) and deterministic: only layer code writes it.
final class MotionCues {
    /// Blink suggestions, each with the time it refers to.
    var blinkRequests: [(time: Double, cue: BlinkCue)] = []
    /// Spontaneous blinks are held back until this time (wide surprised eyes).
    var blinkSuppressedUntil: Double = -.greatestFiniteMagnitude
    /// Glances queued for the gaze layer.
    var glanceRequests: [GlanceRequest] = []
    /// Ends any active glance early (e.g. the speaker re-engages at utterance end).
    var endGlanceRequested = false
    /// -1 / +1 side the character looks to while thinking (set by attitude).
    var thinkingSide: Float = 1
    /// Hair-physics excitation accumulated this frame (consumed by the controller).
    var hairImpulse: Float = 0
    /// True while a sneeze plays, so micro-actions do not start on top of it.
    var transientBusy = false
    /// Last time the user engaged (pointer moved, stroke, conversation).
    var lastEngagement: Double = 0
    /// Current lip-sync target openness (0 when silent), before the mouth
    /// envelope; the speech-gesture layer reads phrasing and stress from it.
    var speechLevel: Float = 0

    func requestBlink(at time: Double, _ cue: BlinkCue) {
        blinkRequests.append((time, cue))
    }

    func consumeHairImpulse() -> Float {
        defer { hairImpulse = 0 }
        return hairImpulse
    }
}

/// Time-shaped envelopes shared by gesture/action layers. All are pure
/// functions of the time elapsed since an event's *scheduled* start, which
/// keeps motion identical at any frame rate.
enum Shape {
    /// 0 → 1 → 0 half-sine over `duration`.
    static func bump(_ elapsed: Double, duration: Double) -> Float {
        guard elapsed >= 0, elapsed < duration, duration > 0 else { return 0 }
        return Float(sin(.pi * elapsed / duration))
    }

    /// Smooth rise over `attack`, hold, smooth fall over `release`.
    static func plateau(_ elapsed: Double, attack: Double, hold: Double, release: Double) -> Float {
        guard elapsed >= 0 else { return 0 }
        if elapsed < attack {
            return Interpolation.smoothstep(0, 1, Float(elapsed / max(attack, 1e-6)))
        }
        if elapsed < attack + hold { return 1 }
        let fall = elapsed - attack - hold
        guard fall < release else { return 0 }
        return 1 - Interpolation.smoothstep(0, 1, Float(fall / max(release, 1e-6)))
    }

    /// Minimum-jerk position profile 0...1 for progress `s` in 0...1 — the
    /// velocity bell of a human saccade or reach.
    static func minimumJerk(_ s: Float) -> Float {
        let t = Interpolation.clamp(s, 0...1)
        return t * t * t * (10 - 15 * t + 6 * t * t)
    }
}

extension SeededRandom {
    /// Standard normal sample (Box–Muller), drawn from this stream.
    mutating func normal() -> Float {
        let u1 = max(unitFloat(), 1e-7)
        let u2 = unitFloat()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// Log-normal duration with the given median and log-space sigma.
    mutating func logNormal(median: Float, sigma: Float) -> Float {
        median * exp(sigma * normal())
    }
}
