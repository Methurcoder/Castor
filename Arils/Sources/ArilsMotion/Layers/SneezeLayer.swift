import Foundation

import ArilsCore

/// Spontaneous sneezes — the character occasionally does something entirely of
/// its own accord, which reads as "alive" like nothing else.
///
/// Three phases, all additive on top of whatever else is running:
/// 1. **Inhale** (~0.6 s): the head tips back, the eyes drift shut, the mouth
///    opens slightly, the chest rises.
/// 2. **Burst** (~0.14 s): the head whips forward, the mouth snaps open, the
///    body dips, and a strong impulse is pumped into the hair physics.
/// 3. **Recovery** (~1.5 s): everything eases back, the eyes stay lazily
///    half-lidded for a moment.
///
/// Scheduling is seeded-random (same seed → same sneeze times); hosts can also
/// force one with `requestSneeze()`. An `averageInterval` of `.infinity`
/// disables spontaneous sneezes without removing the manual trigger.
public final class SneezeLayer: MotionLayer {
    private var rng: SeededRandom
    /// Mean seconds between spontaneous sneezes.
    private let averageInterval: Double

    private var nextSneezeAt: Double = .nan
    private var sneezeStartedAt: Double = -.greatestFiniteMagnitude
    private var manualRequest = false
    private var burstImpulseFired = false

    /// Hair-physics excitation from the burst; the controller consumes it.
    public private(set) var hairImpulse: Float = 0

    // Phase lengths (seconds).
    private let inhaleDuration: Float = 0.6
    private let burstDuration: Float = 0.14
    private let recoveryDuration: Float = 1.5

    public init(seed: UInt64, averageInterval: Double = 240) {
        self.rng = SeededRandom(seed: seed, stream: "sneeze")
        self.averageInterval = max(10, averageInterval)
    }

    /// True from the start of a sneeze until its recovery ends.
    public func isActive(at time: Double) -> Bool {
        let total = Double(inhaleDuration + burstDuration + recoveryDuration)
        return time >= sneezeStartedAt && time - sneezeStartedAt < total
    }

    /// Forces a sneeze to start on the next update (ignored mid-sneeze).
    public func requestSneeze() {
        manualRequest = true
    }

    public func consumeHairImpulse() -> Float {
        defer { hairImpulse = 0 }
        return hairImpulse
    }

    public func update(context: MotionContext, values: inout ParameterValues) {
        let time = context.time
        let totalDuration = Double(inhaleDuration + burstDuration + recoveryDuration)
        let isSneezing = time - sneezeStartedAt < totalDuration

        if nextSneezeAt.isNaN {
            nextSneezeAt = time + scheduleDelay()
        }
        if !isSneezing {
            if manualRequest {
                start(at: time)
            } else if averageInterval.isFinite, time >= nextSneezeAt {
                start(at: time)
            }
        }
        manualRequest = false

        let phase = Float(time - sneezeStartedAt)
        guard phase >= 0, phase < Float(totalDuration) else { return }

        if phase < inhaleDuration {
            // 1. Inhale: head back, eyes closing, breath held high.
            let p = Interpolation.smoothstep(0, 1, phase / inhaleDuration)
            values.add(.angleY, 7 * p)
            values.add(.eyeLeftOpen, -0.85 * p)
            values.add(.eyeRightOpen, -0.85 * p)
            values.add(.mouthOpen, 0.3 * p)
            values.add(.breath, 0.5 * p)
            values.add(.bodyY, 0.06 * p)
        } else if phase < inhaleDuration + burstDuration {
            // 2. Burst: the whip forward.
            let q = Interpolation.smoothstep(0, 1, (phase - inhaleDuration) / burstDuration)
            if !burstImpulseFired {
                burstImpulseFired = true
                let direction: Float = rng.chance(0.5) ? 1 : -1
                hairImpulse = direction * rng.float(in: 1.1...1.6)
            }
            values.add(.angleY, 7 - 19 * q)          // +7 → -12
            values.add(.eyeLeftOpen, -1)
            values.add(.eyeRightOpen, -1)
            values.add(.mouthOpen, 0.3 + 0.65 * q)
            values.add(.bodyY, 0.06 - 0.3 * q)
            values.add(.bodyAngleX, 1.2 * q)
        } else {
            // 3. Recovery: ease back, eyes lazily half-lidded at first.
            let r = Interpolation.smoothstep(
                0, 1,
                (phase - inhaleDuration - burstDuration) / recoveryDuration
            )
            let lingering = 1 - r
            values.add(.angleY, -12 * lingering)
            values.add(.eyeLeftOpen, -0.5 * lingering)
            values.add(.eyeRightOpen, -0.5 * lingering)
            values.add(.mouthOpen, 0.2 * lingering)
            values.add(.bodyY, -0.24 * lingering)
            values.add(.bodyAngleX, 1.2 * lingering)
        }
    }

    private func start(at time: Double) {
        sneezeStartedAt = time
        burstImpulseFired = false
        nextSneezeAt = time + scheduleDelay()
    }

    private func scheduleDelay() -> Double {
        guard averageInterval.isFinite else { return .greatestFiniteMagnitude }
        return averageInterval * Double(rng.float(in: 0.55...1.45))
    }
}
