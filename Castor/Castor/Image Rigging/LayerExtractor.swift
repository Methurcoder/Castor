import CastorCore
import AppKit
import Foundation
import PetRuntime

/// Shared CPU extraction; the Mac host keeps the same NSImage view interface.
enum LayerExtractor {
    static func layerImage(from image:NSImage,part:RigPart)->NSImage? {layerImage(from:image,part:part,document:nil)}
    static func layerImage(from image:NSImage,part:RigPart,document:RigDocument?)->NSImage? {
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]),
              let source=try? PortableRigImage(png:data),let layer=ManualRigLayers.layer(source:source,part:part,document:document) else{return nil}
        // PNG carries straight alpha; ImageIO/AppKit applies premultiplication once.
        guard let result=NSImage(data:layer.image.pngData()) else{return nil}
        let rect=pixelRect(for:part.normalizedRect,pixelWidth:CGFloat(cg.width),pixelHeight:CGFloat(cg.height))
        result.size=rect.size;return result
    }
    static func layerImages(from image:NSImage,document:RigDocument)->[(RigPart,NSImage)] {
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]),
              let source=try? PortableRigImage(png:data),let layers=try? ManualRigLayers.build(source:source,document:document) else{return []}
        return layers.compactMap { layer in
            guard let result=NSImage(data:layer.image.pngData()) else{return nil}
            result.size=pixelRect(for:layer.part.normalizedRect,pixelWidth:CGFloat(cg.width),pixelHeight:CGFloat(cg.height)).size
            return (layer.part,result)
        }
    }
    static func pixelRect(for normalizedRect:CGRect,pixelWidth:CGFloat,pixelHeight:CGFloat)->CGRect {
        CGRect(x:normalizedRect.minX*pixelWidth,y:normalizedRect.minY*pixelHeight,width:normalizedRect.width*pixelWidth,height:normalizedRect.height*pixelHeight)
    }
}
