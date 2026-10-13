import AVFoundation
import Foundation
import simd

import ArilsCore
import ArilsMotion

// Motion evaluation harness: `swift run arils-motion-eval [--audio a.wav ...] [--json out.json]`.
//
// Runs deterministic scenarios through `MotionController` and prints the
// `MotionMetrics` numbers that stand in for "does this look alive". Audio
// files (e.g. `say -v Kyoko -o x.wav --data-format=LEF32@24000 "..."`) are
// used for the lip-sync section; they stay outside Git like the image corpus.

// MARK: - Arguments

var audioPaths: [String] = []
var jsonPath: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--audio":
        if let path = arguments.next() { audioPaths.append(path) }
    case "--json":
        jsonPath = arguments.next()
    default:
        FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
        exit(2)
    }
}

let seeds: [UInt64] = [1, 2, 3, 4, 5, 6]
var report: [String: Double] = [:]
var lines: [String] = []

@MainActor func record(_ key: String, _ value: Double, _ label: String, format: String = "%.3f") {
    report[key] = value
    lines.append("| \(label) | " + String(format: format, value) + " |")
}

@MainActor func section(_ title: String) {
    lines.append("")
    lines.append("### \(title)")
    lines.append("")
    lines.append("| metric | value |")
    lines.append("|---|---|")
}

func makeController(seed: UInt64, sneeze: Double = .infinity) -> MotionController {
    MotionController(
        descriptors: StandardParameters.all,
        configuration: MotionController.Configuration(seed: seed, sneezeInterval: sneeze)
    )
}

func simulate(
    _ controller: MotionController,
    seconds: Double,
    frameRate: Double = 60,
    from start: Double = 0,
    inputs: (Double) -> MotionInputs
) -> MotionTrace {
    var trace = MotionTrace(frameRate: frameRate)
    let count = Int((seconds * frameRate).rounded())
    for index in 0..<count {
        let time = start + Double(index) / frameRate
        trace.frames.append(controller.update(at: time, inputs: inputs(time)))
    }
    return trace
}

func eyeOpenness(_ trace: MotionTrace) -> [Float] {
    zip(trace.series(.eyeLeftOpen, default: 1), trace.series(.eyeRightOpen, default: 1)).map { ($0 + $1) / 2 }
}

// MARK: - Conversation phases (host mapping)

enum Phase: String, CaseIterable {
    case idle, listening, thinking, speaking
}

/// What a host can currently tell the engine about the conversation.
func hostInputs(for phase: Phase, time: Double) -> MotionInputs {
    var inputs = MotionInputs()
    MotionEvalHost.apply(phase: phase, time: time, to: &inputs)
    return inputs
}

// MARK: - 1. Idle

section("Idle (no pointer, 120 s × \(seeds.count) seeds)")
do {
    var blinkRates: [Float] = []
    var blinkCVs: [Float] = []
    var blinkDurations: [Float] = []
    var partialRatios: [Float] = []
    var saccadeRates: [Float] = []
    var periodicityX: [Float] = []
    var periodicityZ: [Float] = []
    var headSpeeds: [Float] = []
    for seed in seeds {
        let trace = simulate(makeController(seed: seed), seconds: 120) { _ in MotionInputs() }
        let blinks = MotionMetrics.blinks(openness: eyeOpenness(trace), frameRate: trace.frameRate)
        blinkRates.append(Float(blinks.count) / Float(trace.duration / 60))
        let intervals = zip(blinks.dropFirst(), blinks).map { Float($0.start - $1.start) }
        blinkCVs.append(MotionMetrics.coefficientOfVariation(intervals))
        blinkDurations.append(MotionMetrics.mean(blinks.map { Float($0.duration) }) * 1000)
        partialRatios.append(blinks.isEmpty ? 0 : Float(blinks.filter { $0.depth < 0.8 }.count) / Float(blinks.count))
        let saccades = MotionMetrics.saccades(
            eyeX: trace.series(.eyeBallX), eyeY: trace.series(.eyeBallY), frameRate: trace.frameRate
        )
        saccadeRates.append(Float(saccades.count) / Float(trace.duration))
        periodicityX.append(MotionMetrics.periodicity(trace.series(.angleX), frameRate: trace.frameRate))
        periodicityZ.append(MotionMetrics.periodicity(trace.series(.angleZ), frameRate: trace.frameRate))
        headSpeeds.append(MotionMetrics.meanSpeed(trace.series(.angleX), frameRate: trace.frameRate))
    }
    record("idle.blinkPerMinute", Double(MotionMetrics.mean(blinkRates)), "blinks / min (human rest ≈ 15–20)", format: "%.1f")
    record("idle.blinkIntervalCV", Double(MotionMetrics.mean(blinkCVs)), "inter-blink interval CV (human ≈ 0.6–1.0)")
    record("idle.blinkDurationMs", Double(MotionMetrics.mean(blinkDurations)), "blink duration ms (human ≈ 100–400)", format: "%.0f")
    record("idle.partialBlinkRatio", Double(MotionMetrics.mean(partialRatios)), "partial-blink ratio (human ≈ 0.1–0.4)")
    record("idle.saccadesPerSecond", Double(MotionMetrics.mean(saccadeRates)), "saccades / s without a target")
    record("idle.periodicityAngleX", Double(MotionMetrics.mean(periodicityX)), "head yaw periodicity (lower = less loop-like)")
    record("idle.periodicityAngleZ", Double(MotionMetrics.mean(periodicityZ)), "head roll periodicity")
    record("idle.headYawSpeed", Double(MotionMetrics.mean(headSpeeds)), "head yaw mean speed deg/s")
}

