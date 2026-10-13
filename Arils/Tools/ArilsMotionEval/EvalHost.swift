import Foundation

import ArilsCore
import ArilsMotion

/// Models what the Pomegranate host feeds the engine, so the harness measures
/// the motion a user actually sees rather than an idealized input.
enum MotionEvalHost {
    /// Gaze reconstruction gain used by the pointer metric: how much of the
    /// head yaw (normalized by 14°) counts toward where the character looks.
    static let vorGain: Float = GazeLayer.vestibuloOcularGain

    /// Which host mapping the scenarios use.
    nonisolated(unsafe) static var useBehavior = true

    /// Host mapping. Legacy (`ArilsPetView.synchronizeEngine` today): only
    /// `energy` (0.5 idle, 0.72 while the conversation is active) and
    /// `isSpeaking` reach the engine. Behavior: the conversation phase is
    /// passed through as `MotionInputs.behavior` as well.
    static func apply(phase: Phase, time: Double, to inputs: inout MotionInputs) {
        if useBehavior {
            switch phase {
            case .idle: inputs.behavior = .idle
            case .listening: inputs.behavior = .listening
            case .thinking: inputs.behavior = .thinking
            case .speaking: inputs.behavior = .speaking
            }
        }
        switch phase {
        case .idle:
            inputs.energy = 0.5
        case .listening, .thinking:
            inputs.energy = 0.72
        case .speaking:
            inputs.energy = 0.72
            inputs.isSpeaking = true
        }
    }

    /// Mouth-open series for each lip-sync delivery path the host can use.
    static func lipSyncPaths(
        samples: [Float],
        sampleRate: Double,
        frameCount: Int,
        fps: Double
    ) -> [(String, [Float])] {
        [
            ("hostMeter30Hz", hostMeter(samples: samples, sampleRate: sampleRate, frameCount: frameCount, fps: fps)),
            ("pcmTap1024", pcmTap(samples: samples, sampleRate: sampleRate, frameCount: frameCount, fps: fps)),
            ("timeline", timeline(samples: samples, sampleRate: sampleRate, frameCount: frameCount, fps: fps)),
        ]
    }

    /// `LipSyncTimeline` computed before playback, read by the player clock.
    static func timeline(samples: [Float], sampleRate: Double, frameCount: Int, fps: Double) -> [Float] {
        let track = LipSyncTimeline.analyze(samples: samples, sampleRate: sampleRate)
        let controller = controller()
        let clipDuration = Double(samples.count) / sampleRate
        var mouth: [Float] = []
        for frame in 0..<frameCount {
            let time = Double(frame) / fps
            let speaking = time < clipDuration
            let inputs = MotionInputs(isSpeaking: speaking, lipSync: speaking ? track.frame(at: time) : nil)
            mouth.append(controller.update(at: time, inputs: inputs)[.mouthOpen] ?? 0)
        }
        return mouth
    }

    private static func controller() -> MotionController {
        MotionController(
            descriptors: StandardParameters.all,
            configuration: MotionController.Configuration(seed: 1, sneezeInterval: .infinity, microActionsEnabled: false)
        )
    }

    /// `AVAudioPlayer.averagePower` (modelled as trailing 1024-sample RMS) →
    /// `SpeechEnergyEnvelope` (attack 18/s, release 6/s) polled at 30 Hz →
    /// `pushSpeechLevel`, exactly the shipping Pomegranate path.
    static func hostMeter(samples: [Float], sampleRate: Double, frameCount: Int, fps: Double) -> [Float] {
        let analyzer = LipSyncAnalyzer()
        let controller = controller()
        let clipDuration = Double(samples.count) / sampleRate
        var envelope: Double = 0
        var nextPoll = 0.0
        var mouth: [Float] = []
        for frame in 0..<frameCount {
            let time = Double(frame) / fps
            let speaking = time < clipDuration
            if speaking, time >= nextPoll {
                nextPoll += 1.0 / 30.0
                let end = min(samples.count, Int(time * sampleRate))
                let start = max(0, end - 1024)
                var decibels: Float = -160
                if end > start {
                    let meanSquare = samples[start..<end].reduce(0) { $0 + $1 * $1 } / Float(end - start)
                    decibels = 20 * log10(max(sqrt(meanSquare), 1e-8))
                }
                let raw = Double((max(-50, min(0, decibels)) + 50) / 50)
                let rate = raw >= envelope ? 18.0 : 6.0
                envelope += (raw - envelope) * (1 - exp(-rate / 30))
                analyzer.push(level: Float(envelope))
            }
            let inputs = MotionInputs(isSpeaking: speaking, lipSync: speaking ? analyzer.currentFrame() : nil)
            mouth.append(controller.update(at: time, inputs: inputs)[.mouthOpen] ?? 0)
        }
        return mouth
    }

    /// AVAudioEngine output tap (1024-frame buffers delivered once rendered)
    /// → `pushSpeechSamples`, the ArilsDemo path.
    static func pcmTap(samples: [Float], sampleRate: Double, frameCount: Int, fps: Double) -> [Float] {
        let analyzer = LipSyncAnalyzer()
        let controller = controller()
        let clipDuration = Double(samples.count) / sampleRate
        var pushed = 0
        var mouth: [Float] = []
        for frame in 0..<frameCount {
            let time = Double(frame) / fps
            let speaking = time < clipDuration
            let played = min(samples.count, Int(time * sampleRate))
            while pushed + 1024 <= played {
                analyzer.push(samples: Array(samples[pushed..<(pushed + 1024)]), sampleRate: sampleRate)
                pushed += 1024
            }
            let inputs = MotionInputs(isSpeaking: speaking, lipSync: speaking ? analyzer.currentFrame() : nil)
            mouth.append(controller.update(at: time, inputs: inputs)[.mouthOpen] ?? 0)
        }
        return mouth
    }
}
