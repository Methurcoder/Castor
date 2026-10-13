import CoreGraphics
import Foundation

import ArilsCore

/// Heuristic face-layout estimator tuned for anime/illustration characters,
/// where Apple Vision's photo-trained face detection usually fails.
///
/// Strategy (all on the ~256 px analysis bitmap):
/// 1. **Head from silhouette** — the head is the top lobe of the subject mask.
///    Scan the mask's per-row width profile downward for the neck pinch (a
///    clear local minimum that widens again at the shoulders).
/// 2. **Eyes from contrast** — anime eyes are the highest-contrast, most
///    saturated features in the face band. Score = edge energy × (darkness ∨
///    saturation); the two dominant peaks of the blurred score density seed
///    local weighted-centroid refinement. Peak-seeking (rather than splitting
///    at the mask centroid) keeps working when the face is drawn slightly
///    turned and both eyes sit off-center under a trailing hair mass.
/// 3. **Mouth from contrast near the face axis** (eye midpoint) below the eyes.
/// 4. Anything that scores too weak falls back to classic anime proportions,
///    lowering `confidence` so the composite can prefer another algorithm.
public struct AnimeFaceEstimator: FaceLayoutEstimating {
    public init() {}

    public func estimateLayout(context: AnalysisContext, subjectMask: FloatPlane) async -> FaceLayout? {
        let bitmap = context.analysis
        let width = bitmap.width
        let height = bitmap.height
        guard width > 8, height > 8 else { return nil }
        // Blob weights historically targeted a longest side of ~256 px. Face
        // refinement now runs at a higher resolution, so normalize accumulated
        // evidence by pixel-area scale instead of making confidence grow merely
        // because the same feature contains more pixels.
        let resolutionScale = max(1, Float(max(width, height)) / 256)
        let evidenceAreaScale = resolutionScale * resolutionScale

        // --- 1. Subject extent and per-row width profile -------------------
        var rowSpan = [ClosedRange<Int>?](repeating: nil, count: height)
        var rowWidth = [Float](repeating: 0, count: height)
        var topRow = -1
        var bottomRow = -1
        for y in 0..<height {
            var minX = Int.max
            var maxX = Int.min
            var coverage: Float = 0
            for x in 0..<width where subjectMask[x, y] > 0.5 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                coverage += 1
            }
            if coverage > Float(width) * 0.01 {
                rowSpan[y] = minX...maxX
                rowWidth[y] = coverage
                if topRow < 0 { topRow = y }
                bottomRow = y
            }
        }
        guard topRow >= 0, bottomRow > topRow + 8 else { return nil }
        let subjectHeight = bottomRow - topRow

        // Smooth the width profile so pixel noise doesn't fake a neck pinch.
        var smoothWidth = rowWidth
        for y in 0..<height {
            var sum: Float = 0
            var count: Float = 0
            for offset in -2...2 {
                let yy = y + offset
                guard yy >= 0, yy < height else { continue }
                sum += rowWidth[yy]
                count += 1
            }
            smoothWidth[y] = sum / max(1, count)
        }