// MARK: - 2. Pointer following

section("Pointer jumps (targets every 1.5–3.5 s, 60 s × \(seeds.count) seeds)")
do {
    var peakVelocities: [Float] = []
    var durations: [Float] = []
    var evokedBlinkRatios: [Float] = []
    var settleErrors: [Float] = []
    var eyeOvershoot: [Float] = []
    for seed in seeds {
        var rng = SeededRandom(seed: seed, stream: "eval.pointer")
        var targets: [(time: Double, point: SIMD2<Float>)] = []
        var time = 1.0
        while time < 60 {
            targets.append((time, SIMD2(rng.float(in: -0.85...0.85), rng.float(in: -0.5...0.6))))
            time += Double(rng.float(in: 1.5...3.5))
        }
        func pointer(at time: Double) -> SIMD2<Float>? {
            guard let current = targets.last(where: { $0.time <= time }) else { return nil }
            // Tiny tremor keeps attention alive, like a real hand on a mouse.
            return current.point + SIMD2(Float(sin(time * 9)) * 0.01, 0)
        }
        let trace = simulate(makeController(seed: seed), seconds: 60) { time in
            MotionInputs(pointer: pointer(at: time))
        }
        let eyeX = trace.series(.eyeBallX)
        let eyeY = trace.series(.eyeBallY)
        let saccades = MotionMetrics.saccades(eyeX: eyeX, eyeY: eyeY, frameRate: trace.frameRate)
        let large = saccades.filter { $0.amplitude > 0.3 }
        peakVelocities.append(MotionMetrics.mean(large.map(\.peakVelocity)))
        durations.append(MotionMetrics.mean(large.map { Float($0.duration) }) * 1000)
        let blinks = MotionMetrics.blinks(openness: eyeOpenness(trace), frameRate: trace.frameRate)
        let evoked = large.filter { saccade in
            blinks.contains { abs($0.start - saccade.start) < 0.2 }
        }
        evokedBlinkRatios.append(large.isEmpty ? 0 : Float(evoked.count) / Float(large.count))
        // Gaze (eye + head contribution) error 1 s after each jump.
        var errors: [Float] = []
        var overshoots: [Float] = []
        for (index, target) in targets.enumerated() {
            let frame = Int((target.time + 1.0) * trace.frameRate)
            guard frame < trace.frames.count else { continue }
            // Acquisition: first frame where the eyes cover 75 % of the jump.
            let jumpFrame = Int(target.time * trace.frameRate)
            let from = SIMD2(eyeX[max(0, jumpFrame - 1)], eyeY[max(0, jumpFrame - 1)])
            let goal = target.point * 0.88
            let distance = simd_distance(from, goal)
            if distance > 0.3,
               let hit = (jumpFrame..<frame).first(where: { simd_distance(SIMD2(eyeX[$0], eyeY[$0]), goal) < 0.25 * distance }) {
                errors.append(Float(hit - jumpFrame) / Float(trace.frameRate) * 1000)
            }
            // Eye-in-head overshoot past its final value within the first 0.6 s.
            let startFrame = Int(target.time * trace.frameRate)
            let endFrame = min(trace.frames.count, startFrame + Int(0.6 * trace.frameRate))
            guard index > 0, endFrame > startFrame + 2 else { continue }
            let previous = eyeX[max(0, startFrame - 1)]
            let direction: Float = eyeX[endFrame - 1] >= previous ? 1 : -1
            let peak = eyeX[startFrame..<endFrame].map { ($0 - previous) * direction }.max() ?? 0
            let final = (eyeX[endFrame - 1] - previous) * direction
            if abs(final) > 0.05 { overshoots.append(peak - final) }
        }
        settleErrors.append(MotionMetrics.mean(errors))
        eyeOvershoot.append(MotionMetrics.mean(overshoots))
    }
    record("pointer.saccadePeakVelocity", Double(MotionMetrics.mean(peakVelocities)), "large-saccade peak velocity (units/s)")
    record("pointer.saccadeDurationMs", Double(MotionMetrics.mean(durations)), "large-saccade duration ms (human ≈ 50–100)", format: "%.0f")
    record("pointer.gazeEvokedBlinkRatio", Double(MotionMetrics.mean(evokedBlinkRatios)), "large saccades with a blink (human ≈ 0.2–0.5)")
    record("pointer.acquisitionMs", Double(MotionMetrics.mean(settleErrors)), "time for the eyes to cover 75 % of a jump (ms)", format: "%.0f")
    record("pointer.eyeLeadOvershoot", Double(MotionMetrics.mean(eyeOvershoot)), "eye-in-head lead then recentre (>0 = eyes lead head)")
}

