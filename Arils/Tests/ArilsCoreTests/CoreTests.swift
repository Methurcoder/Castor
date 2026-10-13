import CoreGraphics
import Foundation
import Testing

@testable import ArilsCore

// MARK: - Randomness & noise

@Test func seededRandomIsDeterministic() {
    var a = SeededRandom(seed: 42)
    var b = SeededRandom(seed: 42)
    for _ in 0..<100 {
        #expect(a.next() == b.next())
    }
}

@Test func seededRandomStreamsAreIndependent() {
    var a = SeededRandom(seed: 42, stream: "blink")
    var b = SeededRandom(seed: 42, stream: "gaze")
    var matches = 0
    for _ in 0..<50 where a.next() == b.next() {
        matches += 1
    }
    #expect(matches == 0)
}

@Test func seededRandomUnitFloatStaysInRange() {
    var rng = SeededRandom(seed: 7)
    for _ in 0..<1000 {
        let value = rng.unitFloat()
        #expect(value >= 0 && value < 1)
    }
}

@Test func valueNoiseIsDeterministicAndBounded() {
    let noise = ValueNoise1D(seed: 9)
    for step in 0..<500 {
        let t = Float(step) * 0.173
        let value = noise.value(at: t)
        #expect(value == noise.value(at: t))
        #expect(value >= -1 && value <= 1)
    }
}

@Test func valueNoiseIsContinuous() {
    let noise = ValueNoise1D(seed: 3)
    for step in 0..<300 {
        let t = Float(step) * 0.31
        let delta = abs(noise.value(at: t + 0.001) - noise.value(at: t))
        #expect(delta < 0.02)
    }
}

@Test func fbmStaysBounded() {
    let noise = ValueNoise1D(seed: 11)
    for step in 0..<300 {
        let value = noise.fbm(at: Float(step) * 0.21, octaves: 3)
        #expect(value >= -1 && value <= 1)
    }
}

// MARK: - Springs & envelopes

@Test func springConvergesToTarget() {
    var spring = SpringDamper(value: 0, frequency: 2, dampingRatio: 1)
    for _ in 0..<300 {
        spring.step(toward: 1, deltaTime: 1.0 / 60.0)
    }
    #expect(abs(spring.value - 1) < 0.01)
}

@Test func springSurvivesHugeDeltaTime() {
    var spring = SpringDamper(value: 0, frequency: 3, dampingRatio: 0.5)
    spring.step(toward: 1, deltaTime: 10)
    #expect(spring.value.isFinite)
    #expect(abs(spring.value - 1) < 0.5)
}

@Test func underdampedSpringOvershoots() {
    var spring = SpringDamper(value: 0, frequency: 2, dampingRatio: 0.3)
    var maxValue: Float = 0
    for _ in 0..<300 {
        maxValue = max(maxValue, spring.step(toward: 1, deltaTime: 1.0 / 60.0))
    }
    #expect(maxValue > 1.05)
}

@Test func envelopeAttacksFasterThanItReleases() {
    var envelope = AttackReleaseEnvelope(value: 0, attack: 0.03, release: 0.2)
    var attackTime: Float = 0
    while envelope.value < 0.9 && attackTime < 2 {
        envelope.step(toward: 1, deltaTime: 1.0 / 60.0)
        attackTime += 1.0 / 60.0
    }
    var releaseTime: Float = 0
    while envelope.value > 0.1 && releaseTime < 2 {
        envelope.step(toward: 0, deltaTime: 1.0 / 60.0)
        releaseTime += 1.0 / 60.0
    }
    #expect(attackTime < releaseTime)
}

// MARK: - Interpolation

@Test func smoothstepClampsAndInterpolates() {
    #expect(Interpolation.smoothstep(0, 1, -1) == 0)
    #expect(Interpolation.smoothstep(0, 1, 2) == 1)
    #expect(abs(Interpolation.smoothstep(0, 1, 0.5) - 0.5) < 0.001)
}

@Test func remapMapsRanges() {
    #expect(abs(Interpolation.remap(5, from: 0...10, to: 0...1) - 0.5) < 0.001)
    #expect(Interpolation.remap(-5, from: 0...10, to: 0...1) == 0)
}

