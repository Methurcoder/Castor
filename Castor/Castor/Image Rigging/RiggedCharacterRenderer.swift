import AppKit
import SwiftUI
import CastorCore

struct RiggedCharacterRenderer: View {
    let image: NSImage
    let document: RigDocument
    let parameters: MotionParameters
    private let layers: [RiggedLayer]

    init(image: NSImage, document: RigDocument, parameters: MotionParameters) {
        self.image = image
        self.document = document
        self.parameters = parameters
        self.layers = RiggedLayerCache.layers(for: image, document: document)
    }

    var body: some View {
        GeometryReader { proxy in
            let headPivot = headPivotPoint(in: proxy.size)
            ZStack {
                ForEach(layers) { layer in
                    let part = layer.part
                    Image(nsImage: layer.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: partRect(part, in: proxy.size).width, height: partRect(part, in: proxy.size).height)
                        .clipShape(part.shape == .ellipse ? AnyShape(Ellipse()) : AnyShape(Rectangle()))
                        .scaleEffect(scale(for: part), anchor: UnitPoint(x: part.anchorPoint.x, y: part.anchorPoint.y))
                        .rotationEffect(.degrees(rotation(for: part)), anchor: UnitPoint(x: part.anchorPoint.x, y: part.anchorPoint.y))
                        .position(position(for: part, in: proxy.size, headPivot: headPivot))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(document.imageSize.width / max(document.imageSize.height, 1), contentMode: .fit)
        .accessibilityLabel("Rigged character animated by Awkward Engine")
    }

    private func partRect(_ part: RigPart, in size: CGSize) -> CGRect {
        CGRect(
            x: part.normalizedRect.minX * size.width,
            y: part.normalizedRect.minY * size.height,
            width: part.normalizedRect.width * size.width,
            height: part.normalizedRect.height * size.height
        )
    }

    /// World-space pivot that `headTilt` rotation is applied around for every head-attached part
    /// (head, hair, both eyes, mouth). Using the `head` part's own `anchorPoint` (mapped into
    /// view space) as a single shared pivot — instead of each part rotating around its own,
    /// independent `anchorPoint` — is what keeps the eyes/mouth/hair traveling on the same
    /// circular arc as the head outline as `headTilt` grows, instead of drifting apart from it
    /// (see `RiggedCharacterRendererGeometryTests` / `headAnchoredRotation(...)`).
    private func headPivotPoint(in size: CGSize) -> CGPoint {
        guard let headPart = document.parts.first(where: { $0.kind == .head }) else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let rect = partRect(headPart, in: size)
        return CGPoint(
            x: rect.minX + rect.width * headPart.anchorPoint.x,
            y: rect.minY + rect.height * headPart.anchorPoint.y
        )
    }

    private func position(for part: RigPart, in size: CGSize, headPivot: CGPoint) -> CGPoint {
        let rect = partRect(part, in: size)
        let offset = offset(for: part)
        let restingCenter = CGPoint(x: rect.midX + offset.width, y: rect.midY + offset.height)

        guard Self.isHeadAnchored(part.kind) else {
            return restingCenter
        }

        // Rotate this part's resting center around the shared head pivot by `headTilt` degrees,
        // so every head-attached part orbits the same point the head itself rotates around
        // (matching the `rotationEffect(anchor:)` applied to the head part).
        return Self.headAnchoredRotation(
            point: restingCenter,
            pivot: headPivot,
            degrees: parameters.headTilt
        )
    }

    private static func isHeadAnchored(_ kind: RigPartKind) -> Bool {
        switch kind {
        case .head, .hair, .leftEye, .rightEye, .mouth:
            true
        case .body:
            false
        }
    }

    /// Pure coordinate-space rotation of `point` around `pivot` by `degrees`. Kept as a pure
    /// function (no SwiftUI/view dependency) so the head-anchored-rotation invariant — every
    /// head-attached part keeps the same offset from the head pivot regardless of `headTilt` — is
    /// unit-testable without a view hierarchy.
    static func headAnchoredRotation(point: CGPoint, pivot: CGPoint, degrees: Double) -> CGPoint {
        guard degrees != 0 else {
            return point
        }
        let radians = degrees * .pi / 180
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let cosTheta = cos(radians)
        let sinTheta = sin(radians)
        return CGPoint(
            x: pivot.x + dx * cosTheta - dy * sinTheta,
            y: pivot.y + dx * sinTheta + dy * cosTheta
        )
    }

    private func offset(for part: RigPart) -> CGSize {
        switch part.kind {
        case .head, .hair:
            CGSize(width: 0, height: parameters.bodyLift + parameters.headBob)
        case .leftEye, .rightEye:
            CGSize(width: parameters.gazeX * 0.7, height: parameters.bodyLift + parameters.headBob + parameters.gazeY * 0.45)
        case .mouth:
            CGSize(width: 0, height: parameters.bodyLift + parameters.headBob)
        case .body:
            CGSize(width: 0, height: parameters.bodyLift * 0.38 + parameters.headBob * 0.12)
        }
    }

    private func rotation(for part: RigPart) -> Double {
        switch part.kind {
        case .head, .hair, .leftEye, .rightEye, .mouth:
            parameters.headTilt
        case .body:
            parameters.headTilt * 0.16
        }
    }

    private func scale(for part: RigPart) -> CGSize {
        switch part.kind {
        case .mouth:
            CGSize(width: 1 + parameters.mouthOpen * 0.10, height: 1 + parameters.mouthOpen * 0.95)
        case .leftEye, .rightEye:
            CGSize(width: parameters.eyeScale, height: max(0.08, parameters.eyeOpen))
        default:
            CGSize(width: 1, height: 1)
        }
    }
}

private struct RiggedLayer: Identifiable {
    var id: String
    var part: RigPart
    var image: NSImage
}

private enum RiggedLayerCache {
    private struct CacheKey: Hashable {
        let imageID: ObjectIdentifier
        let document: RigDocument
    }

    private struct CacheEntry {
        let sourceImage: NSImage
        let layers: [RiggedLayer]
    }

    private static let maximumEntryCount = 8
    private static var cachedEntries: [CacheKey: CacheEntry] = [:]
    private static var usageOrder: [CacheKey] = []

    static func layers(for image: NSImage, document: RigDocument) -> [RiggedLayer] {
        let key = CacheKey(imageID: ObjectIdentifier(image), document: document)
        if let entry = cachedEntries[key] {
            markAsRecentlyUsed(key)
            return entry.layers
        }

        let layers = extractLayers(from: image, document: document)
        cachedEntries[key] = CacheEntry(sourceImage: image, layers: layers)
        markAsRecentlyUsed(key)
        evictOldEntriesIfNeeded()
        return layers
    }

    private static func extractLayers(from image: NSImage, document: RigDocument) -> [RiggedLayer] {
        document.parts
            .sorted(by: { $0.zIndex < $1.zIndex })
            .compactMap { part -> RiggedLayer? in
                guard let layerImage = LayerExtractor.layerImage(from: image, part: part, document: document) else {
                    return nil
                }

                return RiggedLayer(id: part.id.uuidString, part: part, image: layerImage)
            }
    }

    private static func markAsRecentlyUsed(_ key: CacheKey) {
        usageOrder.removeAll(where: { $0 == key })
        usageOrder.append(key)
    }

    private static func evictOldEntriesIfNeeded() {
        while usageOrder.count > maximumEntryCount {
            let oldestKey = usageOrder.removeFirst()
            cachedEntries.removeValue(forKey: oldestKey)
        }
    }
}