// MARK: - 3. Conversation phases

for legacy in [true, false] {
    MotionEvalHost.useBehavior = !legacy
    let prefix = legacy ? "phasesLegacyHost" : "phases"
    section("Conversation phases, \(legacy ? "legacy host (energy + isSpeaking only)" : "behavior host") (20 s each × \(seeds.count) seeds)")
    // Pose features compared across phases. Mouth openness is excluded on
    // purpose: speaking trivially differs there; the question is whether the
    // *rest of the body* tells the phases apart.
    let features: [(ParameterID, Float)] = [
        (.angleX, 1), (.angleY, 1), (.angleZ, 1),
        (.eyeBallX, 10), (.eyeBallY, 10), (.mouthForm, 10), (.bodyY, 30),
    ]
    func featureVector(_ frame: [ParameterID: Float]) -> [Float] {
        var vector = features.map { (frame[$0.0] ?? 0) * $0.1 }
        vector.append(((frame[.eyeLeftOpen] ?? 1) + (frame[.eyeRightOpen] ?? 1)) * 5)
        return vector
    }
    var windows: [[Phase: [[Float]]]] = []
    var speakingHeadSpeed: [Float] = []
    var idleHeadSpeed: [Float] = []
    var speakingPitchSpeed: [Float] = []
    var idlePitchSpeed: [Float] = []
    var phaseBlinkRates: [Phase: [Float]] = [:]
    for seed in seeds {
        let controller = makeController(seed: seed)
        var seedWindows: [Phase: [[Float]]] = [:]
        var time = 0.0
        for phase in Phase.allCases {
            let trace = simulate(controller, seconds: 20, from: time) { hostInputs(for: phase, time: $0) }
            // Skip the first 2 s of each phase: transition, not steady state.
            let steady = Array(trace.frames.dropFirst(Int(2 * trace.frameRate)))
            // An observer glancing for 2 s: window means of the pose features
            // plus how much the head pitches (nods) inside the window.
            let windowLength = Int(2 * trace.frameRate)
            for start in stride(from: 0, to: steady.count - windowLength + 1, by: windowLength) {
                let rows = steady[start..<(start + windowLength)].map(featureVector)
                var vector = (0..<rows[0].count).map { d in MotionMetrics.mean(rows.map { $0[d] }) }
                vector.append(MotionMetrics.standardDeviation(steady[start..<(start + windowLength)].map { $0[.angleY] ?? 0 }) * 3)
                seedWindows[phase, default: []].append(vector)
            }
            let blinks = MotionMetrics.blinks(openness: eyeOpenness(trace), frameRate: trace.frameRate)
            phaseBlinkRates[phase, default: []].append(Float(blinks.count) / Float(trace.duration / 60))
            let steadyTrace = MotionTrace(frameRate: trace.frameRate, frames: steady)
            let yaw = MotionMetrics.meanSpeed(steadyTrace.series(.angleX), frameRate: 60)
                + MotionMetrics.meanSpeed(steadyTrace.series(.angleZ), frameRate: 60)
            let pitch = MotionMetrics.meanSpeed(steadyTrace.series(.angleY), frameRate: 60)
            if phase == .speaking { speakingHeadSpeed.append(yaw); speakingPitchSpeed.append(pitch) }
            if phase == .idle { idleHeadSpeed.append(yaw); idlePitchSpeed.append(pitch) }
            time += 20
        }
        windows.append(seedWindows)
    }
    // Leave-one-seed-out nearest-centroid classification of 2 s windows
    // (features z-scored on the training seeds). Chance level is 25 %.
    var correct: [Phase: Int] = [:]
    var total: [Phase: Int] = [:]
    for held in windows.indices {
        let training = windows.indices.filter { $0 != held }
        let allRows = training.flatMap { index in Phase.allCases.flatMap { windows[index][$0] ?? [] } }
        let dimension = allRows[0].count
        let scale = (0..<dimension).map { d in max(1e-3, MotionMetrics.standardDeviation(allRows.map { $0[d] })) }
        var centroids: [Phase: [Float]] = [:]
        for phase in Phase.allCases {
            let rows = training.flatMap { windows[$0][phase] ?? [] }
            centroids[phase] = (0..<dimension).map { d in MotionMetrics.mean(rows.map { $0[d] }) }
        }
        for phase in Phase.allCases {
            for row in windows[held][phase] ?? [] {
                let predicted = Phase.allCases.min { a, b in
                    func distance(_ centroid: [Float]) -> Float {
                        (0..<dimension).reduce(0) { sum, d in
                            let delta = (row[d] - centroid[d]) / scale[d]
                            return sum + delta * delta
                        }
                    }
                    return distance(centroids[a]!) < distance(centroids[b]!)
                }
                total[phase, default: 0] += 1
                if predicted == phase { correct[phase, default: 0] += 1 }
            }
        }
    }
    let accuracy = Double(correct.values.reduce(0, +)) / Double(max(1, total.values.reduce(0, +)))
    record("\(prefix).classificationAccuracy", accuracy, "phase guessed from 2 s of body motion (chance 0.25)")
    for phase in Phase.allCases {
        record("\(prefix).recall.\(phase.rawValue)", Double(correct[phase] ?? 0) / Double(max(1, total[phase] ?? 0)),
               "  recall: \(phase.rawValue)")
    }
    for phase in Phase.allCases {
        record("\(prefix).blinkPerMinute.\(phase.rawValue)", Double(MotionMetrics.mean(phaseBlinkRates[phase] ?? [])),
               "blinks / min while \(phase.rawValue)", format: "%.1f")
    }
    record("\(prefix).speakingVsIdleHeadSpeed",
           Double(MotionMetrics.mean(speakingHeadSpeed) / max(0.001, MotionMetrics.mean(idleHeadSpeed))),
           "head yaw+roll speed, speaking ÷ idle (human talkers > 1.5)")
    record("\(prefix).speakingVsIdlePitchSpeed",
           Double(MotionMetrics.mean(speakingPitchSpeed) / max(0.001, MotionMetrics.mean(idlePitchSpeed))),
           "head pitch speed, speaking ÷ idle")
}

