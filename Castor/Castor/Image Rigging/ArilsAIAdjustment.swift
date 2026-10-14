import AppKit
import ImageIO
import Arils
import Foundation
import Observation
import CastorCore

import PetRuntime

typealias ArilsAIProvider = PetRuntime.ArilsAIProvider
typealias ArilsAIReferenceSet = PetRuntime.ArilsAIReferenceSet
typealias ArilsAISettings = PetRuntime.ArilsAISettings
typealias ArilsAIAdjustmentProposal = PetRuntime.ArilsAIAdjustmentProposal
typealias ArilsAIAdjustmentError = PetRuntime.ArilsAIAdjustmentError
typealias ArilsAIAdjustmentParser = PetRuntime.ArilsAIAdjustmentParser

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

@MainActor
@Observable
final class ArilsAIAdjustmentCoordinator {
    private(set) var isWorking = false
    private(set) var status = ""
    private(set) var pendingApproval: CastorAgentApprovalRequest?

    private let lmStudioClient = LMStudioClient()
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
            status = "ローカルの画像対応モデルを確認しています…"
            let studioModels = (try? await lmStudioClient.visionModels()) ?? []
            try Task.checkCancellation()
            if let model=OllamaSession.resolvedModelName(availableModels:studioModels,preferredModel:LMStudioModelSelectionStore.selectedModel) {
                status="LM Studioで画像を確認しています…"
                response=try await lmStudioClient.arilsFaceLayoutAdjustment(model:model,prompt:instructions,imageBase64:pngData.base64EncodedString())
                break
            }
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

    func generateUprightImage(image: NSImage, prompt: String) async throws -> NSImage {
        guard let cgImage=image.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let data=NSBitmapImageRep(cgImage:cgImage).representation(using:.png,properties:[:]) else {
            throw ArilsAIAdjustmentError.imageEncodingFailed
        }
        let packet=try makeReviewPacket(imageData:data,instructions:prompt)
        defer {try? FileManager.default.removeItem(at:packet)}
        isWorking=true;pendingApproval=nil
        defer {isWorking=false;pendingApproval=nil}
        let generated=try await codex.generateImage(prompt:prompt,serverURL:CastorAgentPreferenceStore.current.codexServerURL,
            workspacePath:packet.path,localImagePath:packet.appendingPathComponent("source.png").path,
            onStatus:{[weak self] in self?.status=$0},
            onApproval:{[weak self] in self?.pendingApproval=$0.map(CastorAgentApprovalRequest.codex)})
        try Task.checkCancellation()
        guard let source=CGImageSourceCreateWithData(generated as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=4096,height<=4096,
              let pixels=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw ArilsAIAdjustmentError.imageEncodingFailed}
        return NSImage(cgImage:pixels,size:.zero)
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
