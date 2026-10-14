import Foundation
import Testing
@testable import CastorCore

private func wavFixture(format:Int=1,bits:Int=16,audio:[UInt8]) -> Data {
    var bytes=[UInt8]()
    func tag(_ text:String){bytes += text.utf8}
    func u16(_ value:Int){bytes += [UInt8(truncatingIfNeeded:value),UInt8(truncatingIfNeeded:value>>8)]}
    func u32(_ value:Int){for shift in stride(from:0,to:32,by:8){bytes.append(UInt8(truncatingIfNeeded:value>>shift))}}
    tag("RIFF");u32(36+audio.count+(audio.count&1));tag("WAVE");tag("fmt ");u32(16)
    u16(format);u16(1);u32(24000);u32(24000*bits/8);u16(bits/8);u16(bits)
    tag("data");u32(audio.count);bytes += audio;if audio.count&1==1 {bytes.append(0)}
    return Data(bytes)
}
@Test func wavePCMDecodesSignedSamplesWithoutWritingAudioToDisk() throws {
    let pcm=try WavePCM(data:wavFixture(audio:[0,128,255,127,0,0]))
    #expect(pcm.channels==1);#expect(pcm.sampleRate==24000)
    #expect(pcm.samples == [-32768,32767,0]);#expect(pcm.duration==3.0/24000)
}
@Test func waveFloatAnd24BitDecodeWithFiniteClamping() throws {
    let float=try WavePCM(data:wavFixture(format:3,bits:32,audio:[0,0,128,63,0,0,128,191]))
    #expect(float.samples==[32767,-32767])
    let pcm24=try WavePCM(data:wavFixture(bits:24,audio:[0,0,128,0,255,127]))
    #expect(pcm24.samples==[-32768,32767])
    #expect(throws:WavePCM.DecodeError.self){_ = try WavePCM(data:wavFixture(format:3,bits:32,audio:[0,0,192,127]))}
}
@Test func waveRejectsCorruptionAndUnsupportedCodecs() throws {
    var data=wavFixture(audio:[0,0]);data[40]=255
    #expect(throws:WavePCM.DecodeError.self){_ = try WavePCM(data:data)}
    #expect(throws:WavePCM.DecodeError.self){_ = try WavePCM(data:wavFixture(format:17,audio:[0,0]))}
    #expect(throws:WavePCM.DecodeError.self){_ = try WavePCM(data:wavFixture(audio:[0]))}
    #expect(throws:WavePCM.DecodeError.self){_ = try WavePCM(data:Data("RIFFinvalid".utf8))}
}
@Test func neuralTransportRestrictsEndpointsAndKeepsPayloadKeys() throws {
    for endpoint in ["https://example.com/v1/audio/speech","http://user@localhost/v1/audio/speech","http://127.0.0.1/v1/audio/speech?token=secret","file:///tmp/audio"] {
        #expect(throws:NeuralSpeechTransport.TransportError.self){_ = try NeuralSpeechTransport(endpoint:URL(string:endpoint)!)}
    }
    _ = try NeuralSpeechTransport(endpoint:URL(string:"http://[::1]:8000/v1/audio/speech")!)
    let payload=NeuralSpeechPayload(model:"model-id",input:"hello",instruct:"calm",voice:"Ryan",speed:1,langCode:"en")
    let object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(payload)) as? [String:Any])
    #expect(object["lang_code"] as? String == "en")
    #expect(object["response_format"] as? String == "wav")
    #expect(object["voice"] as? String == "Ryan")
}
@Test func neuralTransportRejectsInvalidRequestBeforeConnecting() async throws {
    let transport=try NeuralSpeechTransport()
    let invalid=NeuralSpeechPayload(model:"model",input:"",instruct:"",voice:"Ryan",speed:1,langCode:"en")
    await #expect(throws:NeuralSpeechTransport.TransportError.self){_ = try await transport.audio(for:invalid)}
}