// MARK: - 4. Transitions

section("State transition idle → thinking (× \(seeds.count) seeds)")
do {
    var latencies: [Float] = []
    var overshoots: [Float] = []
    var responded = 0
    for seed in seeds {
        let controller = makeController(seed: seed)
        let reference = makeController(seed: seed)
        // Same seed, one switches to thinking at 5 s; the difference isolates
        // the state response from the shared idle drift.
        let switched = simulate(controller, seconds: 10) { time in
            hostInputs(for: time < 5 ? .idle : .thinking, time: time)
        }
        let baseline = simulate(reference, seconds: 10) { time in hostInputs(for: .idle, time: time) }
        // mouthForm is driven only by the posture layer outside speech, so
        // the difference isolates the hesitant transition itself.
        let delta = zip(switched.series(.mouthForm), baseline.series(.mouthForm)).map { $0 - $1 }
        let after = Array(delta.dropFirst(5 * 60))
        let final = MotionMetrics.mean(Array(after.suffix(60)))
        guard abs(final) > 0.05 else { continue }
        responded += 1
        if let index = after.firstIndex(where: { abs($0) >= abs(final) * 0.5 }) {
            latencies.append(Float(index) / 60 * 1000)
        }
        let peak = after.map { $0 * (final > 0 ? 1 : -1) }.max() ?? 0
        overshoots.append(max(0, peak / abs(final) - 1))
    }
    record("transition.respondingSeeds", Double(responded) / Double(seeds.count), "share of runs where the head pose responds")
    record("transition.halfwayLatencyMs", Double(MotionMetrics.mean(latencies)), "time to 50 % of the new pose (ms)", format: "%.0f")
    record("transition.overshoot", Double(MotionMetrics.mean(overshoots)), "overshoot fraction (awkward settle)")
}

