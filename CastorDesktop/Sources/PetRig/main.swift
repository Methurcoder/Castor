// Developer verification tool. End users create pets in the native Windows UI.
import Foundation
import PetRuntime

let arguments = CommandLine.arguments
if arguments.count < 3 {
    print("usage: pet-rig INPUT.png OUTPUT.arils|OUTPUT.json [MARKERS.json]")
    exit(1)
}
do {
    let input = URL(fileURLWithPath: arguments[1])
    let output = URL(fileURLWithPath: arguments[2])
    let source = try PortableRigImage(png: Data(contentsOf: input))
    let draft = try PortableRigBuilder.prepare(source)
    let layout = arguments.count > 3
        ? try JSONDecoder().decode(PortableFaceLayout.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        : draft.layout
    let archive = try PortableRigBuilder.build(image: draft.image, layout: layout)
    let data: Data
    switch output.pathExtension.lowercased() {
    case "arils": data = try archive.data()
    case "json": data = try PortableRigBuilder.savedPetData(image: source, archive: archive)
    default: throw PortableRigImage.ImageError.invalidImage
    }
    try data.write(to: output, options: .withoutOverwriting)
    print("Created \(source.width) × \(source.height), \(data.count) bytes.")
    for warning in draft.warnings { print(warning) }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
