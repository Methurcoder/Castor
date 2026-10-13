import AppKit
import Foundation
import Vision

public protocol ScreenshotTextRecognizing: Sendable {
    func recognizeText(in imageURL: URL) async throws -> String
}

public struct VisionTextRecognizer: ScreenshotTextRecognizing {
    public let recognitionLanguages: [String]

    public init(recognitionLanguages: [String] = ["ja-JP", "en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognizeText(in imageURL: URL) async throws -> String {
        let languages = recognitionLanguages
        return try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: imageURL),
                  let imageData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: imageData),
                  let cgImage = bitmap.cgImage else {
                throw ScreenshotAnswerError.unreadableImage
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            let observations = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return OCRLine(text: text, box: observation.boundingBox)
            }

            let text = OCRReadingOrder.lines(from: observations)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ScreenshotAnswerError.noTextFound }
            return text
        }.value
    }
}

struct OCRLine: Sendable, Equatable {
    let text: String
    let box: CGRect
}

enum OCRReadingOrder {
    static func lines(from observations: [OCRLine]) -> [String] {
        observations
            .sorted { left, right in
                let verticalTolerance = max(left.box.height, right.box.height) * 0.45
                if abs(left.box.midY - right.box.midY) <= verticalTolerance {
                    return left.box.minX < right.box.minX
                }
                return left.box.midY > right.box.midY
            }
            .map(\.text)
    }
}