        // --- 2. Neck pinch: local minimum that flares again below ----------
        let nonemptyWidths = smoothWidth[topRow...bottomRow].filter { $0 > 0 }.sorted()
        // The single widest row is commonly a skirt hem, spread hair, cape, or
        // sleeve. Using it made visually tall full-body art look "compact" and
        // reopened the late waist-pinch failure. A high percentile still
        // represents the body mass without letting one extreme row decide.
        let representativeIndex = min(
            max(0, nonemptyWidths.count - 1),
            Int(Float(max(0, nonemptyWidths.count - 1)) * 0.75)
        )
        let representativeWidth = nonemptyWidths.isEmpty ? 1 : nonemptyWidths[representativeIndex]
        let subjectAspect = Float(subjectHeight) / max(1, representativeWidth)
        // In a tall full-body illustration, long hair often covers the real
        // neck and creates a much stronger pinch near the waist. Blend toward
        // the earlier search range instead of switching four geometry
        // constants at aspect 2.2: tiny crop/resample changes around that
        // boundary must not move the eye band by several percent at once.
        let fullBodyBlend = Self.fullBodyBlend(forSubjectAspect: subjectAspect)
        func blend(_ compact: Float, _ fullBody: Float) -> Float {
            compact + (fullBody - compact) * fullBodyBlend
        }
        let neckSearchEndFraction = blend(0.60, 0.38)
        let fallbackHeadFraction = blend(0.45, 0.32)
        let searchTop = topRow + Int(0.15 * Float(subjectHeight))
        let searchBottom = topRow + Int(neckSearchEndFraction * Float(subjectHeight))
        var neckY = -1
        var bestPinchScore: Float = 0
        var maxWidthAbove: Float = 0
        for y in topRow...min(searchBottom, bottomRow) {
            maxWidthAbove = max(maxWidthAbove, smoothWidth[y])
            guard y >= searchTop else { continue }
            let widthHere = smoothWidth[y]
            guard widthHere > 0, widthHere < maxWidthAbove * 0.9 else { continue }
            // Look for shoulder flare within 20% of subject height below.
            let flareEnd = min(bottomRow, y + Int(0.2 * Float(subjectHeight)))
            var maxBelow: Float = 0
            for yy in y...flareEnd {
                maxBelow = max(maxBelow, smoothWidth[yy])
            }
            let pinch = (maxWidthAbove - widthHere) / maxWidthAbove
            let flare = (maxBelow - widthHere) / max(1, maxWidthAbove)
            let score = pinch + flare
            if flare > 0.08, score > bestPinchScore {
                bestPinchScore = score
                neckY = y
            }
        }
        var headConfidence: Float = 0.55
        if neckY < 0 {
            // No visible neck (bust crop, chin resting on frame edge, ...):
            // assume the head takes the classic ~45% of the visible subject.
            neckY = topRow + Int(fallbackHeadFraction * Float(subjectHeight))
            headConfidence = 0.3
        }

        // --- 3. Head rect: mask extent over the head rows -------------------
        var headMinX = Int.max
        var headMaxX = Int.min
        for y in topRow...max(topRow, neckY) {
            guard let span = rowSpan[y] else { continue }
            headMinX = min(headMinX, span.lowerBound)
            headMaxX = max(headMaxX, span.upperBound)
        }
        guard headMaxX > headMinX else { return nil }
        let headRect = CGRect(
            x: CGFloat(headMinX),
            y: CGFloat(topRow),
            width: CGFloat(headMaxX - headMinX + 1),
            height: CGFloat(neckY - topRow)
        )
        guard headRect.width > 4, headRect.height > 4 else { return nil }

        // Symmetry axis: mask centroid over head rows.
        var axisSum: Float = 0
        var axisWeight: Float = 0
        for y in topRow...neckY {
            guard let span = rowSpan[y] else { continue }
            let center = Float(span.lowerBound + span.upperBound) / 2
            let weight = rowWidth[y]
            axisSum += center * weight
            axisWeight += weight
        }
        let axisX = axisWeight > 0 ? axisSum / axisWeight : Float(headRect.midX)

        // --- 4. Feature scoring planes --------------------------------------
        let luminance = bitmap.luminancePlane()
        let saturation = bitmap.saturationPlane()
        let edges = luminance.boxBlurred(radius: 1).gradientMagnitude()

        func featureScore(x: Int, y: Int) -> Float {
            guard subjectMask[x, y] > 0.5 else { return 0 }
            let contrast = edges[x, y]
            let darkness = 1 - luminance[x, y]
            let vivid = saturation[x, y]
            return contrast * (0.35 + 0.65 * max(darkness, vivid))
        }

