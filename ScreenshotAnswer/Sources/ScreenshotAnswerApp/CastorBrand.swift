import AppKit
import SwiftUI

struct CastorMenuBarIcon: View {
    private static let image = CastorTemplateImage.make()
    let isRecording: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: Self.image)
                .renderingMode(.template)
                .frame(width: 19, height: 19)
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
                    .offset(x: 2, y: -1)
            }
        }
    }
}

private enum CastorTemplateImage {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let body = NSBezierPath()
            body.move(to: NSPoint(x: 5.3, y: 6.5))
            body.curve(
                to: NSPoint(x: 2.8, y: 11.0),
                controlPoint1: NSPoint(x: 3.7, y: 7.0),
                controlPoint2: NSPoint(x: 2.7, y: 8.6)
            )
            body.curve(
                to: NSPoint(x: 9.5, y: 17.1),
                controlPoint1: NSPoint(x: 2.8, y: 14.8),
                controlPoint2: NSPoint(x: 5.5, y: 17.1)
            )
            body.curve(
                to: NSPoint(x: 16.2, y: 11.0),
                controlPoint1: NSPoint(x: 13.5, y: 17.1),
                controlPoint2: NSPoint(x: 16.2, y: 14.8)
            )
            body.curve(
                to: NSPoint(x: 13.7, y: 6.5),
                controlPoint1: NSPoint(x: 16.3, y: 8.6),
                controlPoint2: NSPoint(x: 15.3, y: 7.0)
            )
            body.curve(
                to: NSPoint(x: 5.3, y: 6.5),
                controlPoint1: NSPoint(x: 11.3, y: 5.8),
                controlPoint2: NSPoint(x: 7.7, y: 5.8)
            )
            body.close()
            configureStroke(body)
            body.stroke()

            let crown = NSBezierPath()
            crown.move(to: NSPoint(x: 5.4, y: 6.5))
            crown.line(to: NSPoint(x: 4.6, y: 2.4))
            crown.line(to: NSPoint(x: 8.0, y: 4.2))
            crown.line(to: NSPoint(x: 9.5, y: 1.2))
            crown.line(to: NSPoint(x: 11.0, y: 4.2))
            crown.line(to: NSPoint(x: 14.4, y: 2.4))
            crown.line(to: NSPoint(x: 13.6, y: 6.5))
            configureStroke(crown)
            crown.stroke()

            NSBezierPath(ovalIn: NSRect(x: 8.45, y: 8.0, width: 2.1, height: 2.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 5.75, y: 11.0, width: 2.1, height: 2.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 11.15, y: 11.0, width: 2.1, height: 2.5)).fill()
            return true
        }

        // macOS recolors template images for light, dark, highlighted, and
        // accessibility appearances instead of preserving the source black.
        image.isTemplate = true
        image.accessibilityDescription = "Screenshot Answer"
        return image
    }

    private static func configureStroke(_ path: NSBezierPath) {
        path.lineWidth = 1.65
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
}
