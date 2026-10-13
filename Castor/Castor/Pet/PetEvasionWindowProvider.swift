import AppKit
import CoreGraphics
import Foundation
import CastorCore

struct CGPetEvasionWindowProvider: PetEvasionWindowProviding {
    func onScreenWindows() -> [PetEvasionWindow] {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let mainTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0

        return entries.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds) else {
                return nil
            }

            // CGWindow bounds use a top-left desktop origin; AppKit panels use bottom-left.
            let appKitFrame = CGRect(
                x: quartzFrame.minX,
                y: mainTop - quartzFrame.maxY,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
            guard appKitFrame.width > 8, appKitFrame.height > 8 else {
                return nil
            }
            return PetEvasionWindow(id: windowNumber, ownerPID: ownerPID, frame: appKitFrame)
        }
    }
}
