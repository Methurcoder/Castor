import AppKit

final class CastorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CastorPetController.shared.startEdgeDoubleClickMonitor()
    }
}
