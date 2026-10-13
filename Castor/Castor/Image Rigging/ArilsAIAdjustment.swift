import AppKit
import Arils
import Foundation
import Observation
import CastorCore

enum ArilsAIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case ollama
    case codex
    case claudeCode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollama: "Ollama"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }

    var isExternal: Bool { self != .ollama }
}

enum ArilsAIReferenceSet: String, CaseIterable, Codable, Identifiable, Sendable {
    case frontOnly
    case frontAndThreeQuarter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .frontOnly: "Front image only"
        case .frontAndThreeQuarter: "Front + three-quarter view"
        }
    }
}

struct ArilsAISettings: Codable, Equatable, Sendable {
    var provider: ArilsAIProvider = .ollama
    var referenceSet: ArilsAIReferenceSet = .frontOnly
    var useLaMa = false
}

enum ArilsAISettingsStore {
    private static let key = "Pomegranate.Arils.AISettings.v1"

    static var current: ArilsAISettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let settings = try? JSONDecoder().decode(ArilsAISettings.self, from: data) else {
                return ArilsAISettings()
            }
            return settings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }
}

struct ArilsAIAdjustmentProposal: Equatable, Sendable {
    let layout: FaceLayout
    let explanation: String
    let confidence: Double
    let provider: ArilsAIProvider
}

enum ArilsAIAdjustmentError: LocalizedError, Equatable {
    case imageEncodingFailed
    case noOllamaModel
    case invalidResponse
    case wrongOperation
    case invalidGeometry(String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            "The source image could not be prepared for AI review."
        case .noOllamaModel:
            "Start Ollama and select an installed vision-capable model first."
        case .invalidResponse:
            "The AI did not return a readable Arils alignment proposal."
        case .wrongOperation:
            "The AI response did not identify the requested Arils operation."
        case .invalidGeometry(let reason):
            "The AI proposal was rejected before preview: \(reason)"
        }
    }
}

enum ArilsAIAdjustmentParser {
    static let operation = "POME_ARILS_FACE_LAYOUT_V1"

