import Foundation

/// Bounded RIFF/WAVE decoder for in-memory playback. Accepts PCM16/24/32 and
/// IEEE Float32, including standard extensible subformats; no compressed codecs.
public nonisolated struct WavePCM: Sendable {
    public let samples:[Int16]
    public let channels:Int
    public let sampleRate:Int
    public var duration:Double {Double(samples.count)/Double(channels*sampleRate)}
    public enum DecodeError:Error {case invalid}
    public init(data:Data) throws {
        let bytes=[UInt8](data)
        guard bytes.count>=44,bytes.count<=64*1024*1024 else {throw DecodeError.invalid}
        func u16(_ i:Int)->Int {Int(bytes[i])|Int(bytes[i+1])<<8}
        func u32(_ i:Int)->UInt32 {UInt32(bytes[i])|UInt32(bytes[i+1])<<8|UInt32(bytes[i+2])<<16|UInt32(bytes[i+3])<<24}
        func tag(_ i:Int,_ value:String)->Bool {Array(bytes[i..<i+4]) == Array(value.utf8)}
        guard tag(0,"RIFF"),tag(8,"WAVE"),Int(u32(4))+8<=bytes.count,Int(u32(4))+8>=44 else {throw DecodeError.invalid}
        let end=Int(u32(4))+8
        var offset=12,format=0,channels=0,rate=0,bits=0,alignment=0,audio:Range<Int>?
        while offset+8<=end {
            let length=Int(u32(offset+4)),start=offset+8
            guard length<=end-start else {throw DecodeError.invalid}
            if tag(offset,"fmt ") {
                guard format==0,length>=16 else {throw DecodeError.invalid}
                format=u16(start);channels=u16(start+2);rate=Int(u32(start+4));alignment=u16(start+12);bits=u16(start+14)
                if format==65534 {
                    let suffix:[UInt8]=[0,0,0,0,16,0,128,0,0,170,0,56,155,113]
                    guard length>=40,u16(start+16)>=22,u16(start+18)==bits,
                          Array(bytes[start+26..<start+40])==suffix else {throw DecodeError.invalid}
                    format=u16(start+24)
                }
                guard (1...8).contains(channels),(8000...192000).contains(rate),
                      (format==1 && [16,24,32].contains(bits)) || (format==3 && bits==32),
                      alignment==channels*(bits/8),Int(u32(start+8))==rate*alignment else {throw DecodeError.invalid}
            } else if tag(offset,"data") {
                guard audio==nil else {throw DecodeError.invalid};audio=start..<start+length
            }
            offset=start+length+(length&1)
        }
        guard format != 0,let audio,!audio.isEmpty,audio.count%alignment==0,
              Double(audio.count)/Double(rate*alignment)<=300 else {throw DecodeError.invalid}
        var converted=[Int16]();converted.reserveCapacity(audio.count/(bits/8))
        for i in stride(from:audio.lowerBound,to:audio.upperBound,by:bits/8) {
            if format==3 {
                let value=Float(bitPattern:u32(i));guard value.isFinite else {throw DecodeError.invalid}
                converted.append(Int16(clamping:Int((Double(min(max(value,-1),1))*32767).rounded())))
            } else if bits==16 {converted.append(Int16(bitPattern:UInt16(u16(i))))}
            else if bits==24 {converted.append(Int16(bitPattern:UInt16(bytes[i+1])|UInt16(bytes[i+2])<<8))}
            else {converted.append(Int16(bitPattern:UInt16(bytes[i+2])|UInt16(bytes[i+3])<<8))}
        }
        self.channels=channels;sampleRate=rate;samples=converted
    }
}
