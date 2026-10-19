import ArilsPlayer
import Foundation

public struct PetGIFClipOptions: Sendable {
    public enum Motion: String, Sendable { case idle, lookAround }
    public var motion: Motion = .idle
    public var duration: Int = 4
    public var background: [UInt8] = [255, 255, 255] // RGB
    public init() {}
}
public struct PetGIFClipResult: Sendable {
    public let data: Data
    public let dimension: Int
    public let fps: Int
    public let frames: [PetCanvas] // composited preview; no live UI/camera/screen capture
}
public enum PetGIFClip {
    public enum ExportError: LocalizedError {
        case invalidBackground, tooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidBackground: "背景色を確認してください。"
            case .tooLarge: "GIFを5MB以下にできませんでした。長さを短くしてお試しください。"
            }
        }
    }
    public static func make(asset: PetAsset, options: PetGIFClipOptions, maximumBytes: Int = 5_000_000) async throws -> PetGIFClipResult {
        guard options.background.count == 3 else { throw ExportError.invalidBackground }
        let duration = min(max(options.duration, 3), 5)
        for (dimension, fps) in [(384, 20), (320, 20), (256, 10)] {
            try Task.checkCancellation()
            let player = PetPlayback(asset: asset)
            player.automaticTurn = false
            // GIF uses a centered square composition on both platforms.
            let size = CGSize(width: player.front.rig.imageWidth, height: player.front.rig.imageHeight)
            player.front.imageFrame = QualityRegistrationLayout.aspectFitRect(imageSize: size,
                in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            var writer = GIFStream(width: dimension, height: dimension), preview: [PetCanvas] = []
            var canvas = PetCanvas(width: dimension, height: dimension)
            for frame in 0..<(duration * fps) {
                try Task.checkCancellation()
                let time = Double(frame) / Double(fps)
                if options.motion == .lookAround {
                    let x = Float(sin(time / Double(duration) * 2 * .pi)) * 0.8
                    player.viewTurn = x
                    let rect = player.front.rig.firstPart(ofKind: .head)?.rect ?? CGRect(origin: .zero, size: size)
                    let cx = Float(rect.midX), cy = Float(rect.midY)
                    let imageX = cx + x * (x < 0 ? cx : Float(size.width) - cx)
                    let (scale, offset) = player.front.placement(canvasWidth: dimension, canvasHeight: dimension)
                    player.pointerMoved(to: SIMD2(imageX, cy) * scale + offset,
                                        canvasWidth: dimension, canvasHeight: dimension, time: time)
                }
                player.render(into: &canvas, time: time)
                for i in stride(from: 0, to: canvas.bgra.count, by: 4) {
                    let remain = 255 - Int(canvas.bgra[i + 3])
                    for c in 0..<3 {
                        canvas.bgra[i + c] = UInt8(min(255, Int(canvas.bgra[i + c]) + (Int(options.background[2 - c]) * remain + 127) / 255))
                    }
                    canvas.bgra[i + 3] = 255
                }
                preview.append(writer.append(canvas, delay: 100 / fps))
                if writer.data.count + 1 > maximumBytes { break }
                await Task.yield()
            }
            if preview.count == duration * fps, writer.data.count + 1 <= maximumBytes {
                return PetGIFClipResult(data: writer.finish(), dimension: dimension, fps: fps, frames: preview)
            }
        }
        throw ExportError.tooLarge
    }
    public static func sharingURL() -> URL {
        var components = URLComponents(string: "https://x.com/intent/tweet")!
        components.queryItems = [URLQueryItem(name: "text", value: "Castorで作ったキャラクターです。 #Castor"),
                                URLQueryItem(name: "url", value: "https://github.com/Methurcoder/Castor")]
        return components.url!
    }
}
