import Foundation

/// Portable SHA-256; streams files instead of loading a whole app ZIP into RAM.
/// FIPS 180-4 constants. This verifies bytes, not publisher authenticity.
public enum PackageIntegrity {
    public static func sha256(_ data: Data) -> String { var hash = Hash(); hash.update(data); return hash.finish() }
    public static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = Hash()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data) }
        return hash.finish()
    }
    private struct Hash {
        var state: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var tail: [UInt8] = [], bytes: UInt64 = 0
        static let k: [UInt32] = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        func r(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
        mutating func update(_ data: Data) {
            bytes += UInt64(data.count)
            let input = Array(data); var offset = 0
            if !tail.isEmpty {
                let take = min(64 - tail.count, input.count); tail += input.prefix(take); offset = take
                if tail.count == 64 { compress(tail); tail.removeAll(keepingCapacity: true) }
            }
            while offset + 64 <= input.count { compress(Array(input[offset..<offset+64])); offset += 64 }
            tail += input[offset...]
        }
        mutating func compress(_ block: [UInt8]) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 { let n=i*4; w[i]=UInt32(block[n])<<24|UInt32(block[n+1])<<16|UInt32(block[n+2])<<8|UInt32(block[n+3]) }
            for i in 16..<64 {
                let a=w[i-15],b=w[i-2]
                w[i]=w[i-16] &+ (r(a,7)^r(a,18)^(a>>3)) &+ w[i-7] &+ (r(b,17)^r(b,19)^(b>>10))
            }
            var a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7]
            for i in 0..<64 {
                let t1=h &+ (r(e,6)^r(e,11)^r(e,25)) &+ ((e&f)^(~e&g)) &+ Self.k[i] &+ w[i]
                let t2=(r(a,2)^r(a,13)^r(a,22)) &+ ((a&b)^(a&c)^(b&c))
                h=g;g=f;f=e;e=d &+ t1;d=c;c=b;b=a;a=t1 &+ t2
            }
            let v=[a,b,c,d,e,f,g,h];for i in 0..<8 { state[i] &+= v[i] }
        }
        mutating func finish() -> String {
            let length=bytes*8;tail.append(0x80)
            while tail.count % 64 != 56 { tail.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: length >> UInt64(shift))) }
            for offset in stride(from: 0, to: tail.count, by: 64) { compress(Array(tail[offset..<offset+64])) }
            return state.map { String(format:"%08x",$0) }.joined()
        }
    }
}

