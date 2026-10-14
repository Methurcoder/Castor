import CastorCore
import Foundation

public final class DesktopButtonDodge {
    public private(set) var state=PetDodgeStateMachine()
    private var manualUntil=Date.distantPast
    private var movement: (start:CGRect,end:CGRect,date:Date)?
    public init() {}
    public func disable() {state.cancelForManualPlacement();movement=nil}
    public var active: Bool {state.isDodged || movement != nil}
    public func manualPlacement(now: Date=Date()) {state.cancelForManualPlacement();movement=nil;manualUntil=now.addingTimeInterval(PetDodgePolicy().manualPlacementProtection)}
    public func update(frame: CGRect,pointer: CGPoint,visible: CGRect,actionable: Bool?,buttonsPressed: Bool,enabled: Bool,now:Date=Date()) -> CGRect? {
        guard enabled,now>=manualUntil else {state.cancelForManualPlacement();movement=nil;return nil}
        if let movement {
            let t=min(max(now.timeIntervalSince(movement.date)/0.22,0),1)
            let f=DesktopEvasion.easing(t,style:.easeInOut)
            let rect=CGRect(x:movement.start.minX+(movement.end.minX-movement.start.minX)*f,
                y:movement.start.minY+(movement.end.minY-movement.start.minY)*f,width:frame.width,height:frame.height)
            if t>=1 {self.movement=nil};return rect
        }
        let action=state.update(pointer:pointer,petFrame:frame,visible:visible,underneathIsActionable:actionable,buttonsPressed:buttonsPressed,now:now)
        switch action {
        case .none:break
        case let .move(to:destination),let .returnTo(destination):movement=(frame,destination,now)
        }
        return nil
    }
}
