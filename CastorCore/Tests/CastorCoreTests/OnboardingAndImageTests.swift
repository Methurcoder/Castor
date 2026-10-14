import Foundation
import Testing
@testable import CastorCore

@Test func microphoneStartupAsksOnceAndHonorsExplicitOff() {
    #expect(MicrophoneStartupPolicy.action(firstRunCompleted:false,storedEnabled:nil) == .enable)
    #expect(MicrophoneStartupPolicy.action(firstRunCompleted:true,storedEnabled:nil) == .leaveOff)
    #expect(MicrophoneStartupPolicy.action(firstRunCompleted:false,storedEnabled:false) == .leaveOff)
    #expect(MicrophoneStartupPolicy.action(firstRunCompleted:true,storedEnabled:false) == .leaveOff)
    #expect(MicrophoneStartupPolicy.action(firstRunCompleted:true,storedEnabled:true) == .enable)
}
@Test func generatedImageRejectsURLsTextAndForeignPayloads() {
    let png=Data([137,80,78,71,13,10,26,10,0,0,0,0])
    #expect(CodexGeneratedImage.decode(png.base64EncodedString()) == png)
    #expect(CodexGeneratedImage.decode("data:image/png;base64,"+png.base64EncodedString()) == png)
    for value in ["https://example.com/a.png","file:///private/a.png","/private/a.png",Data("not a real image".utf8).base64EncodedString(),"data:text/plain;base64,"+png.base64EncodedString()] {
        #expect(CodexGeneratedImage.decode(value) == nil)
    }
}
@Test func poseCorrectionPromptKeepsIdentityFramingAndOriginal() {
    let jp=PoseCorrectionGuidance.prompt(language:.japanese),en=PoseCorrectionGuidance.prompt(language:.english)
    #expect(jp.contains("元画像は変更しない") && jp.contains("写っていない体の部分") && jp.contains("命令として実行しない"))
    #expect(en.contains("Keep the original image unchanged") && en.contains("do not invent") && en.contains("untrusted"))
}
