import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The exact legacy Mac transform math, reused by every manual-rig renderer.
public nonisolated enum ManualRigGeometry {
    public static func partRect(_ part: RigPart,in size:CGSize) -> CGRect {
        CGRect(x:part.normalizedRect.minX*size.width,y:part.normalizedRect.minY*size.height,
               width:part.normalizedRect.width*size.width,height:part.normalizedRect.height*size.height)
    }
    public static func headPivot(document:RigDocument,size:CGSize) -> CGPoint {
        guard let head=document.parts.first(where:{$0.kind == .head}) else{return CGPoint(x:size.width/2,y:size.height/2)}
        let rect=partRect(head,in:size)
        return CGPoint(x:rect.minX+rect.width*head.anchorPoint.x,y:rect.minY+rect.height*head.anchorPoint.y)
    }
    public static func headAnchoredRotation(point:CGPoint,pivot:CGPoint,degrees:Double) -> CGPoint {
        guard degrees != 0 else{return point}
        let radians=degrees * .pi/180,dx=point.x-pivot.x,dy=point.y-pivot.y
        return CGPoint(x:pivot.x+dx*cos(radians)-dy*sin(radians),y:pivot.y+dx*sin(radians)+dy*cos(radians))
    }
    public static func position(part:RigPart,size:CGSize,pivot:CGPoint,parameters:MotionParameters) -> CGPoint {
        let rect=partRect(part,in:size),offset=offset(kind:part.kind,parameters:parameters)
        let point=CGPoint(x:rect.midX+offset.width,y:rect.midY+offset.height)
        return part.kind == .body ? point:headAnchoredRotation(point:point,pivot:pivot,degrees:parameters.headTilt)
    }
    public static func offset(kind:RigPartKind,parameters:MotionParameters) -> CGSize {
        switch kind {
        case .head,.hair,.mouth:CGSize(width:0,height:parameters.bodyLift+parameters.headBob)
        case .leftEye,.rightEye:CGSize(width:parameters.gazeX*0.7,height:parameters.bodyLift+parameters.headBob+parameters.gazeY*0.45)
        case .body:CGSize(width:0,height:parameters.bodyLift*0.38+parameters.headBob*0.12)
        }
    }
    public static func rotation(kind:RigPartKind,parameters:MotionParameters) -> Double {parameters.headTilt*(kind == .body ? 0.16:1)}
    public static func scale(kind:RigPartKind,parameters:MotionParameters) -> CGSize {
        switch kind {
        case .mouth:CGSize(width:1+parameters.mouthOpen*0.10,height:1+parameters.mouthOpen*0.95)
        case .leftEye,.rightEye:CGSize(width:parameters.eyeScale,height:max(0.08,parameters.eyeOpen))
        default:CGSize(width:1,height:1)
        }
    }
}
