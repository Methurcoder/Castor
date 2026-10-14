import AppKit

final class CastorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CastorPetController.shared.startEdgeDoubleClickMonitor()
        AgentLauncher.shared.startEnabledServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The helper also quits on its own once Castor is gone; this is faster.
        AgentLauncher.shared.stopHelperBeforeQuit()
    }
}
