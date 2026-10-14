import CastorCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Local review uses the same strict loopback/redirect policy as conversation.
public enum ArilsAILocalReview {
    public static func models(provider:DesktopPreferences.Provider,endpoint:String) async throws -> [OllamaModel] {
        let url=try DesktopConversation.endpoint(endpoint)
        let session=URLSession(configuration:.ephemeral,delegate:LocalRedirectPolicy(),delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        switch provider {
        case .lmStudio:return try await LMStudioClient(endpoint:url,session:session).visionModels()
        case .ollama:return try await OllamaClient(endpoint:url,session:session).models()
        }
    }
    public static func suggest(provider:DesktopPreferences.Provider,endpoint:String,model:String,prompt:String,png:Data) async throws -> String {
        let url=try DesktopConversation.endpoint(endpoint)
        guard !model.isEmpty,png.count<=8*1024*1024,prompt.utf8.count<=65536 else {throw ArilsAIAdjustmentError.invalidResponse}
        let session=URLSession(configuration:.ephemeral,delegate:LocalRedirectPolicy(),delegateQueue:nil)
        defer {session.invalidateAndCancel()}
        switch provider {
        case .lmStudio:return try await LMStudioClient(endpoint:url,session:session).arilsFaceLayoutAdjustment(model:model,prompt:prompt,imageBase64:png.base64EncodedString())
        case .ollama:return try await OllamaClient(endpoint:url,session:session).arilsFaceLayoutAdjustment(model:model,prompt:prompt,imageBase64:png.base64EncodedString())
        }
    }
}
