import CoreGraphics
import Foundation
import ImageIO

import ArilsRig

private struct CorpusManifest: Decodable {
    var version: Int
    var minimumBoundaryPrecisionForAcceptance: Float?
    var entries: [CorpusEntry]
}

private struct CorpusEntry: Decodable {
    var id: String
    var image: String
    var faceLayout: FaceLayoutRecord
}

private struct CreateMLCorpusEntry: Decodable {
    var image: String
    var annotations: [CreateMLAnnotation]
    var excluded: Bool?
}

private struct CreateMLAnnotation: Decodable {
    var label: String
    var coordinates: CreateMLCoordinates
}

private struct CreateMLCoordinates: Decodable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var rect: RectRecord {
        RectRecord(
            x: x - width * 0.5,
            y: y - height * 0.5,
            width: width,
            height: height
        )
    }
}

private struct FaceLayoutRecord: Decodable {
    var headRect: RectRecord
    var eyeLeftRect: RectRecord
    var eyeRightRect: RectRecord
    var mouthRect: RectRecord

    var layout: FaceLayout {
        FaceLayout(
            headRect: headRect.rect,
            eyeLeftRect: eyeLeftRect.rect,
            eyeRightRect: eyeRightRect.rect,
            mouthRect: mouthRect.rect,
            confidence: 1
        )
    }
}

private struct RectRecord: Decodable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct CorpusRow {
    var id: String
    var image: String
    var status: String
    var autoAccepted: Bool
    var falseAccepted: Bool
    var autoBuildEligible: Bool
    var autoApprovalRate: Float?
    var falseApprovalRate: Float?
    var falseApprovalRateUpper95: Float?
    var autoBuildRate: Float?
    var boundaryPrecision: Float
    var faceConfidence: Float?
    var reviewConfidence: Float?
    var reviewIssues: String
    var metrics: RigIntegrityMetrics
    var validationDisposition: RigValidationDisposition
    var limits: ValidatedPoseLimits
    var safetyLimits: ValidatedPoseLimits
    var error: String

    var csv: String {
        [
            Self.escaped(id),
            Self.escaped(image),
            Self.escaped(status),
            autoAccepted ? "1" : "0",
            falseAccepted ? "1" : "0",
            autoBuildEligible ? "1" : "0",
            autoApprovalRate.map(Self.number) ?? "",
            falseApprovalRate.map(Self.number) ?? "",
            falseApprovalRateUpper95.map(Self.number) ?? "",
            autoBuildRate.map(Self.number) ?? "",
            Self.number(boundaryPrecision),
            faceConfidence.map(Self.number) ?? "",
            reviewConfidence.map(Self.number) ?? "",
            Self.escaped(reviewIssues),
            String(metrics.meshInversionCount),
            String(metrics.nonFiniteVertexCount),
            Self.number(metrics.holeArea),
            Self.number(metrics.ghostArea),
            Self.number(metrics.unknownExposure),
            validationDisposition.rawValue,
            Self.number(limits.minimumYawDegrees),
            Self.number(limits.maximumYawDegrees),
            Self.number(limits.minimumPitchDegrees),
            Self.number(limits.maximumPitchDegrees),
            Self.number(safetyLimits.minimumYawDegrees),
            Self.number(safetyLimits.maximumYawDegrees),
            Self.number(safetyLimits.minimumPitchDegrees),
            Self.number(safetyLimits.maximumPitchDegrees),
            Self.escaped(error),
        ].joined(separator: ",")
    }

    static let header = [
        "id",
        "image",
        "status",
        "autoAccepted",
        "falseAccepted",
        "autoBuildEligible",
        "autoApprovalRate",
        "falseApprovalRate",
        "falseApprovalRateUpper95",
        "autoBuildRate",
        "boundaryPrecision",
        "faceConfidence",
        "reviewConfidence",
        "reviewIssues",
        "meshInversionCount",
        "nonFiniteVertexCount",
        "holeArea",
        "ghostArea",
        "unknownExposure",
        "validationDisposition",
        "minimumYawDegrees",
        "maximumYawDegrees",
        "minimumPitchDegrees",
        "maximumPitchDegrees",
        "safetyMinimumYawDegrees",
        "safetyMaximumYawDegrees",
        "safetyMinimumPitchDegrees",
        "safetyMaximumPitchDegrees",
        "error",
    ].joined(separator: ",")

    private static func number(_ value: Float) -> String {
        value.isFinite ? String(format: "%.6f", value) : ""
    }

