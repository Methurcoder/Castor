import AppKit
import Arils
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import CastorCore

struct PetGIFOptions {
    enum Motion: String, CaseIterable, Identifiable {
        case idle = "呼吸・瞬き"
        case lookAround = "きょろきょろ"
        var id: Self { self }
    }
    var motion: Motion = .idle
    var duration: Int = 4
    var background: NSColor = .white
}

struct PetGIFResult {
    let data: Data
    let dimension: Int
    let framesPerSecond: Int
    let duration: Int
}

@MainActor
enum PetGIFExporter {
    enum ExportError: LocalizedError {
        case missingPet, couldNotRender, couldNotEncode, tooLarge
        var errorDescription: String? {
            switch self {
            case .missingPet: "ペットを作成してからGIFを書き出してください。"
            case .couldNotRender: "ペットを描画できませんでした。リグを作り直してお試しください。"
            case .couldNotEncode: "GIFを作成できませんでした。"
            case .tooLarge: "GIFの容量を抑えられませんでした。短い長さでお試しください。"
            }
        }
    }

    /// Encode only the pet and selected background. There is no desktop capture or network access.
    static func make(asset: SavedPetCharacter, options: PetGIFOptions,
                     progress: (Double) -> Void) async throws -> PetGIFResult {
        // GIF delays are centiseconds: 20/10 fps have exact 0.05/0.10 s intervals.
        let formats = [(384, 20), (320, 20), (256, 10)]
        let duration = min(5, max(3, options.duration))
        for (attempt, format) in formats.enumerated() {
            try Task.checkCancellation()
            let (dimension, fps) = format
            let draw = try frameProvider(asset: asset, motion: options.motion, duration: duration)
            let data = NSMutableData()
            let count = duration * fps
            guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil) else {
                throw ExportError.couldNotEncode
            }
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
            let properties = [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 1.0 / Double(fps),
                kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(fps)
            ]] as CFDictionary
            let size = CGSize(width: dimension, height: dimension)
            for frame in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let pet = try draw(Double(frame) / Double(fps), size)
                    let image = try composite(pet, size: dimension, background: options.background)
                    CGImageDestinationAddImage(destination, image, properties)
                }
                progress(Double(frame + 1) / Double(count))
                // Keep the progress indicator and Cancel button responsive between frames.
                await Task.yield()
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination) else { throw ExportError.couldNotEncode }
            let encoded = data as Data
            if encoded.count <= 5_000_000 {
                return PetGIFResult(data: encoded, dimension: dimension, framesPerSecond: fps, duration: duration)
            }
            if attempt == formats.count - 1 { throw ExportError.tooLarge }
            progress(0)
        }
        throw ExportError.couldNotEncode
    }

    private static func frameProvider(asset: SavedPetCharacter, motion: PetGIFOptions.Motion,
                                      duration: Int) throws -> (Double, CGSize) throws -> CGImage {
        let exporter: AvatarImageExporter?
        // Match the saved floating pet: Quality wins, and decode errors never silently switch its appearance.
        if let data = asset.qualityArchiveData {
            exporter = try AvatarImageExporter(qualityArchive: QualityAvatarArchive(data: data))
        } else if let data = asset.arilsArchiveData {
            exporter = try AvatarImageExporter(archive: AvatarArchive(data: data))
        } else { exporter = nil }
        if let exporter {
            return { time, size in
                let x: Float = motion == .lookAround ? Float(sin(time / Double(duration) * 2 * .pi)) * 0.8 : 0
                return try exporter.image(at: time, size: size,
                    gaze: motion == .lookAround ? SIMD2(x, 0) : nil, viewTurn: x)
            }
        }
        guard let image = asset.image, let document = asset.document else { throw ExportError.missingPet }
        let connection = CherryConnection()
        let snapshot = HesitateSnapshot(state: .idle, previousState: .idle, confidence: 0.8,
            awkwardness: 0.35, speechEnergy: 0, requestedAt: Date(timeIntervalSinceReferenceDate: 0))
        return { time, size in
            var parameters = connection.parameters(from: snapshot, at: Date(timeIntervalSinceReferenceDate: time + 10))
            if motion == .lookAround { parameters.gazeX = sin(time / Double(duration) * 2 * .pi) * 5 }
            let renderer = ImageRenderer(content: RiggedCharacterRenderer(image: image, document: document,
                parameters: parameters).frame(width: size.width, height: size.height))
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(size)
            guard let image = renderer.cgImage else { throw ExportError.couldNotRender }
            return image
        }
    }

    private static func composite(_ pet: CGImage, size: Int, background: NSColor) throws -> CGImage {
        guard let color = background.usingColorSpace(.sRGB),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                  bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ExportError.couldNotRender
        }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        context.setFillColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: 1)
        context.fill(bounds)
        context.draw(pet, in: bounds)
        guard let result = context.makeImage() else { throw ExportError.couldNotRender }
        return result
    }
}

enum PetGIFSharing {
    static let manualAttachmentNotice = "GIFは自動添付されません。保存したGIFを、Xの投稿画面で手動で添付してください。"
    static var postURL: URL? {
        var components = URLComponents(string: "https://x.com/intent/tweet")
        components?.queryItems = [
            URLQueryItem(name: "text", value: "Castorで作ったペットです。"),
            URLQueryItem(name: "hashtags", value: "Castor")
        ]
        // Add this compilation condition only after the repository is public.
        #if CASTOR_PUBLIC_REPOSITORY
        components?.queryItems?.append(URLQueryItem(name: "url", value: "https://github.com/Methurcoder/Castor"))
        #endif
        return components?.url
    }
}
