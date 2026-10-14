import Foundation

/// app-server ImageGenerationThreadItem.result is image bytes as base64.
/// Do not follow an arbitrary URL or read savedPath from an agent response.
public nonisolated enum CodexGeneratedImage {
    public static func decode(_ result: String) -> Data? {
        guard !result.isEmpty,result.utf8.count<=90_000_000 else { return nil }
        var encoded=result
        if encoded.hasPrefix("data:image/png;base64,") { encoded=String(encoded.dropFirst(22)) }
        else if encoded.hasPrefix("data:image/jpeg;base64,") { encoded=String(encoded.dropFirst(23)) }
        guard let data=Data(base64Encoded:encoded),data.count<=64*1_024*1_024 else { return nil }
        let png=Data([137,80,78,71,13,10,26,10]),jpeg=Data([255,216,255])
        guard data.starts(with:png)||data.starts(with:jpeg) else { return nil }
        return data
    }
}