        // --- 5. Eyes: symmetric high-contrast blobs in the eye band ---------
        let silhouetteHeadH = Float(headRect.height)
        let silhouetteHeadW = Float(headRect.width)
        // First pass uses the silhouette-derived ROI. Once a reliable eye pair
        // exists, these are reduced to a face-scale estimate and the local eye
        // refinement plus mouth search run again on that scale. `headRect`
        // itself remains the hair/neck search region returned to the pipeline.
        var featureHeadH = silhouetteHeadH
        var featureHeadW = silhouetteHeadW
        // Clamp both ends so a head touching the frame bottom can't form an
        // invalid ClosedRange below.
        let eyeBandTopFraction = blend(0.40, 0.34)
        let eyeBandBottomFraction = blend(0.78, 0.70)
        let eyeBandTop = min(height - 1, topRow + Int(eyeBandTopFraction * silhouetteHeadH))
        let eyeBandBottom = min(height - 1, topRow + Int(eyeBandBottomFraction * silhouetteHeadH))
        let insetX = Int(0.10 * silhouetteHeadW)

        struct Blob {
            var weight: Float = 0
            var sumX: Float = 0
            var sumY: Float = 0
            var sumXX: Float = 0
            var sumYY: Float = 0
            mutating func accumulate(x: Int, y: Int, score: Float) {
                weight += score
                sumX += Float(x) * score
                sumY += Float(y) * score
                sumXX += Float(x) * Float(x) * score
                sumYY += Float(y) * Float(y) * score
            }
            var centerX: Float { weight > 0 ? sumX / weight : 0 }
            var centerY: Float { weight > 0 ? sumY / weight : 0 }
            var spreadX: Float {
                guard weight > 0 else { return 0 }
                return sqrt(max(0, sumXX / weight - centerX * centerX))
            }
            var spreadY: Float {
                guard weight > 0 else { return 0 }
                return sqrt(max(0, sumYY / weight - centerY * centerY))
            }
        }

        // Pass 1: the two dominant compact contrast clusters in the eye band.
        // Peak-seeking on a blurred score density instead of a centroid split
        // at the mask axis, for two reasons: (a) on a slightly turned face the
        // mask centroid sits inside the hair mass, so an axis split lumps both
        // eyes into one half; (b) blurring dilutes thin hair edges while an
        // eye-sized blob keeps its mass, so peaks land on eyes, not on hair
        // streaks. Hair contrast still pollutes the spread, so a second pass
        // restricted to a window around each seed re-estimates center and
        // size from local pixels only.
        let columnLo = headMinX + insetX
        let columnHi = max(columnLo, headMaxX - insetX)
        var scorePlane = FloatPlane(width: width, height: height)
        if eyeBandBottom > eyeBandTop {
            for y in eyeBandTop...eyeBandBottom {
                for x in columnLo...columnHi {
                    let score = featureScore(x: x, y: y)
                    if score > 0.02 { scorePlane[x, y] = score }
                }
            }
        }
        let density = scorePlane.boxBlurred(radius: max(2, Int(0.05 * featureHeadW)))

        struct Peak {
            var point: SIMD2<Int>
            var value: Float
        }

