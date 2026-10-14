import ArilsCore
import ArilsPlayer
import CastorCore
import Foundation

/// The legacy Mac manual document and original pixels remain the saved asset.
/// The static archive supplies bounds/input controls only; playback never substitutes
/// an automatically generated rig for the user's manual parts.
public struct ManualPet: Sendable {
    public let document: RigDocument
    public let source: PortableRigImage
    public let controlArchive: AvatarArchive
    public let layers: [ManualRigLayerPixels]
    public init(document: RigDocument, source: PortableRigImage) throws {
        try document.validate()
        self.document = document
        self.source = source
        let extracted = try ManualRigLayers.build(source: source, document: document)
        guard !extracted.isEmpty else { throw RigDocument.ValidationError.invalid }
        layers = extracted
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let head = document.parts.first(where: { $0.kind == .head }).map {
            ManualRigLayers.pixelRect($0.normalizedRect, width: source.width, height: source.height)
        } ?? bounds
        let body = AvatarPart(id: "manualOriginal", kind: .body, rect: bounds, zOrder: 0, opacity: 0,
                              mesh: .grid(rect: bounds, columns: 1, rows: 1))
        let zone = AvatarPart(id: "manualHeadZone", kind: .head, rect: head, zOrder: 1, opacity: 0,
                              mesh: .grid(rect: head, columns: 1, rows: 1))
        let empty = try PortableRigImage(width: 1, height: 1, rgba: [0,0,0,0])
        controlArchive = AvatarArchive(rig: AvatarRig(imageWidth: source.width, imageHeight: source.height,
            parts: [body, zone], parameters: StandardParameters.all),
            texturePNGs: [body.id: empty.pngData(), zone.id: empty.pngData()])
    }
    public func data() throws -> Data {
        struct Saved: Encodable { let document: RigDocument; let imageData: Data }
        return try JSONEncoder().encode(Saved(document: document, imageData: source.pngData()))
    }
}