    private static func escaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

@main
private enum ArilsCorpusCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--pilot" {
            await runPilot()
            return
        }
        guard let manifestArgument = arguments.first, !manifestArgument.hasPrefix("-") else {
            emitSkip(reason: "manifest path was not supplied")
            return
        }

        let manifestURL = URL(fileURLWithPath: manifestArgument).standardizedFileURL
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            emitSkip(reason: "manifest not found: \(manifestURL.path)")
            return
        }

        do {
            let manifest = try JSONDecoder().decode(
                CorpusManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard manifest.version == 1 else {
                emitSkip(reason: "unsupported manifest version: \(manifest.version)")
                return
            }
            let minimumPrecision = manifest.minimumBoundaryPrecisionForAcceptance ?? 0.75
            let baseURL = manifestURL.deletingLastPathComponent()
            let rows = await evaluate(
                manifest.entries,
                baseURL: baseURL,
                minimumPrecision: minimumPrecision
            )
            printReport(rows)
        } catch {
            emitSkip(reason: "manifest unreadable: \(error)")
        }
    }

    private static func runPilot() async {
        do {
            let annotationsURL = try pilotAnnotationsURL()
            let records = try JSONDecoder().decode(
                [CreateMLCorpusEntry].self,
                from: Data(contentsOf: annotationsURL)
            )
            let entries = try records.filter { $0.excluded != true }.map(pilotEntry)
            let rows = await evaluate(
                entries,
                baseURL: annotationsURL.deletingLastPathComponent(),
                minimumPrecision: 0.75
            )
            printReport(rows)
        } catch {
            emitSkip(reason: "pilot corpus unavailable: \(error)")
        }
    }

    private static func pilotEntry(_ record: CreateMLCorpusEntry) throws -> CorpusEntry {
        let boxes = Dictionary(uniqueKeysWithValues: record.annotations.map {
            ($0.label, $0.coordinates.rect)
        })
        guard let head = boxes["head"],
              let eyeLeft = boxes["eyeLeft"],
              let eyeRight = boxes["eyeRight"],
              let mouth = boxes["mouth"] else {
            throw CorpusError.incompletePilotAnnotation(record.image)
        }
        return CorpusEntry(
            id: URL(fileURLWithPath: record.image).deletingPathExtension().lastPathComponent,
            image: "images/\(record.image)",
            faceLayout: FaceLayoutRecord(
                headRect: head,
                eyeLeftRect: eyeLeft,
                eyeRightRect: eyeRight,
                mouthRect: mouth
            )
        )
    }

    private static func pilotAnnotationsURL() throws -> URL {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
        for _ in 0..<8 {
            let nested = directory.appendingPathComponent("Arils_Dataset/annotations.json")
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
            let direct = directory.appendingPathComponent("annotations.json")
            let images = directory.appendingPathComponent("images", isDirectory: true)
            if FileManager.default.fileExists(atPath: direct.path),
               FileManager.default.fileExists(atPath: images.path) {
                return direct
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        throw CorpusError.pilotAnnotationsNotFound
    }

    private static func evaluate(
        _ entries: [CorpusEntry],
        baseURL: URL,
        minimumPrecision: Float
    ) async -> [CorpusRow] {
        let pipeline = AutoRigPipeline()
        var rows: [CorpusRow] = []
        rows.reserveCapacity(entries.count)

        for entry in entries {
            let imageURL = URL(fileURLWithPath: entry.image, relativeTo: baseURL).standardizedFileURL
            do {
                let image = try loadImage(at: imageURL)
                let prepared = try await pipeline.prepare(image: image)
                let proposal = try await pipeline.faceLayoutProposal(from: prepared)
                let precision = boundaryPrecision(
                    predicted: proposal.layout,
                    expected: entry.faceLayout.layout,
                    imageWidth: image.width,
                    imageHeight: image.height
                )
                let autoAccepted = !proposal.review.requiresReview
                let falseAccepted = autoAccepted && precision < minimumPrecision
                let avatar = try await pipeline.makeAvatar(
                    from: prepared,
                    faceLayout: proposal.layout
                )
                let alphaCoverage = avatar.textures.reduce(
                    into: [String: FloatPlane]()
                ) { result, element in
                    if let bitmap = Bitmap(image: element.value) {
                        result[element.key] = bitmap.alphaPlane()
                    }
                }
                let validation = PoseSweepValidator.validate(
                    rig: avatar.rig,
                    plan: .supportedHead,
                    alphaCoverageByPartID: alphaCoverage
                )
                let worst = validation.metricsByPose.values.reduce(
                    into: RigIntegrityMetrics()
                ) { result, metrics in
                    result.meshInversionCount = max(
                        result.meshInversionCount,
                        metrics.meshInversionCount
                    )
                    result.nonFiniteVertexCount = max(
                        result.nonFiniteVertexCount,
                        metrics.nonFiniteVertexCount
                    )
                    result.holeArea = max(result.holeArea, metrics.holeArea)
                    result.ghostArea = max(result.ghostArea, metrics.ghostArea)
                    result.unknownExposure = max(
                        result.unknownExposure,
                        metrics.unknownExposure
                    )
                }
                rows.append(CorpusRow(
                    id: entry.id,
                    image: entry.image,
                    status: "evaluated",
                    autoAccepted: autoAccepted,
                    falseAccepted: falseAccepted,
                    autoBuildEligible: autoAccepted
                        && worstDisposition(validation.dispositionsByPose.values) == .accepted,
                    autoApprovalRate: nil,
                    falseApprovalRate: nil,
                    falseApprovalRateUpper95: nil,
                    autoBuildRate: nil,
                    boundaryPrecision: precision,
                    faceConfidence: proposal.layout.confidence,
                    reviewConfidence: proposal.review.confidence,
                    reviewIssues: proposal.review.issues.map(\.rawValue).joined(separator: ";"),
                    metrics: worst,
                    validationDisposition: worstDisposition(
                        validation.dispositionsByPose.values
                    ),
                    limits: validation.validatedPoseLimits,
                    safetyLimits: validation.safetyPoseLimits,
                    error: ""
                ))
            } catch {
                rows.append(CorpusRow(
                    id: entry.id,
                    image: entry.image,
                    status: "error",
                    autoAccepted: false,
                    falseAccepted: false,
                    autoBuildEligible: false,
                    autoApprovalRate: nil,
                    falseApprovalRate: nil,
                    falseApprovalRateUpper95: nil,
                    autoBuildRate: nil,
                    boundaryPrecision: 0,
                    faceConfidence: nil,
                    reviewConfidence: nil,
                    reviewIssues: "",
                    metrics: RigIntegrityMetrics(),
                    validationDisposition: .rejected,
                    limits: .legacyDefault,
                    safetyLimits: .legacyDefault,
                    error: String(describing: error)
                ))
            }
        }
        return rows
    }

    private static func printReport(_ rows: [CorpusRow]) {
        print(CorpusRow.header)
        rows.forEach { print($0.csv) }

        let evaluated = rows.filter { $0.status == "evaluated" }
        let accepted = evaluated.filter(\.autoAccepted)
        let falseAccepted = accepted.filter(\.falseAccepted)
        let buildEligible = evaluated.filter(\.autoBuildEligible)
        let evaluatedCount = Float(evaluated.count)
        let acceptedCount = Float(accepted.count)
        let meanBoundary = evaluated.isEmpty ? 0 : evaluated.reduce(Float.zero) {
            $0 + $1.boundaryPrecision
        } / evaluatedCount
        let worst = evaluated.reduce(into: RigIntegrityMetrics()) { result, row in
            result.meshInversionCount = max(
                result.meshInversionCount,
                row.metrics.meshInversionCount
            )
            result.nonFiniteVertexCount = max(
                result.nonFiniteVertexCount,
                row.metrics.nonFiniteVertexCount
            )
            result.holeArea = max(result.holeArea, row.metrics.holeArea)
            result.ghostArea = max(result.ghostArea, row.metrics.ghostArea)
            result.unknownExposure = max(
                result.unknownExposure,
                row.metrics.unknownExposure
            )
        }
        let summary = CorpusRow(
            id: "__summary__",
            image: "",
            status: "evaluated=\(evaluated.count);errors=\(rows.count - evaluated.count)",
            autoAccepted: false,
            falseAccepted: false,
            autoBuildEligible: false,
            autoApprovalRate: evaluated.isEmpty
                ? nil
                : Float(accepted.count) / evaluatedCount,
            falseApprovalRate: accepted.isEmpty
                ? nil
                : Float(falseAccepted.count) / acceptedCount,
            falseApprovalRateUpper95: accepted.isEmpty
                ? nil
                : wilsonUpper95(successes: falseAccepted.count, trials: accepted.count),
            autoBuildRate: evaluated.isEmpty
                ? nil
                : Float(buildEligible.count) / evaluatedCount,
            boundaryPrecision: meanBoundary,
            faceConfidence: nil,
            reviewConfidence: nil,
            reviewIssues: "",
            metrics: worst,
            validationDisposition: worstDisposition(evaluated.map(\.validationDisposition)),
            limits: .legacyDefault,
            safetyLimits: .legacyDefault,
            error: ""
        )
        print(summary.csv)
    }

    private static func emitSkip(reason: String) {
        print(CorpusRow.header)
        print(CorpusRow(
            id: "__summary__",
            image: "",
            status: "skipped",
            autoAccepted: false,
            falseAccepted: false,
            autoBuildEligible: false,
            autoApprovalRate: nil,
            falseApprovalRate: nil,
            falseApprovalRateUpper95: nil,
            autoBuildRate: nil,
            boundaryPrecision: 0,
            faceConfidence: nil,
            reviewConfidence: nil,
            reviewIssues: "",
            metrics: RigIntegrityMetrics(),
            validationDisposition: .rejected,
            limits: ValidatedPoseLimits(
                minimumYawDegrees: 0,
                maximumYawDegrees: 0,
                minimumPitchDegrees: 0,
                maximumPitchDegrees: 0
            ),
            safetyLimits: ValidatedPoseLimits(
                minimumYawDegrees: 0,
                maximumYawDegrees: 0,
                minimumPitchDegrees: 0,
                maximumPitchDegrees: 0
            ),
            error: reason
        ).csv)
    }

    private static func worstDisposition<S: Sequence>(
        _ dispositions: S
    ) -> RigValidationDisposition where S.Element == RigValidationDisposition {
        var result = RigValidationDisposition.accepted
        for disposition in dispositions {
            if disposition == .rejected { return .rejected }
            if disposition == .requiresReview { result = .requiresReview }
        }
        return result
    }

    private static func wilsonUpper95(successes: Int, trials: Int) -> Float? {
        guard trials > 0 else { return nil }
        let z = 1.959_964
        let n = Double(trials)
        let p = Double(successes) / n
        let denominator = 1 + z * z / n
        let center = (p + z * z / (2 * n)) / denominator
        let margin = z * sqrt((p * (1 - p) + z * z / (4 * n)) / n) / denominator
        return Float(min(1, center + margin))
    }

    private static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CorpusError.imageUnreadable(url.path)
        }
        return image
    }

    /// Precision of predicted face-rectangle boundaries at a tolerance scaled
    /// to the source image diagonal. Ground truth comes from manual review.
    private static func boundaryPrecision(
        predicted: FaceLayout,
        expected: FaceLayout,
        imageWidth: Int,
        imageHeight: Int
    ) -> Float {
        let tolerance = max(
            2,
            hypot(Float(imageWidth), Float(imageHeight)) * 0.015
        )
        let pairs = [
            (predicted.headRect, expected.headRect),
            (predicted.eyeLeftRect, expected.eyeLeftRect),
            (predicted.eyeRightRect, expected.eyeRightRect),
            (predicted.mouthRect, expected.mouthRect),
        ]
        let scores = pairs.map {
            rectangleBoundaryPrecision(
                predicted: $0.0,
                expected: $0.1,
                tolerance: CGFloat(tolerance)
            )
        }
        return scores.reduce(0, +) / Float(max(1, scores.count))
    }

    private static func rectangleBoundaryPrecision(
        predicted: CGRect,
        expected: CGRect,
        tolerance: CGFloat
    ) -> Float {
        guard !predicted.isNull, predicted.width > 0, predicted.height > 0,
              !expected.isNull, expected.width > 0, expected.height > 0 else {
            return 0
        }
        let sampleCount = 16
        var matches = 0
        var total = 0
        for index in 0..<sampleCount {
            let t = CGFloat(index) / CGFloat(sampleCount - 1)
            let points = [
                CGPoint(x: predicted.minX + predicted.width * t, y: predicted.minY),
                CGPoint(x: predicted.minX + predicted.width * t, y: predicted.maxY),
                CGPoint(x: predicted.minX, y: predicted.minY + predicted.height * t),
                CGPoint(x: predicted.maxX, y: predicted.minY + predicted.height * t),
            ]
            for point in points {
                total += 1
                if distanceToBoundary(point, of: expected) <= tolerance {
                    matches += 1
                }
            }
        }
        return Float(matches) / Float(max(1, total))
    }

    private static func distanceToBoundary(_ point: CGPoint, of rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let outsideDistance = hypot(point.x - clampedX, point.y - clampedY)
        if outsideDistance > 0 { return outsideDistance }
        return min(
            min(point.x - rect.minX, rect.maxX - point.x),
            min(point.y - rect.minY, rect.maxY - point.y)
        )
    }
}

private enum CorpusError: Error, CustomStringConvertible {
    case imageUnreadable(String)
    case incompletePilotAnnotation(String)
    case pilotAnnotationsNotFound

    var description: String {
        switch self {
        case let .imageUnreadable(path):
            "image unreadable: \(path)"
        case let .incompletePilotAnnotation(image):
            "pilot annotation is incomplete: \(image)"
        case .pilotAnnotationsNotFound:
            "Arils_Dataset/annotations.json was not found in this directory or its parents"
        }
    }
}