        func bestEyePeakPair() -> (SIMD2<Int>, SIMD2<Int>)? {
            guard eyeBandBottom > eyeBandTop else { return nil }
            var ranked: [Peak] = []
            ranked.reserveCapacity((eyeBandBottom - eyeBandTop + 1) * (columnHi - columnLo + 1))
            for y in eyeBandTop...eyeBandBottom {
                for x in columnLo...columnHi {
                    let value = density[x, y]
                    if value > 0 { ranked.append(Peak(point: SIMD2(x, y), value: value)) }
                }
            }
            ranked.sort { $0.value > $1.value }
            guard let strongest = ranked.first, strongest.value > 0 else { return nil }

            // Non-maximum suppression keeps one representative per compact
            // feature instead of filling the candidate list with adjacent
            // pixels from the strongest eye or highlight.
            let suppressionRadius = max(2, 0.09 * featureHeadW)
            var candidates: [Peak] = []
            for peak in ranked {
                guard peak.value >= strongest.value * 0.18 else { break }
                let isSeparate = candidates.allSatisfy { existing in
                    let dx = Float(peak.point.x - existing.point.x)
                    let dy = Float(peak.point.y - existing.point.y)
                    return sqrt(dx * dx + dy * dy) >= suppressionRadius
                }
                if isSeparate { candidates.append(peak) }
                if candidates.count == 12 { break }
            }
            guard candidates.count >= 2 else { return nil }

            var bestPair: (Peak, Peak)?
            var bestScore: Float = -.infinity
            for firstIndex in 0..<(candidates.count - 1) {
                for secondIndex in (firstIndex + 1)..<candidates.count {
                    let first = candidates[firstIndex]
                    let second = candidates[secondIndex]
                    let left = first.point.x <= second.point.x ? first : second
                    let right = first.point.x <= second.point.x ? second : first
                    let separation = Float(right.point.x - left.point.x)
                    let verticalDifference = abs(Float(right.point.y - left.point.y))
                    guard separation >= 0.12 * featureHeadW,
                          separation <= 0.62 * featureHeadW,
                          verticalDifference <= 0.14 * featureHeadH else { continue }

                    let densityScore = (left.value + right.value) / (2 * strongest.value)
                    let heightScore = 1 - verticalDifference / max(1, 0.14 * featureHeadH)
                    let separationScore = 1 - min(
                        1,
                        abs(separation - 0.30 * featureHeadW) / max(1, 0.24 * featureHeadW)
                    )
                    let midpoint = Float(left.point.x + right.point.x) / 2
                    let axisScore = 1 - min(
                        1,
                        abs(midpoint - axisX) / max(1, 0.35 * featureHeadW)
                    )
                    let score = densityScore * 0.45
                        + heightScore * 0.25
                        + separationScore * 0.15
                        + axisScore * 0.15
                    if score > bestScore {
                        bestScore = score
                        bestPair = (left, right)
                    }
                }
            }
            guard let bestPair else { return nil }
            return (bestPair.0.point, bestPair.1.point)
        }

        func bandBlob(around seed: SIMD2<Int>, xBounds: ClosedRange<Int>) -> Blob {
            var blob = Blob()
            let radiusX = Int(0.16 * featureHeadW)
            let radiusY = Int(0.12 * featureHeadH)
            for y in max(eyeBandTop, seed.y - radiusY)...min(eyeBandBottom, seed.y + radiusY) {
                let minX = max(xBounds.lowerBound, seed.x - radiusX)
                let maxX = min(xBounds.upperBound, seed.x + radiusX)
                guard maxX >= minX else { continue }
                for x in minX...maxX {
                    let score = featureScore(x: x, y: y)
                    guard score > 0.02 else { continue }
                    blob.accumulate(x: x, y: y, score: score)
                }
            }
            return blob
        }

        var leftBlob = Blob()
        var rightBlob = Blob()
        let maskSplitX = min(columnHi, max(columnLo, Int(axisX)))
        var leftBounds = columnLo...maskSplitX
        var rightBounds = min(columnHi, maskSplitX + 1)...columnHi
        var foundEyePeakPair = false
        if let (leftSeed, rightSeed) = bestEyePeakPair() {
            foundEyePeakPair = true
            let splitX = (leftSeed.x + rightSeed.x) / 2
            leftBounds = columnLo...max(columnLo, splitX)
            rightBounds = min(columnHi, splitX + 1)...columnHi
            leftBlob = bandBlob(around: leftSeed, xBounds: leftBounds)
            rightBlob = bandBlob(around: rightSeed, xBounds: rightBounds)
        } else if eyeBandBottom > eyeBandTop {
            // Degenerate contrast (a single cluster, or none): fall back to
            // the frontal assumption and split at the mask axis.
            for y in eyeBandTop...eyeBandBottom {
                for x in columnLo...columnHi {
                    let score = featureScore(x: x, y: y)
                    guard score > 0.02 else { continue }
                    if Float(x) < axisX {
                        leftBlob.accumulate(x: x, y: y, score: score)
                    } else {
                        rightBlob.accumulate(x: x, y: y, score: score)
                    }
                }
            }
        }

