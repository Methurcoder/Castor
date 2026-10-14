import AppKit
import SwiftUI
import CastorCore

struct RiggedCharacterRenderer: View {
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    private func L(_ source: String) -> String { CastorAppStrings.label(source, language: displayLanguage) }

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
        .accessibilityLabel(L("Rigged character animated by Awkward Engine"))
    }

    private func partRect(_ part: RigPart,in size:CGSize)->CGRect {ManualRigGeometry.partRect(part,in:size)}
    private func headPivotPoint(in size:CGSize)->CGPoint {ManualRigGeometry.headPivot(document:document,size:size)}
    private func position(for part:RigPart,in size:CGSize,headPivot:CGPoint)->CGPoint {ManualRigGeometry.position(part:part,size:size,pivot:headPivot,parameters:parameters)}
    static func headAnchoredRotation(point:CGPoint,pivot:CGPoint,degrees:Double)->CGPoint {ManualRigGeometry.headAnchoredRotation(point:point,pivot:pivot,degrees:degrees)}
    private func rotation(for part:RigPart)->Double {ManualRigGeometry.rotation(kind:part.kind,parameters:parameters)}
    private func scale(for part:RigPart)->CGSize {ManualRigGeometry.scale(kind:part.kind,parameters:parameters)}

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
        LayerExtractor.layerImages(from:image,document:document).map { part, layerImage in
            RiggedLayer(id:part.id.uuidString,part:part,image:layerImage)
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
