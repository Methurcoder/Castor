import Foundation
import Testing
@testable import PetRuntime
#if os(macOS) || os(Windows)
@Test func nativeTIFFDecoderRetainsRowsAndPixelColors() throws {
    // Generated 3x2 RGB fixture; no user artwork or private data.
    let bytes=Data(base64Encoded:"SUkqAAgAAAAKAAABBAABAAAAAwAAAAEBBAABAAAAAgAAAAIBAwADAAAAhgAAAAMBAwABAAAAAQAAAAYBAwABAAAAAgAAABEBBAABAAAAjAAAABUBAwABAAAAAwAAABYBBAABAAAAAgAAABcBBAABAAAAEgAAABwBAwABAAAAAQAAAAAAAAAIAAgACAD/AAAA/wAAAP///wD/AP////8=")!
    let image=try PortableRigImage(png:bytes)
    #expect(image.width==3 && image.height==2)
    #expect(image.rgba == [255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255,255,0,255,255,255,255,255,255])
    #expect(try PortableRigImage(png:image.pngData()).rgba == image.rgba)
}
#endif