        func refined(
            _ blob: Blob,
            windowRadiusX: Float,
            windowRadiusY: Float,
            xBounds: ClosedRange<Int>? = nil
        ) -> Blob {
            guard blob.weight > 0 else { return blob }
            var result = Blob()
            let minY = max(0, Int(blob.centerY - windowRadiusY))
            let maxY = min(height - 1, Int(blob.centerY + windowRadiusY))
            let minX = max(xBounds?.lowerBound ?? 0, Int(blob.centerX - windowRadiusX))
            let maxX = min(xBounds?.upperBound ?? (width - 1), Int(blob.centerX + windowRadiusX))
            guard maxY >= minY, maxX >= minX else { return blob }
            for y in minY...maxY {
                for x in minX...maxX {
                    let score = featureScore(x: x, y: y)
                    guard score > 0.02 else { continue }
                    result.accumulate(x: x, y: y, score: score)
                }
            }
            return result.weight > 0 ? result : blob
        }

        leftBlob = refined(
            leftBlob,
            windowRadiusX: 0.16 * featureHeadW,
            windowRadiusY: 0.12 * featureHeadH,
            xBounds: leftBounds
        )
        rightBlob = refined(
            rightBlob,
            windowRadiusX: 0.16 * featureHeadW,
            windowRadiusY: 0.12 * featureHeadH,
            xBounds: rightBounds
        )

        func templateEyeRect(offset: Float) -> CGRect {
            CGRect(
                x: CGFloat(axisX + offset * featureHeadW - 0.11 * featureHeadW),
                y: CGFloat(Float(topRow) + 0.52 * featureHeadH),
                width: CGFloat(0.22 * featureHeadW),
                height: CGFloat(0.13 * featureHeadH)
            )
        }

        func eyeRect(from blob: Blob, fallbackOffset: Float) -> (CGRect, Float) {
            let minWidth = 0.09 * featureHeadW
            let maxWidth = 0.24 * featureHeadW
            let normalizedWeight = blob.weight / evidenceAreaScale
            if normalizedWeight > 0.5 {
                let eyeWidth = Interpolation.clamp(blob.spreadX * 2.8, minWidth...maxWidth)
                let eyeHeight = Interpolation.clamp(
                    blob.spreadY * 2.8,
                    0.06 * featureHeadH...0.15 * featureHeadH
                )
                let rect = CGRect(
                    x: CGFloat(blob.centerX - eyeWidth / 2),
                    y: CGFloat(blob.centerY - eyeHeight / 2),
                    width: CGFloat(eyeWidth),
                    height: CGFloat(eyeHeight)
                )
                return (rect, min(1, normalizedWeight / 8))
            }
            // Template: classic anime eye placement.
            return (templateEyeRect(offset: fallbackOffset), 0.1)
        }

        var (eyeLeft, eyeLeftConfidence) = eyeRect(from: leftBlob, fallbackOffset: -0.19)
        var (eyeRight, eyeRightConfidence) = eyeRect(from: rightBlob, fallbackOffset: 0.19)

        // Sanity: eyes should sit at a similar height and not overlap the axis
        // by much; otherwise fall back to symmetric placement of the better eye.
        func alignEyeHeightsIfNeeded() {
            let verticalMismatch = abs(eyeLeft.midY - eyeRight.midY)
            if verticalMismatch > CGFloat(0.14 * featureHeadH) {
                if eyeLeftConfidence >= eyeRightConfidence {
                    eyeRight.origin.y = eyeLeft.origin.y
                    eyeRightConfidence *= 0.7
                } else {
                    eyeLeft.origin.y = eyeRight.origin.y
                    eyeLeftConfidence *= 0.7
                }
            }
        }

        // A pair of independently plausible blobs can still be the same eye
        // or two highlights in one hair mass. Reject the pair unless its final
        // geometry resembles two distinct eyes. Falling back to proportions is
        // safer than cutting overlapping eye textures out of the neck or hair.
        func eyePairIsPlausible() -> Bool {
            let horizontalSeparation = eyeRight.midX - eyeLeft.midX
            let overlap = eyeLeft.intersection(eyeRight)
            let smallerEyeArea = min(eyeLeft.width * eyeLeft.height, eyeRight.width * eyeRight.height)
            let overlapRatio = overlap.isNull || smallerEyeArea <= 0
                ? 0
                : overlap.width * overlap.height / smallerEyeArea
            let widthRatio = max(eyeLeft.width, eyeRight.width) / max(1, min(eyeLeft.width, eyeRight.width))
            return horizontalSeparation >= CGFloat(0.12 * featureHeadW)
                && horizontalSeparation <= CGFloat(0.62 * featureHeadW)
                && overlapRatio <= 0.08
                && widthRatio <= 2.4
        }

