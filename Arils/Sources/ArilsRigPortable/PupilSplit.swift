#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(simd)
import simd
#endif

/// Splits a cut eye layer so the iris can move inside the eye instead of the
/// whole eye sliding over the face.
///
/// Three layers come out, drawn back to front:
/// - `white`: the eye opening with the iris painted over by the white of the
///   eye on either side of it, row by row;
/// - `iris`: the iris column band of the opening, which follows the gaze;
/// - `overlay`: the original eye cut with the iris and the visible white made
///   transparent, so lashes, lid lines and the skin around the eye stay put
///   and the iris slides *under* them.
///
/// At rest the three layers recompose the original pixels exactly: every
/// pixel the overlay drops is drawn, unchanged, by one of the layers below.
/// The iris never needs clipping either. It can only show through the
/// overlay's transparent part, which lies inside the opening, and the opaque
/// lids and skin around it cover it wherever it slides past.
///
/// Built from the six eyelid landmarks (upper lid three, lower lid three).
/// Returns nil whenever the eye does not look like "an iris with white on
/// its sides": too little white (the iris fills the eye), a pale iris that
/// reads as white, closed or tiny eyes. The caller then keeps moving the
/// whole eye as before.
public struct PupilSplit: Sendable {
    public var white: Bitmap
    public var iris: Bitmap
    public var overlay: Bitmap
    /// How far the iris moves at full gaze (eyeBall ±1), in source pixels.
    public var travel: SIMD2<Float>

    /// Fraction of the iris width the iris travels at full gaze.
    static let horizontalTravel: Float = 0.28
    /// Fraction of the iris height it travels at full vertical gaze. Small:
    /// the lids cover most of a vertical move anyway.
    static let verticalTravel: Float = 0.05
    static let minimumOpeningWidth = 20
    /// White columns added to each side of the iris band; its fade lies
    /// entirely inside them.
    static let bandPadding = 2