// MARK: - 4b. Listening backchannel

section("Listening backchannel (60 s × \(seeds.count) seeds, synthetic user speech)")
do {
    var nodsPerMinute: [Float] = []
    var timedShare: [Float] = []
    var spontaneous: [Float] = []
    for seed in seeds {
        // User talks in 1.5–3.5 s bursts separated by 0.6–1.5 s pauses.
        var rng = SeededRandom(seed: seed, stream: "eval.listener")
        var pauses: [(start: Double, end: Double)] = []
        var time = 0.5
        while time < 60 {
            time += Double(rng.float(in: 1.5...3.5))
            let pause = Double(rng.float(in: 0.6...1.5))
            pauses.append((time, time + pause))
            time += pause
        }
        func level(at time: Double) -> Float {
            if time < 0.5 { return 0 }
            return pauses.contains { time >= $0.start && time < $0.end } ? 0.02 : 0.5
        }
        let controller = makeController(seed: seed)
        var nodTimes: [Double] = []
        var lastCount = 0
        var frame = 0
        while Double(frame) / 60 < 60 {
            let t = Double(frame) / 60
            _ = controller.update(at: t, inputs: MotionInputs(behavior: .listening, listenerVoiceLevel: level(at: t)))
            if controller.nodCount > lastCount { nodTimes.append(t); lastCount = controller.nodCount }
            frame += 1
        }
        nodsPerMinute.append(Float(nodTimes.count))
        let timed = nodTimes.filter { nod in pauses.contains { nod >= $0.start && nod <= $0.start + 0.9 } }
        timedShare.append(nodTimes.isEmpty ? 0 : Float(timed.count) / Float(nodTimes.count))
        let silentHost = makeController(seed: seed)
        _ = simulate(silentHost, seconds: 60) { _ in MotionInputs(behavior: .listening) }
        spontaneous.append(Float(silentHost.nodCount))
    }
    record("listening.nodsPerMinute", Double(MotionMetrics.mean(nodsPerMinute)), "nods / min with user voice level", format: "%.1f")
    record("listening.nodsInPauses", Double(MotionMetrics.mean(timedShare)), "share of nods within 0.9 s of a user pause")
    record("listening.spontaneousNodsPerMinute", Double(MotionMetrics.mean(spontaneous)), "nods / min without voice level", format: "%.1f")
}

// MARK: - 4c. Micro-actions

