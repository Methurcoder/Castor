import ArilsCore
import Foundation
import Testing
@testable import PetRuntime

private let alignmentJSON = """
{"operation":"POME_ARILS_FACE_LAYOUT_V1","head":{"x":0.2,"y":0.1,"width":0.6,"height":0.5},"eye_left":{"x":0.3,"y":0.25,"width":0.1,"height":0.1},"eye_right":{"x":0.6,"y":0.25,"width":0.1,"height":0.1},"mouth":{"x":0.4,"y":0.45,"width":0.2,"height":0.05},"confidence":0.8,"explanation":"Review this proposal"}
"""
@Test func sharedAIProposalKeepsLegacyOperationAndRequiresValidGeometry() throws {
    let proposal=try ArilsAIAdjustmentParser.parse("proposal\n\(alignmentJSON)",imageSize:CGSize(width:100,height:200),provider:.codex)
    #expect(proposal.layout.headRect==CGRect(x:20,y:20,width:60,height:100))
    #expect(proposal.provider == .codex)
    #expect(proposal.confidence==0.8)
    #expect(throws:ArilsAIAdjustmentError.self) {
        _ = try ArilsAIAdjustmentParser.parse(alignmentJSON.replacingOccurrences(of:"POME_ARILS_FACE_LAYOUT_V1",with:"OTHER"),imageSize:CGSize(width:100,height:200),provider:.ollama)
    }
    #expect(throws:ArilsAIAdjustmentError.self) {
        _ = try ArilsAIAdjustmentParser.parse(alignmentJSON.replacingOccurrences(of:"\"x\":0.2",with:"\"x\":-0.2"),imageSize:CGSize(width:100,height:200),provider:.ollama)
    }
    #expect(throws:ArilsAIAdjustmentError.self) {
        _ = try ArilsAIAdjustmentParser.parse(String(repeating:" ",count:65537),imageSize:CGSize(width:100,height:200),provider:.ollama)
    }
}
@Test func sharedAISettingsKeepOldSavedKeysAndProviderIdentifiers() throws {
    let data=Data(#"{"provider":"ollama","referenceSet":"frontAndThreeQuarter","useLaMa":true}"#.utf8)
    let settings=try JSONDecoder().decode(ArilsAISettings.self,from:data)
    #expect(settings.provider.label=="Ollama / LM Studio")
    #expect(settings.referenceSet == .frontAndThreeQuarter)
    #expect(settings.useLaMa)
    #expect(!settings.provider.isExternal)
    #expect(ArilsAIProvider.claudeCode.isExternal)
}
