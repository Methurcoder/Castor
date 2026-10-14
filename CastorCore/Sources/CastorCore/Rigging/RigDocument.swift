#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

public nonisolated struct RigDocument: Codable, Equatable, Hashable, Sendable {
    public var version: Int
    public var imageName: String?
    public var imageSize: CGSize
    public var parts: [RigPart]

    public init(version: Int,imageName: String?,imageSize: CGSize,parts: [RigPart]) {
        self.version=version;self.imageName=imageName;self.imageSize=imageSize;self.parts=parts
    }
    public func validate() throws {
        guard version==1,imageSize.width.isFinite,imageSize.height.isFinite,imageSize.width>0,imageSize.height>0,
              imageSize.width<=4096,imageSize.height<=4096,!parts.isEmpty,parts.count<=64,Set(parts.map(\.id)).count==parts.count else {throw ValidationError.invalid}
        let bounds=CGRect(x:0,y:0,width:1,height:1)
        for part in parts {
            let rect=part.normalizedRect
            guard [rect.minX,rect.minY,rect.width,rect.height,part.anchorPoint.x,part.anchorPoint.y,CGFloat(part.zIndex)].allSatisfy(\.isFinite),
                  rect.width>0,rect.height>0,bounds.contains(rect),(0...1).contains(part.anchorPoint.x),(0...1).contains(part.anchorPoint.y),abs(part.zIndex)<=1_000_000 else {throw ValidationError.invalid}
        }
    }
    public nonisolated enum ValidationError: LocalizedError {case invalid;public var errorDescription:String? {"手動リグの画像サイズ・部位・範囲・アンカーを確認してください。"}}

    public static func starter(imageName: String?, imageSize: CGSize) -> RigDocument {
        let aspectRatio = imageSize.width / max(imageSize.height, 1)
        let parts = aspectRatio < 0.9 ? portraitStarterParts() : squareStarterParts()

        return RigDocument(
            version: 1,
            imageName: imageName,
            imageSize: imageSize,
            parts: parts
        )
    }

    private static func portraitStarterParts() -> [RigPart] {
        [
            RigPart(kind: .body, normalizedRect: CGRect(x: 0.28, y: 0.54, width: 0.44, height: 0.40), shape: .ellipse, zIndex: 0),
            RigPart(kind: .head, normalizedRect: CGRect(x: 0.27, y: 0.33, width: 0.46, height: 0.34), shape: .ellipse, zIndex: 10),
            RigPart(kind: .hair, normalizedRect: CGRect(x: 0.24, y: 0.29, width: 0.52, height: 0.25), shape: .ellipse, zIndex: 20),
            RigPart(kind: .leftEye, normalizedRect: CGRect(x: 0.39, y: 0.46, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .rightEye, normalizedRect: CGRect(x: 0.53, y: 0.46, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .mouth, normalizedRect: CGRect(x: 0.45, y: 0.55, width: 0.10, height: 0.05), shape: .ellipse, zIndex: 35)
        ]
    }

    private static func squareStarterParts() -> [RigPart] {
        [
            RigPart(kind: .body, normalizedRect: CGRect(x: 0.30, y: 0.53, width: 0.40, height: 0.38), shape: .ellipse, zIndex: 0),
            RigPart(kind: .head, normalizedRect: CGRect(x: 0.28, y: 0.29, width: 0.44, height: 0.34), shape: .ellipse, zIndex: 10),
            RigPart(kind: .hair, normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.25), shape: .ellipse, zIndex: 20),
            RigPart(kind: .leftEye, normalizedRect: CGRect(x: 0.39, y: 0.43, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .rightEye, normalizedRect: CGRect(x: 0.53, y: 0.43, width: 0.09, height: 0.06), shape: .ellipse, zIndex: 30),
            RigPart(kind: .mouth, normalizedRect: CGRect(x: 0.45, y: 0.52, width: 0.10, height: 0.05), shape: .ellipse, zIndex: 35)
        ]
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> RigDocument {
        try JSONDecoder().decode(RigDocument.self, from: data)
    }
}