section("Micro-actions (10 min unattended × \(seeds.count) seeds)")
do {
    var counts: [MicroActionLayer.Kind: [Float]] = [:]
    var engagedCounts: [MicroActionLayer.Kind: [Float]] = [:]
    for seed in seeds {
        let controller = makeController(seed: seed)
        _ = simulate(controller, seconds: 600) { _ in MotionInputs() }
        for kind in MicroActionLayer.Kind.allCases {
            counts[kind, default: []].append(Float(controller.microActionHistory.filter { $0.kind == kind }.count))
        }
        // Same, but the user wiggles the pointer for 2 s every 20 s.
        let engaged = makeController(seed: seed)
        _ = simulate(engaged, seconds: 600) { time in
            time.truncatingRemainder(dividingBy: 20) < 2 ? MotionInputs(pointer: SIMD2(Float(sin(time * 3)) * 0.5, 0)) : MotionInputs()
        }
        for kind in MicroActionLayer.Kind.allCases {
            engagedCounts[kind, default: []].append(Float(engaged.microActionHistory.filter { $0.kind == kind }.count))
        }
    }
    for kind in MicroActionLayer.Kind.allCases {
        record("micro.\(kind.rawValue).unattended", Double(MotionMetrics.mean(counts[kind] ?? [])),
               "\(kind.rawValue) per 10 min, unattended", format: "%.1f")
        record("micro.\(kind.rawValue).engaged", Double(MotionMetrics.mean(engagedCounts[kind] ?? [])),
               "\(kind.rawValue) per 10 min, user present", format: "%.1f")
    }
}

// MARK: - 4d. Personalities

section("Personality presets (idle → thinking, × \(seeds.count) seeds)")
do {
    for (name, personality) in MotionPersonality.presets {
        var latencies: [Float] = []
        var overshoots: [Float] = []
        var blinkRates: [Float] = []
        var aversion: [Float] = []
        for seed in seeds {
            func controller() -> MotionController {
                MotionController(
                    descriptors: StandardParameters.all,
                    configuration: MotionController.Configuration(seed: seed, sneezeInterval: .infinity, personality: personality, microActionsEnabled: false)
                )
            }
            let switched = simulate(controller(), seconds: 10) { MotionInputs(behavior: $0 < 5 ? .idle : .thinking) }
            let baseline = simulate(controller(), seconds: 10) { _ in MotionInputs() }
            let delta = zip(switched.series(.mouthForm), baseline.series(.mouthForm)).map { $0 - $1 }
            let after = Array(delta.dropFirst(5 * 60))
            let final = MotionMetrics.mean(Array(after.suffix(60)))
            if let index = after.firstIndex(where: { abs($0) >= abs(final) * 0.5 }) {
                latencies.append(Float(index) / 60 * 1000)
            }
            let peak = after.map { $0 * (final > 0 ? 1 : -1) }.max() ?? 0
            overshoots.append(max(0, peak / max(0.01, abs(final)) - 1))
            let watched = simulate(controller(), seconds: 60) { time in
                // Keeps moving fast enough to stay interesting.
                MotionInputs(pointer: SIMD2(0.3 + Float(sin(time * 5)) * 0.25, 0.1))
            }
            blinkRates.append(Float(MotionMetrics.blinks(openness: eyeOpenness(watched), frameRate: 60).count))
            let target = (0..<watched.frames.count).map { Float(0.3 + sin(Double($0) / 60 * 5) * 0.25) * 0.88 * (1 - 0.5 * 0.55) }
            let away = zip(watched.series(.eyeBallX), target).filter { abs($0.0 - $0.1) > 0.3 }.count
            aversion.append(Float(away) / Float(watched.frames.count))
        }
        record("personality.\(name).latencyMs", Double(MotionMetrics.mean(latencies)), "\(name): time to 50 % of thinking pose ms", format: "%.0f")
        record("personality.\(name).overshoot", Double(MotionMetrics.mean(overshoots)), "\(name): settle overshoot")
        record("personality.\(name).blinksPerMinute", Double(MotionMetrics.mean(blinkRates)), "\(name): blinks / min while watching", format: "%.1f")
        record("personality.\(name).gazeAvertedShare", Double(MotionMetrics.mean(aversion)), "\(name): time with gaze averted")
    }
}

// MARK: - 5. Frame-rate invariance