    static func parse(
        _ response: String,
        imageSize: CGSize,
        provider: ArilsAIProvider
    ) throws -> ArilsAIAdjustmentProposal {
        let decoder = JSONDecoder()
        var decoded: ResponsePayload?
        for candidate in jsonCandidates(in: response) {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? decoder.decode(ResponsePayload.self, from: data) else {
                continue
            }
            decoded = payload
            break
        }
        guard let payload = decoded else {
            throw ArilsAIAdjustmentError.invalidResponse
        }
        guard payload.operation == operation else {
            throw ArilsAIAdjustmentError.wrongOperation
        }

        let layout = FaceLayout(
            headRect: try payload.head.pixelRect(in: imageSize, name: "head"),
            eyeLeftRect: try payload.eyeLeft.pixelRect(in: imageSize, name: "left eye"),
            eyeRightRect: try payload.eyeRight.pixelRect(in: imageSize, name: "right eye"),
            mouthRect: try payload.mouth.pixelRect(in: imageSize, name: "mouth"),
            confidence: Float(min(max(payload.confidence, 0), 1))
        )
        try validate(layout: layout, imageSize: imageSize)
        return ArilsAIAdjustmentProposal(
            layout: layout,
            explanation: String(payload.explanation.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)),
            confidence: min(max(payload.confidence, 0), 1),
            provider: provider
        )
    }

    static func validate(layout: FaceLayout, imageSize: CGSize) throws {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let namedRects = [
            ("head", layout.headRect),
            ("left eye", layout.eyeLeftRect),
            ("right eye", layout.eyeRightRect),
            ("mouth", layout.mouthRect),
        ]
        for (name, rect) in namedRects {
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width >= 2, rect.height >= 2,
                  bounds.contains(rect) else {
                throw ArilsAIAdjustmentError.invalidGeometry("\(name) is outside the image bounds.")
            }
        }

        let head = layout.headRect
        let left = CGPoint(x: layout.eyeLeftRect.midX, y: layout.eyeLeftRect.midY)
        let right = CGPoint(x: layout.eyeRightRect.midX, y: layout.eyeRightRect.midY)
        let mouth = CGPoint(x: layout.mouthRect.midX, y: layout.mouthRect.midY)
        guard head.contains(left), head.contains(right), head.contains(mouth) else {
            throw ArilsAIAdjustmentError.invalidGeometry("eyes and mouth must remain inside the head search area.")
        }
        guard left.x < right.x else {
            throw ArilsAIAdjustmentError.invalidGeometry("left and right eyes are reversed.")
        }
        guard mouth.y > (left.y + right.y) / 2 else {
            throw ArilsAIAdjustmentError.invalidGeometry("the mouth must be below the eyes.")
        }
    }

    static func requestMarkdown(
        imageSize: CGSize,
        currentLayout: FaceLayout,
        review: FaceLayoutReview
    ) -> String {
        let normalized = RequestLayout(
            head: .init(rect: currentLayout.headRect, imageSize: imageSize),
            eyeLeft: .init(rect: currentLayout.eyeLeftRect, imageSize: imageSize),
            eyeRight: .init(rect: currentLayout.eyeRightRect, imageSize: imageSize),
            mouth: .init(rect: currentLayout.mouthRect, imageSize: imageSize)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let layoutJSON = (try? encoder.encode(normalized))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let issues = review.issues.isEmpty
            ? "none"
            : review.issues.map(\.rawValue).joined(separator: ", ")

        return """
        # Castor Arils AI operation

        Operation: `\(operation)`

        Inspect `source.png`. Propose corrected rectangles for the head/neck search area,
        viewer-left eye, viewer-right eye, and mouth. Coordinates use a top-left origin and
        must be normalized to 0...1. The head rectangle is a search area: include the visible
        head, hair relevant to head motion, and the neck transition, but do not extend into the
        torso. Eye rectangles should contain the visible eye units; the mouth should contain the
        visible mouth. Use the current layout as a starting point, not as ground truth.

        Image size: \(Int(imageSize.width)) x \(Int(imageSize.height))
        Existing review confidence: \(review.confidence)
        Existing geometric warnings: \(issues)

        Current normalized layout:

        ```json
        \(layoutJSON)
        ```

        Return only one JSON object with exactly this shape:

        ```json
        {
          "operation": "\(operation)",
          "head": {"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0},
          "eye_left": {"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0},
          "eye_right": {"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0},
          "mouth": {"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0},
          "confidence": 0.0,
          "explanation": "short user-facing explanation"
        }
        ```

        Do not edit files, run unrelated commands, or build the avatar. Castor validates
        the proposal and the user must explicitly approve it before it becomes the active layout.
        """
    }

    private static func jsonCandidates(in text: String) -> [String] {
        var candidates = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    candidates.append(String(text[start...index]))
                }
            }
            index = text.index(after: index)
        }
        return candidates
    }

    private struct ResponsePayload: Decodable {
        let operation: String
        let head: NormalizedRect
        let eyeLeft: NormalizedRect
        let eyeRight: NormalizedRect
        let mouth: NormalizedRect
        let confidence: Double
        let explanation: String

        enum CodingKeys: String, CodingKey {
            case operation
            case head
            case eyeLeft = "eye_left"
            case eyeRight = "eye_right"
            case mouth
            case confidence
            case explanation
        }
    }

    private struct RequestLayout: Encodable {
        let head: NormalizedRect
        let eyeLeft: NormalizedRect
        let eyeRight: NormalizedRect
        let mouth: NormalizedRect

        enum CodingKeys: String, CodingKey {
            case head
            case eyeLeft = "eye_left"
            case eyeRight = "eye_right"
            case mouth
        }
    }

    private struct NormalizedRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(rect: CGRect, imageSize: CGSize) {
            x = Double(rect.minX / max(1, imageSize.width))
            y = Double(rect.minY / max(1, imageSize.height))
            width = Double(rect.width / max(1, imageSize.width))
            height = Double(rect.height / max(1, imageSize.height))
        }

        func pixelRect(in imageSize: CGSize, name: String) throws -> CGRect {
            let values = [x, y, width, height]
            guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  width > 0, height > 0,
                  x + width <= 1.000_001,
                  y + height <= 1.000_001 else {
                throw ArilsAIAdjustmentError.invalidGeometry("\(name) has invalid normalized coordinates.")
            }
            return CGRect(
                x: CGFloat(x) * imageSize.width,
                y: CGFloat(y) * imageSize.height,
                width: CGFloat(width) * imageSize.width,
                height: CGFloat(height) * imageSize.height
            )
        }
    }
}

