import CoreGraphics
import Foundation
import Testing

import ArilsCore
import ArilsPlayer

private func eye(kind: PartKind = .eyeLeft, parameter: ParameterID = .eyeLeftOpen) -> AvatarPart {
    let rect = CGRect(x: 10, y: 10, width: 20, height: 10)
    return AvatarPart(
        id: "eye", kind: kind, parentID: "head", rect: rect, zOrder: 30,
        mesh: .grid(rect: rect, columns: 4, rows: 4),
        deformations: [.scale(parameter: parameter, pivot: SIMD2(0.5, 0.55), gainX: 0.06, gainY: 0.92)]
    )
}

@Test func openAndSleepyEyesKeepFullOpacity() {
    #expect(BlinkFade.multiplier(openness: 1) == 1)
    #expect(BlinkFade.multiplier(openness: 1.2) == 1)
    // Other layers lower the base to about 0.65 for a sleepy look.
    #expect(BlinkFade.multiplier(openness: 0.65) == 1)
}

@Test func closingEyesFadeToALightLine() {
    let closed = BlinkFade.multiplier(openness: 0)
    #expect(abs(closed - BlinkFade.closedOpacity) < 1e-6)
    let half = BlinkFade.multiplier(openness: 0.2)
    #expect(half > closed && half < 1)
    // Monotonic: more open never draws fainter.
    var previous: Float = 0
    for step in 0...40 {
        let value = BlinkFade.multiplier(openness: Float(step) / 40)
        #expect(value >= previous)
        previous = value
    }
    #expect(BlinkFade.multiplier(openness: .nan) == 1)
}

@Test func onlyAutomaticEyesFade() {
    #expect(BlinkFade.parameter(for: eye()) == .eyeLeftOpen)
    #expect(BlinkFade.parameter(for: eye(kind: .eyeRight, parameter: .eyeRightOpen)) == .eyeRightOpen)
    // A mouth scaled by its own parameter, or an eye without a blink scale, is left alone.
    #expect(BlinkFade.parameter(for: eye(kind: .mouth, parameter: .mouthOpen)) == nil)
    var still = eye()
    still.deformations = []
    #expect(BlinkFade.parameter(for: still) == nil)

    let opacity = BlinkFade.opacity(base: 0.8, parameter: .eyeLeftOpen, parameters: [.eyeLeftOpen: 0])
    #expect(abs(opacity - 0.8 * BlinkFade.closedOpacity) < 1e-6)
    #expect(BlinkFade.opacity(base: 0.8, parameter: .eyeLeftOpen, parameters: [:]) == 0.8)
    #expect(BlinkFade.opacity(base: 0.8, parameter: nil, parameters: [.eyeLeftOpen: 0]) == 0.8)
}