section("Frame-rate invariance (10 s, idle + pointer + speech)")
do {
    func runAt(_ fps: Double) -> MotionTrace {
        simulate(makeController(seed: 9), seconds: 10, frameRate: fps) { time in
            var inputs = MotionInputs(pointer: time >= 3 ? SIMD2(0.6, Float(sin(time)) * 0.3) : nil)
            inputs.isSpeaking = time >= 6
            return inputs
        }
    }
    let low = runAt(30)
    let mid = runAt(60)
    let high = runAt(120)
    var worst: Float = 0
    var worstParameter = ""
    var differences: [Float] = []
    for id in StandardParameters.all.map(\.id) {
        guard let descriptor = StandardParameters.descriptor(for: id) else { continue }
        let range = descriptor.maximum - descriptor.minimum
        // Compare at the shared 30 Hz timestamps.
        for index in 0..<low.frames.count {
            let a = low.frames[index][id] ?? 0
            let b = mid.frames[index * 2][id] ?? 0
            let c = high.frames[index * 4][id] ?? 0
            let difference = max(abs(a - b), abs(b - c)) / range
            differences.append(difference)
            if difference > worst {
                worst = difference
                worstParameter = id.rawValue + String(format: " @ %.2fs", Double(index) / 30)
            }
        }
    }
    differences.sort()
    record("framerate.p99RelativeDifference", Double(differences[Int(Double(differences.count) * 0.99)]),
           "99th-percentile max Δ across 30/60/120 fps (fraction of range)")
    record("framerate.worstRelativeDifference", Double(worst), "worst max Δ across 30/60/120 fps (fraction of range) — \(worstParameter)")
}

// MARK: - 6. Lip sync

func loadMono(_ path: String) -> (samples: [Float], sampleRate: Double)? {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil,
          let channel = buffer.floatChannelData?[0] else { return nil }
    return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
}

func decibels(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return -100 }
    let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
    return 20 * log10(max(sqrt(meanSquare), 1e-5))
}

if !audioPaths.isEmpty {
    section("Lip sync (real speech; \(audioPaths.count) clip(s))")
    struct PathScore { var lag: [Float] = []; var corr: [Float] = []; var closure: [Float] = []; var articulation: [Float] = []; var quietRatio: [Float] = [] }
    var scores: [String: PathScore] = [:]
    for path in audioPaths {
        guard let clip = loadMono(path) else {
            lines.append("| could not read \(path) | – |")
            continue
        }
        let fps = 60.0
        let tail = 1.0
        let frameCount = Int((Double(clip.samples.count) / clip.sampleRate + tail) * fps)
        // Reference: centred 20 ms RMS per frame.
        let half = Int(0.01 * clip.sampleRate)
        let reference: [Float] = (0..<frameCount).map { frame in
            let center = Int(Double(frame) / fps * clip.sampleRate)
            let lower = max(0, center - half)
            let upper = min(clip.samples.count, center + half)
            return lower < upper ? max(-100, decibels(clip.samples[lower..<upper])) : -100
        }
        let peak = reference.sorted()[Int(Double(reference.count) * 0.98)]
        let speech = reference.map { $0 > peak - 24 }
        // Silence = well below speech AND ≥ 120 ms from any speech frame.
        let silence: [Bool] = reference.indices.map { index in
            let lower = max(0, index - 7)
            let upper = min(reference.count - 1, index + 7)
            return reference[index] < peak - 40 && !(lower...upper).contains { speech[$0] }
        }
        let normalizedReference = reference.map { Interpolation.clamp(($0 - (peak - 30)) / 26, 0...1) }

        for gain in [Float(1), Float(0.125)] { // 0 dB and −18 dB
            let samples = clip.samples.map { $0 * gain }
            for (name, mouth) in MotionEvalHost.lipSyncPaths(samples: samples, sampleRate: clip.sampleRate, frameCount: frameCount, fps: fps) {
                var score = scores[name, default: PathScore()]
                if gain == 1 {
                    let best = MotionMetrics.bestLag(reference: normalizedReference, signal: mouth, maximumLag: 20)
                    score.lag.append(Float(best.lag) / Float(fps) * 1000)
                    score.corr.append(best.correlation)
                    let closed = zip(mouth, silence).filter { $0.1 }.map { $0.0 < 0.08 ? Float(1) : 0 }
                    if !closed.isEmpty { score.closure.append(MotionMetrics.mean(closed)) }
                    func normalized(_ values: [Float]) -> [Float] {
                        let top = max(0.05, values.sorted()[Int(Double(values.count) * 0.95)])
                        return values.map { $0 / top }
                    }
                    let mouthCycles = MotionMetrics.cycles(normalized(mouth), low: 0.35, high: 0.65)
                    let referenceCycles = MotionMetrics.cycles(normalized(normalizedReference), low: 0.35, high: 0.65)
                    score.articulation.append(Float(mouthCycles) / Float(max(1, referenceCycles)))
                    score.quietRatio.append(MotionMetrics.mean(mouth, where: speech)) // stash loud mean
                } else if let loudMean = score.quietRatio.popLast() {
                    score.quietRatio.append(MotionMetrics.mean(mouth, where: speech) / max(0.001, loudMean))
                }
                scores[name] = score
            }
        }
    }
    for name in scores.keys.sorted() {
        let score = scores[name]!
        record("lipsync.\(name).lagMs", Double(MotionMetrics.mean(score.lag)), "\(name): mouth lag behind audio ms (− = leads)", format: "%.0f")
        record("lipsync.\(name).correlation", Double(MotionMetrics.mean(score.corr)), "\(name): envelope correlation")
        record("lipsync.\(name).silenceClosure", Double(MotionMetrics.mean(score.closure)), "\(name): mouth closed in pauses")
        record("lipsync.\(name).articulation", Double(MotionMetrics.mean(score.articulation)), "\(name): open/close cycles ÷ audio syllable cycles")
        record("lipsync.\(name).quietSpeechRatio", Double(MotionMetrics.mean(score.quietRatio)), "\(name): mouth at −18 dB ÷ at 0 dB")
    }
}

