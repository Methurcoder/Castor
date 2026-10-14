#if os(Windows)
import CastorCore
import CDesktopUI
import Foundation
import PetRuntime

/// Native editing preserves all legacy manual document fields. Nothing is saved
/// until the user chooses Save; editing an existing pet creates a new library copy.
enum WindowsManualRiggingFlow {
    static func edit(_ existing: ManualPet? = nil, language: SettingsDisplayLanguage) throws -> PetAsset? {
        let ja = language == .japanese
        let source: PortableRigImage
        var document: RigDocument
        if let existing { source = existing.source; document = existing.document }
        else {
            guard let file = try WindowsRiggingFlow.choose(kind: "image") else { return nil }
            source = try PortableRigImage(png: Data(contentsOf: file))
            document = RigDocument.starter(imageName: file.lastPathComponent,
                imageSize: CGSize(width: source.width, height: source.height))
        }
        func label(_ kind: RigPartKind) -> String {
            if !ja { return ["Head","Viewer-left eye","Viewer-right eye","Mouth","Body","Hair"][RigPartKind.allCases.firstIndex(of: kind)!] }
            return ["頭","見る側の左目","見る側の右目","口","体","髪"][RigPartKind.allCases.firstIndex(of: kind)!]
        }
        while true {
            let items = [ja ? "保存して表示（新しいコピー）" : "Save and display a new copy",
                         ja ? "部位を追加" : "Add a part"] + document.parts.map {label($0.kind)+" · "+String($0.zIndex)}
            guard let action = try WindowsRiggingFlow.option(title: ja ? "Castor - 手動リグ" : "Castor - Manual rig", items: items) else { return nil }
            if action == 0 {
                let pet = try ManualPet(document: document, source: source)
                try PortablePetLibrary(root: WindowsRiggingFlow.directory).saveNew(pet.data())
                return .manual(pet)
            }
            if action == 1 {
                guard document.parts.count < 64 else { throw RigDocument.ValidationError.invalid }
                guard let kind = try WindowsRiggingFlow.option(title: ja ? "追加する部位" : "Part kind", items: RigPartKind.allCases.map(label)) else { continue }
                document.parts.append(RigPart(kind: RigPartKind.allCases[kind],
                    normalizedRect: CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5), shape: .rectangle,
                    zIndex: (document.parts.map(\.zIndex).max() ?? 0)+1))
                continue
            }
            let index = action-2
            guard let field = try WindowsRiggingFlow.option(title: label(document.parts[index].kind), items: ja ?
                ["画像上で範囲を編集","形を変更","回転中心を変更","重ね順を変更","種類を変更","部位を削除"] :
                ["Edit rectangle on image","Change shape","Change rotation anchor","Change layer order","Change part kind","Delete part"]) else { continue }
            var part = document.parts[index]
            switch field {
            case 0:
                let r = ManualRigLayers.pixelRect(part.normalizedRect,width: source.width,height: source.height)
                var rectangle = [Float(r.minX),Float(r.minY),Float(r.width),Float(r.height)]
                let result = source.rgba.withUnsafeBufferPointer { pixels in rectangle.withUnsafeMutableBufferPointer {
                    castor_review_part_rectangle(pixels.baseAddress, Int32(source.width), Int32(source.height), $0.baseAddress)
                }}
                if result < 0 { throw WindowsRiggingFlow.FlowError.dialogFailed }
                if result > 0 { part.normalizedRect = CGRect(x: Double(rectangle[0])/Double(source.width),y: Double(rectangle[1])/Double(source.height),width: Double(rectangle[2])/Double(source.width),height: Double(rectangle[3])/Double(source.height)) }
            case 1:
                if let shape = try WindowsRiggingFlow.option(title: ja ? "形" : "Shape", items: ja ? ["矩形","楕円"] : ["Rectangle","Ellipse"]) { part.shape = shape == 0 ? .rectangle : .ellipse }
            case 2:
                if let value = try WindowsRiggingFlow.text(title: ja ? "回転中心: X,Y（各0〜100%、左上が0,0）" : "Anchor: X,Y (0–100%, top-left is 0,0)", value: "\(part.anchorPoint.x*100),\(part.anchorPoint.y*100)") {
                    let values = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    guard values.count == 2, values.allSatisfy({$0.isFinite && (0...100).contains($0)}) else { throw RigDocument.ValidationError.invalid }
                    part.anchorPoint = CGPoint(x: values[0]/100,y: values[1]/100)
                }
            case 3:
                if let value = try WindowsRiggingFlow.text(title: ja ? "重ね順（大きい値ほど前）" : "Layer order (larger is in front)", value: String(part.zIndex)) {
                    guard let order = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),order.isFinite,abs(order)<=1_000_000 else {throw RigDocument.ValidationError.invalid}
                    part.zIndex = order
                }
            case 4:
                if let kind = try WindowsRiggingFlow.option(title: ja ? "種類" : "Part kind", items: RigPartKind.allCases.map(label)) {part.kind = RigPartKind.allCases[kind]}
            case 5:
                if document.parts.count > 1 { document.parts.remove(at: index) };continue
            default: break
            }
            document.parts[index] = part
            try document.validate()
        }
    }
}
#endif
