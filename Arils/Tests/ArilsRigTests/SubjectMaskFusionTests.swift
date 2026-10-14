import Foundation
import Testing

@testable import ArilsRig
@testable import ArilsRigPortable

private let side = 400

private func plane(_ value: (Int, Int) -> Float) -> FloatPlane {
    var result = FloatPlane(width: side, height: side)
    for y in 0..<side {
        for x in 0..<side { result[x, y] = value(x, y) }
    }
    return result
}

private func inside(_ x: Int, _ y: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Bool {
    x >= x0 && x < x1 && y >= y0 && y < y1
}

@Test func fusionTakesTheModelsOutlineInsideVisionsRegion() throws {
    // Vision: a rounded-off blob. Model: the character inside it with a gap
    // (background between strands) that Vision filled.
    let vision = plane { x, y in inside(x, y, 100, 100, 300, 300) ? 1 : 0 }
    let model = plane { x, y in
        inside(x, y, 110, 110, 290, 290) && !inside(x, y, 110, 150, 140, 170) ? 0.95 : 0.02
    }
    let fused = try #require(SubjectMaskFusion.fuse(vision: vision, model: model))
    #expect(fused.mask[200, 200] > 0.99)   // body
    #expect(fused.mask[120, 160] == 0)     // the gap Vision filled
    #expect(fused.mask[104, 200] == 0)     // Vision's rounded margin
}

@Test func fusionKeepsThinStrandsButNotSlabsOutsideVision() throws {
    let vision = plane { x, y in inside(x, y, 150, 100, 250, 300) ? 1 : 0 }
    let model = plane { x, y in
        if inside(x, y, 150, 100, 250, 300) { return 0.95 }
        if inside(x, y, 250, 150, 262, 153) { return 0.95 } // thin strand Vision cut off
        if inside(x, y, 250, 220, 268, 260) { return 0.95 } // slab: the edge of a desk
        return 0.01
    }
    let fused = try #require(SubjectMaskFusion.fuse(vision: vision, model: model))
    #expect(fused.mask[255, 151] > 0.5)
    #expect(fused.mask[258, 240] == 0)
}

@Test func fusionDeclinesWhenTheModelMissesVisionsSubject() {
    let vision = plane { x, y in inside(x, y, 100, 100, 300, 300) ? 1 : 0 }
    let model = plane { x, y in inside(x, y, 100, 100, 160, 300) ? 0.9 : 0.05 }
    #expect(SubjectMaskFusion.fuse(vision: vision, model: model) == nil)
}

@Test func probabilityIsMappedToCoverageNotUsedAsAlpha() throws {
    // "Fairly sure" (0.75) must be opaque, "unsure" (0.2) transparent.
    let vision = plane { x, y in inside(x, y, 100, 100, 300, 300) ? 1 : 0 }
    let model = plane { x, y in
        guard inside(x, y, 100, 100, 300, 300) else { return 0 }
        return x < 280 ? 0.75 : 0.2
    }
    let fused = try #require(SubjectMaskFusion.fuse(vision: vision, model: model))
    #expect(fused.mask[200, 200] == 1)
    #expect(fused.mask[290, 200] == 0)
}

@Test func modelAloneRejectsEmptyAndFullFrameAnswers() {
    #expect(SubjectMaskFusion.modelOnly(plane { _, _ in 0.01 }) == nil)
    #expect(SubjectMaskFusion.modelOnly(plane { _, _ in 0.99 }) == nil)
    let character = SubjectMaskFusion.modelOnly(plane { x, y in inside(x, y, 100, 100, 300, 300) ? 0.9 : 0.01 })
    #expect(character?[200, 200] == 1)
}
