import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import CastorCore

@MainActor
struct CastorCoreTests {
    @Test func petEvasionObstructionUsesAreaRatioOrCenterCoverage() {
        let pet = CGRect(x: 100, y: 100, width: 100, height: 100)

        #expect(PetEvasionGeometry.isObstructed(
            petFrame: pet,
            by: CGRect(x: 100, y: 100, width: 25, height: 100)
        ))
        #expect(PetEvasionGeometry.isObstructed(
            petFrame: pet,
            by: CGRect(x: 149, y: 149, width: 2, height: 2)
        ))
        #expect(!PetEvasionGeometry.isObstructed(
            petFrame: pet,
            by: CGRect(x: 100, y: 100, width: 10, height: 10)
        ))
    }

    @Test func petEvasionChoosesNearestUnoccupiedFrame() throws {
        let pet = CGRect(x: 740, y: 20, width: 240, height: 300)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let blockingWindow = CGRect(x: 500, y: 0, width: 500, height: 800)

        let destination = try #require(PetEvasionGeometry.nearestAvailableFrame(
            for: pet,
            in: screen,
            avoiding: [blockingWindow]
        ))

        #expect(destination.maxX < blockingWindow.minX)
        #expect(screen.insetBy(dx: 12, dy: 12).contains(destination))
    }

    @Test func petEvasionFallsBackWhenNoFreeRectangleExists() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let destination = PetEvasionGeometry.nearestAvailableFrame(
            for: CGRect(x: 500, y: 20, width: 260, height: 340),
            in: screen,
            avoiding: [screen]
        )
        #expect(destination == nil)
        #expect(PetEvasionGeometry.isFullscreen(screen, on: screen))
    }

    @Test func petEvasionRequiresPointerPressureInsteadOfWindowOverlapAlone() {
        let pet = CGRect(x: 700, y: 20, width: 260, height: 340)

        #expect(PetEvasionGeometry.isPointerRequestingSpace(
            around: pet,
            pointer: CGPoint(x: pet.minX - 24, y: pet.midY)
        ))
        #expect(!PetEvasionGeometry.isPointerRequestingSpace(
            around: pet,
            pointer: CGPoint(x: pet.midX, y: pet.midY)
        ))
        #expect(!PetEvasionGeometry.isPointerRequestingSpace(
            around: pet,
            pointer: CGPoint(x: 100, y: 100)
        ))
    }

    @Test func petEvasionDestinationKeepsClearOfTheUsersPointer() throws {
        let pet = CGRect(x: 700, y: 20, width: 260, height: 340)
        let pointer = CGPoint(x: 680, y: pet.midY)
        let destination = try #require(PetEvasionGeometry.nearestAvailableFrame(
            for: pet,
            in: CGRect(x: 0, y: 0, width: 1200, height: 800),
            avoiding: [],
            avoidingPoint: pointer
        ))

        #expect(!destination.contains(pointer))
        #expect(destination.origin != pet.origin)
    }

    @Test func petEvasionBetaDefaultsOff() {
        #expect(PetEvasionSettingsStore.defaultEnabled == false)
    }

    @Test func petEvasionStateMachineWaitsThenMovesAndReturnsAfterHysteresis() {
        let start = Date(timeIntervalSince1970: 1_000)
        let destination = CGRect(x: 20, y: 20, width: 260, height: 340)
        let profile = EvasionProfiles.profile(for: .calm)
        let policy = PetEvasionPolicy(returnDelay: 8, cooldown: 15)
        var machine = PetEvasionStateMachine()

        let anticipating = machine.update(
            obstructed: true,
            destination: destination,
            focusedWindowIsFullscreen: false,
            manualPlacementProtected: false,
            profile: profile,
            policy: policy,
            now: start
        )
        #expect(anticipating == .none)
        #expect(machine.phase == .anticipating)

        let moving = machine.update(
            obstructed: true,
            destination: destination,
            focusedWindowIsFullscreen: false,
            manualPlacementProtected: false,
            profile: profile,
            policy: policy,
            now: start.addingTimeInterval(0.21)
        )
        #expect(moving == .move(to: destination))
        machine.movementCompleted(at: start.addingTimeInterval(0.75))
        #expect(machine.phase == .displaced)

        #expect(machine.update(
            obstructed: false,
            homeObstructed: true,
            destination: nil,
            focusedWindowIsFullscreen: false,
            manualPlacementProtected: false,
            profile: profile,
            policy: policy,
            now: start.addingTimeInterval(1)
        ) == .none)
        #expect(machine.phase == .displaced)

        #expect(machine.update(
            obstructed: false,
            destination: nil,
            focusedWindowIsFullscreen: false,
            manualPlacementProtected: false,
            profile: profile,
            policy: policy,
            now: start.addingTimeInterval(16)
        ) == .none)
        #expect(machine.update(
            obstructed: false,
            destination: nil,
            focusedWindowIsFullscreen: false,
            manualPlacementProtected: false,
            profile: profile,
            policy: policy,
            now: start.addingTimeInterval(23.9)
        ) == .none)
        #expect(machine.update(
            obstructed: false,
            destination: nil,
            focusedWindowIsFullscreen: false,
            manualPlacementProtected: false,
            profile: profile,
            policy: policy,
            now: start.addingTimeInterval(24)
        ) == .returnHome)
    }

    @Test func petEvasionManualPlacementAndFullscreenUseSafeFallbacks() {
        let now = Date(timeIntervalSince1970: 2_000)
        let destination = CGRect(x: 10, y: 10, width: 100, height: 100)
        let profile = EvasionProfiles.profile(for: .cute)
        let policy = PetEvasionPolicy()
        var machine = PetEvasionStateMachine()

        #expect(machine.update(
            obstructed: true,
            destination: destination,
            focusedWindowIsFullscreen: false,
            manualPlacementProtected: true,
            profile: profile,
            policy: policy,
            now: now
        ) == .ghost)
        #expect(machine.phase == .settled)

        #expect(machine.update(
            obstructed: true,
            destination: nil,
            focusedWindowIsFullscreen: true,
            manualPlacementProtected: false,
            profile: profile,
            policy: policy,
            now: now
        ) == .hide)
    }

    @Test func cherryConnectionDelaysMotionAfterStateChange() async throws {
        let core = HesitateCore()
        core.request(.surprised)

        let connection = CherryConnection()
        let immediate = connection.parameters(from: core.snapshot, at: core.snapshot.requestedAt)
        let settled = connection.parameters(from: core.snapshot, at: core.snapshot.requestedAt.addingTimeInterval(1.0))

        #expect(immediate.mouthOpen < settled.mouthOpen)
        #expect(settled.state == .surprised)
    }

    @Test func cherryConnectionCrossFadesPoseFromPreviousStateImmediatelyAfterTransition() async throws {
        // idle's baseline pose (headTilt -2, eyeScale 1, browLift 0, mouthSlant 0.04) should still
        // be showing right at `requestedAt`, before the hesitant delay has had any chance to ease
        // toward thinking's pose (headTilt 8, eyeScale 0.88, browLift -4, mouthSlant -0.12).
        let core = HesitateCore()
        #expect(core.snapshot.state == .idle)
        core.request(.thinking)

        let connection = CherryConnection()
        let immediate = connection.parameters(from: core.snapshot, at: core.snapshot.requestedAt)

        #expect(abs(immediate.headTilt - (-2)) < 0.01)
        #expect(abs(immediate.eyeScale - 1) < 0.01)
        #expect(abs(immediate.browLift - 0) < 0.01)
        #expect(abs(immediate.mouthSlant - 0.04) < 0.01)
    }

    @Test func cherryConnectionSettlesPoseIntoNewStateAfterTransitionCompletes() async throws {
        let core = HesitateCore()
        core.request(.thinking)

        let connection = CherryConnection()
        let settled = connection.parameters(
            from: core.snapshot,
            at: core.snapshot.requestedAt.addingTimeInterval(2.0)
        )

        #expect(abs(settled.headTilt - 8) < 0.05)
        #expect(abs(settled.eyeScale - 0.88) < 0.05)
        #expect(abs(settled.browLift - (-4)) < 0.05)
        #expect(abs(settled.mouthSlant - (-0.12)) < 0.05)
    }

    @Test func cherryConnectionRequestingSameStateDoesNotRetriggerTransition() async throws {
        let core = HesitateCore()
        core.request(.thinking)
        let firstRequestedAt = core.snapshot.requestedAt
        let firstPreviousState = core.snapshot.previousState

        // Requesting the already-current state again must not reset `previousState`/`requestedAt`
        // — otherwise a settled pose would jump back into a fresh cross-fade for no reason.
        core.request(.thinking)

        #expect(core.snapshot.requestedAt == firstRequestedAt)
        #expect(core.snapshot.previousState == firstPreviousState)
    }

    @Test func cherryConnectionAmbientBodyLiftStaysContinuousAcrossStateTransition() async throws {
        // Breathing (bodyLift) must be a pure function of time, unaffected by the hesitant lag.
        // Under the old behavior (`bodyLift = breathing * lag`), `lag` is exactly 0 at
        // `requestedAt`, so bodyLift would be pinned to 0 right at the instant of every state
        // change, no matter what point in the breathing cycle time was at. Holding `awkwardness`
        // fixed (so only the transition itself varies) and sampling exactly at `requestedAt`
        // across many phases of the breathing cycle catches that regression: bodyLift must track
        // the same continuous sine wave whether or not a transition just started.
        let connection = CherryConnection()
        let awkwardness = 0.5

        for offsetSeconds in stride(from: 0.0, through: 20.0, by: 1.3) {
            let requestedAt = Date(timeIntervalSinceReferenceDate: 1_000 + offsetSeconds)

            let steadySnapshot = HesitateSnapshot(
                state: .idle,
                previousState: .idle,
                confidence: 0.58,
                awkwardness: awkwardness,
                speechEnergy: 0.10,
                requestedAt: requestedAt.addingTimeInterval(-30)
            )
            let justTransitionedSnapshot = HesitateSnapshot(
                state: .surprised,
                previousState: .idle,
                confidence: 0.18,
                awkwardness: awkwardness,
                speechEnergy: 0.68,
                requestedAt: requestedAt
            )

            let steady = connection.parameters(from: steadySnapshot, at: requestedAt)
            let justTransitioned = connection.parameters(from: justTransitionedSnapshot, at: requestedAt)

            #expect(abs(justTransitioned.bodyLift - steady.bodyLift) < 0.01)
        }
    }

    @Test func cherryConnectionBlinkAmountIsDeterministicForTheSameSnapshotAndTime() async throws {
        let core = HesitateCore()
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(12.345)

        let first = connection.parameters(from: core.snapshot, at: date)
        let second = connection.parameters(from: core.snapshot, at: date)

        #expect(first.eyeOpen == second.eyeOpen)
    }

    @Test func cherryConnectionBlinksRoughlyEveryTwoToSixSeconds() async throws {
        // Sample eyeOpen densely over two minutes and count how many times it dips into a
        // "blinking" region (a proxy for a blink event peak). With an average interval of
        // 3.2 - awkwardness*0.8 seconds (plus an occasional low-probability double-blink), the
        // number of blink events across 120 seconds should land in a broad, non-brittle band
        // around the expected count rather than being wildly sparse or dense.
        let core = HesitateCore()
        let connection = CherryConnection()
        let start = core.snapshot.requestedAt.addingTimeInterval(10) // clear of the startup transition blink
        let duration = 120.0
        let step = 0.01

        var blinkEventCount = 0
        var wasBlinking = false
        var sampleTime = 0.0
        while sampleTime < duration {
            let parameters = connection.parameters(
                from: core.snapshot,
                at: start.addingTimeInterval(sampleTime)
            )
            let isBlinking = parameters.eyeOpen < 0.5
            if isBlinking && !wasBlinking {
                blinkEventCount += 1
            }
            wasBlinking = isBlinking
            sampleTime += step
        }

        let averageInterval = 3.2 - core.snapshot.awkwardness * 0.8
        let expectedCount = duration / averageInterval
        // Allow generous slack for jitter and the occasional double-blink inflating the count.
        #expect(Double(blinkEventCount) > expectedCount * 0.5)
        #expect(Double(blinkEventCount) < expectedCount * 1.8)
    }

    @Test func cherryConnectionEyeOpenReachesNearFullClosureAtBlinkPeaks() async throws {
        // The blink waveform should still be able to fully close the eye (eyeOpen close to the
        // 0.05 floor) at its peak, confirming the gaussian blink shape survived unification.
        let core = HesitateCore()
        let connection = CherryConnection()
        let start = core.snapshot.requestedAt.addingTimeInterval(10)

        var minimumEyeOpen = Double.greatestFiniteMagnitude
        var sampleTime = 0.0
        while sampleTime < 30 {
            let parameters = connection.parameters(
                from: core.snapshot,
                at: start.addingTimeInterval(sampleTime)
            )
            minimumEyeOpen = min(minimumEyeOpen, parameters.eyeOpen)
            sampleTime += 0.005
        }

        #expect(minimumEyeOpen < 0.15)
    }

    @Test func cherryConnectionAllFalseContextReproducesOldPetFloatingViewUntouchedOverlay() async throws {
        // The old `petParameters(at:touched:)` always applied its ambient overlay terms
        // (`sin(t*1.45)*2.6` on bodyLift, `sin(t*0.72)*2.8` on headTilt, etc.) regardless of
        // `touched`/`isSpeaking`/`isListening` — those flags only switched which *variant* of the
        // overlay played. So an all-false `MotionContext` must still show the overlay applied
        // (i.e. differ from the context-free path), matching the old pet-only behavior exactly.
        let core = HesitateCore()
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(3.7)
        let t = date.timeIntervalSinceReferenceDate

        let contextFree = connection.parameters(from: core.snapshot, trilobite: .inactive, at: date)
        let allFalseContext = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: MotionContext(touched: false, isSpeaking: false, isListening: false),
            at: date
        )
        let viaPreviewContext = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: .preview,
            at: date
        )

        let expectedBodyLift = contextFree.bodyLift + sin(t * 1.45) * 2.6
        let expectedHeadTilt = contextFree.headTilt + sin(t * 0.72) * 2.8

        #expect(abs(allFalseContext.bodyLift - expectedBodyLift) < 0.0001)
        #expect(abs(allFalseContext.headTilt - expectedHeadTilt) < 0.0001)
        #expect(allFalseContext.bodyLift == viaPreviewContext.bodyLift)
        #expect(allFalseContext.headTilt == viaPreviewContext.headTilt)
    }

    @Test func cherryConnectionSpeakingContextOverridesMouthOpen() async throws {
        // While `isSpeaking` with no `speechEnergy` supplied (the phase-E fallback path — no live
        // audio signal available yet), mouthOpen should follow the legacy
        // `0.18 + abs(sin(t*8.4))*0.48` sine flap, matching the original ported mouth-chatter
        // override from the old speaking overlay.
        let core = HesitateCore()
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(8.25)
        let t = date.timeIntervalSinceReferenceDate

        let parameters = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: MotionContext(isSpeaking: true),
            at: date
        )

        let expectedFloor = 0.18 + abs(sin(t * 8.4)) * 0.48
        #expect(parameters.mouthOpen >= expectedFloor - 0.0001)
    }

    @Test func cherryConnectionUsesEnergyMappingWhenSpeechEnergyIsSupplied() async throws {
        // Once a live `speechEnergy` value is available, mouthOpen must follow
        // `SpeechEnergyMouthMapping.mouthOpen(forEnergy:)` rather than the legacy sine flap.
        let core = HesitateCore()
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(8.25)

        let lowEnergy = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: MotionContext(isSpeaking: true, speechEnergy: 0.05),
            at: date
        )
        let highEnergy = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: MotionContext(isSpeaking: true, speechEnergy: 0.95),
            at: date
        )

        let expectedLow = SpeechEnergyMouthMapping.mouthOpen(forEnergy: 0.05)
        let expectedHigh = SpeechEnergyMouthMapping.mouthOpen(forEnergy: 0.95)

        #expect(abs(lowEnergy.mouthOpen - expectedLow) < 0.0001)
        #expect(abs(highEnergy.mouthOpen - expectedHigh) < 0.0001)
        #expect(highEnergy.mouthOpen > lowEnergy.mouthOpen)
    }

    @Test func speechEnergyMouthMappingIsMonotonicAndClosesNearZeroEnergy() {
        // The energy->mouthOpen curve must be monotonic in energy, and stay close to its
        // near-closed floor at zero energy (never fully snapping shut to 0, matching other resting
        // mouthOpen baselines elsewhere in CherryConnection).
        var previous = SpeechEnergyMouthMapping.mouthOpen(forEnergy: 0)
        #expect(abs(previous - SpeechEnergyMouthMapping.closedFloor) < 0.0001)

        for energyTenth in 1...10 {
            let energy = Double(energyTenth) / 10.0
            let value = SpeechEnergyMouthMapping.mouthOpen(forEnergy: energy)
            #expect(value >= previous)
            #expect(value <= SpeechEnergyMouthMapping.openCeiling + 0.0001)
            previous = value
        }
    }

    @Test func speechEnergyMouthMappingClampsOutOfRangeEnergy() {
        #expect(SpeechEnergyMouthMapping.mouthOpen(forEnergy: -5) == SpeechEnergyMouthMapping.closedFloor)
        #expect(abs(SpeechEnergyMouthMapping.mouthOpen(forEnergy: 5) - SpeechEnergyMouthMapping.openCeiling) < 0.0001)
    }

    @Test func speechEnergyEnvelopeAttacksFasterThanItReleases() {
        // Stepping toward a higher target should move further in one step than stepping the same
        // distance toward a lower target, given the same elapsed time — i.e. attack is snappier
        // than release, so the mouth opens quickly but eases closed instead of snapping shut.
        let deltaTime = 0.05

        var risingEnvelope = SpeechEnergyEnvelope()
        risingEnvelope = risingEnvelope.stepping(toward: 1.0, deltaTime: deltaTime)

        var fallingEnvelope = SpeechEnergyEnvelope(value: 1.0)
        fallingEnvelope = fallingEnvelope.stepping(toward: 0.0, deltaTime: deltaTime)

        let attackDistance = risingEnvelope.value
        let releaseDistance = 1.0 - fallingEnvelope.value

        #expect(attackDistance > releaseDistance)
    }

    @Test func speechEnergyEnvelopeConvergesToTargetOverTime() {
        var envelope = SpeechEnergyEnvelope()
        for _ in 0..<200 {
            envelope = envelope.stepping(toward: 0.7, deltaTime: 1.0 / 30.0)
        }
        #expect(abs(envelope.value - 0.7) < 0.01)

        for _ in 0..<200 {
            envelope = envelope.stepping(toward: 0.1, deltaTime: 1.0 / 30.0)
        }
        #expect(abs(envelope.value - 0.1) < 0.01)
    }

    @Test func speechEnergyEnvelopeNormalizedLevelMapsDecibelsMonotonically() {
        let silent = SpeechEnergyEnvelope.normalizedLevel(fromDecibels: -80, silenceFloor: -50)
        let mid = SpeechEnergyEnvelope.normalizedLevel(fromDecibels: -25, silenceFloor: -50)
        let loud = SpeechEnergyEnvelope.normalizedLevel(fromDecibels: 0, silenceFloor: -50)

        #expect(silent == 0)
        #expect(mid > 0 && mid < 1)
        #expect(abs(loud - 1) < 0.0001)
    }

    @Test func cherryConnectionListeningMouthStaysQuietRegardlessOfMicLevel() async throws {
        // Listening must not carry mouth chatter tied to the *user's* mic level — the pet is
        // listening, not talking. mouthOpen while listening should sit at the flat resting value
        // (0.12) regardless of `trilobite.audioLevel`, unlike the old behavior where chatter scaled
        // with the listening resting energy (0.72) and (via `currentInputEnergy`) the live mic
        // level too.
        let connection = CherryConnection()
        let snapshot = HesitateSnapshot(
            state: .listening,
            previousState: .listening,
            confidence: 0.5,
            awkwardness: 0.3,
            speechEnergy: 0.72,
            requestedAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        var quietTrilobite = TrilobiteInputSnapshot.inactive
        quietTrilobite.audioLevel = 0
        var loudTrilobite = TrilobiteInputSnapshot.inactive
        loudTrilobite.audioLevel = 1.0

        var sampleTime = 50.0
        while sampleTime < 60.0 {
            let date = Date(timeIntervalSinceReferenceDate: sampleTime)
            let quiet = connection.parameters(from: snapshot, trilobite: quietTrilobite, at: date)
            let loud = connection.parameters(from: snapshot, trilobite: loudTrilobite, at: date)

            #expect(abs(quiet.mouthOpen - 0.12) < 0.0001)
            #expect(abs(loud.mouthOpen - 0.12) < 0.0001)
            sampleTime += 0.3
        }
    }

    @Test func cherryConnectionListeningNodsMoreWithHigherMicLevel() async throws {
        // In place of mouth chatter, listening should show a small extra head-bob "nod" that
        // amplifies with the mic level, capped modestly (per spec, up to roughly +2 on headBob).
        let connection = CherryConnection()
        let snapshot = HesitateSnapshot(
            state: .listening,
            previousState: .listening,
            confidence: 0.5,
            awkwardness: 0.3,
            speechEnergy: 0.72,
            requestedAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        func headBobRange(audioLevel: Double) -> ClosedRange<Double> {
            var trilobite = TrilobiteInputSnapshot.inactive
            trilobite.audioLevel = audioLevel
            var minBob = Double.greatestFiniteMagnitude
            var maxBob = -Double.greatestFiniteMagnitude
            var sampleTime = 50.0
            while sampleTime < 60.0 {
                let parameters = connection.parameters(
                    from: snapshot,
                    trilobite: trilobite,
                    at: Date(timeIntervalSinceReferenceDate: sampleTime)
                )
                minBob = min(minBob, parameters.headBob)
                maxBob = max(maxBob, parameters.headBob)
                sampleTime += 0.05
            }
            return minBob...maxBob
        }

        let quietRange = headBobRange(audioLevel: 0)
        let loudRange = headBobRange(audioLevel: 1.0)

        let quietSpan = quietRange.upperBound - quietRange.lowerBound
        let loudSpan = loudRange.upperBound - loudRange.lowerBound

        #expect(loudSpan > quietSpan)
        // Amplitude stays modest: the extra nod term is capped at 2.0 in amplitude, so the total
        // span shouldn't blow up disproportionately versus the quiet baseline.
        #expect(loudSpan - quietSpan < 4.5)
    }

    @Test func cherryConnectionPropagatesIsSpeakingFromContextOnly() async throws {
        // `MotionParameters.isSpeaking` must reflect `MotionContext.isSpeaking` exactly (not be
        // derived from mouthOpen's magnitude), and every context-free overload must default it to
        // false so renderers never infer speech from ambient mouth chatter alone.
        let core = HesitateCore()
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(5.0)

        let contextFree = connection.parameters(from: core.snapshot, at: date)
        #expect(contextFree.isSpeaking == false)

        let notSpeaking = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: MotionContext(isSpeaking: false),
            at: date
        )
        #expect(notSpeaking.isSpeaking == false)

        let speaking = connection.parameters(
            from: core.snapshot,
            trilobite: .inactive,
            context: MotionContext(isSpeaking: true),
            at: date
        )
        #expect(speaking.isSpeaking == true)
    }

    @Test func cherryConnectionGazeIsDeterministicForSameSnapshotAndTime() async throws {
        let core = HesitateCore()
        let connection = CherryConnection()
        let date = core.snapshot.requestedAt.addingTimeInterval(42.5)

        let first = connection.parameters(from: core.snapshot, at: date)
        let second = connection.parameters(from: core.snapshot, at: date)

        #expect(first.gazeX == second.gazeX)
        #expect(first.gazeY == second.gazeY)
    }

    @Test func cherryConnectionGazeMostlyHoldsStillDuringFixations() async throws {
        // Sample gaze densely over a long idle window and measure frame-to-frame movement. Most
        // samples should show only small jitter (fixation), with movement above the jitter band
        // only during the brief saccade windows — i.e. "mostly still" should dominate.
        let core = HesitateCore()
        let connection = CherryConnection()
        let start = core.snapshot.requestedAt.addingTimeInterval(20) // clear of transition blend
        let duration = 60.0
        let step = 0.02

        var previous: (x: Double, y: Double)?
        var stillSampleCount = 0
        var totalSampleCount = 0
        var sampleTime = 0.0
        while sampleTime < duration {
            let parameters = connection.parameters(from: core.snapshot, at: start.addingTimeInterval(sampleTime))
            if let previous {
                let movement = abs(parameters.gazeX - previous.x) + abs(parameters.gazeY - previous.y)
                totalSampleCount += 1
                if movement < 0.6 {
                    stillSampleCount += 1
                }
            }
            previous = (parameters.gazeX, parameters.gazeY)
            sampleTime += step
        }

        let stillFraction = Double(stillSampleCount) / Double(totalSampleCount)
        #expect(stillFraction > 0.7)
    }

    @Test func cherryConnectionGazeSaccadesCompleteQuickly() async throws {
        // During a saccade, the gaze should traverse from one fixation point to the next within a
        // short window (<= ~0.2s), rather than smoothly drifting over seconds like the old
        // continuous sine-wave gaze.
        let core = HesitateCore()
        let connection = CherryConnection()
        let start = core.snapshot.requestedAt.addingTimeInterval(20)
        let duration = 40.0
        let step = 0.01

        var previous: (time: Double, x: Double, y: Double)?
        var maxSaccadeSpanForLargeJump = 0.0
        var sampleTime = 0.0
        var largeJumpStartTime: Double?
        while sampleTime < duration {
            let parameters = connection.parameters(from: core.snapshot, at: start.addingTimeInterval(sampleTime))
            if let previous {
                let movement = abs(parameters.gazeX - previous.x) + abs(parameters.gazeY - previous.y)
                if movement > 1.0 {
                    if largeJumpStartTime == nil {
                        largeJumpStartTime = previous.time
                    }
                } else if let jumpStart = largeJumpStartTime {
                    maxSaccadeSpanForLargeJump = max(maxSaccadeSpanForLargeJump, previous.time - jumpStart)
                    largeJumpStartTime = nil
                }
            }
            previous = (sampleTime, parameters.gazeX, parameters.gazeY)
            sampleTime += step
        }

        // Idle's saccade duration is 0.16s; allow slack for sampling granularity and jitter.
        #expect(maxSaccadeSpanForLargeJump < 0.35)
    }

    @Test func cherryConnectionGazeStateRangesStayWithinSpecifiedBounds() async throws {
        // Long-run sample of each state's gaze and confirm min/max stay within the specified
        // fixation ranges (plus jitter/saccade overshoot slack).
        func sampleRange(state: MotionState, duration: Double, audioLevel: Double = 0) -> (xRange: ClosedRange<Double>, yRange: ClosedRange<Double>) {
            let connection = CherryConnection()
            let snapshot = HesitateSnapshot(
                state: state,
                previousState: state,
                confidence: 0.5,
                awkwardness: 0.5,
                speechEnergy: 0.3,
                requestedAt: Date(timeIntervalSinceReferenceDate: 0)
            )
            var trilobite = TrilobiteInputSnapshot.inactive
            trilobite.audioLevel = audioLevel

            var minX = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var minY = Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude
            var sampleTime = 100.0 // clear of the requestedAt transition
            while sampleTime < 100.0 + duration {
                let parameters = connection.parameters(
                    from: snapshot,
                    trilobite: trilobite,
                    at: Date(timeIntervalSinceReferenceDate: sampleTime)
                )
                minX = min(minX, parameters.gazeX)
                maxX = max(maxX, parameters.gazeX)
                minY = min(minY, parameters.gazeY)
                maxY = max(maxY, parameters.gazeY)
                sampleTime += 0.02
            }
            return (minX...maxX, minY...maxY)
        }

        let idle = sampleRange(state: .idle, duration: 120)
        #expect(idle.xRange.lowerBound > -10)
        #expect(idle.xRange.upperBound < 10)
        #expect(idle.yRange.lowerBound > -5)
        #expect(idle.yRange.upperBound < 5)

        let thinking = sampleRange(state: .thinking, duration: 120)
        #expect(thinking.xRange.lowerBound > -16)
        #expect(thinking.xRange.upperBound < -4)
        #expect(thinking.yRange.lowerBound > 1)
        #expect(thinking.yRange.upperBound < 9)

        let listening = sampleRange(state: .listening, duration: 60)
        #expect(listening.xRange.lowerBound > -6)
        #expect(listening.xRange.upperBound < 6)
        #expect(listening.yRange.lowerBound > -4)
        #expect(listening.yRange.upperBound < 4)

        let listeningLoud = sampleRange(state: .listening, duration: 60, audioLevel: 1.0)
        #expect(listeningLoud.xRange.upperBound - listeningLoud.xRange.lowerBound
            >= listening.xRange.upperBound - listening.xRange.lowerBound - 0.5)

        let surprised = sampleRange(state: .surprised, duration: 20)
        #expect(surprised.xRange.lowerBound > -4)
        #expect(surprised.xRange.upperBound < 4)
        #expect(surprised.yRange.lowerBound > -4)
        #expect(surprised.yRange.upperBound < 4)
    }

    @Test func cherryConnectionTouchedGazeBiasesUpward() async throws {
        // Touched context biases idle's gaze fixation center upward (yCenter around -2) versus
        // the untouched idle center (0).
        let connection = CherryConnection()
        let snapshot = HesitateSnapshot(
            state: .idle,
            previousState: .idle,
            confidence: 0.5,
            awkwardness: 0.3,
            speechEnergy: 0.1,
            requestedAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        var touchedYSum = 0.0
        var untouchedYSum = 0.0
        var sampleCount = 0.0
        var sampleTime = 50.0
        while sampleTime < 130.0 {
            let touched = connection.parameters(
                from: snapshot,
                trilobite: .inactive,
                context: MotionContext(touched: true),
                at: Date(timeIntervalSinceReferenceDate: sampleTime)
            )
            let untouched = connection.parameters(
                from: snapshot,
                trilobite: .inactive,
                context: .preview,
                at: Date(timeIntervalSinceReferenceDate: sampleTime)
            )
            touchedYSum += touched.gazeY
            untouchedYSum += untouched.gazeY
            sampleCount += 1
            sampleTime += 0.5
        }

        #expect(touchedYSum / sampleCount < untouchedYSum / sampleCount)
    }

    @Test func cherryConnectionGazeDoesNotJumpAtStateTransitionMoment() async throws {
        // At the exact moment a transition is requested (`lag == 0`), gaze must equal the
        // previous state's gaze model value, not jump straight to the new state's — otherwise the
        // pet's eyes would visibly snap the instant a new state is requested.
        let core = HesitateCore()
        #expect(core.snapshot.state == .idle)

        // Let idle settle for a while so we're mid-fixation/saccade cycle, not at t=0.
        let requestTime = core.snapshot.requestedAt.addingTimeInterval(37.0)

        let connection = CherryConnection()
        let idleOnlySnapshot = HesitateSnapshot(
            state: .idle,
            previousState: .idle,
            confidence: core.snapshot.confidence,
            awkwardness: core.snapshot.awkwardness,
            speechEnergy: core.snapshot.speechEnergy,
            requestedAt: core.snapshot.requestedAt
        )
        let transitionSnapshot = HesitateSnapshot(
            state: .thinking,
            previousState: .idle,
            confidence: 0.36,
            awkwardness: 0.72,
            speechEnergy: 0.34,
            requestedAt: requestTime
        )

        let idleGaze = connection.parameters(from: idleOnlySnapshot, at: requestTime)
        let justTransitioned = connection.parameters(from: transitionSnapshot, at: requestTime)

        #expect(abs(justTransitioned.gazeX - idleGaze.gazeX) < 0.01)
        #expect(abs(justTransitioned.gazeY - idleGaze.gazeY) < 0.01)
    }

    @Test func manualAndAutomaticBrainRoutingStayExplicit() {
        let manual = CastorAgentPreferences(
            routingPolicy: .manual,
            selectedBrain: .codex,
            automaticExternalBrain: .codex,
            codexServerURL: "ws://127.0.0.1:4500",
            claudeCodeBridgeURL: "http://127.0.0.1:4510",
            workspacePath: "/tmp/project"
        )
        #expect(manual.resolvedBrain(for: "こんにちは") == .codex)

        var automatic = manual
        automatic.routingPolicy = .automatic
        #expect(automatic.resolvedBrain(for: "今日はどうだった？") == .onDevice)
        #expect(automatic.resolvedBrain(for: "What is the latest news?") == .onDevice)
        #expect(automatic.resolvedBrain(for: "Tell me the contest result") == .onDevice)
        #expect(automatic.resolvedBrain(for: "このファイルのバグを修正して") == .codex)
        #expect(automatic.resolvedBrain(for: "Run the tests and fix the build") == .codex)

        automatic.automaticExternalBrain = .claudeCode
        #expect(automatic.resolvedBrain(for: "Implement this feature") == .claudeCode)
    }

    @Test func claudeCodeIsImplementedWhileAntigravityFallsBackOnDevice() {
        let preferences = CastorAgentPreferences(
            routingPolicy: .manual,
            selectedBrain: .claudeCode,
            automaticExternalBrain: .antigravity,
            codexServerURL: "ws://127.0.0.1:4500",
            claudeCodeBridgeURL: "http://127.0.0.1:4510",
            workspacePath: ""
        )

        #expect(preferences.resolvedBrain(for: "anything") == .claudeCode)

        var antigravity = preferences
        antigravity.selectedBrain = .antigravity
        #expect(antigravity.resolvedBrain(for: "anything") == .onDevice)
    }

    @Test func importedPersonalityIsTrimmedAndBounded() {
        let original = PetPersonalityStore.customPersonality
        defer { PetPersonalityStore.customPersonality = original }

        PetPersonalityStore.customPersonality = "   \(String(repeating: "a", count: 900))   "

        #expect(PetPersonalityStore.customPersonality.count == 800)
        #expect(!PetPersonalityStore.customPersonality.hasPrefix(" "))
    }

    @Test func codexJSONValueRoundTripsMixedPayloads() throws {
        let value = CodexJSONValue.object([
            "method": .string("turn/start"),
            "id": .number(3),
            "params": .object([
                "enabled": .bool(true),
                "input": .array([.string("hello"), .null])
            ])
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(CodexJSONValue.self, from: data)

        #expect(decoded == value)
    }

    @Test func codexAppServerOnlyAllowsLoopbackConnections() {
        #expect(CodexAppServerSession.isAllowedServerURL("ws://127.0.0.1:4500"))
        #expect(CodexAppServerSession.isAllowedServerURL("wss://localhost:4500"))
        #expect(CodexAppServerSession.isAllowedServerURL("ws://[::1]:4500"))
        #expect(!CodexAppServerSession.isAllowedServerURL("https://127.0.0.1:4500"))
        #expect(!CodexAppServerSession.isAllowedServerURL("ws://example.com:4500"))
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func claudeCodeBridgeThatIsNotRunningGetsPlainGuidance() async throws {
        // A loopback port nothing listens on: the bridge is not running.
        let session = ClaudeCodeBridgeSession()
        await #expect(throws: ClaudeCodeBridgeError.bridgeNotRunning) {
            _ = try await session.send(
                prompt: "hello", bridgeURL: "http://127.0.0.1:9", workspacePath: "", personalityInstruction: "",
                onDelta: { _ in }, onStatus: { _ in }, onApproval: { _ in })
        }
        let message = ClaudeCodeBridgeError.bridgeNotRunning.errorDescription ?? ""
        #expect(message.contains("Claude Code"))
        #expect(message.contains("bridge"))
        #expect(!ClaudeCodeBridgeError.isNotRunning(URLError(.timedOut)))
        #expect(ClaudeCodeBridgeError.isNotRunning(URLError(.cannotConnectToHost)))
    }

    @Test func claudeCodeBridgeOnlyAllowsLoopbackConnections() {
        #expect(ClaudeCodeBridgeSession.isAllowedBridgeURL("http://127.0.0.1:4510"))
        #expect(ClaudeCodeBridgeSession.isAllowedBridgeURL("https://localhost:4510"))
        #expect(ClaudeCodeBridgeSession.isAllowedBridgeURL("http://[::1]:4510"))
        #expect(!ClaudeCodeBridgeSession.isAllowedBridgeURL("ws://127.0.0.1:4510"))
        #expect(!ClaudeCodeBridgeSession.isAllowedBridgeURL("http://example.com:4510"))
        #expect(!ClaudeCodeBridgeSession.isAllowedBridgeURL("http://127.0.0.1:4510/remote"))
    }

    @Test func claudeCodeApprovalDetailShowsToolAndExactInput() {
        let detail = ClaudeCodeBridgeSession.approvalDetail(
            toolName: "Bash",
            input: .object([
                "command": .string("swift test"),
                "description": .string("Run package tests")
            ])
        )

        #expect(detail.contains("run a command"))
        #expect(detail.contains("swift test"))
        #expect(detail.contains("Run package tests"))
    }

    @Test func codexPermissionApprovalDetailShowsExactScope() {
        let permissions = CodexJSONValue.object([
            "network": .object(["enabled": .bool(true)]),
            "fileSystem": .object([
                "write": .array([.string("/tmp/project")])
            ])
        ])

        let detail = CodexAppServerSession.permissionApprovalDetail(
            permissions: permissions,
            cwd: "/tmp/project",
            reason: "Run the requested build"
        )

        #expect(detail.contains("Run the requested build"))
        #expect(detail.contains("/tmp/project"))
        #expect(detail.contains("\"network\""))
        #expect(detail.contains("\"enabled\" : true"))
    }

    @Test func codexCancellationAnswersOutstandingApprovalBeforeInterrupting() {
        let command = CodexApprovalRequest(
            requestID: .number(7),
            kind: .command,
            title: "Allow this command?",
            detail: "xcodebuild",
            requestedPermissions: nil
        )
        let permissions = CodexApprovalRequest(
            requestID: .number(8),
            kind: .permissions,
            title: "Grant additional access?",
            detail: "Network access",
            requestedPermissions: .object(["network": .bool(true)])
        )

        #expect(
            CodexAppServerSession.approvalResult(
                for: command,
                approved: false,
                cancelsTurn: true
            )["decision"] == .string("cancel")
        )
        #expect(
            CodexAppServerSession.approvalResult(
                for: permissions,
                approved: false,
                cancelsTurn: true
            )["permissions"] == .object([:])
        )
    }

    @Test(arguments: [false, true])
    func ollamaSessionIncludesCapabilityLimitsAndPersonalityInBothChatPaths(streaming: Bool) async throws {
        let host = "castor-personality-\(streaming).test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(#"{"models":[{"name":"local-model"}]}"#),
            .success(
                streaming
                    ? #"{"message":{"content":"Ahoy."},"done":true}"#
                    : #"{"message":{"content":"{\"response\":\"Ahoy.\",\"motion_state\":\"idle\"}"},"done":true}"#
            )
        ], for: host)
        let client = OllamaClient(
            endpoint: URL(string: "http://\(host)")!,
            session: Self.stubbedURLSession()
        )
        let session = OllamaSession(client: client)

        await session.connect()
        if streaming {
            try await session.sendStreaming(
                "Open a file",
                to: HesitateCore(),
                personalityInstruction: "Speak like a pirate."
            ) { _ in }
        } else {
            await session.send(
                "Open a file",
                to: HesitateCore(),
                personalityInstruction: "Speak like a pirate."
            )
        }

        let requests = OllamaClientURLProtocol.requests(for: host)
        #expect(requests.count == 2)
        let body = try Self.jsonBody(from: requests[1])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let systemMessage = try #require(messages.first?["content"] as? String)
        #expect(systemMessage.contains("Character direction: Speak like a pirate."))
        #expect(systemMessage.contains("cannot operate the user's Mac"))
        #expect(systemMessage.contains("read or change files, run commands, or control apps"))
        #expect(systemMessage.contains("honestly say you cannot do it in on-device mode"))
        #expect(systemMessage.contains("switching to Codex or Claude Code"))
        #expect(systemMessage.contains("Never claim you performed an action you did not perform"))
        #expect(systemMessage.contains("Keep response to one short sentence"))
        #expect(body["stream"] as? Bool == streaming)
        #expect(session.responseText == "Ahoy.")
    }

    @Test func ollamaSessionRejectsEmptyStreamWithoutCommittingItToHistory() async throws {
        let host = "castor-empty-stream.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(#"{"models":[{"name":"local-model"}]}"#),
            .success(#"{"message":{"content":""},"done":true}"#),
            .success(
                #"{"message":{"content":"{\"response\":\"Recovered.\",\"motion_state\":\"idle\"}"},"done":true}"#
            )
        ], for: host)
        let client = OllamaClient(
            endpoint: URL(string: "http://\(host)")!,
            session: Self.stubbedURLSession()
        )
        let session = OllamaSession(client: client)

        await session.connect()
        do {
            try await session.sendStreaming("First attempt", to: HesitateCore()) { _ in }
            Issue.record("An empty stream should fail before it is committed to history.")
        } catch let error as OllamaClientError {
            guard case .emptyResponse = error else {
                Issue.record("Unexpected Ollama error: \(error.localizedDescription)")
                return
            }
        }

        await session.send("Retry", to: HesitateCore())

        let requests = OllamaClientURLProtocol.requests(for: host)
        #expect(requests.count == 3)
        let body = try Self.jsonBody(from: requests[2])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userMessages = messages.filter { $0["role"] as? String == "user" }
        #expect(userMessages.count == 1)
        #expect(userMessages.first?["content"] as? String == "Retry")
    }

    @Test func ollamaModelDecodesLegacyDataAndRoundTripsMetadata() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(OllamaModel.self, from: Data(#"{"name":"local-chat"}"#.utf8))
        #expect(legacy.parameterSize == nil)
        #expect(legacy.parameterSizeLabel == nil)
        #expect(!legacy.isSmallModel)
        let model = OllamaModel(name: "local-chat", parameterSize: "3.2B")
        #expect(try decoder.decode(OllamaModel.self, from: JSONEncoder().encode(model)) == model)
    }

    @Test(arguments: [
        ("qwen2.5:0.5b", 0.5),
        ("model-270M", 0.27),
        ("model-3b-instruct", 3.0),
        ("model-6.9B", 6.9),
        ("model-7B", 7.0),
        ("model-8b-Q4_K_M", 8.0),
        ("model-30B-A3B", 30.0),
        ("model-1T", 1_000.0)
    ])
    func ollamaModelInfersSizeAndUsesSevenBillionBoundary(name: String, billions: Double) throws {
        let model = OllamaModel(name: name)
        let count = try #require(model.parameterCountBillions)
        #expect(abs(count - billions) < 0.000001)
        #expect(model.isSmallModel == (billions < 7))
        #expect(model.parameterSizeLabel?.contains("estimated") == true)
    }

    @Test(arguments: ["qwen2.5:latest", "model-4bit", "model-Q4_K_M", "model-A3B", "model-0B"])
    func ollamaModelDoesNotTreatVersionsOrQuantizationAsSize(name: String) {
        let model = OllamaModel(name: name)
        #expect(model.parameterCountBillions == nil)
        #expect(model.parameterSizeLabel == nil)
        #expect(!model.isSmallModel)
    }

    @Test func ollamaModelPrefersReportedTotalParametersOverNameAndActiveCount() {
        let model = OllamaModel(name: "model-3b", parameterSize: "26B-A4B")
        #expect(model.parameterCountBillions == 26)
        #expect(model.parameterSizeLabel == "26B-A4B")
        #expect(!model.isSmallModel)
        let fallback = OllamaModel(name: "model-3b", parameterSize: "unknown")
        #expect(fallback.parameterCountBillions == 3)
        #expect(fallback.parameterSizeLabel == "3B (estimated)")
    }

    @Test func ollamaClientReadsParameterSizeFromTagsDetails() async throws {
        let host = "castor-model-sizes.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(#"{"models":[{"name":"local-chat","details":{"parameter_size":"3.2B"}},{"name":"model-8b"},{"name":"unknown","details":{}}]}"#)
        ], for: host)
        let client = OllamaClient(endpoint: URL(string: "http://\(host)")!, session: Self.stubbedURLSession())
        let models = try await client.models()
        #expect(models.map(\.parameterSize) == ["3.2B", nil, nil])
        #expect(models[0].isSmallModel)
        #expect(models[1].parameterSizeLabel == "8B (estimated)")
        #expect(models[2].parameterCountBillions == nil)
        #expect(OllamaClientURLProtocol.requests(for: host).first?.url?.path == "/api/tags")
    }

    @Test func ollamaModelResolutionKeepsAvailablePreferenceAndFallsBackSafely() {
        let models = [OllamaModel(name: "first"), OllamaModel(name: "preferred")]

        #expect(
            OllamaSession.resolvedModelName(
                availableModels: models,
                preferredModel: "preferred"
            ) == "preferred"
        )
        #expect(
            OllamaSession.resolvedModelName(
                availableModels: models,
                preferredModel: "missing"
            ) == "first"
        )
    }

    @Test func lmStudioClientListsOnlyConversationalModelsFromNativeAPI() async throws {
        let host = "castor-lmstudio-models.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(
                #"{"models":[{"type":"embedding","key":"text-embed","params_string":"0.1B"},{"type":"llm","key":"local-chat","params_string":"3.2B"},{"type":"llm","key":"model-7B","params_string":null},{"type":"llm","key":"legacy-model"}]}"#
            )
        ], for: host)
        let client = LMStudioClient(
            endpoint: URL(string: "http://\(host):1234")!,
            session: Self.stubbedURLSession()
        )

        let models = try await client.models()

        #expect(models.map(\.name) == ["local-chat", "model-7B", "legacy-model"])
        #expect(models.map(\.parameterSize) == ["3.2B", nil, nil])
        #expect(models[0].parameterSizeLabel == "3.2B")
        #expect(models[0].isSmallModel)
        #expect(models[1].parameterSizeLabel == "7B (estimated)")
        #expect(!models[1].isSmallModel)
        #expect(models[2].parameterSizeLabel == nil)
        let request = try #require(OllamaClientURLProtocol.requests(for: host).first)
        #expect(request.url?.path == "/api/v1/models")
    }

    @Test func lmStudioClientUsesOpenAICompatibleStructuredChat() async throws {
        let host = "castor-lmstudio-chat.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(
                #"{"choices":[{"message":{"content":"{\"response\":\"Hello.\",\"motion_state\":\"idle\",\"tts\":{\"emotion\":\"neutral\",\"intensity\":0.5,\"speaking_rate\":1.0}}"}}]}"#
            )
        ], for: host)
        let client = LMStudioClient(
            endpoint: URL(string: "http://\(host):1234")!,
            session: Self.stubbedURLSession()
        )

        let reply = try await client.chat(
            model: "local-chat",
            messages: [OllamaChatMessage(role: .user, content: "Hello")]
        )

        #expect(reply.contains("Hello."))
        let request = try #require(OllamaClientURLProtocol.requests(for: host).first)
        #expect(request.url?.path == "/v1/chat/completions")
        let body = try Self.jsonBody(from: request)
        #expect(body["model"] as? String == "local-chat")
        #expect(body["stream"] as? Bool == false)
        #expect(body["response_format"] != nil)
        #expect(body["draft_model"] == nil)
    }

    @Test func lmStudioClientStreamsOpenAICompatibleSSE() async throws {
        let host = "castor-lmstudio-stream.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(
                """
                data: {"choices":[{"delta":{"content":"Hello"}}]}

                data: {"choices":[{"delta":{"content":" there."}}]}

                data: [DONE]

                """
            )
        ], for: host)
        let client = LMStudioClient(
            endpoint: URL(string: "http://\(host):1234")!,
            session: Self.stubbedURLSession()
        )
        var deltas: [String] = []

        let reply = try await client.chatStream(
            model: "local-chat",
            messages: [OllamaChatMessage(role: .user, content: "Hello")]
        ) { delta in
            deltas.append(delta)
        }

        #expect(reply == "Hello there.")
        #expect(deltas == ["Hello", " there."])
        let request = try #require(OllamaClientURLProtocol.requests(for: host).first)
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(try Self.jsonBody(from: request)["stream"] as? Bool == true)
    }

    @Test func localAIConnectChecksBothAndPrefersLMStudio() async throws {
        let ollamaHost = "castor-local-ai-ollama.test"
        let lmStudioHost = "castor-local-ai-lmstudio.test"
        OllamaClientURLProtocol.reset(host: ollamaHost)
        OllamaClientURLProtocol.reset(host: lmStudioHost)
        OllamaClientURLProtocol.setResponses([
            .success(#"{"models":[{"name":"ollama-model"}]}"#)
        ], for: ollamaHost)
        OllamaClientURLProtocol.setResponses([
            .success(#"{"models":[{"type":"llm","key":"lm-studio-model"}]}"#)
        ], for: lmStudioHost)
        let session = OllamaSession(
            client: OllamaClient(
                endpoint: URL(string: "http://\(ollamaHost)")!,
                session: Self.stubbedURLSession()
            ),
            lmStudioClient: LMStudioClient(
                endpoint: URL(string: "http://\(lmStudioHost):1234")!,
                session: Self.stubbedURLSession()
            )
        )

        await session.connect()

        #expect(session.connectionState == .connected)
        #expect(session.activeProvider == .lmStudio)
        #expect(session.availableProviders == [.lmStudio, .ollama])
        #expect(session.models.map(\.name) == ["lm-studio-model"])
        #expect(session.selectedModel == "lm-studio-model")
        #expect(OllamaClientURLProtocol.requests(for: lmStudioHost).count == 1)
        #expect(OllamaClientURLProtocol.requests(for: ollamaHost).count == 1)
    }

    @Test func localAIConnectFallsBackToOllamaWhenLMStudioHasNoLLM() async {
        let ollamaHost = "castor-local-ai-fallback-ollama.test"
        let lmStudioHost = "castor-local-ai-fallback-lmstudio.test"
        OllamaClientURLProtocol.reset(host: ollamaHost)
        OllamaClientURLProtocol.reset(host: lmStudioHost)
        OllamaClientURLProtocol.setResponses([
            .success(#"{"models":[{"name":"ollama-model"}]}"#)
        ], for: ollamaHost)
        OllamaClientURLProtocol.setResponses([
            .success(#"{"models":[{"type":"embedding","key":"embed-only"}]}"#)
        ], for: lmStudioHost)
        let session = OllamaSession(
            client: OllamaClient(
                endpoint: URL(string: "http://\(ollamaHost)")!,
                session: Self.stubbedURLSession()
            ),
            lmStudioClient: LMStudioClient(
                endpoint: URL(string: "http://\(lmStudioHost):1234")!,
                session: Self.stubbedURLSession()
            )
        )

        await session.connect()

        #expect(session.activeProvider == .ollama)
        #expect(session.selectedModel == "ollama-model")
    }

    @Test func ollamaArilsAlignmentRequestIncludesImageAndVersionedSchema() async throws {
        let host = "castor-arils-ai.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(
                #"{"message":{"content":"{\"operation\":\"POME_ARILS_FACE_LAYOUT_V1\"}"},"done":true}"#
            )
        ], for: host)
        let client = OllamaClient(
            endpoint: URL(string: "http://\(host)")!,
            session: Self.stubbedURLSession()
        )

        _ = try await client.arilsFaceLayoutAdjustment(
            model: "vision-model",
            prompt: "Inspect the markers.",
            imageBase64: "cG5n"
        )

        let request = try #require(OllamaClientURLProtocol.requests(for: host).first)
        let body = try Self.jsonBody(from: request)
        #expect(body["model"] as? String == "vision-model")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == "Inspect the markers.")
        #expect(messages[0]["images"] as? [String] == ["cG5n"])
        let format = try #require(body["format"] as? [String: Any])
        let properties = try #require(format["properties"] as? [String: Any])
        let operation = try #require(properties["operation"] as? [String: Any])
        #expect(operation["enum"] as? [String] == ["POME_ARILS_FACE_LAYOUT_V1"])
    }

    @Test func ollamaResponseParserReadsStructuredMotionState() {
        let reply = OllamaResponseParser.parse(
            #"{"response":"Oh, hello.","motion_state":"surprised","tts":{"emotion":"surprised","intensity":0.85,"speaking_rate":1.15,"performance_note":"A quick, warm intake."}}"#
        )

        #expect(reply.text == "Oh, hello.")
        #expect(reply.motionState == .surprised)
        #expect(reply.speech.emotion == .surprised)
        #expect(reply.speech.intensity == 0.85)
        #expect(reply.speech.speakingRate == 1.15)
        #expect(reply.speech.performanceNote == "A quick, warm intake.")
    }

    @Test func ollamaResponseParserExtractsJSONFromModelFormatting() {
        let reply = OllamaResponseParser.parse(
            """
            Here is the result:
            {"response":"Let me think.","motion_state":"thinking"}
            """
        )

        #expect(reply.text == "Let me think.")
        #expect(reply.motionState == .thinking)
    }

    @Test func ollamaResponseParserFindsJSONAmongUnrelatedBraces() {
        let reply = OllamaResponseParser.parse(
            """
            I considered {another format}, but the model left an unmatched " before:
            ```json
            {"response":"This one is usable.","motion_state":"listening"}
            ```
            """
        )

        #expect(reply.text == "This one is usable.")
        #expect(reply.motionState == .listening)
    }

    @Test func ollamaClientUsesStructuredNonStreamingRequestWithoutPredictionCap() async throws {
        let host = "castor-nonstream.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .success(
                #"{"message":{"content":"{\"response\":\"こんばんは。\",\"motion_state\":\"idle\"}"},"done":true}"#
            )
        ], for: host)
        let client = OllamaClient(
            endpoint: URL(string: "http://\(host)")!,
            session: Self.stubbedURLSession()
        )

        let reply = try await client.chat(
            model: "local-model",
            messages: [OllamaChatMessage(role: .user, content: "こんばんは")]
        )

        #expect(reply.contains("こんばんは。"))
        let requests = OllamaClientURLProtocol.requests(for: host)
        #expect(requests.count == 1)

        let body = try Self.jsonBody(from: requests[0])
        #expect(body["stream"] as? Bool == false)
        #expect(body["keep_alive"] as? String == "10m")
        #expect(body["options"] == nil)
        #expect(body["format"] != nil)
    }

    @Test func ollamaClientFallsBackToPlainNonStreamingWhenStructuredRequestFails() async throws {
        let host = "castor-plain-fallback.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .failure(URLError(.badServerResponse)),
            .success(
                #"{"message":{"content":"{\"response\":\"plain fallback ok\",\"motion_state\":\"idle\"}"},"done":true}"#
            )
        ], for: host)
        let client = OllamaClient(
            endpoint: URL(string: "http://\(host)")!,
            session: Self.stubbedURLSession()
        )

        let reply = try await client.chat(
            model: "local-model",
            messages: [OllamaChatMessage(role: .user, content: "Googleの本社はどこ？")]
        )

        #expect(reply.contains("plain fallback ok"))
        let requests = OllamaClientURLProtocol.requests(for: host)
        #expect(requests.count == 2)
        #expect(try Self.jsonBody(from: requests[0])["stream"] as? Bool == false)
        #expect(try Self.jsonBody(from: requests[0])["format"] != nil)
        #expect(try Self.jsonBody(from: requests[1])["stream"] as? Bool == false)
        #expect(try Self.jsonBody(from: requests[1])["format"] == nil)
    }

    @Test func ollamaClientFallsBackToPlainStreamingWhenNonStreamingRequestsFail() async throws {
        let host = "castor-stream-fallback.test"
        OllamaClientURLProtocol.reset(host: host)
        OllamaClientURLProtocol.setResponses([
            .failure(URLError(.badServerResponse)),
            .failure(URLError(.timedOut)),
            .success(
                #"{"message":{"content":"{\"response\":\"stream fallback ok\",\"motion_state\":\"idle\"}"},"done":true}"#
            )
        ], for: host)
        let client = OllamaClient(
            endpoint: URL(string: "http://\(host)")!,
            session: Self.stubbedURLSession()
        )

        let reply = try await client.chat(
            model: "local-model",
            messages: [OllamaChatMessage(role: .user, content: "Appleの製品を3つ教えて")]
        )

        #expect(reply.contains("stream fallback ok"))
        let requests = OllamaClientURLProtocol.requests(for: host)
        #expect(requests.count == 3)
        #expect(try Self.jsonBody(from: requests[0])["stream"] as? Bool == false)
        #expect(try Self.jsonBody(from: requests[0])["format"] != nil)
        #expect(try Self.jsonBody(from: requests[1])["stream"] as? Bool == false)
        #expect(try Self.jsonBody(from: requests[1])["format"] == nil)
        #expect(try Self.jsonBody(from: requests[2])["stream"] as? Bool == true)
        #expect(try Self.jsonBody(from: requests[2])["format"] == nil)
    }

    @Test func ollamaResponseParserChoosesBestOfMultipleJSONObjects() {
        let reply = OllamaResponseParser.parse(
            """
            {"debug":true}
            {"message":"A weaker candidate."}
            {"response":"Use the complete answer.","motion_state":"surprised","tts":{"emotion":"happy"}}
            """
        )

        #expect(reply.text == "Use the complete answer.")
        #expect(reply.motionState == .surprised)
        #expect(reply.speech.emotion == .happy)
    }

    @Test func ollamaResponseParserIgnoresBracesInsideResponseText() {
        let reply = OllamaResponseParser.parse(
            """
            Result:
            {"response":"Keep {this} text.","motion_state":"idle"}
            Additional {non-JSON} notes.
            """
        )

        #expect(reply.text == "Keep {this} text.")
        #expect(reply.motionState == .idle)
    }

    @Test func ollamaResponseParserFallsBackSafely() {
        let unknownState = OllamaResponseParser.parse(
            #"{"response":"Still here.","motion_state":"dancing"}"#
        )
        let plainText = OllamaResponseParser.parse("A plain response.")

        #expect(unknownState.text == "Still here.")
        #expect(unknownState.motionState == .idle)
        #expect(unknownState.speech == .fallback)
        #expect(plainText.text == "A plain response.")
        #expect(plainText.motionState == .idle)
        #expect(plainText.speech == .fallback)
    }

    @Test func ollamaMotionStateParserAcceptsConservativeAliases() {
        #expect(OllamaResponseParser.motionState(from: "attentive") == .listening)
        #expect(OllamaResponseParser.motionState(from: " STARTLED ") == .surprised)
        #expect(OllamaResponseParser.motionState(from: nil) == nil)
    }

    @Test func ollamaResponseParserNormalizesUnsafeSpeechMetadata() {
        let reply = OllamaResponseParser.parse(
            #"{"response":"We can try again.","motion_state":"idle","tts":{"emotion":"mysterious","intensity":4.0,"speaking_rate":0.1,"performance_note":"   "}}"#
        )

        #expect(reply.speech.emotion == .neutral)
        #expect(reply.speech.intensity == 1.0)
        #expect(reply.speech.speakingRate == 0.5)
        #expect(reply.speech.performanceNote == nil)
    }

    @Test func ollamaResponseParserIgnoresMalformedSpeechFields() {
        let reply = OllamaResponseParser.parse(
            #"{"response":"Still usable.","motion_state":"thinking","tts":{"emotion":42,"intensity":"loud","speaking_rate":false,"performance_note":["softly"]}}"#
        )

        #expect(reply.text == "Still usable.")
        #expect(reply.motionState == .thinking)
        #expect(reply.speech == .fallback)
    }

    @Test func ollamaResponseParserSupportsEverySpeechEmotion() {
        for emotion in OllamaSpeechEmotion.allCases {
            let reply = OllamaResponseParser.parse(
                #"{"response":"Okay.","tts":{"emotion":"\#(emotion.rawValue)","intensity":0.5,"speaking_rate":1.0}}"#
            )

            #expect(reply.speech.emotion == emotion)
        }
    }

    @Test func speechAudioMeterCalculatesNormalizedRMS() {
        #expect(SpeechAudioMeter.level(from: [Float]()) == 0)
        #expect(SpeechAudioMeter.level(from: [0.1, -0.1]) > 0.49)
        #expect(SpeechAudioMeter.level(from: [1, -1]) == 1)
    }

    @Test func speechSilenceDetectorWaitsForTranscriptAndSilence() {
        var detector = SpeechSilenceDetector(
            minimumLevelThreshold: 0.03,
            requiredSilence: 1.0,
            calibrationDuration: 0
        )

        let beforeTranscript = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: false,
            at: 0
        )
        let voiceActivity = detector.shouldFinalize(
            audioLevel: 0.2,
            hasTranscript: true,
            at: 0.2
        )
        let shortSilence = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: true,
            at: 1.1
        )
        let enoughSilence = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: true,
            at: 1.21
        )

        #expect(!beforeTranscript)
        #expect(!voiceActivity)
        #expect(!shortSilence)
        #expect(enoughSilence)
    }

    @Test func speechSilenceDetectorExtendsForNewVoiceActivity() {
        var detector = SpeechSilenceDetector(
            minimumLevelThreshold: 0.03,
            requiredSilence: 1.0,
            calibrationDuration: 0
        )

        let firstVoice = detector.shouldFinalize(
            audioLevel: 0.1,
            hasTranscript: true,
            at: 0
        )
        let laterVoice = detector.shouldFinalize(
            audioLevel: 0.1,
            hasTranscript: true,
            at: 0.8
        )
        let shortSilence = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: true,
            at: 1.7
        )
        let enoughSilence = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: true,
            at: 1.81
        )

        #expect(!firstVoice)
        #expect(!laterVoice)
        #expect(!shortSilence)
        #expect(enoughSilence)
    }

    @Test func speechSilenceDetectorExtendsWhenTranscriptChangesBelowAudioThreshold() {
        var detector = SpeechSilenceDetector(
            minimumLevelThreshold: 0.03,
            requiredSilence: 1.0,
            calibrationDuration: 0
        )

        detector.noteTranscriptActivity(at: 0)
        let beforeSilence = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: true,
            at: 0.9
        )

        detector.noteTranscriptActivity(at: 0.95)
        let afterTranscriptActivity = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: true,
            at: 1.5
        )
        let afterEnoughSilence = detector.shouldFinalize(
            audioLevel: 0.01,
            hasTranscript: true,
            at: 1.96
        )

        #expect(!beforeSilence)
        #expect(!afterTranscriptActivity)
        #expect(afterEnoughSilence)
    }

    @Test func speechSilenceDetectorFinalizesAboveLegacyCalibrationCap() {
        var detector = SpeechSilenceDetector(
            minimumLevelThreshold: 0.008,
            requiredSilence: 1.0,
            calibrationDuration: 0.5
        )

        detector.noteTranscriptActivity(at: 0)
        let calibrationStart = detector.shouldFinalize(audioLevel: 0.04, hasTranscript: true, at: 0)
        let calibrationEnd = detector.shouldFinalize(audioLevel: 0.04, hasTranscript: true, at: 0.5)
        let afterSilence = detector.shouldFinalize(audioLevel: 0.04, hasTranscript: true, at: 1.51)

        #expect(!calibrationStart)
        #expect(!calibrationEnd)
        #expect(afterSilence)
    }

    @Test func speechSilenceDetectorDefaultFinalizesAfterShorterPause() {
        var detector = SpeechSilenceDetector(calibrationDuration: 0)

        detector.noteTranscriptActivity(at: 0)
        let tooSoon = detector.shouldFinalize(audioLevel: 0.001, hasTranscript: true, at: 1.0)
        let ready = detector.shouldFinalize(audioLevel: 0.001, hasTranscript: true, at: 1.16)

        #expect(!tooSoon)
        #expect(ready)
    }

    @Test func progressiveSpeechTranscriptKeepsFinalAndVolatileTextSeparate() {
        var transcript = ProgressiveSpeechTranscript()

        #expect(transcript.accept("こんにちは", isFinal: false) == "こんにちは")
        #expect(transcript.accept("こんにちは。", isFinal: true) == "こんにちは。")
        #expect(transcript.accept("今日は", isFinal: false) == "こんにちは。 今日は")
        #expect(transcript.accept("今日は元気です。", isFinal: true) == "こんにちは。 今日は元気です。")
    }

    @Test func progressiveSpeechTranscriptKeepsRepeatedFinalChunks() {
        var transcript = ProgressiveSpeechTranscript()

        #expect(transcript.accept("yes", isFinal: true) == "yes")
        #expect(transcript.accept("yes", isFinal: true) == "yes yes")
    }

    @Test func petSpeechSegmenterSplitsJapaneseSentences() {
        let segments = PetSpeechSegmenter.segments(
            from: "こんにちは。今日は少し考えています！でも、ちゃんとここにいます？"
        )

        #expect(segments == [
            "こんにちは。",
            "今日は少し考えています！",
            "でも、ちゃんとここにいます？"
        ])
    }

    @Test func neuralSegmentsReadTheWholeReplyAtOnce() {
        let text = "こんにちは。今日はまず状況を確認して、必要な情報をゆっくり整理して、それから次にできることを一緒に考えてみましょう。焦らなくて大丈夫です。"
        #expect(PetSpeechSegmenter.neuralReplySegments(from: text) == [text])
        // The short-phrase tuning for the system voice cuts the same text into many pieces.
        #expect(PetSpeechSegmenter.spokenReplySegments(from: text, isFirstSpokenText: true).count > 5)
    }

    @Test func readerFollowsTheSpokenLineOfALongSegment() {
        let reply = "今日はお鍋にしましょう。具材を食べやすい大きさに切って、だしと合わせて、刻んだネギをかけてください。あたたかいうちにどうぞ。"
        let layout = PetReaderLines.layout(for: [reply, "ほかに何か作りますか？"])
        #expect(layout.lines.count > 3)
        #expect(layout.lines.allSatisfy { $0.count <= PetReaderLines.maximumLength })
        let ownLines = layout.segmentOfLine.filter { $0 == 0 }.count
        #expect(PetReaderLines.currentLine(in: layout, segmentIndex: 0, progress: 0) == 0)
        #expect(PetReaderLines.currentLine(in: layout, segmentIndex: 0, progress: 0.5) > 0)
        #expect(PetReaderLines.currentLine(in: layout, segmentIndex: 0, progress: 0.5) < ownLines - 1)
        #expect(PetReaderLines.currentLine(in: layout, segmentIndex: 0, progress: 1) == ownLines - 1)
        // The next segment starts at its own first line.
        #expect(PetReaderLines.currentLine(in: layout, segmentIndex: 1, progress: 0) == ownLines)
        // Lines advance in order as playback moves on.
        let walk = stride(from: 0.0, through: 1.0, by: 0.05).map { PetReaderLines.currentLine(in: layout, segmentIndex: 0, progress: $0) }
        #expect(walk == walk.sorted())
        // Short system-voice segments stay one line each.
        let short = PetReaderLines.layout(for: ["こんにちは。", "元気です。"])
        #expect(short.lines == ["こんにちは。", "元気です。"])
        #expect(PetReaderLines.currentLine(in: short, segmentIndex: 1, progress: 0.3) == 1)
        #expect(PetReaderLines.currentLine(in: PetReaderLines.layout(for: []), segmentIndex: 0, progress: 0) == 0)
    }

    @Test func neuralSegmentsDivideOnlyBeyondTheLimit() {
        let sentence = String(repeating: "あいうえおかきくけこ、", count: 40) + "おわり。"
        let text = sentence + "次の文です。"
        let segments = PetSpeechSegmenter.neuralReplySegments(from: text)
        #expect(segments.allSatisfy { $0.count <= PetSpeechSegmenter.neuralSegmentLength })
        #expect(segments.joined() == text)
        #expect(segments.count == 2)
        #expect(PetSpeechSegmenter.neuralJoin("Hello there.", "How are you?") == "Hello there. How are you?")
        #expect(PetSpeechSegmenter.neuralJoin(sentence, "次の文です。") == nil)
    }

    @Test func petSpeechSegmenterSplitsEnglishSentencesAndKeepsClosers() {
        let segments = PetSpeechSegmenter.segments(
            from: #"She said, "Give me a moment." Then she smiled! Are you still there?"#
        )

        #expect(segments == [
            #"She said, "Give me a moment.""#,
            "Then she smiled!",
            "Are you still there?"
        ])
    }

    @Test func petSpeechSegmenterBreaksLongSentencesAtReadablePhrases() {
        let segments = PetSpeechSegmenter.segments(
            from: "まず状況を確認して、必要な情報をゆっくり整理して、それから次にできることを一緒に考えてみましょう。",
            maximumLength: 24
        )

        #expect(segments == [
            "まず状況を確認して、",
            "必要な情報をゆっくり整理して、",
            "それから次にできることを一緒に考えてみましょう。"
        ])
        #expect(segments.allSatisfy { !$0.trimmingCharacters(in: .punctuationCharacters).isEmpty })
    }

    @Test func petSpeechSegmenterCanMakeShortNaturalSpeechPhrases() {
        let segments = PetSpeechSegmenter.segments(
            from: "Googleの本社は、カリフォルニア州マウンテンビューにあります。",
            targetLength: 14,
            maximumLength: 18
        )

        #expect(segments == [
            "Googleの本社は、",
            "カリフォルニア州マウンテンビューに",
            "あります。"
        ])
    }

    @Test func petSpeechSegmenterNormalizesWhitespaceAndDropsEmptyInput() {
        #expect(PetSpeechSegmenter.segments(from: "  Hello,\n\nthere.   Still here. ") == [
            "Hello, there.",
            "Still here."
        ])
        #expect(PetSpeechSegmenter.segments(from: " \n\t ") == [])
    }

    @Test func petSpeechSegmenterKeepsDecimalAndURLPeriodsInsideSentences() {
        let segments = PetSpeechSegmenter.segments(
            from: "Version 2.1 is ready. Visit example.com/docs. 次へ。"
        )

        #expect(segments == [
            "Version 2.1 is ready.",
            "Visit example.com/docs.",
            "次へ。"
        ])
    }

    @Test func speechTranscriptAccumulatorPreservesLastNonEmptyResult() {
        var accumulator = SpeechTranscriptAccumulator()

        #expect(accumulator.accept("こんにちは") == "こんにちは")
        #expect(accumulator.accept("") == "こんにちは")
        #expect(accumulator.accept(nil) == "こんにちは")
        #expect(accumulator.accept("こんにちは、聞こえますか？") == "こんにちは、聞こえますか？")
    }

    @Test func voiceLatencyReportOrdersMarksByFixedKindRegardlessOfInsertionOrder() {
        let report = VoiceLatencyReport(marks: [
            VoiceLatencyMark(kind: .ttsRequestStarted, elapsed: 0.20),
            VoiceLatencyMark(kind: .inputFinalized, elapsed: 0.0),
            VoiceLatencyMark(kind: .playbackStarted, elapsed: 0.62),
            VoiceLatencyMark(kind: .llmFirstToken, elapsed: 0.18)
        ])

        #expect(report.orderedMarks.map(\.kind) == [
            .inputFinalized,
            .llmFirstToken,
            .ttsRequestStarted,
            .playbackStarted
        ])
        #expect(report.timeToFirstAudio == 0.62)
    }

    @Test func voiceLatencyReportComputesSegmentDurationsBetweenConsecutiveMarks() {
        let report = VoiceLatencyReport(marks: [
            VoiceLatencyMark(kind: .inputFinalized, elapsed: 0.0),
            VoiceLatencyMark(kind: .llmFirstToken, elapsed: 0.18),
            VoiceLatencyMark(kind: .ttsRequestStarted, elapsed: 0.20),
            VoiceLatencyMark(kind: .ttsResponseReceived, elapsed: 0.55),
            VoiceLatencyMark(kind: .playbackStarted, elapsed: 0.62)
        ])

        let durations = report.segmentDurations()
        #expect(durations.count == 4)
        #expect(durations[0].from == .inputFinalized)
        #expect(durations[0].to == .llmFirstToken)
        #expect(abs(durations[0].duration - 0.18) < 0.0001)
        #expect(abs(durations[2].duration - 0.35) < 0.0001)
        #expect(durations[3].to == .playbackStarted)
    }

    @Test func voiceLatencyReportHandlesMissingMarksGracefully() {
        let empty = VoiceLatencyReport(marks: [])
        #expect(empty.timeToFirstAudio == nil)
        #expect(empty.segmentDurations().isEmpty)
        #expect(empty.summaryLine().contains("n/a"))

        let partial = VoiceLatencyReport(marks: [
            VoiceLatencyMark(kind: .inputFinalized, elapsed: 0.0),
            VoiceLatencyMark(kind: .llmComplete, elapsed: 0.4)
        ])
        #expect(partial.timeToFirstAudio == nil)
        #expect(partial.segmentDurations().count == 1)
    }

    @Test func voiceLatencyTrackerRecordsElapsedTimeRelativeToTurnStart() {
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let tracker = VoiceLatencyTracker(now: { currentTime })

        tracker.startTurn()
        currentTime = currentTime.addingTimeInterval(0.2)
        tracker.record(.llmFirstToken)
        currentTime = currentTime.addingTimeInterval(0.4)
        tracker.record(.playbackStarted)

        let report = tracker.finishAndLog()
        #expect(report.timeToFirstAudio != nil)
        #expect(abs((report.timeToFirstAudio ?? -1) - 0.6) < 0.0001)
    }

    @Test func voiceLatencyTrackerIgnoresMarksRecordedBeforeStartTurn() {
        let tracker = VoiceLatencyTracker()
        tracker.record(.llmFirstToken)
        let report = tracker.finishAndLog()
        #expect(report.orderedMarks.isEmpty)
    }

    @Test func streamingSentenceExtractorEmitsSentenceAsSoonAsAnUnambiguousTerminatorArrives() {
        var extractor = OllamaStreamingSentenceExtractor()

        #expect(extractor.append("Hello") == [])
        // The period after a letter (not a digit) is unambiguous, so it is emitted immediately —
        // this is what lets TTS start on the very next event loop tick instead of waiting for the
        // next streamed chunk, minimizing time-to-first-audio.
        #expect(extractor.append(" there.") == ["Hello there."])
        #expect(extractor.append(" Next.") == ["Next."])
    }

    @Test func streamingSentenceExtractorHandlesJapaneseTerminatorsImmediately() {
        var extractor = OllamaStreamingSentenceExtractor()

        // Japanese terminators are unambiguous, so they can be emitted without waiting for a
        // lookahead character (unlike ".", which could be a decimal point).
        let emitted = extractor.append("こんにちは。")
        #expect(emitted == ["こんにちは。"])
    }

    @Test func streamingSentenceExtractorWithholdsAmbiguousDecimalPeriod() {
        var extractor = OllamaStreamingSentenceExtractor()

        #expect(extractor.append("Version 3") == [])
        // "." immediately after a digit, with nothing yet known to follow, is ambiguous (could
        // become "3.14"): must not be emitted as a sentence end yet.
        #expect(extractor.append(".") == [])
        // Once "14 is ready." streams in, the trailing "." after "y" is unambiguous, so the whole
        // sentence (correctly keeping "3.14" intact) is emitted immediately.
        #expect(extractor.append("14 is ready.") == ["Version 3.14 is ready."])
        #expect(extractor.append(" Next.") == ["Next."])
    }

    @Test func streamingSentenceExtractorWithholdsPeriodImmediatelyAfterDigitAtBufferEnd() {
        var extractor = OllamaStreamingSentenceExtractor()

        // A "." right after a digit, sitting at the very end of the buffer, must not be treated
        // as a sentence end — only once we see what follows can we tell it wasn't a decimal point.
        #expect(extractor.append("It costs 5") == [])
        #expect(extractor.append(".") == [])
        // A space (non-digit) after the period disambiguates it as a real sentence end.
        #expect(extractor.append(" Okay") == ["It costs 5."])
    }

    @Test func streamingSentenceExtractorAbsorbsClosingQuotesAfterTerminator() {
        var extractor = OllamaStreamingSentenceExtractor()

        let emitted = extractor.append(#"She said, "Give me a moment." Then she smiled!"#)
        #expect(emitted == [
            #"She said, "Give me a moment.""#,
            "Then she smiled!"
        ])
    }

    @Test func streamingSentenceExtractorFlushRemainderReturnsTrailingIncompleteText() {
        var extractor = OllamaStreamingSentenceExtractor()

        _ = extractor.append("Complete sentence. Trailing clause without punctuation")
        let remainder = extractor.flushRemainder()

        #expect(remainder == "Trailing clause without punctuation")
        #expect(extractor.flushRemainder() == nil)
    }

    @Test func streamingSentenceExtractorNeverEmitsEmptyOrDuplicateSentences() {
        var extractor = OllamaStreamingSentenceExtractor()

        let firstBatch = extractor.append("First.")
        let secondBatch = extractor.append(" Second.")
        #expect(firstBatch == ["First."])
        #expect(secondBatch == ["Second."])
        #expect(extractor.flushRemainder() == nil)
    }

    @Test func petSpeechSegmenterShrinksOnlyTheFirstSegmentWhenRequested() {
        // Two sentences, each short enough to stay a single segment under the default maximum
        // length, so without shrinking the "first segment" spoken would be the entire first
        // sentence (32 characters) before any audio could start.
        let text = "今日は天気がとても良くて、公園には人がたくさん集まっていました。それでみんなでお弁当を食べました。"

        let baseline = PetSpeechSegmenter.segments(from: text)
        #expect(baseline.count == 2)
        #expect(baseline[0] == "今日は天気がとても良くて、公園には人がたくさん集まっていました。")

        let shrunk = PetSpeechSegmenter.segments(from: text, shrinkFirstSegment: true)

        // Shrinking splits the first baseline segment at its earliest natural pause, so what was
        // one long first segment becomes two short ones spoken back-to-back.
        #expect(shrunk.count == baseline.count + 1)
        #expect(shrunk[0] == "今日は天気がとても良くて、")
        #expect(shrunk[0].count < baseline[0].count)

        // Every later sentence (the second baseline segment) is completely untouched.
        #expect(Array(shrunk.dropFirst(2)) == Array(baseline.dropFirst(1)))

        // Rejoining the shrunk pieces recovers exactly the original first segment, so shrinking
        // never drops or duplicates characters.
        #expect(shrunk[0] + shrunk[1] == baseline[0])
    }

    @Test func petSpeechSegmenterShrinkFirstSegmentLeavesShortFirstSegmentUnchanged() {
        let segments = PetSpeechSegmenter.segments(
            from: "こんにちは。今日は少し考えています！",
            shrinkFirstSegment: true
        )

        #expect(segments == ["こんにちは。", "今日は少し考えています！"])
    }

    @Test func spokenReplySegmentsShrinkOnlyTheFirstSpokenText() {
        // First spoken text: shrunk at its earliest natural pause so playback can begin sooner.
        let first = PetSpeechSegmenter.spokenReplySegments(
            from: "はい、今日はとても天気が良いですね。",
            isFirstSpokenText: true
        )
        #expect(first.first == "はい、")
        #expect(first.count >= 2)

        // The same sentence arriving later in the stream keeps its normal granularity.
        let later = PetSpeechSegmenter.spokenReplySegments(
            from: "はい、今日はとても天気が良いですね。",
            isFirstSpokenText: false
        )
        #expect(later.first != "はい、")
    }

    @Test func spokenReplySegmentsSplitLongStreamedSentencesIntoShortPhrases() {
        // A single long streamed sentence must not become one oversized TTS request: it is
        // re-split with the same tuning as the full-reply path.
        let segments = PetSpeechSegmenter.spokenReplySegments(
            from: "今日は天気がとても良くて、公園には人がたくさん集まっていました。",
            isFirstSpokenText: false
        )
        #expect(segments.count >= 2)
        #expect(segments.allSatisfy { $0.count <= 19 })
    }

    @Test func streamedSentenceSegmentsMatchFullReplySegmentation() {
        // Segmenting sentence-by-sentence (streaming path) must yield exactly the same segments
        // as segmenting the whole reply at once (fallback path), so TTS request sizes and the
        // response reader granularity do not depend on which path was taken.
        let first = "はい、今日はとても天気が良いですね。"
        let second = "公園に行きましょう。"

        let streamed = PetSpeechSegmenter.spokenReplySegments(from: first, isFirstSpokenText: true)
            + PetSpeechSegmenter.spokenReplySegments(from: second, isFirstSpokenText: false)
        let full = PetSpeechSegmenter.spokenReplySegments(from: first + second, isFirstSpokenText: true)

        #expect(streamed == full)
    }

    @Test func petSpeechSegmenterShrinkFirstSegmentIsOptOutByDefault() {
        // A first sentence long enough to have an early comma the shrink logic would use, but
        // omitting `shrinkFirstSegment` must leave existing callers' output unchanged.
        let text = "まず状況を確認して、必要な情報をゆっくり整理して、それから次にできることを考えます。"
        let defaultBehavior = PetSpeechSegmenter.segments(from: text, maximumLength: 80)
        let explicitOptOut = PetSpeechSegmenter.segments(
            from: text,
            maximumLength: 80,
            shrinkFirstSegment: false
        )
        let explicitShrink = PetSpeechSegmenter.segments(
            from: text,
            maximumLength: 80,
            shrinkFirstSegment: true
        )

        #expect(defaultBehavior == explicitOptOut)
        #expect(defaultBehavior != explicitShrink)
        #expect(explicitShrink.first == "まず状況を確認して、")
    }

    private static func stubbedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaClientURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try #require(Self.httpBodyData(from: request))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func httpBodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private nonisolated final class OllamaClientURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var requestsByHost: [String: [URLRequest]] = [:]
    nonisolated(unsafe) static var stubResponsesByHost: [String: [OllamaClientStubResponse]] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let host = request.url?.host ?? ""
        guard let response = Self.recordRequestAndPopResponse(request, host: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        switch response {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .success(body, statusCode):
            let data = Data(body.utf8)
            let httpResponse = HTTPURLResponse(
                url: request.url ?? URL(string: "http://castor.test")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func requests(for host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsByHost[host] ?? []
    }

    static func setResponses(_ responses: [OllamaClientStubResponse], for host: String) {
        lock.lock()
        defer { lock.unlock() }
        stubResponsesByHost[host] = responses
    }

    static func reset(host: String) {
        lock.lock()
        defer { lock.unlock() }
        requestsByHost[host] = []
        stubResponsesByHost[host] = []
    }

    private static func recordRequestAndPopResponse(
        _ request: URLRequest,
        host: String
    ) -> OllamaClientStubResponse? {
        lock.lock()
        defer { lock.unlock() }

        requestsByHost[host, default: []].append(request)
        guard var responses = stubResponsesByHost[host], !responses.isEmpty else {
            return nil
        }

        let response = responses.removeFirst()
        stubResponsesByHost[host] = responses
        return response
    }
}

private nonisolated enum OllamaClientStubResponse {
    case success(String, statusCode: Int = 200)
    case failure(Error)
}