    /// - Parameters:
    ///   - eyeLayer: the cut eye layer, cropped at `origin` in the source.
    ///   - origin: source pixel of the layer's top-left corner.
    ///   - landmarks: upper lid (3) then lower lid (3), source pixels.
    public static func split(eyeLayer: Bitmap, origin: SIMD2<Int>, landmarks: [CGPoint]) -> PupilSplit? {
        guard landmarks.count == 6,
              landmarks.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              eyeLayer.width >= 8, eyeLayer.height >= 6 else { return nil }
        let width = eyeLayer.width
        let height = eyeLayer.height

        // The opening: a smooth closed curve through the six lid points.
        let local = landmarks.map {
            CGPoint(x: $0.x - CGFloat(origin.x), y: $0.y - CGFloat(origin.y))
        }
        let upper = local[0..<3].sorted { $0.x < $1.x }
        let lower = local[3..<6].sorted { $0.x > $1.x }
        let opening = EyeShape(
            outline: EyeShape.closedCatmullRom(Array(upper) + Array(lower), samplesPerSegment: 8),
            feather: 1
        )
        var inside = [Bool](repeating: false, count: width * height)
        var openingCount = 0
        for y in 0..<height {
            for x in 0..<width where eyeLayer.alpha(x: x, y: y) > 0.9
                && opening.signedDistance(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5) > 0 {
                inside[y * width + x] = true
                openingCount += 1
            }
        }
        guard openingCount >= 24 else { return nil }

        let luminance = (0..<(width * height)).map { eyeLayer.luminance(x: $0 % width, y: $0 / width) }
        let saturation = (0..<(width * height)).map { eyeLayer.saturation(x: $0 % width, y: $0 / width) }
        let openingLuminance = inside.indices.filter { inside[$0] }.map { luminance[$0] }.sorted()
        func percentile(_ p: Float) -> Float {
            openingLuminance[min(openingLuminance.count - 1, Int(Float(openingLuminance.count - 1) * p))]
        }

        // Lid bands: the dark lash line along the top of the opening, and the
        // lower lid line along its bottom, stay with the overlay so they do not
        // ride along with the iris.
        let lashLuminance = min(0.38, percentile(0.12) + 0.12)
        var lid = [Bool](repeating: false, count: width * height)
        var columnTop = [Int](repeating: -1, count: width)
        var columnBottom = [Int](repeating: -1, count: width)
        for x in 0..<width {
            let rows = (0..<height).filter { inside[$0 * width + x] }
            guard let top = rows.first, let bottom = rows.last else { continue }
            columnTop[x] = top
            columnBottom[x] = bottom
            let span = bottom - top + 1
            let topCap = max(1, Int(Float(span) * 0.25))
            var y = top
            while y <= bottom, y - top < topCap,
                  y - top < 1 || luminance[y * width + x] < lashLuminance {
                lid[y * width + x] = true
                y += 1
            }
            let bottomCap = max(1, Int(Float(span) * 0.15))
            y = bottom
            while y >= top, bottom - y < bottomCap,
                  bottom - y < 1 || luminance[y * width + x] < lashLuminance {
                lid[y * width + x] = true
                y -= 1
            }
        }

        // The white of the eye: bright and nearly grey, relative to this eye
        // (a shaded or tinted sclera is still the brightest grey in it), and
        // reachable from the eye's corners. Highlights and pale patches inside
        // the iris are just as white but enclosed by iris, so the corner
        // flood leaves them with the iris they belong to.
        let whiteLuminance = max(0.62, percentile(0.92) - 0.18)
        var candidate = [Bool](repeating: false, count: width * height)
        var free = 0
        for i in inside.indices where inside[i] && !lid[i] {
            free += 1
            candidate[i] = luminance[i] >= whiteLuminance && saturation[i] <= 0.16
        }
        guard free >= 16 else { return nil }
        let openingColumnsForSeed = (0..<width).filter { x in (0..<height).contains { inside[$0 * width + x] } }
        guard let seedLeft = openingColumnsForSeed.first, let seedRight = openingColumnsForSeed.last else { return nil }
        let cornerReach = max(1, (seedRight - seedLeft + 1) / 4)
        var white = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for i in candidate.indices where candidate[i] {
            let x = i % width
            if x < seedLeft + cornerReach || x > seedRight - cornerReach {
                white[i] = true
                stack.append(i)
            }
        }
        while let i = stack.popLast() {
            let x = i % width
            let y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let n = ny * width + nx
                if candidate[n], !white[n] {
                    white[n] = true
                    stack.append(n)
                }
            }
        }

