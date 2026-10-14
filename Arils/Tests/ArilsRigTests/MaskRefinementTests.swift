import Foundation
import simd
import Testing

@testable import ArilsRig
@testable import ArilsRigPortable

/// Synthetic scenes for `SubjectMaskBoundaryRefinement`: each fixes one way
/// the Vision blob is wrong (or must be left alone).

private let side = 600

private func image(
    background: (Int, Int) -> SIMD3<Float>,
    paint: (Int, Int) -> SIMD3<Float>?
) -> Bitmap {
    var bitmap = Bitmap(width: side, height: side)
    for y in 0..<side {
        for x in 0..<side {
            let color = paint(x, y) ?? background(x, y)
            bitmap.setRGBA(x: x, y: y, SIMD4(color.x, color.y, color.z, 1))
        }
    }
    return bitmap
}

private func rectMask(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> FloatPlane {
    var mask = FloatPlane(width: side, height: side)
    for y in y0..<y1 {
        for x in x0..<x1 { mask[x, y] = 1 }
    }
    return mask
}

private let paper = SIMD3<Float>(0.99, 0.99, 0.98)
private let line = SIMD3<Float>(0.35, 0.38, 0.5)
private let strand = SIMD3<Float>(0.85, 0.87, 0.93)

@Test func backgroundBetweenStrandsIsCutOut() {
    // Vertical strands (outlined) with paper showing between them; Vision's
    // blob covers the whole hair mass including the gaps.
    let hair = image(background: { _, _ in paper }) { x, y in
        guard (200..<400).contains(x), (200..<500).contains(y) else { return nil }
        let phase = (x - 200) % 14
        if phase == 0 || phase == 7 { return line }
        if phase < 7 { return strand }
        return nil
    }
    let blob = rectMask(185, 185, 415, 515)
    let result = SubjectMaskBoundaryRefinement.refine(blob, image: hair)

    #expect(result.accepted)
    #expect(result.mask[195, 300] == 0) // blob margin outside the strands
    #expect(result.mask[210, 205] == 0) // gap between strands near the edge
    #expect(result.mask[203, 205] == 1) // strand itself
    #expect(result.edgeAlignmentAfter > result.edgeAlignmentBefore)
}

@Test func undercutSubjectColorNeverKeysTheFlood() {
    // Vision undercuts a flat coat by 2 px on one side: the pixels just
    // outside its edge are coat, not background. The coat must stay whole.
    let orange = SIMD3<Float>(0.8, 0.45, 0.3)
    let coat = SIMD3<Float>(0.5, 0.55, 0.7)
    let scene = image(background: { _, _ in orange }) { x, y in
        guard (200..<400).contains(x), (150..<450).contains(y) else { return nil }
        if x < 202 || x >= 398 || y < 152 || y >= 448 { return line }
        return coat
    }
    let undercut = rectMask(190, 140, 396, 460)
    let result = SubjectMaskBoundaryRefinement.refine(undercut, image: scene)

    #expect(result.mask[390, 300] == 1)
    #expect(result.mask[300, 300] == 1)
    #expect(result.mask[194, 300] == 0) // the blob's background margin goes
}

@Test func busyBackgroundsAreLeftToVision() {
    var rng = SystemRandomNumberGenerator()
    var noise = [SIMD3<Float>](repeating: .zero, count: side * side)
    for index in noise.indices {
        noise[index] = SIMD3(
            Float.random(in: 0.2...0.8, using: &rng),
            Float.random(in: 0.2...0.8, using: &rng),
            Float.random(in: 0.2...0.8, using: &rng)
        )
    }
    let scene = image(background: { x, y in noise[y * side + x] }) { x, y in
        (200..<400).contains(x) && (200..<400).contains(y) ? coatColor : nil
    }
    let blob = rectMask(190, 190, 410, 410)
    let result = SubjectMaskBoundaryRefinement.refine(blob, image: scene)

    #expect(!result.accepted)
    #expect(result.mask.values == blob.values)
}

private let coatColor = SIMD3<Float>(0.5, 0.55, 0.7)

@Test func paleSubjectWithoutLinesIsNotHollowed() {
    // Pale skin close to the paper color and no outline: the flood can enter,
    // but where it stops there is no drawn edge, so the region is a leak.
    let pale = SIMD3<Float>(0.975, 0.975, 0.97)
    let scene = image(background: { _, _ in paper }) { x, y in
        (200..<400).contains(x) && (150..<450).contains(y) ? pale : nil
    }
    let exact = rectMask(200, 150, 400, 450)
    let result = SubjectMaskBoundaryRefinement.refine(exact, image: scene)

    #expect(result.mask[205, 300] == 1)
    #expect(result.mask[300, 300] == 1)
}

@Test func enclosedBackgroundPocketsAreRemovedButTinyOnesKept() {
    // A loop of hair encloses paper near the silhouette; a second, tiny loop
    // encloses a speck too small to matter (and too risky to judge).
    func ring(_ x: Int, _ y: Int, cx: Int, cy: Int, inner: Int, outer: Int) -> Bool {
        let d = (x - cx) * (x - cx) + (y - cy) * (y - cy)
        return d >= inner * inner && d <= outer * outer
    }
    let scene = image(background: { _, _ in paper }) { x, y in
        if ring(x, y, cx: 222, cy: 300, inner: 8, outer: 12) { return line }
        if ring(x, y, cx: 222, cy: 400, inner: 2, outer: 6) { return line }
        if (236..<400).contains(x), (150..<450).contains(y) { return line }
        return nil
    }
    let blob = rectMask(208, 140, 410, 460)
    let result = SubjectMaskBoundaryRefinement.refine(blob, image: scene)

    #expect(result.mask[222, 300] == 0) // pocket inside the big loop
    #expect(result.mask[222, 400] == 1) // speck inside the tiny loop
    #expect(result.mask[222, 290] == 1) // the loop itself
}

@Test func visionMasksAreRefinedByDefault() {
    #expect(VisionSubjectMaskProvider().refinesBoundary)
    #expect(!VisionSubjectMaskProvider(refinesBoundary: false).refinesBoundary)
}
