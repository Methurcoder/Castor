import CastorCore
import Foundation

public struct ManualRigLayerPixels: Sendable {
    public let part: RigPart
    public let image: PortableRigImage
}

/// Legacy rectangle/ellipse extraction and backing repair, shared by both OSes.
public enum ManualRigLayers {
    public static func build(source: PortableRigImage,document: RigDocument) throws -> [ManualRigLayerPixels] {
        try document.validate()
        return document.parts.sorted{$0.zIndex<$1.zIndex}.compactMap {layer(source:source,part:$0,document:document)}
    }
    public static func pixelRect(_ normalized: CGRect,width:Int,height:Int) -> CGRect {
        CGRect(x:normalized.minX*CGFloat(width),y:normalized.minY*CGFloat(height),width:normalized.width*CGFloat(width),height:normalized.height*CGFloat(height))
    }
    public static func layer(source: PortableRigImage,part:RigPart,document:RigDocument?) -> ManualRigLayerPixels? {
        let rect=pixelRect(part.normalizedRect,width:source.width,height:source.height)
        let crop=rect.integral.intersection(CGRect(x:0,y:0,width:source.width,height:source.height))
        guard !crop.isNull,crop.width>=2,crop.height>=2 else{return nil}
        let width=Int(crop.width),height=Int(crop.height),originX=Int(crop.minX),originY=Int(crop.minY)
        var rgba=[UInt8](repeating:0,count:width*height*4)
        for y in 0..<height {
            let begin=((originY+y)*source.width+originX)*4
            rgba.replaceSubrange(y*width*4..<(y+1)*width*4,with:source.rgba[begin..<begin+width*4])
        }
        if [.head,.hair,.body].contains(part.kind),let document {
            for eraser in document.parts where eraser.zIndex>part.zIndex && [.leftEye,.rightEye,.mouth].contains(eraser.kind) {
                let eye=pixelRect(eraser.normalizedRect,width:source.width,height:source.height).integral
                let spreadX=max(eraser.kind == .mouth ? 1:2,eye.width*(eraser.kind == .mouth ? 0.18:0.16))
                let spreadY=max(eraser.kind == .mouth ? 1:2,eye.height*(eraser.kind == .mouth ? 0.32:0.28))
                let fill=eye.insetBy(dx:-spreadX,dy:-spreadY).integral.offsetBy(dx:-crop.minX,dy:-crop.minY)
                let clipped=fill.intersection(CGRect(x:0,y:0,width:width,height:height))
                guard !clipped.isNull else{continue}
                let color=replacementColor(kind:eraser.kind,near:eye,source:source)
                for y in max(0,Int(floor(clipped.minY)))..<min(height,Int(ceil(clipped.maxY))) {
                    for x in max(0,Int(floor(clipped.minX)))..<min(width,Int(ceil(clipped.maxX))) {
                        let coverage=eraser.shape == .ellipse ? ellipseCoverage(x:x,y:y,rect:fill):1
                        guard coverage>0 else{continue}
                        let i=(y*width+x)*4
                        let oldAlpha=Double(rgba[i+3])/255,newAlpha=coverage+oldAlpha*(1-coverage)
                        for c in 0..<3 {rgba[i+c]=UInt8(clamping:Int(((Double(color[c])*coverage+Double(rgba[i+c])*oldAlpha*(1-coverage))/max(newAlpha,0.0001)).rounded()))}
                        rgba[i+3]=UInt8(clamping:Int((newAlpha*255).rounded()))
                    }
                }
            }
        }
        let corners=[pixel(source,x:1,y:1),pixel(source,x:source.width-2,y:1),pixel(source,x:1,y:source.height-2),pixel(source,x:source.width-2,y:source.height-2)]
        let background=(0..<3).map {c in corners.reduce(0){$0+Int($1[c])}/4}
        var visited=[Bool](repeating:false,count:width*height),queue=[Int]();queue.reserveCapacity(width*height/4)
        func enqueue(_ x:Int,_ y:Int) {
            guard x>=0,y>=0,x<width,y<height else{return}
            let index=y*width+x,i=index*4
            guard !visited[index],rgba[i+3]>0 else{return}
            let a=Double(rgba[i+3])/255
            let distance=(0..<3).reduce(0.0){sum,c in let d=Double(rgba[i+c])*a-Double(background[c]);return sum+d*d}
            guard distance<42*42 else{return}
            visited[index]=true;queue.append(index)
        }
        for x in 0..<width {enqueue(x,0);enqueue(x,height-1)}
        for y in 0..<height {enqueue(0,y);enqueue(width-1,y)}
        var cursor=0
        while cursor<queue.count {
            let i=queue[cursor],x=i%width,y=i/width;cursor+=1;rgba[i*4+3]=0
            enqueue(x+1,y);enqueue(x-1,y);enqueue(x,y+1);enqueue(x,y-1)
        }
        if part.shape == .ellipse {
            let bounds=CGRect(x:0,y:0,width:width,height:height)
            for y in 0..<height {for x in 0..<width {
                let i=(y*width+x)*4;rgba[i+3]=UInt8(clamping:Int((Double(rgba[i+3])*ellipseCoverage(x:x,y:y,rect:bounds)).rounded()))
            }}
        }
        guard let image=try? PortableRigImage(width:width,height:height,rgba:rgba) else{return nil}
        return ManualRigLayerPixels(part:part,image:image)
    }
    private static func ellipseCoverage(x:Int,y:Int,rect:CGRect) -> Double {
        var covered=0
        for iy in 0..<4 {for ix in 0..<4 {
            let dx=(CGFloat(x)+(CGFloat(ix)+0.5)/4-rect.midX)/(rect.width/2)
            let dy=(CGFloat(y)+(CGFloat(iy)+0.5)/4-rect.midY)/(rect.height/2)
            if dx*dx+dy*dy<=1 {covered+=1}
        }}
        return Double(covered)/16
    }
    private static func pixel(_ source:PortableRigImage,x:Int,y:Int) -> [UInt8] {
        let x=min(max(x,0),source.width-1),y=min(max(y,0),source.height-1),i=(y*source.width+x)*4
        let alpha=Int(source.rgba[i+3])
        return (0..<3).map {UInt8((Int(source.rgba[i+$0])*alpha+127)/255)}+[source.rgba[i+3]]
    }
    private static func skin(_ source:PortableRigImage,x:CGFloat,y:CGFloat) -> [UInt8]? {
        let p=pixel(source,x:Int(x),y:Int(y)),rgb=p.prefix(3).map(Int.init)
        guard p[3]>40,rgb.reduce(0,+)/3>96,rgb.max()!-rgb.min()!<95 else{return nil};return p
    }
    private static func replacementColor(kind:RigPartKind,near rect:CGRect,source:PortableRigImage) -> [UInt8] {
        let preferred: CGRect
        if kind == .mouth {preferred=CGRect(x:rect.minX-rect.width*0.24,y:rect.minY-rect.height*1.05,width:rect.width*1.48,height:max(4,rect.height*0.75))}
        else {preferred=CGRect(x:rect.minX-rect.width*0.18,y:rect.maxY+rect.height*0.28,width:rect.width*1.36,height:max(4,rect.height*0.85))}
        let image=CGRect(x:0,y:0,width:source.width,height:source.height),bounds=preferred.intersection(image)
        var samples=[[UInt8]]()
        if !bounds.isNull {
            for x in 0..<7 {for y in 0..<4 {
                if let value=skin(source,x:bounds.minX+bounds.width*(CGFloat(x)+0.5)/7,y:bounds.minY+bounds.height*(CGFloat(y)+0.5)/4){samples.append(value)}
            }}
        }
        if samples.count<3 {
            samples.removeAll()
            let border=rect.insetBy(dx:-max(4,rect.width*0.22),dy:-max(4,rect.height*0.45)).intersection(image)
            if !border.isNull {
                for x in stride(from:Int(border.minX),through:Int(border.maxX),by:max(1,Int(border.width/12))) {
                    for y in [Int(border.minY),Int(border.maxY)] {if let p=skin(source,x:CGFloat(x),y:CGFloat(y)){samples.append(p)}}
                }
                for y in stride(from:Int(border.minY),through:Int(border.maxY),by:max(1,Int(border.height/8))) {
                    for x in [Int(border.minX),Int(border.maxX)] {if let p=skin(source,x:CGFloat(x),y:CGFloat(y)){samples.append(p)}}
                }
            }
        }
        guard !samples.isEmpty else{return [238,214,202,255]}
        return (0..<3).map {c in UInt8(samples.reduce(0){$0+Int($1[c])}/samples.count)}+[255]
    }
}
