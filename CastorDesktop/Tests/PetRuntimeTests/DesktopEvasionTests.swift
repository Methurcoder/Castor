import CastorCore
import Foundation
import Testing
@testable import PetRuntime

@Test func desktopEvasionSharesManualProtectionAndReturnTiming() {
    let engine = DesktopEvasion()
    let frame = CGRect(x: 700, y: 500, width: 120, height: 160), work = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let window = PetEvasionWindow(id: 1, ownerPID: 10, frame: CGRect(x: 0, y: 0, width: 900, height: 700))
    let pointer = CGPoint(x: 690, y: 530), now = Date(timeIntervalSince1970: 1000)
    engine.manualPlacement(frame: frame, now: now)
    _ = engine.update(frame: frame, pointer: pointer, screen: work, workArea: work, windows: [window], focusedID: 1, style: .calm, now: now)
    #expect(engine.ghost && !engine.hidden)
    _ = engine.update(frame: frame, pointer: pointer, screen: work, workArea: work, windows: [window], focusedID: 1, style: .calm, now: now.addingTimeInterval(301))
    #expect(engine.state.phase == .anticipating && !engine.ghost)
    _ = engine.update(frame: frame, pointer: pointer, screen: work, workArea: work, windows: [window], focusedID: 1, style: .calm, now: now.addingTimeInterval(302))
    #expect(engine.state.phase == .evading)
    let destination = engine.update(frame: frame, pointer: .zero, screen: work, workArea: work, windows: [], focusedID: nil, style: .calm, now: now.addingTimeInterval(303))
    #expect(destination != nil && destination != frame)
    #expect(engine.state.phase == .displaced)
    _ = engine.update(frame: destination!, pointer: .zero, screen: work, workArea: work, windows: [], focusedID: nil, style: .calm, now: now.addingTimeInterval(304))
    _ = engine.update(frame: destination!, pointer: .zero, screen: work, workArea: work, windows: [], focusedID: nil, style: .calm, now: now.addingTimeInterval(318))
    #expect(engine.state.phase == .returning)
    let home = engine.update(frame: destination!, pointer: .zero, screen: work, workArea: work, windows: [], focusedID: nil, style: .calm, now: now.addingTimeInterval(319))
    #expect(abs(home!.minX - frame.minX) < 0.001 && abs(home!.minY - frame.minY) < 0.001)
}
@Test func desktopEvasionCurvesAreFiniteAndMatchPanelEndpoints() {
    for style: EvasionPathEasing in [.linear, .spring, .easeInOut, .overdamped] {
        #expect(abs(DesktopEvasion.easing(0, style: style)) < 0.0001)
        #expect(abs(DesktopEvasion.easing(1, style: style) - 1) < 0.0001)
        for t in stride(from: 0.0, through: 1.0, by: 0.01) { #expect(DesktopEvasion.easing(t, style: style).isFinite) }
    }
}

@Test func desktopButtonDodgeReturnsAndProtectsManualPlacement() {
    let dodge=DesktopButtonDodge(),now=Date(timeIntervalSince1970:1000)
    let frame=CGRect(x:200,y:200,width:100,height:120),visible=CGRect(x:0,y:0,width:1000,height:800)
    let point=CGPoint(x:230,y:240)
    _ = dodge.update(frame:frame,pointer:point,visible:visible,actionable:true,buttonsPressed:false,enabled:true,now:now)
    #expect(dodge.active)
    let moved=dodge.update(frame:frame,pointer:point,visible:visible,actionable:nil,buttonsPressed:false,enabled:true,now:now.addingTimeInterval(0.3))!
    #expect(!moved.contains(point))
    let away=CGPoint(x:900,y:700)
    _ = dodge.update(frame:moved,pointer:away,visible:visible,actionable:nil,buttonsPressed:false,enabled:true,now:now.addingTimeInterval(0.4))
    _ = dodge.update(frame:moved,pointer:away,visible:visible,actionable:nil,buttonsPressed:false,enabled:true,now:now.addingTimeInterval(2.1))
    #expect(dodge.update(frame:moved,pointer:away,visible:visible,actionable:nil,buttonsPressed:false,enabled:true,now:now.addingTimeInterval(2.4))!.origin == frame.origin)
    dodge.manualPlacement(now:now.addingTimeInterval(3))
    _ = dodge.update(frame:frame,pointer:point,visible:visible,actionable:true,buttonsPressed:false,enabled:true,now:now.addingTimeInterval(4))
    #expect(!dodge.active)
}
