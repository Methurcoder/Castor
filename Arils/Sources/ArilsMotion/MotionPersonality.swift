import Foundation

/// Per-character motion temperament. The same layers produce visibly
/// different characters by scaling *how* they move — how long they hesitate,
/// how snappy their springs are, how often they fidget or look away — while
/// the authored behaviors stay shared.
///
/// Every field is a plain number so hosts can derive one from whatever they
/// know about a character (a preset, a slider, a persona text classifier)
/// and persist it alongside the rig.
public struct MotionPersonality: Sendable, Equatable, Codable {
    /// 0...1 resting unsureness: reaction delay, false starts, and settle
    /// overshoot on behavior changes (the "不器用さ" of the character).
    public var hesitation: Float
    /// 0.5...1.8 spring-frequency scale for posture and head responses.
    public var responsiveness: Float
    /// 0...2 scale for ambient idle drift.
    public var idleAmplitude: Float
    /// 0.3...2 scale for spontaneous blink rate (1 ≈ 17–20 per minute at rest).
    public var blinkRate: Float
    /// 0...2.5 scale for spontaneous micro-actions (glances, weight shifts,
    /// sighs, yawns, dozing off).
    public var fidgetRate: Float
    /// 0...1 tendency to avert the gaze (probability and duration).
    public var shyness: Float
    /// 0...2 amplitude scale for attitude postures, nods, and speech head motion.
    public var expressiveness: Float

    public init(
        hesitation: Float = 0.35,
        responsiveness: Float = 1,
        idleAmplitude: Float = 1,
        blinkRate: Float = 1,
        fidgetRate: Float = 1,
        shyness: Float = 0.4,
        expressiveness: Float = 1
    ) {
        self.hesitation = hesitation
        self.responsiveness = responsiveness
        self.idleAmplitude = idleAmplitude
        self.blinkRate = blinkRate
        self.fidgetRate = fidgetRate
        self.shyness = shyness
        self.expressiveness = expressiveness
    }

    public static let standard = MotionPersonality()
    /// Hesitant, looks away often, small gestures, blinks a little more.
    public static let shy = MotionPersonality(
        hesitation: 0.6, responsiveness: 0.85, idleAmplitude: 0.8, blinkRate: 1.25,
        fidgetRate: 0.8, shyness: 0.85, expressiveness: 0.75
    )
    /// Quick, bouncy, big gestures, holds eye contact.
    public static let lively = MotionPersonality(
        hesitation: 0.2, responsiveness: 1.35, idleAmplitude: 1.3, blinkRate: 1.1,
        fidgetRate: 1.4, shyness: 0.2, expressiveness: 1.35
    )
    /// Slow, steady, few fidgets.
    public static let calm = MotionPersonality(
        hesitation: 0.25, responsiveness: 0.75, idleAmplitude: 0.7, blinkRate: 0.8,
        fidgetRate: 0.6, shyness: 0.35, expressiveness: 0.8
    )
    /// Pomegranate's signature: late, overshooting, a little flustered.
    public static let clumsy = MotionPersonality(
        hesitation: 0.8, responsiveness: 1.0, idleAmplitude: 1.1, blinkRate: 1.1,
        fidgetRate: 1.2, shyness: 0.5, expressiveness: 1.1
    )

    public static let presets: [(name: String, personality: MotionPersonality)] = [
        ("standard", .standard), ("shy", .shy), ("lively", .lively), ("calm", .calm), ("clumsy", .clumsy),
    ]

    /// The personality with every field forced finite and into its range, so
    /// a corrupt persisted value can never destabilize a spring.
    public var sanitized: MotionPersonality {
        func clamp(_ value: Float, _ range: ClosedRange<Float>, _ fallback: Float) -> Float {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return MotionPersonality(
            hesitation: clamp(hesitation, 0...1, 0.35),
            responsiveness: clamp(responsiveness, 0.5...1.8, 1),
            idleAmplitude: clamp(idleAmplitude, 0...2, 1),
            blinkRate: clamp(blinkRate, 0.3...2, 1),
            fidgetRate: clamp(fidgetRate, 0...2.5, 1),
            shyness: clamp(shyness, 0...1, 0.4),
            expressiveness: clamp(expressiveness, 0...2, 1)
        )
    }
}