        alignEyeHeightsIfNeeded()
        var pairIsPlausible = eyePairIsPlausible()

        // Pass 2: the silhouette includes hair, ribbons, or a hat, while the
        // eye separation is a direct measurement of the face. A sufficiently
        // supported pair lets us infer a smaller face scale, then repeat the
        // local refinement with windows and output bounds derived from it.
        if pairIsPlausible, foundEyePeakPair {
            let firstPass = (eyeLeft, eyeRight, eyeLeftConfidence, eyeRightConfidence)
            let originalFeatureScale = (featureHeadW, featureHeadH)
            let inferred = Self.inferredFeatureScale(
                silhouetteWidth: silhouetteHeadW,
                silhouetteHeight: silhouetteHeadH,
                eyeSeparation: abs(Float(eyeRight.midX - eyeLeft.midX))
            )
            if inferred.width < featureHeadW - 0.5 || inferred.height < featureHeadH - 0.5 {
                featureHeadW = inferred.width
                featureHeadH = inferred.height
                leftBlob = refined(
                    leftBlob,
                    windowRadiusX: 0.16 * featureHeadW,
                    windowRadiusY: 0.12 * featureHeadH,
                    xBounds: leftBounds
                )
                rightBlob = refined(
                    rightBlob,
                    windowRadiusX: 0.16 * featureHeadW,
                    windowRadiusY: 0.12 * featureHeadH,
                    xBounds: rightBounds
                )
                (eyeLeft, eyeLeftConfidence) = eyeRect(from: leftBlob, fallbackOffset: -0.19)
                (eyeRight, eyeRightConfidence) = eyeRect(from: rightBlob, fallbackOffset: 0.19)
                alignEyeHeightsIfNeeded()
                pairIsPlausible = eyePairIsPlausible()
                if !pairIsPlausible {
                    // A noisy provisional pair must not make the second pass
                    // worse. Restore the valid silhouette-scale result.
                    featureHeadW = originalFeatureScale.0
                    featureHeadH = originalFeatureScale.1
                    (eyeLeft, eyeRight, eyeLeftConfidence, eyeRightConfidence) = firstPass
                    pairIsPlausible = true
                }
            }
        }

        if !pairIsPlausible {
            eyeLeft = templateEyeRect(offset: -0.19)
            eyeRight = templateEyeRect(offset: 0.19)
            eyeLeftConfidence = min(eyeLeftConfidence, 0.1)
            eyeRightConfidence = min(eyeRightConfidence, 0.1)
        }
        let eyeConfidence = (eyeLeftConfidence + eyeRightConfidence) / 2

