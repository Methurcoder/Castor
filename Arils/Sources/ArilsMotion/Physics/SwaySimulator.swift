import Foundation

import ArilsCore

/// Settings for one sway oscillator (mirrors the rig's `SwayChannel`; the
/// umbrella module maps between them so ArilsMotion stays rig-agnostic).
public struct SwayChannelSettings: Sendable, Equatable {
    public var output: ParameterID
    /// Natural frequency in Hz.
    public var frequency: Float
    public var dampingRatio: Float
    /// Gain from head angular velocity (deg/s) into oscillator force.
    public var headDrive: Float
    /// Constant noise excitation so the channel never freezes solid.
    public var breeze: Float

    public init(
        output: ParameterID,
        frequency: Float,
        dampingRatio: Float,
        headDrive: Float,
        breeze: Float
    ) {
        self.output = output
        self.frequency = frequency
        self.dampingRatio = dampingRatio
        self.headDrive = headDrive
        self.breeze = breeze
    }

    /// Matches `BindingSynthesizer`'s default physics rig.
    public static let standard: [SwayChannelSettings] = [
        SwayChannelSettings(output: .hairFrontSway, frequency: 1.7, dampingRatio: 0.25, headDrive: 0.9, breeze: 0.25),
        SwayChannelSettings(output: .hairBackSway, frequency: 1.0, dampingRatio: 0.30, headDrive: 1.2, breeze: 0.35),
    ]
}

/// Damped-oscillator "secondary motion" for hair and similar appendages.
///
/// Each channel is a driven harmonic oscillator: head rotation accelerations
/// swing it, petting strokes kick it, and a slow noise breeze keeps a faint
/// residual sway during stillness. Output is a normalized -1...1 parameter the
/// rig's `regionSway` bindings translate into pixels.
public final class SwaySimulator {
    private struct ChannelState {
        var settings: SwayChannelSettings
        var position: Float = 0
        var velocity: Float = 0
        let noise: ValueNoise1D
    }

    private var channels: [ChannelState]
    private static let maxStep: Float = 1.0 / 60.0

    public init(channels: [SwayChannelSettings], seed: UInt64) {
        self.channels = channels.map { settings in
            ChannelState(
                settings: settings,
                noise: ValueNoise1D(seed: BitMix.mix(seed ^ BitMix.hash("sway." + settings.output.rawValue)))
            )
        }
    }

    /// Integrates all channels and adds their outputs to `values`.
    /// - Parameters:
    ///   - headAngularVelocity: combined head angular velocity in deg/s.
    ///   - impulse: sustained excitation from an active petting stroke
    ///     (normalized; folded into the drive, *not* a per-frame velocity kick —
    ///     a kick every frame would integrate into unbounded velocity).
    public func update(
        context: MotionContext,
        headAngularVelocity: Float,
        impulse: Float,
        values: inout ParameterValues
    ) {
        let t = Float(context.time)
        for index in channels.indices {
            var channel = channels[index]
            let omega = 2 * Float.pi * channel.settings.frequency
            let breeze = channel.noise.fbm(at: t * 0.4, octaves: 2) * channel.settings.breeze * 1.4
            // Head swings the hair opposite to its own motion (inertia);
            // a petting stroke brushes it along the stroke direction.
            let drive = -headAngularVelocity * 0.045 * channel.settings.headDrive
                + breeze
                + impulse * 0.45

            var remaining = min(context.deltaTime, 0.5)
            while remaining > 0 {
                let dt = min(remaining, Self.maxStep)
                remaining -= dt
                let acceleration = -omega * omega * channel.position
                    - 2 * channel.settings.dampingRatio * omega * channel.velocity
                    + drive * omega * omega
                channel.velocity += acceleration * dt
                channel.position += channel.velocity * dt
            }
            // Belt-and-braces bounds so no input sequence can wind the
            // oscillator up into a long recovery.
            channel.velocity = Interpolation.clamp(channel.velocity, -25...25)
            channel.position = Interpolation.clamp(channel.position, -1...1)
            values.add(channel.settings.output, channel.position)
            channels[index] = channel
        }
    }
}
