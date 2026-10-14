// Developer verification tool; end users use the native creation UI.
import ArilsPlayer
import Foundation
import PetRuntime

let args = CommandLine.arguments
func markers(_ file: String?, prepared: PreparedPortableRig) throws -> PortableFaceLayout {
    if let file { return try JSONDecoder().decode(PortableFaceLayout.self, from: Data(contentsOf: URL(fileURLWithPath: file))) }
    return LayeredRigging.markers(prepared.face.layout)
}
do {
    let source: PortableRigImage, asset: PetAsset, output: URL
    if args.count >= 7 && args[1] == "--quality" {
        source = try PortableRigImage(png: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let sideImage = try PortableRigImage(png: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let front = try await LayeredRigging.prepare(source), side = try await LayeredRigging.prepare(sideImage)
        let quality = try await LayeredRigging.buildQuality(front: front, side: side,
            frontMarkers: markers(args[5], prepared: front), sideMarkers: markers(args[6], prepared: side),
            direction: args.contains("--left") ? .left : .right, sideFileName: URL(fileURLWithPath: args[3]).lastPathComponent)
        asset = .quality(quality); output = URL(fileURLWithPath: args[4])
    } else if args.count >= 3 && args[1] != "--quality" {
        source = try PortableRigImage(png: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let prepared = try await LayeredRigging.prepare(source)
        asset = .standard(try LayeredRigging.build(prepared, markers: markers(args.count > 3 ? args[3] : nil, prepared: prepared)))
        output = URL(fileURLWithPath: args[2])
        for warning in prepared.warnings { print(warning) }
    } else {
        print("usage: pet-rig INPUT.png OUTPUT.arils|OUTPUT.json [MARKERS.json]\n       pet-rig --quality FRONT.png SIDE.png OUTPUT FRONT_MARKERS.json SIDE_MARKERS.json [--left]")
        exit(1)
    }
    let data: Data
    switch output.pathExtension.lowercased() {
    case "arils": data = try asset.data()
    case "json": data = try LayeredRigging.savedPetData(source: source, asset: asset)
    default: throw PortableRigImage.ImageError.invalidImage
    }
    try data.write(to: output, options: .withoutOverwriting)
    print("Created \(source.width) × \(source.height), \(data.count) bytes. Developer output; validate markers/appearance before use.")
} catch { print("error: \(error.localizedDescription)"); exit(1) }