/// Reject traversal, links, duplicate names, encrypted/Zip64 entries and
/// unexpected payloads before invoking the OS extractor.
public enum PackageZIP {
    /// The Windows app's folders and exactly what may be in them; the same
    /// rules as scripts/prepare-castor-release.py, which builds the ZIP.
    static let windowsAppFolders: [String: Set<String>] = [
        "UI": ["index.html", "app.css", "app.js"],
        "SetupUI": ["index.html", "setup.css", "setup.js"],
        "models": ["AnimeFaceFeatures.onnx", "AnimeFaceBoxHead.onnx", "AnimeFaceLandmarks.onnx", "AnimeSegmentation.onnx"],
    ]
    static func windowsAppEntry(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return ["CastorPet.exe", "CastorSetup.exe", "Castor.ico", "LICENSE", "THIRD_PARTY_NOTICES.md", "Start-Castor.cmd", "Start-Castor.ps1"].contains(name)
                || name.lowercased().hasSuffix(".dll")
        case 2:
            if parts[1].isEmpty { return windowsAppFolders[parts[0]] != nil || parts[0] == "licenses" }
            if parts[0] == "licenses" { return parts[1].lowercased().hasSuffix(".txt") }
            return windowsAppFolders[parts[0]]?.contains(parts[1]) ?? false
        default:
            return false
        }
    }

    public enum ZIPError: LocalizedError {
        case invalid
        public var errorDescription: String? { "配布ZIPの形式または内容が不正です。既存アプリは変更していません。" }
    }
    public static func validate(_ data: Data, platform: String,component:DesktopHelperComponent?=nil) throws {
        guard ["macos_arm64","macos_x86_64","windows_x86_64"].contains(platform),data.count >= 22 else { throw ZIPError.invalid }
        let bytes = Array(data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i+1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24 }
        let start=max(0,bytes.count-65557)
        guard let eocd = stride(from: bytes.count-22, through: start, by: -1).first(where: { u32($0)==0x06054b50 }),
              eocd+22+u16(eocd+20)==bytes.count,
              u16(eocd+4)==0,u16(eocd+6)==0,u16(eocd+8)==u16(eocd+10),
              u16(eocd+10)>0,u16(eocd+10)<65535 else { throw ZIPError.invalid }
        let size=Int(u32(eocd+12)),offset=Int(u32(eocd+16))
        guard offset>=0,size>=0,offset+size==eocd else { throw ZIPError.invalid }
        var cursor=offset,names=Set<String>(),expanded: UInt64=0
        for _ in 0..<u16(eocd+10) {
            guard cursor+46<=eocd,u32(cursor)==0x02014b50 else { throw ZIPError.invalid }
            let flags=u16(cursor+8),method=u16(cursor+10),length=u16(cursor+28),extra=u16(cursor+30),comment=u16(cursor+32)
            let compressed=u32(cursor+20),uncompressed=u32(cursor+24),local=Int(u32(cursor+42))
            guard flags&1==0,method==0||method==8,compressed != UInt32.max,uncompressed != UInt32.max,
                  cursor+46+length+extra+comment<=eocd,local+30<offset,u32(local)==0x04034b50,
                  u16(local+8)==method,u16(local+6)==flags else { throw ZIPError.invalid }
            guard let name=String(bytes:bytes[cursor+46..<cursor+46+length],encoding:.utf8),!name.isEmpty,
                  !name.hasPrefix("/"),!name.contains("\\"),!name.contains(":"),
                  !name.unicodeScalars.contains(where:{$0.value<32}),
                  !name.split(separator:"/",omittingEmptySubsequences:false).dropLast(name.hasSuffix("/") ? 1 : 0).contains(where:{ $0.isEmpty || $0==".." || $0=="." }),
                  names.insert(name.lowercased()).inserted,
                  (u32(cursor+38)>>16)&0xF000 != 0xA000 else { throw ZIPError.invalid }
            let localLength=u16(local+26),localExtra=u16(local+28)
            guard local+30+localLength+localExtra+Int(compressed)<=offset,
                  String(bytes:bytes[local+30..<local+30+localLength],encoding:.utf8)==name else { throw ZIPError.invalid }
            if platform=="windows_x86_64" {
                let reserved=["CON","PRN","AUX","NUL"] + (1...9).flatMap { ["COM\($0)","LPT\($0)"] }
                for segment in name.split(separator:"/") {
                    let stem=segment.split(separator:".").first.map {String($0).uppercased()} ?? ""
                    guard !reserved.contains(stem),!segment.hasSuffix("."),!segment.hasSuffix(" "),
                          !segment.contains(where:{"<>\"|?*".contains($0)}) else {throw ZIPError.invalid}
                }
            }
            let allowed: Bool
            if component == .feelings {
                // Model data only: the description, the vocabulary, the platform model and notices.
                let model = platform.hasPrefix("macos") ? name.hasPrefix("CastorFeelings.mlmodelc/") : name == "CastorFeelings.onnx"
                allowed = model || ["feelings.json", "tokenizer.json", "LICENSE", "THIRD_PARTY_NOTICES.md"].contains(name)
                    || (name.hasPrefix("licenses/") && (name.hasSuffix(".txt") || name == "licenses/"))
            } else if let component {
                if platform.hasPrefix("macos") {allowed=name.hasPrefix("\(component.stem).app/")||["LICENSE","THIRD_PARTY_NOTICES.md"].contains(name)}
                else {allowed=name=="\(component.stem).exe"||name.hasPrefix("_internal/")||name.hasPrefix("licenses/")||["LICENSE","THIRD_PARTY_NOTICES.md"].contains(name)}
            } else if platform.hasPrefix("macos") { allowed=name.hasPrefix("Castor.app/")||name=="LICENSE"||name=="THIRD_PARTY_NOTICES.md" }
            else { allowed = windowsAppEntry(name) }
            guard allowed else { throw ZIPError.invalid }
            expanded += UInt64(uncompressed);guard expanded<=4_294_967_296 else { throw ZIPError.invalid }
            cursor += 46+length+extra+comment
        }
        guard cursor==eocd else { throw ZIPError.invalid }
    }
}