if !audioPaths.isEmpty {
    section("Speaking with real speech (timeline lip sync, behavior host, × \(seeds.count) seeds)")
    var headSpeedRatio: [Float] = []
    var nods: [Float] = []
    var startAversion: [Float] = []
    var speakingBlinks: [Float] = []
    for path in audioPaths {
        guard let clip = loadMono(path) else { continue }
        let track = LipSyncTimeline.analyze(samples: clip.samples, sampleRate: clip.sampleRate)
        let clipDuration = Double(clip.samples.count) / clip.sampleRate
        for seed in seeds {
            let controller = makeController(seed: seed)
            _ = simulate(controller, seconds: 3) { _ in MotionInputs(behavior: .idle) }
            let idle = simulate(controller, seconds: 6, from: 3) { _ in MotionInputs(behavior: .idle) }
            let before = controller.nodCount
            let speaking = simulate(controller, seconds: clipDuration, from: 9) { time in
                MotionInputs(isSpeaking: true, lipSync: track.frame(at: time - 9), energy: 0.72, behavior: .speaking)
            }
            nods.append(Float(controller.nodCount - before) / Float(clipDuration / 60))
            func speed(_ trace: MotionTrace) -> Float {
                MotionMetrics.meanSpeed(trace.series(.angleX), frameRate: 60)
                    + MotionMetrics.meanSpeed(trace.series(.angleY), frameRate: 60)
                    + MotionMetrics.meanSpeed(trace.series(.angleZ), frameRate: 60)
            }
            headSpeedRatio.append(speed(speaking) / max(0.001, speed(idle)))
            let firstSecond = speaking.series(.eyeBallX).prefix(72)
            startAversion.append(firstSecond.contains { abs($0) > 0.3 } ? 1 : 0)
            speakingBlinks.append(Float(MotionMetrics.blinks(openness: eyeOpenness(speaking), frameRate: 60).count) / Float(clipDuration / 60))
        }
    }
    record("speaking.headSpeedVsIdle", Double(MotionMetrics.mean(headSpeedRatio)), "head speed while talking ÷ idle (human > 1.5)")
    record("speaking.nodsPerMinute", Double(MotionMetrics.mean(nods)), "phrase/settle nods per minute of speech", format: "%.1f")
    record("speaking.startAversionShare", Double(MotionMetrics.mean(startAversion)), "utterances starting with a look-away")
    record("speaking.blinksPerMinute", Double(MotionMetrics.mean(speakingBlinks)), "blinks / min while talking (human ≈ 20–30)", format: "%.1f")
}

print(lines.joined(separator: "\n"))
if let jsonPath {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: jsonPath))
}