// MARK: - Mesh

@Test func gridMeshHasExpectedTopology() {
    let mesh = DeformableMesh.grid(rect: CGRect(x: 10, y: 20, width: 100, height: 50), columns: 4, rows: 3)
    #expect(mesh.vertexCount == 5 * 4)
    #expect(mesh.indices.count == 4 * 3 * 6)
    #expect(mesh.uvs.first == SIMD2<Float>(0, 0))
    #expect(mesh.uvs.last == SIMD2<Float>(1, 1))
    #expect(mesh.vertices.first == SIMD2<Float>(10, 20))
    #expect(mesh.vertices.last == SIMD2<Float>(110, 70))
    for index in mesh.indices {
        #expect(Int(index) < mesh.vertexCount)
    }
}

@Test func renderProjectionContractMatchesImageSpacePerspectiveAndAspectFit() {
    let contract = RenderProjectionContract(imageWidth: 200, imageHeight: 100)
    #expect(contract.center == SIMD2<Float>(100, 50))
    #expect(abs(contract.cameraDistance - 635) < 0.000_1)
    #expect(abs(contract.depthRange - 800) < 0.000_1)

    let vertex = SIMD3<Float>(150, 50, 100)
    let projected = contract.project(vertex, zBias: contract.zBias(forDrawOrderIndex: 2))
    let expectedPerspective: Float = 635 / 535
    #expect(abs(projected.x - (100 + 50 * expectedPerspective)) < 0.000_1)
    #expect(abs(projected.y - 50) < 0.000_1)
    #expect(abs(projected.z - (0.5 - 100 / 800 - 0.016)) < 0.000_1)

    let fit = contract.aspectFit(drawableSize: SIMD2<Float>(400, 400))
    #expect(abs(fit.scale.x - 0.01) < 0.000_1)
    #expect(abs(fit.scale.y + 0.01) < 0.000_1)
    #expect(abs(fit.offset.x + 1) < 0.000_1)
    #expect(abs(fit.offset.y - 0.5) < 0.000_1)
}

// MARK: - Parameters

@Test func parameterValuesResolveDefaults() {
    let values = ParameterValues(descriptors: StandardParameters.all)
    let resolved = values.resolved()
    #expect(resolved[.eyeLeftOpen] == 1)
    #expect(resolved[.mouthOpen] == 0)
}

@Test func additionsStackAndClamp() {
    var values = ParameterValues(descriptors: StandardParameters.all)
    values.add(.angleX, 20)
    values.add(.angleX, 20)
    #expect(values.resolved()[.angleX] == 30) // clamped to descriptor max
}

@Test func overrideReplacesBaseButKeepsAdditions() {
    var values = ParameterValues(descriptors: StandardParameters.all)
    values.override(.eyeLeftOpen, 0.5)
    values.add(.eyeLeftOpen, -0.2)
    #expect(abs(values.resolved()[.eyeLeftOpen]! - 0.3) < 0.0001)
}

@Test func parameterValuesIgnoreNonFiniteContributions() {
    var values = ParameterValues(descriptors: StandardParameters.all)
    values.add(.angleX, .nan)
    values.add(.angleY, .infinity)
    values.override(.mouthOpen, -.infinity)
    values.add(ParameterID(rawValue: "custom.tail"), .nan)

    let resolved = values.resolved()
    #expect(resolved[.angleX] == 0)
    #expect(resolved[.angleY] == 0)
    #expect(resolved[.mouthOpen] == 0)
    #expect(resolved[ParameterID(rawValue: "custom.tail")] == nil)
    #expect(resolved.values.allSatisfy { $0.isFinite })
}

@Test func unknownParametersPassThrough() {
    var values = ParameterValues(descriptors: StandardParameters.all)
    values.override(ParameterID(rawValue: "custom.tail"), 3)
    #expect(values.resolved()[ParameterID(rawValue: "custom.tail")] == 3)
}

@Test func clearRemovesContributions() {
    var values = ParameterValues(descriptors: StandardParameters.all)
    values.add(.angleX, 10)
    values.clear()
    #expect(values.resolved()[.angleX] == 0)
}
