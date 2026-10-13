import AppKit
import Foundation

enum LayerExtractor {
    static func layerImage(from image: NSImage, part: RigPart) -> NSImage? {
        layerImage(from: image, part: part, document: nil)
    }

    static func layerImage(from image: NSImage, part: RigPart, document: RigDocument?) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let rect = pixelRect(for: part.normalizedRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard rect.width >= 2, rect.height >= 2, let cropped = cgImage.cropping(to: rect.integral) else {
            return nil
        }

        let erased = movingPartErasedImage(
            cropped,
            source: cgImage,
            part: part,
            partPixelRect: rect.integral,
            document: document,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) ?? cropped
        let background = estimatedBackgroundColor(from: cgImage)
        let transparent = backgroundTransparentImage(erased, background: background) ?? erased
        let masked = part.shape == .ellipse ? ellipseMaskedImage(transparent) ?? transparent : transparent
        return NSImage(cgImage: masked, size: CGSize(width: rect.width, height: rect.height))
    }

    static func pixelRect(for normalizedRect: CGRect, pixelWidth: CGFloat, pixelHeight: CGFloat) -> CGRect {
        CGRect(
            x: normalizedRect.minX * pixelWidth,
            y: normalizedRect.minY * pixelHeight,
            width: normalizedRect.width * pixelWidth,
            height: normalizedRect.height * pixelHeight
        )
    }

    fileprivate struct Pixel: Equatable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    private static func estimatedBackgroundColor(from image: CGImage) -> Pixel {
        let width = image.width
        let height = image.height
        let points = [
            CGPoint(x: 1, y: 1),
            CGPoint(x: max(width - 2, 0), y: 1),
            CGPoint(x: 1, y: max(height - 2, 0)),
            CGPoint(x: max(width - 2, 0), y: max(height - 2, 0))
        ]
        let samples = points.compactMap { sampledPixel(from: image, at: $0) }
        guard !samples.isEmpty else {
            return Pixel(red: 255, green: 255, blue: 255, alpha: 255)
        }

        let totals = samples.reduce((red: 0, green: 0, blue: 0)) { result, pixel in
            (
                red: result.red + Int(pixel.red),
                green: result.green + Int(pixel.green),
                blue: result.blue + Int(pixel.blue)
            )
        }
        let count = samples.count
        return Pixel(
            red: UInt8(totals.red / count),
            green: UInt8(totals.green / count),
            blue: UInt8(totals.blue / count),
            alpha: 255
        )
    }