        // The iris: the run of columns, around the darkest-filled column, where
        // most of the free opening is not white.
        var notWhite = [Int](repeating: 0, count: width)
        var freeCount = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard inside[i], !lid[i] else { continue }
                freeCount[x] += 1
                if !white[i] { notWhite[x] += 1 }
            }
        }
        guard let seed = (0..<width).max(by: { notWhite[$0] < notWhite[$1] }),
              notWhite[seed] > 0 else { return nil }
        func isIrisColumn(_ x: Int) -> Bool {
            freeCount[x] > 0 && Float(notWhite[x]) >= 0.45 * Float(freeCount[x])
        }
        var first = seed
        while first > 0, isIrisColumn(first - 1) { first -= 1 }
        var last = seed
        while last < width - 1, isIrisColumn(last + 1) { last += 1 }
        // A round iris covers little of its outermost columns; take a few of
        // them too while a fair share of the column is still not white. Only
        // a few: further out the same rule would walk into the corner shade.
        func touchesIris(_ x: Int) -> Bool {
            freeCount[x] > 0 && Float(notWhite[x]) >= 0.12 * Float(freeCount[x])
        }
        let rim = max(2, (last - first + 1) * 12 / 100)
        let coreFirst = first
        let coreLast = last
        while first > 0, coreFirst - first < rim, touchesIris(first - 1) { first -= 1 }
        while last < width - 1, last - coreLast < rim, touchesIris(last + 1) { last += 1 }
        // Columns of white on each side, so the moving band's edges are
        // white over white and can fade out there.
        first = max(0, first - bandPadding)
        last = min(width - 1, last + bandPadding)

        let openingColumns = (0..<width).filter { columnTop[$0] >= 0 }
        guard let openingLeft = openingColumns.first, let openingRight = openingColumns.last else { return nil }
        let openingWidth = openingRight - openingLeft + 1
        let irisWidth = last - first + 1
        // Below about twenty pixels the iris is a handful of pixels wide and
        // its moving edges read as blocks rather than as an eye looking aside.
        guard openingWidth >= minimumOpeningWidth,
              irisWidth >= max(3, openingWidth / 5), irisWidth <= openingWidth * 85 / 100 else { return nil }

        // Inside the iris columns everything moves, lash rows included: a
        // static lash band there would leave the iris's dark top behind as a
        // step. Outside them the lid bands stay with the overlay and cover
        // the iris's lash rows wherever it slides.
        var irisMask = [Bool](repeating: false, count: width * height)
        var visibleWhite = 0
        var irisTop = height
        var irisBottom = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard inside[i] else { continue }
                if x >= first, x <= last {
                    irisMask[i] = true
                    if !lid[i] {
                        irisTop = min(irisTop, y)
                        irisBottom = max(irisBottom, y)
                    }
                }
                // Counted against the iris itself, not the padded band: the
                // padding is white the iris can move into.
                if white[i], !lid[i], x < coreFirst || x > coreLast {
                    visibleWhite += 1
                }
            }
        }
        // Without white beside the iris there is nothing to reveal: moving
        // it would only expose paint.
        guard Float(visibleWhite) >= 0.06 * Float(free), irisBottom >= irisTop else { return nil }

        // What the iris covered, row by row: the opening's pixels just left
        // and right of the iris, blended across. On lash rows that continues
        // the lash line, on the middle rows the white, on the bottom the lid.
        var rowEnds = [(SIMD4<Float>?, SIMD4<Float>?)](repeating: (nil, nil), count: height)
        for y in 0..<height {
            func nearest(from start: Int, step: Int) -> SIMD4<Float>? {
                var x = start
                while x >= 0, x < width {
                    if inside[y * width + x] { return eyeLayer.rgba(x: x, y: y) }
                    x += step
                }
                return nil
            }
            rowEnds[y] = (nearest(from: first - 1, step: -1), nearest(from: last + 1, step: 1))
        }
        // Rows where the opening lies wholly inside the iris columns (the very
        // top and bottom) borrow the nearest row that has an edge.
        let rowsWithEnds = (0..<height).filter { rowEnds[$0].0 != nil || rowEnds[$0].1 != nil }
        guard !rowsWithEnds.isEmpty else { return nil }

        var whiteLayer = Bitmap(width: width, height: height)
        var irisLayer = Bitmap(width: width, height: height)
        var overlay = eyeLayer
        for y in 0..<height {
            let source = rowsWithEnds.min { abs($0 - y) < abs($1 - y) }!
            let (left, right) = rowEnds[source]
            for x in 0..<width {
                let i = y * width + x
                guard inside[i] else { continue }
                let pixel = eyeLayer.rgba(x: x, y: y)
                if irisMask[i] {
                    // The band's outer columns are white on white; fading them
                    // keeps its sides from showing as straight lines as it moves.
                    let edge = Float(min(x - first, last - x) + 1) / Float(bandPadding + 1)
                    irisLayer.setRGBA(x: x, y: y, pixel * min(1, edge))
                    let t = Float(x - first + 1) / Float(irisWidth + 1)
                    let fill: SIMD4<Float>
                    switch (left, right) {
                    case let (l?, r?): fill = l + (r - l) * t
                    case let (l?, nil): fill = l
                    case let (nil, r?): fill = r
                    case (nil, nil): fill = pixel
                    }
                    whiteLayer.setRGBA(x: x, y: y, fill)
                    overlay.setRGBA(x: x, y: y, .zero)
                } else {
                    whiteLayer.setRGBA(x: x, y: y, pixel)
                    if white[i], !lid[i] {
                        overlay.setRGBA(x: x, y: y, .zero)
                    }
                }
            }
        }

        return PupilSplit(
            white: whiteLayer,
            iris: irisLayer,
            overlay: overlay,
            travel: SIMD2(
                Float(irisWidth) * horizontalTravel,
                Float(irisBottom - irisTop + 1) * verticalTravel
            )
        )
    }
}
