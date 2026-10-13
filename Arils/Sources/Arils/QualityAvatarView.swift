import SwiftUI

/// SwiftUI wrapper for a `QualityCharacterEngine` two-view renderer.
public struct QualityAvatarView: NSViewRepresentable {
    private let engine: QualityCharacterEngine

    public init(engine: QualityCharacterEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> NSView {
        engine.makeView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
