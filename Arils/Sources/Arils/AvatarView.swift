import SwiftUI

/// SwiftUI wrapper around the engine's rendering view.
///
///     AvatarView(engine: engine)
///         .aspectRatio(imageAspect, contentMode: .fit)
public struct AvatarView: NSViewRepresentable {
    private let engine: CharacterEngine

    public init(engine: CharacterEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> NSView {
        engine.makeView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