@MainActor
@Observable
final class ArilsAIAdjustmentCoordinator {
    private(set) var isWorking = false
    private(set) var status = ""
    private(set) var pendingApproval: CastorAgentApprovalRequest?

    private let ollamaClient: OllamaClient
    private let codex = CodexAppServerSession()
    private let claudeCode = ClaudeCodeBridgeSession()

    init(ollamaClient: OllamaClient? = nil) {
        self.ollamaClient = ollamaClient ?? OllamaClient()
    }

    func suggest(
        image: NSImage,
        currentLayout: FaceLayout,
        review: FaceLayoutReview,
        provider: ArilsAIProvider
    ) async throws -> ArilsAIAdjustmentProposal {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw ArilsAIAdjustmentError.imageEncodingFailed
        }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let instructions = ArilsAIAdjustmentParser.requestMarkdown(
            imageSize: imageSize,
            currentLayout: currentLayout,
            review: review
        )

        isWorking = true
        pendingApproval = nil
        defer {
            isWorking = false
            pendingApproval = nil
        }

        let response: String
        switch provider {
        case .ollama:
            status = "Checking the image with Ollama..."
            let models = try await ollamaClient.models()
            guard let model = OllamaSession.resolvedModelName(
                availableModels: models,
                preferredModel: OllamaModelSelectionStore.selectedModel
            ) else {
                throw ArilsAIAdjustmentError.noOllamaModel
            }
            response = try await ollamaClient.arilsFaceLayoutAdjustment(
                model: model,
                prompt: instructions,
                imageBase64: pngData.base64EncodedString()
            )
        case .codex, .claudeCode:
            let packet = try makeReviewPacket(imageData: pngData, instructions: instructions)
            defer { try? FileManager.default.removeItem(at: packet) }
            let prompt = """
            Perform operation \(ArilsAIAdjustmentParser.operation).
            Read REQUEST.md and visually inspect source.png in the current working directory.
            Return only the requested JSON object. Do not modify any file.
            """
            if provider == .codex {
                status = "Asking Codex to inspect the alignment..."
                response = try await codex.send(
                    prompt: prompt,
                    serverURL: CastorAgentPreferenceStore.current.codexServerURL,
                    workspacePath: packet.path,
                    personalityInstruction: "Act as a conservative image-rig alignment reviewer.",
                    localImagePath: packet.appending(path: "source.png").path,
                    onDelta: { [weak self] _ in self?.status = "Receiving the Codex proposal..." },
                    onStatus: { [weak self] status in self?.status = status },
                    onApproval: { [weak self] approval in
                        self?.pendingApproval = approval.map(CastorAgentApprovalRequest.codex)
                    }
                )
            } else {
                status = "Asking Claude Code to inspect the alignment..."
                response = try await claudeCode.send(
                    prompt: prompt,
                    bridgeURL: CastorAgentPreferenceStore.current.claudeCodeBridgeURL,
                    workspacePath: packet.path,
                    personalityInstruction: "Act as a conservative image-rig alignment reviewer.",
                    onDelta: { [weak self] _ in self?.status = "Receiving the Claude Code proposal..." },
                    onStatus: { [weak self] status in self?.status = status },
                    onApproval: { [weak self] approval in
                        self?.pendingApproval = approval.map(CastorAgentApprovalRequest.claudeCode)
                    }
                )
            }
        }

        try Task.checkCancellation()
        status = "Validating the proposed markers..."
        return try ArilsAIAdjustmentParser.parse(
            response,
            imageSize: imageSize,
            provider: provider
        )
    }

    func resolvePendingApproval(approved: Bool) {
        guard let pendingApproval else { return }
        Task {
            do {
                switch pendingApproval {
                case .codex(let request):
                    try await codex.resolveApproval(request, approved: approved)
                case .claudeCode(let request):
                    try await claudeCode.resolveApproval(request, approved: approved)
                }
                self.pendingApproval = nil
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func cancel() {
        codex.disconnect()
        claudeCode.disconnect()
        pendingApproval = nil
        isWorking = false
    }

    private func makeReviewPacket(imageData: Data, instructions: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "castor-arils-ai-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try imageData.write(to: directory.appending(path: "source.png"), options: .atomic)
        try Data(instructions.utf8).write(to: directory.appending(path: "REQUEST.md"), options: .atomic)
        return directory
    }
}