/// CPU counterpart of the legacy SwiftUI manual renderer. Part geometry and
/// Cherry Connection are shared, including eye/mouth scale and head-pivot orbit.
final class ManualPetRenderer {
    let pet: ManualPet
    let layers: [ManualRigLayerPixels]
    private let connection = CherryConnection()
    private var snapshot = HesitateSnapshot(state: .idle, previousState: .idle, confidence: 0.58,
        awkwardness: 0.34, speechEnergy: 0.10, requestedAt: Date(timeIntervalSinceReferenceDate: 0))
    private var touchedUntil = -Double.infinity
    private var previousPointer: SIMD2<Float>?
    private var previousTime: Double?
    init(pet: ManualPet) { self.pet = pet; layers = pet.layers }
    func pointerMoved(_ point: SIMD2<Float>?, control: PetPlayer, width: Int, height: Int, time: Double) {
        defer { previousPointer = point; previousTime = time }
        guard let point, let previousPointer, let previousTime, time > previousTime else { return }
        let dx = point.x - previousPointer.x, dy = point.y - previousPointer.y
        let (scale, offset) = control.placement(canvasWidth: width, canvasHeight: height)
        let image = (point-offset)/max(scale, 0.0001)
        let head = control.rig.firstPart(ofKind: .head)?.rect
        if head?.contains(CGPoint(x: Double(image.x), y: Double(image.y))) == true,
           sqrt(dx*dx+dy*dy)/Float(time-previousTime)>20 { touchedUntil = time+0.9 }
    }
    func render(into canvas: inout PetCanvas, control: PetPlayer, time: Double, opacity: Float) {
        guard time.isFinite else { return }
        let date = Date(timeIntervalSinceReferenceDate: time)
        let state: MotionState = control.behavior == .listening ? .listening : .idle
        if state != snapshot.state {
            snapshot.previousState = snapshot.state; snapshot.state = state; snapshot.requestedAt = date
        }
        var input = TrilobiteInputSnapshot.inactive
        input.microphoneEnabled = control.microphoneEnabled; input.audioLevel = Double(control.microphoneLevel)
        let parameters = connection.parameters(from: snapshot, trilobite: input,
            context: MotionContext(touched: time<touchedUntil, isSpeaking: control.isSpeaking,
                                   isListening: state == .listening), at: date)
        render(into: &canvas, control: control, parameters: parameters, opacity: opacity)
    }
    func render(into canvas: inout PetCanvas, control: PetPlayer, parameters: MotionParameters, opacity: Float) {
        canvas.bgra = [UInt8](repeating: 0, count: canvas.width*canvas.height*4)
        let (fit, offset) = control.placement(canvasWidth: canvas.width, canvasHeight: canvas.height)
        let size = pet.document.imageSize
        // SwiftUI applies motion in its fitted view coordinate system.
        let logical = CGSize(width: Double(pet.source.width)*Double(fit), height: Double(pet.source.height)*Double(fit))
        let pivot = ManualRigGeometry.headPivot(document: pet.document, size: logical)
        let fade = opacity.isFinite ? Double(min(max(opacity,0),1)) : 1
        guard size.width > 0, size.height > 0, fit > 0 else { return }
        for layer in layers {
            let part = layer.part, rect = ManualRigGeometry.partRect(part, in: logical)
            let position = ManualRigGeometry.position(part: part, size: logical, pivot: pivot, parameters: parameters)
            let scale = ManualRigGeometry.scale(kind: part.kind, parameters: parameters)
            let angle = ManualRigGeometry.rotation(kind: part.kind, parameters: parameters)*Double.pi/180
            let cosine = cos(angle), sine = sin(angle)
            let ax = rect.width*part.anchorPoint.x, ay = rect.height*part.anchorPoint.y
            let cx = Double(offset.x)+position.x-rect.width/2+ax
            let cy = Double(offset.y)+position.y-rect.height/2+ay
            func transformed(_ x: Double,_ y: Double) -> CGPoint {
                let dx=(x-ax)*scale.width,dy=(y-ay)*scale.height
                return CGPoint(x:cx+dx*cosine-dy*sine,y:cy+dx*sine+dy*cosine)
            }
            let corners=[transformed(0,0),transformed(rect.width,0),transformed(0,rect.height),transformed(rect.width,rect.height)]
            let x0=max(0,Int(floor(corners.map(\.x).min()!))),x1=min(canvas.width,Int(ceil(corners.map(\.x).max()!)))
            let y0=max(0,Int(floor(corners.map(\.y).min()!))),y1=min(canvas.height,Int(ceil(corners.map(\.y).max()!)))
            guard x0<x1,y0<y1 else {continue}
            let image=layer.image
            for y in y0..<y1 { for x in x0..<x1 {
                let dx=Double(x)+0.5-cx,dy=Double(y)+0.5-cy
                let u=(dx*cosine+dy*sine)/scale.width+ax
                let v=(-dx*sine+dy*cosine)/scale.height+ay
                guard u>=0,v>=0,u<rect.width,v<rect.height else {continue}
                if part.shape == .ellipse {
                    let ex=(u-rect.width/2)/(rect.width/2),ey=(v-rect.height/2)/(rect.height/2)
                    if ex*ex+ey*ey>1 {continue}
                }
                let sx=u/rect.width*Double(image.width)-0.5,sy=v/rect.height*Double(image.height)-0.5
                let ix=Int(floor(sx)),iy=Int(floor(sy)),fx=sx-floor(sx),fy=sy-floor(sy)
                var premult=[Double](repeating:0,count:4)
                for row in 0..<2 {for column in 0..<2 {
                    let px=min(max(ix+column,0),image.width-1),py=min(max(iy+row,0),image.height-1)
                    let i=(py*image.width+px)*4,weight=(column==0 ? 1-fx:fx)*(row==0 ? 1-fy:fy)*fade
                    let alpha=Double(image.rgba[i+3])/255
                    for c in 0..<3 {premult[c]+=Double(image.rgba[i+2-c])*alpha*weight}
                    premult[3]+=Double(image.rgba[i+3])*weight
                }}
                let out=(y*canvas.width+x)*4,remaining=1-premult[3]/255
                for c in 0..<4 {canvas.bgra[out+c]=UInt8(clamping:Int((premult[c]+Double(canvas.bgra[out+c])*remaining).rounded()))}
            }}
        }
    }
}
