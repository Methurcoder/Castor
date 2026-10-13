import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import CastorCore

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

@Test func uncoveringMovesTheShortestWayAndClearsThePoint() throws {
    let pet = CGRect(x: 600, y: 300, width: 260, height: 340)
    // Pointer near the pet's left edge: sliding right is shortest.
    let point = CGPoint(x: 620, y: 450)
    let moved = try #require(PetPassThroughGeometry.uncoveringFrame(for: pet, uncovering: point, within: screen))
    #expect(moved.minX >= point.x + 27)
    #expect(moved.minY == pet.minY)
    #expect(!moved.contains(point))
}

@Test func uncoveringStaysOnScreen() throws {
    // Pet against the right edge: it cannot slide right, so it goes another way.
    let pet = CGRect(x: 1180, y: 300, width: 260, height: 340)
    let point = CGPoint(x: 1200, y: 320)
    let moved = try #require(PetPassThroughGeometry.uncoveringFrame(for: pet, uncovering: point, within: screen))
    #expect(screen.contains(moved))
    #expect(!moved.contains(point))
}

@Test func uncoveringIgnoresPointsOutsideThePet() {
    let pet = CGRect(x: 600, y: 300, width: 260, height: 340)
    #expect(PetPassThroughGeometry.uncoveringFrame(for: pet, uncovering: CGPoint(x: 10, y: 10), within: screen) == nil)
}

@Test func actionableRolesIncludeButtonsAndPressableElements() {
    #expect(PointerTargetRoles.isActionable(role: "AXButton", hasPressAction: false))
    #expect(PointerTargetRoles.isActionable(role: "AXGroup", hasPressAction: true))
    #expect(!PointerTargetRoles.isActionable(role: "AXStaticText", hasPressAction: false))
    #expect(!PointerTargetRoles.isActionable(role: nil, hasPressAction: false))
    let disabled = PointerTargetClient.Target(role: "AXButton", subrole: nil, hasPress: true, enabled: false)
    #expect(!disabled.isActionable)
}

@Test func dodgeMovesOverAButtonAndReturnsWhenTheSpotIsFree() {
    var dodge = PetDodgeStateMachine()
    let pet = CGRect(x: 600, y: 300, width: 260, height: 340)
    let start = Date(timeIntervalSince1970: 0)
    let outside = CGPoint(x: 560, y: 450)
    let button = CGPoint(x: 620, y: 450)

    #expect(dodge.update(pointer: outside, petFrame: pet, visible: screen,
                         underneathIsActionable: nil, buttonsPressed: false, now: start) == .none)
    #expect(dodge.isEntering(pointer: button, petFrame: pet))

    guard case let .move(to: moved) = dodge.update(
        pointer: button, petFrame: pet, visible: screen,
        underneathIsActionable: true, buttonsPressed: false, now: start
    ) else {
        Issue.record("expected a dodge")
        return
    }
    #expect(!moved.contains(button))

    // Clicking at the spot keeps the pet away.
    #expect(dodge.update(pointer: button, petFrame: moved, visible: screen,
                         underneathIsActionable: nil, buttonsPressed: true, now: start.addingTimeInterval(1)) == .none)
    // Pointer leaves: the return waits for the delay.
    let away = CGPoint(x: 200, y: 200)
    #expect(dodge.update(pointer: away, petFrame: moved, visible: screen,
                         underneathIsActionable: nil, buttonsPressed: false, now: start.addingTimeInterval(2)) == .none)
    #expect(dodge.update(pointer: away, petFrame: moved, visible: screen,
                         underneathIsActionable: nil, buttonsPressed: false, now: start.addingTimeInterval(2.5)) == .none)
    #expect(dodge.update(pointer: away, petFrame: moved, visible: screen,
                         underneathIsActionable: nil, buttonsPressed: false, now: start.addingTimeInterval(4)) == .returnTo(pet))
    #expect(!dodge.isDodged)
}

@Test func dodgeDoesNothingOverNonControlsOrWhileDragging() {
    var dodge = PetDodgeStateMachine()
    let pet = CGRect(x: 600, y: 300, width: 260, height: 340)
    let inside = CGPoint(x: 700, y: 450)
    #expect(dodge.update(pointer: inside, petFrame: pet, visible: screen,
                         underneathIsActionable: false, buttonsPressed: false, now: Date()) == .none)
    #expect(dodge.update(pointer: inside, petFrame: pet, visible: screen,
                         underneathIsActionable: true, buttonsPressed: true, now: Date()) == .none)
    #expect(!dodge.isDodged)
}

@Test func manualPlacementCancelsAPendingReturn() {
    var dodge = PetDodgeStateMachine()
    let pet = CGRect(x: 600, y: 300, width: 260, height: 340)
    _ = dodge.update(pointer: CGPoint(x: 620, y: 450), petFrame: pet, visible: screen,
                     underneathIsActionable: true, buttonsPressed: false, now: Date())
    #expect(dodge.isDodged)
    dodge.cancelForManualPlacement()
    #expect(!dodge.isDodged)
}
