import Foundation
import Observation

public nonisolated struct HesitateSnapshot: Sendable {
    public var state: MotionState
    public var previousState: MotionState
    public var confidence: Double
    public var awkwardness: Double
    public var speechEnergy: Double
    public var requestedAt: Date

    public init(
        state: MotionState,
        previousState: MotionState,
        confidence: Double,
        awkwardness: Double,
        speechEnergy: Double,
        requestedAt: Date
    ) {
        self.state = state
        self.previousState = previousState
        self.confidence = confidence
        self.awkwardness = awkwardness
        self.speechEnergy = speechEnergy
        self.requestedAt = requestedAt
    }
}

@Observable
public final class HesitateCore {
    public private(set) var snapshot: HesitateSnapshot

    public init(initialState: MotionState = .idle) {
        snapshot = HesitateSnapshot(
            state: initialState,
            previousState: initialState,
            confidence: 0.58,
            awkwardness: 0.34,
            speechEnergy: 0.10,
            requestedAt: .now
        )
    }

    public func request(_ state: MotionState) {
        // Requesting the same state again is not a transition: keep the existing
        // `previousState`/`requestedAt` so an already-settled pose does not
        // re-trigger the cross-fade (and the hesitant lag delay) from scratch.
        guard state != snapshot.state else {
            return
        }

        snapshot = HesitateSnapshot(
            state: state,
            previousState: snapshot.state,
            confidence: confidence(for: state),
            awkwardness: awkwardness(for: state),
            speechEnergy: speechEnergy(for: state),
            requestedAt: .now
        )
    }

    private func confidence(for state: MotionState) -> Double {
        switch state {
        case .idle:
            0.58
        case .thinking:
            0.36
        case .listening:
            0.50
        case .surprised:
            0.18
        }
    }

    private func awkwardness(for state: MotionState) -> Double {
        switch state {
        case .idle:
            0.34
        case .thinking:
            0.72
        case .listening:
            0.48
        case .surprised:
            0.92
        }
    }

    private func speechEnergy(for state: MotionState) -> Double {
        switch state {
        case .idle:
            0.10
        case .thinking:
            0.34
        case .listening:
            0.72
        case .surprised:
            0.68
        }
    }
}