        // --- 6. Mouth: contrast blob near the axis below the eyes -----------
        // The face axis, not the mask axis: on a turned face the mouth sits
        // under the midpoint of the eyes, while the mask centroid is pulled
        // toward the hair mass.
        let faceAxisX = eyeConfidence > 0.15
            ? Float(eyeLeft.midX + eyeRight.midX) / 2
            : axisX
        let eyesBottom = max(eyeLeft.maxY, eyeRight.maxY)
        let eyesMidY = Float(eyeLeft.midY + eyeRight.midY) / 2
        let eyeSeparation = abs(Float(eyeRight.midX - eyeLeft.midX))
        // Hair, hats, and long side locks can make the silhouette height much
        // larger than the actual face. Basing the vertical offset primarily on
        // the eye separation keeps the expected mouth on the face instead of
        // drifting down to a choker or sailor collar.
        let mouthOffset = Interpolation.clamp(
            0.52 * eyeSeparation,
            0.07 * featureHeadH...0.19 * featureHeadH
        )
        let expectedMouthY = eyesMidY + mouthOffset
        let mouthSearchRadiusY = max(2, 0.055 * featureHeadH)
        let mouthTop = min(
            height - 1,
            max(
                Int(eyesBottom) + Int(0.01 * featureHeadH),
                Int(expectedMouthY - mouthSearchRadiusY)
            )
        )
        let mouthBottom = min(
            height - 1,
            min(topRow + Int(0.88 * featureHeadH), Int(expectedMouthY + mouthSearchRadiusY))
        )
        let mouthHalfSpan = Int(0.16 * featureHeadW)
        let mouthXLo = max(0, Int(faceAxisX) - mouthHalfSpan)
        let mouthXHi = min(width - 1, Int(faceAxisX) + mouthHalfSpan)
        let shapeProbeHalfSpan = max(mouthHalfSpan, Int(0.40 * featureHeadW))
        let shapeXLo = max(0, Int(faceAxisX) - shapeProbeHalfSpan)
        let shapeXHi = min(width - 1, Int(faceAxisX) + shapeProbeHalfSpan)
        func rawMouthFeatureScore(x: Int, y: Int) -> Float {
            let base = featureScore(x: x, y: y)
            // Color is only a weak cue. A black line-art mouth must not receive
            // the old 0.35 multiplier while a saturated collar keeps 1.0.
            let pixel = bitmap.rgba(x: x, y: y)
            let warmth = max(0, pixel.x - max(pixel.y, pixel.z))
            let colorEvidence = max(saturation[x, y], min(1, warmth * 3))
            return base * (0.80 + 0.20 * colorEvidence)
        }
        var rawMouthScorePlane = FloatPlane(width: width, height: height)
        var mouthScorePlane = FloatPlane(width: width, height: height)
        if mouthBottom > mouthTop {
            for y in mouthTop...mouthBottom {
                for x in shapeXLo...shapeXHi {
                    let score = rawMouthFeatureScore(x: x, y: y)
                    if score > 0.02 { rawMouthScorePlane[x, y] = score }
                }
            }

            // Mouth lines are compact. Collar/choker/band edges often remain a
            // single contrast ridge beyond ±0.16 face widths. Measure each
            // horizontal run on a wider probe range and suppress the broad
            // runs before blurring, independent of hue.
            let broadRunStart = max(4, Int(0.32 * featureHeadW))
            let broadRunEnd = max(broadRunStart + 1, Int(0.55 * featureHeadW))
            for y in mouthTop...mouthBottom {
                var x = shapeXLo
                while x <= shapeXHi {
                    while x <= shapeXHi, rawMouthScorePlane[x, y] <= 0.02 {
                        x += 1
                    }
                    guard x <= shapeXHi else { break }
                    let runStart = x
                    while x <= shapeXHi, rawMouthScorePlane[x, y] > 0.02 {
                        x += 1
                    }
                    let runEnd = x - 1
                    let runLength = runEnd - runStart + 1
                    let broadness = Interpolation.smoothstep(
                        Float(broadRunStart),
                        Float(broadRunEnd),
                        Float(runLength)
                    )
                    let continuityWeight = 1 - 0.85 * broadness
                    let candidateStart = max(runStart, mouthXLo)
                    let candidateEnd = min(runEnd, mouthXHi)
                    guard candidateEnd >= candidateStart else { continue }
                    for candidateX in candidateStart...candidateEnd {
                        let raw = rawMouthScorePlane[candidateX, y]
                        let mirroredX = Int((2 * faceAxisX - Float(candidateX)).rounded())
                        let mirrored = mirroredX >= shapeXLo && mirroredX <= shapeXHi
                            ? rawMouthScorePlane[mirroredX, y]
                            : 0
                        let symmetry = min(raw, mirrored) / max(0.0001, max(raw, mirrored))
                        let symmetryWeight = 0.72 + 0.28 * symmetry
                        mouthScorePlane[candidateX, y] = raw
                            * continuityWeight
                            * symmetryWeight
                    }
                }
            }
        }
        let mouthDensity = mouthScorePlane.boxBlurred(radius: max(1, Int(0.025 * featureHeadW)))
        var mouthSeed: SIMD2<Int>?
        var bestMouthSeedScore: Float = 0
        if mouthBottom > mouthTop {
            for y in mouthTop...mouthBottom {
                let verticalPrior = 1 - min(1, abs(Float(y) - expectedMouthY) / mouthSearchRadiusY)
                for x in mouthXLo...mouthXHi {
                    let axisPrior = 1 - min(
                        1,
                        abs(Float(x) - faceAxisX) / max(1, 0.20 * featureHeadW)
                    )
                    let score = mouthDensity[x, y]
                        * (0.10 + 0.90 * verticalPrior)
                        * (0.45 + 0.55 * axisPrior)
                    if score > bestMouthSeedScore {
                        bestMouthSeedScore = score
                        mouthSeed = SIMD2(x, y)
                    }
                }
            }
        }

