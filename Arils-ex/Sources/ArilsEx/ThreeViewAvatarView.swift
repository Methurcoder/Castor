import SwiftUI

public struct ThreeViewAvatarView: NSViewRepresentable {
    private let engine: ThreeViewCharacterEngine

    public init(engine: ThreeViewCharacterEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> NSView {
        engine.makeView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
