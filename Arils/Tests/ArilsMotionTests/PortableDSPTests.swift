#if canImport(Accelerate)
import Accelerate
import Foundation
import Testing

@testable import ArilsMotion

/// The non-Apple lip-sync path must match the Accelerate one it replaces.
@Test func portableWindowAndBinPowerMatchAccelerate() throws {
    let count = 1024
    let accelerated = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: count, isHalfWindow: false)
    let portable = LipSyncAnalyzer.portableHannWindow(count: count)
    #expect(zip(accelerated, portable).allSatisfy { abs($0 - $1) < 1e-5 })

    let signal = (0..<count).map { n in
        sin(2 * Float.pi * 440 * Float(n) / 48_000) + 0.3 * sin(2 * Float.pi * 2_500 * Float(n) / 48_000)
    }
    let windowed = zip(signal, accelerated).map { $0 * $1 }
    let dft = try #require(try? vDSP.DiscreteFourierTransform(
        previous: nil, count: count, direction: .forward, transformType: .complexComplex, ofType: Float.self))
    let (real, imaginary) = dft.transform(real: windowed, imaginary: [Float](repeating: 0, count: count))
    for bin in [2, 9, 10, 53, 54, 106] {
        let expected = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
        let actual = LipSyncAnalyzer.portableBinPower(windowed, bin: bin)
        #expect(abs(expected - actual) <= max(1e-3, expected * 1e-3))
    }
}
#endif
