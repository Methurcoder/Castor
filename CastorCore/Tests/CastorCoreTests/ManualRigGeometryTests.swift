import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import CastorCore

@Test func sharedManualRigKeepsLegacyWireShapeAndValidatesEdits() throws {
    let doc=RigDocument.starter(imageName:"fixture",imageSize:CGSize(width:1024,height:1536))
    try doc.validate()
    #expect(try RigDocument.decodeJSON(doc.encodedJSON()) == doc)
    let object=try JSONSerialization.jsonObject(with:doc.encodedJSON()) as! [String:Any]
    #expect(Set(object.keys)==["version","imageName","imageSize","parts"])
    #expect((object["parts"] as? [Any])?.count==6)
    var invalid=doc;invalid.parts[0].anchorPoint.x = .nan
    #expect(throws:(any Error).self){try invalid.validate()}
    invalid=doc;invalid.parts.append(doc.parts[0])
    #expect(throws:(any Error).self){try invalid.validate()}
}
@Test func sharedManualGeometryKeepsEyeOrbitAndLegacyScales() {
    let doc=RigDocument.starter(imageName:nil,imageSize:CGSize(width:500,height:500)),size=CGSize(width:260,height:260)
    let pivot=ManualRigGeometry.headPivot(document:doc,size:size)
    let eye=doc.parts.first{$0.kind == .leftEye}!
    var p=MotionParameters.neutral;p.headTilt=20;p.headBob=2;p.bodyLift=5;p.gazeX=3;p.gazeY=4;p.eyeOpen=0
    let rect=ManualRigGeometry.partRect(eye,in:size)
    let expected=ManualRigGeometry.headAnchoredRotation(point:CGPoint(x:rect.midX+2.1,y:rect.midY+8.8),pivot:pivot,degrees:20)
    let actual=ManualRigGeometry.position(part:eye,size:size,pivot:pivot,parameters:p)
    #expect(abs(actual.x-expected.x)<0.0001 && abs(actual.y-expected.y)<0.0001)
    #expect(ManualRigGeometry.scale(kind:.leftEye,parameters:p).height==0.08)
    #expect(ManualRigGeometry.rotation(kind:.body,parameters:p)==3.2)
}
