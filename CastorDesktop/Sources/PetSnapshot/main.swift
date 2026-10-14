import ArilsCore
import Foundation
import PetRuntime

// pet-snapshot PET_FILE OUT_PREFIX [WIDTH HEIGHT]
//     Writes OUT_PREFIX-<t>.ppm for a few points in time, composited over grey.
//     Add --wide-head for the wider head movement beta.
// pet-snapshot QUALITY_FILE OUT_PREFIX WIDTH HEIGHT --turn -1...1
//     Writes OUT_PREFIX.ppm with a fixed Quality turn.
// pet-snapshot PET_FILE OUT_PREFIX WIDTH HEIGHT --pose YAW PITCH
//     Writes OUT_PREFIX.ppm with the head held at YAW/PITCH degrees.
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: pet-snapshot PET_FILE OUT_PREFIX [WIDTH HEIGHT] [--pose YAW PITCH | --turn VALUE]")
    exit(1)
}
let width = arguments.count > 3 ? Int(arguments[3]) ?? 260 : 260
let height = arguments.count > 4 ? Int(arguments[4]) ?? 340 : 340

func writePPM(_ canvas: PetCanvas, to path: String) throws {
    var ppm = Data("P6\n\(canvas.width) \(canvas.height)\n255\n".utf8)
    for i in 0..<(canvas.width * canvas.height) {
        let a = Float(canvas.bgra[i * 4 + 3]) / 255
        for c in [2, 1, 0] {
            let premultiplied = Float(canvas.bgra[i * 4 + c]) / 255
            ppm.append(UInt8(min(255, (premultiplied + 0.5 * (1 - a)) * 255)))
        }
    }
    try ppm.write(to: URL(fileURLWithPath: path))
}

do {
    let asset = try PetSource.loadAsset(contentsOf: URL(fileURLWithPath: arguments[1]))
    if arguments.contains("--gif") {
        var options = PetGIFClipOptions()
        options.motion = arguments.contains("--look-around") ? .lookAround : .idle
        let result = try await PetGIFClip.make(asset: asset, options: options)
        try result.data.write(to: URL(fileURLWithPath: "\(arguments[2]).gif"), options: .withoutOverwriting)
        print("GIF: \(result.dimension)px, \(result.fps)fps, \(result.data.count) bytes")
        exit(0)
    }
    let player = PetPlayback(asset: asset, wideHeadMovement: arguments.contains("--wide-head"))
    var canvas = PetCanvas(width: width, height: height)

    if let turnFlag = arguments.firstIndex(of: "--turn"), arguments.count > turnFlag + 1,
       let turn = Float(arguments[turnFlag + 1]) {
        player.automaticTurn = false
        player.viewTurn = turn
        player.viewPitch = 0
        player.render(into: &canvas, time: 0)
        try writePPM(canvas, to: "\(arguments[2]).ppm")
        exit(0)
    }
    if let flag = arguments.firstIndex(of: "--pose"), arguments.count > flag + 2,
       let yaw = Float(arguments[flag + 1]), let pitch = Float(arguments[flag + 2]) {
        // Eyes open and centred, no idle drift: only the pose differs.
        player.parameterOverrides = [
            .angleX: yaw, .angleY: pitch, .angleZ: 0,
            .eyeBallX: 0, .eyeBallY: 0, .eyeLeftOpen: 1, .eyeRightOpen: 1,
        ]
        player.render(into: &canvas, time: 0)
        try writePPM(canvas, to: "\(arguments[2]).ppm")
        exit(0)
    }

    let started = Date()
    var frames = 0
    for step in 0...90 {
        let time = Double(step) / 30
        // Sweep the pointer across the canvas so gaze moves.
        player.pointerMoved(
            to: SIMD2(Float(width) * Float(step) / 90, Float(height) * 0.2),
            canvasWidth: width, canvasHeight: height, time: time
        )
        player.render(into: &canvas, time: time)
        frames += 1
        if step % 30 == 0 {
            try writePPM(canvas, to: "\(arguments[2])-\(step / 30).ppm")
        }
    }
    let seconds = Date().timeIntervalSince(started)
    print(String(format: "%d frames at %dx%d in %.2fs (%.1f ms/frame)", frames, width, height, seconds, seconds / Double(frames) * 1000))
} catch {
    print("error: \(error)")
    exit(1)
}