        var mouthBlob = Blob()
        if let mouthSeed {
            let localRadiusX = max(2, Int(0.08 * featureHeadW))
            let localRadiusY = max(2, Int(0.035 * featureHeadH))
            for y in max(mouthTop, mouthSeed.y - localRadiusY)...min(mouthBottom, mouthSeed.y + localRadiusY) {
                for x in max(0, mouthSeed.x - localRadiusX)...min(width - 1, mouthSeed.x + localRadiusX) {
                    let score = mouthScorePlane[x, y]
                    guard score > 0.02 else { continue }
                    mouthBlob.accumulate(x: x, y: y, score: score)
                }
            }
        }

        var mouthConfidence: Float = 0.1
        let fallbackMouthWidth = 0.12 * featureHeadW
        let fallbackMouthHeight = 0.04 * featureHeadH
        var mouthRect = CGRect(
            x: CGFloat(faceAxisX - fallbackMouthWidth / 2),
            y: CGFloat(expectedMouthY - fallbackMouthHeight / 2),
            width: CGFloat(fallbackMouthWidth),
            height: CGFloat(fallbackMouthHeight)
        )
        let mouthCenterIsPlausible = abs(mouthBlob.centerX - faceAxisX) <= 0.16 * featureHeadW
            && abs(mouthBlob.centerY - expectedMouthY) <= mouthSearchRadiusY * 0.85
        let normalizedMouthWeight = mouthBlob.weight / evidenceAreaScale
        if normalizedMouthWeight > 0.3, mouthCenterIsPlausible {
            let mouthWidth = Interpolation.clamp(
                mouthBlob.spreadX * 2.8,
                0.05 * featureHeadW...0.15 * featureHeadW
            )
            let mouthHeight = Interpolation.clamp(
                mouthBlob.spreadY * 2.8,
                0.02 * featureHeadH...0.055 * featureHeadH
            )
            mouthRect = CGRect(
                x: CGFloat(mouthBlob.centerX - mouthWidth / 2),
                y: CGFloat(mouthBlob.centerY - mouthHeight / 2),
                width: CGFloat(mouthWidth),
                height: CGFloat(mouthHeight)
            )
            mouthConfidence = min(1, normalizedMouthWeight / 5)
        }

        let confidence = Interpolation.clamp(
            headConfidence * (0.5 + 0.35 * eyeConfidence + 0.15 * mouthConfidence),
            0...1
        )

        return FaceLayout(
            headRect: headRect,
            eyeLeftRect: eyeLeft,
            eyeRightRect: eyeRight,
            mouthRect: mouthRect,
            confidence: confidence
        ).scaled(by: context.scaleToOriginal)
    }

    static func fullBodyBlend(forSubjectAspect subjectAspect: Float) -> Float {
        Interpolation.smoothstep(2.0, 2.4, subjectAspect)
    }

    static func inferredFeatureScale(
        silhouetteWidth: Float,
        silhouetteHeight: Float,
        eyeSeparation: Float
    ) -> (width: Float, height: Float) {
        guard eyeSeparation > 0 else {
            return (silhouetteWidth, silhouetteHeight)
        }
        // A conservative anime-face prior: the eye centers span about 38% of
        // the visible face width, and the usable face height is slightly
        // larger. Never enlarge the silhouette-derived search region.
        return (
            min(silhouetteWidth, eyeSeparation * 2.6),
            min(silhouetteHeight, eyeSeparation * 2.8)
        )
    }
}