    private static func sampledPixel(from image: CGImage, at point: CGPoint) -> Pixel? {
        guard image.width > 0, image.height > 0 else {
            return nil
        }

        let x = min(max(Int(point.x), 0), image.width - 1)
        let topOriginY = min(max(Int(point.y), 0), image.height - 1)
        let contextY = image.height - 1 - topOriginY
        var bytes = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: -CGFloat(x), y: -CGFloat(contextY))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }

    private static func movingPartErasedImage(
        _ cropped: CGImage,
        source: CGImage,
        part: RigPart,
        partPixelRect: CGRect,
        document: RigDocument?,
        pixelWidth: CGFloat,
        pixelHeight: CGFloat
    ) -> CGImage? {
        guard let document, shouldReceiveMovingPartErasures(part) else {
            return cropped
        }

        let erasers = document.parts.filter { eraser in
            shouldEraseMovingPart(eraser, from: part)
        }
        guard !erasers.isEmpty else {
            return cropped
        }

        let width = cropped.width
        let height = cropped.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let layerBounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cropped, in: layerBounds)

        for eraser in erasers {
            let eraserRect = pixelRect(for: eraser.normalizedRect, pixelWidth: pixelWidth, pixelHeight: pixelHeight).integral
            let fillRect = eraseFillRect(for: eraser, pixelRect: eraserRect)
            let localRect = fillRect.offsetBy(dx: -partPixelRect.minX, dy: -partPixelRect.minY)
            guard layerBounds.intersects(localRect) else {
                continue
            }
            let contextRect = CGRect(
                x: localRect.minX,
                y: layerBounds.height - localRect.maxY,
                width: localRect.width,
                height: localRect.height
            )

            let fill = replacementColor(for: eraser, near: eraserRect, in: source)
            context.setFillColor(fill.cgColor)
            if eraser.shape == .ellipse {
                context.fillEllipse(in: contextRect)
            } else {
                context.fill(contextRect)
            }
        }

        return context.makeImage()
    }

    private static func eraseFillRect(for part: RigPart, pixelRect: CGRect) -> CGRect {
        switch part.kind {
        case .leftEye, .rightEye:
            pixelRect.insetBy(dx: -max(2, pixelRect.width * 0.16), dy: -max(2, pixelRect.height * 0.28)).integral
        case .mouth:
            pixelRect.insetBy(dx: -max(1, pixelRect.width * 0.18), dy: -max(1, pixelRect.height * 0.32)).integral
        case .head, .body, .hair:
            pixelRect
        }
    }

    private static func shouldReceiveMovingPartErasures(_ part: RigPart) -> Bool {
        switch part.kind {
        case .head, .hair, .body:
            true
        case .leftEye, .rightEye, .mouth:
            false
        }
    }

    private static func shouldEraseMovingPart(_ eraser: RigPart, from part: RigPart) -> Bool {
        guard eraser.zIndex > part.zIndex else {
            return false
        }

        switch eraser.kind {
        case .leftEye, .rightEye, .mouth:
            return true
        case .head, .body, .hair:
            return false
        }
    }

    private static func replacementColor(for eraser: RigPart, near rect: CGRect, in image: CGImage) -> ColorComponents {
        let samples = skinLikeSamples(for: eraser.kind, near: rect, in: image)
        guard !samples.isEmpty else {
            return ColorComponents(red: 238, green: 214, blue: 202, alpha: 255)
        }

        let totals = samples.reduce((red: 0, green: 0, blue: 0)) { result, pixel in
            (
                red: result.red + Int(pixel.red),
                green: result.green + Int(pixel.green),
                blue: result.blue + Int(pixel.blue)
            )
        }
        let count = samples.count
        return ColorComponents(
            red: UInt8(totals.red / count),
            green: UInt8(totals.green / count),
            blue: UInt8(totals.blue / count),
            alpha: 255
        )
    }

    private static func skinLikeSamples(for kind: RigPartKind, near rect: CGRect, in image: CGImage) -> [Pixel] {
        let preferred = preferredSkinSamples(for: kind, near: rect, in: image)
        if preferred.count >= 3 {
            return preferred
        }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let expanded = rect.insetBy(dx: -max(4, rect.width * 0.22), dy: -max(4, rect.height * 0.45)).intersection(imageBounds)
        guard !expanded.isNull else {
            return []
        }

        let strideX = max(1, Int(expanded.width / 12))
        let strideY = max(1, Int(expanded.height / 8))
        var samples: [Pixel] = []

        for x in stride(from: Int(expanded.minX), through: Int(expanded.maxX), by: strideX) {
            samples.appendIfSkinLike(sampledPixel(from: image, at: CGPoint(x: CGFloat(x), y: CGFloat(Int(expanded.minY)))))
            samples.appendIfSkinLike(sampledPixel(from: image, at: CGPoint(x: CGFloat(x), y: CGFloat(Int(expanded.maxY)))))
        }

        for y in stride(from: Int(expanded.minY), through: Int(expanded.maxY), by: strideY) {
            samples.appendIfSkinLike(sampledPixel(from: image, at: CGPoint(x: CGFloat(Int(expanded.minX)), y: CGFloat(y))))
            samples.appendIfSkinLike(sampledPixel(from: image, at: CGPoint(x: CGFloat(Int(expanded.maxX)), y: CGFloat(y))))
        }

        return samples
    }

    private static func preferredSkinSamples(for kind: RigPartKind, near rect: CGRect, in image: CGImage) -> [Pixel] {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sampleRect: CGRect
        switch kind {
        case .leftEye, .rightEye:
            sampleRect = CGRect(
                x: rect.minX - rect.width * 0.18,
                y: rect.maxY + rect.height * 0.28,
                width: rect.width * 1.36,
                height: max(4, rect.height * 0.85)
            )
        case .mouth:
            sampleRect = CGRect(
                x: rect.minX - rect.width * 0.24,
                y: rect.minY - rect.height * 1.05,
                width: rect.width * 1.48,
                height: max(4, rect.height * 0.75)
            )
        case .head, .body, .hair:
            sampleRect = rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.2)
        }

        let clampedRect = sampleRect.intersection(imageBounds)
        guard !clampedRect.isNull else {
            return []
        }

        let columns = 7
        let rows = 4
        var samples: [Pixel] = []
        for column in 0..<columns {
            for row in 0..<rows {
                let x = clampedRect.minX + clampedRect.width * (CGFloat(column) + 0.5) / CGFloat(columns)
                let y = clampedRect.minY + clampedRect.height * (CGFloat(row) + 0.5) / CGFloat(rows)
                samples.appendIfSkinLike(sampledPixel(from: image, at: CGPoint(x: x, y: y)))
            }
        }
        return samples
    }

    private static func backgroundTransparentImage(_ source: CGImage, background: Pixel) -> CGImage? {
        let width = source.width
        let height = source.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [(x: Int, y: Int)] = []

        func enqueueIfBackground(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else {
                return
            }
            let index = y * width + x
            guard !visited[index], isBackgroundLike(pixelAt: index, in: bytes, background: background) else {
                return
            }
            visited[index] = true
            queue.append((x, y))
        }

        for x in 0..<width {
            enqueueIfBackground(x, 0)
            enqueueIfBackground(x, height - 1)
        }
        for y in 0..<height {
            enqueueIfBackground(0, y)
            enqueueIfBackground(width - 1, y)
        }

        var queueIndex = 0
        while queueIndex < queue.count {
            let point = queue[queueIndex]
            queueIndex += 1
            let byteOffset = (point.y * width + point.x) * bytesPerPixel
            bytes[byteOffset + 3] = 0

            enqueueIfBackground(point.x + 1, point.y)
            enqueueIfBackground(point.x - 1, point.y)
            enqueueIfBackground(point.x, point.y + 1)
            enqueueIfBackground(point.x, point.y - 1)
        }

        return context.makeImage()
    }

    private static func isBackgroundLike(pixelAt index: Int, in bytes: [UInt8], background: Pixel) -> Bool {
        let offset = index * 4
        guard bytes[offset + 3] > 0 else {
            return false
        }

        let red = Int(bytes[offset]) - Int(background.red)
        let green = Int(bytes[offset + 1]) - Int(background.green)
        let blue = Int(bytes[offset + 2]) - Int(background.blue)
        let distance = sqrt(Double(red * red + green * green + blue * blue))
        return distance < 42
    }

    private static func ellipseMaskedImage(_ source: CGImage) -> CGImage? {
        let width = source.width
        let height = source.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.addEllipse(in: rect)
        context.clip()
        context.draw(source, in: rect)
        return context.makeImage()
    }
}

private struct ColorComponents {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    var cgColor: CGColor {
        CGColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}

private extension Array where Element == LayerExtractor.Pixel {
    mutating func appendIfSkinLike(_ pixel: LayerExtractor.Pixel?) {
        guard let pixel, pixel.alpha > 40 else {
            return
        }

        let brightness = (Int(pixel.red) + Int(pixel.green) + Int(pixel.blue)) / 3
        let channelSpread = Swift.max(Int(pixel.red), Int(pixel.green), Int(pixel.blue)) - Swift.min(Int(pixel.red), Int(pixel.green), Int(pixel.blue))
        guard brightness > 96, channelSpread < 95 else {
            return
        }

        append(pixel)
    }
}
