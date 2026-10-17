import CastorCore
import SwiftUI

/// The answer reader for a reply being spoken: each spoken segment is shown in
/// short lines, and the reader follows the line being spoken.
struct SpokenResponseReader: View {
    let segments: [String]
    let segmentIndex: Int
    let progress: () -> Double
    let isSpeaking: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: isSpeaking ? 0.2 : 3600)) { _ in
            let layout = PetReaderLines.layout(for: segments)
            PetResponseReader(
                segments: layout.lines,
                currentIndex: PetReaderLines.currentLine(in: layout, segmentIndex: segmentIndex, progress: progress()),
                isSpeaking: isSpeaking,
                isExpanded: isExpanded,
                onToggleExpanded: onToggleExpanded
            )
        }
    }
}

struct PetResponseReader: View {
    @AppStorage("Castor.SettingsDisplayLanguage") private var displayLanguage: SettingsDisplayLanguage = .systemDefault
    private func L(_ source: String) -> String { CastorAppStrings.label(source, language: displayLanguage) }

    let segments: [String]
    let currentIndex: Int
    let isSpeaking: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: isExpanded ? 24 : 10) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Text(segment)
                            .font(textFont(for: index))
                            .foregroundStyle(textColor(for: index))
                            .lineSpacing(isExpanded ? 8 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            .animation(.easeOut(duration: 0.28), value: currentIndex)
                    }
                }
                .padding(.leading, isExpanded ? 34 : 38)
                .padding(.trailing, isExpanded ? 34 : 38)
                .padding(.vertical, isExpanded ? 80 : 12)
            }
            // Full screen lets earlier lines run past the edges; the small
            // reader keeps them inside its frame, fading out toward the top.
            .scrollClipDisabled(isExpanded)
            .safeAreaPadding(.top, isExpanded ? 0 : Self.compactFadeHeight)
            .mask(LinearGradient(stops: isExpanded
                ? [.init(color: .black, location: 0), .init(color: .black, location: 1)]
                : [.init(color: .clear, location: 0),
                   .init(color: .black.opacity(0.35), location: 0.18),
                   .init(color: .black, location: 0.40),
                   .init(color: .black, location: 0.88),
                   .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom))
            .onAppear {
                scrollToCurrent(using: proxy, animated: false)
            }
            .onChange(of: currentIndex) {
                scrollToCurrent(using: proxy, animated: true)
            }
        }
        .overlay(alignment: .leading) {
            if !isExpanded {
                Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "text.alignleft")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.leading, 12)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded
                    ? "xmark"
                    : "arrow.up.left.and.arrow.down.right"
                )
                .font(.system(size: isExpanded ? 16 : 11, weight: .semibold))
                .frame(width: isExpanded ? 38 : 26, height: isExpanded ? 38 : 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.86))
            .background(Circle().fill(.black.opacity(0.42)))
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            .padding(isExpanded ? 24 : 7)
            .accessibilityLabel(isExpanded ? L("Exit full screen answer") : L("View answer full screen"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isExpanded {
                onToggleExpanded()
            }
        }
    }

    /// Room above the current line in the small reader, where the previous
    /// line shows faded.
    private static let compactFadeHeight: CGFloat = 20

    private func textFont(for index: Int) -> Font {
        let isCurrent = index == displayedIndex
        if isExpanded {
            return .system(size: isCurrent ? 34 : 28, weight: isCurrent ? .bold : .semibold, design: .rounded)
        }
        return .system(size: isCurrent ? 15 : 13, weight: isCurrent ? .bold : .semibold, design: .rounded)
    }

    private func textColor(for index: Int) -> Color {
        guard !segments.isEmpty else {
            return .white.opacity(0.72)
        }

        if index == displayedIndex {
            return .white
        }
        if index < displayedIndex {
            return .white.opacity(0.24)
        }
        return .white.opacity(isSpeaking ? 0.48 : 0.62)
    }

    private var displayedIndex: Int {
        guard !segments.isEmpty else {
            return 0
        }
        return min(max(currentIndex, 0), segments.count - 1)
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy, animated: Bool) {
        guard segments.indices.contains(displayedIndex) else {
            return
        }

        let action = {
            proxy.scrollTo(displayedIndex, anchor: isExpanded ? .center : .top)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.42), action)
        } else {
            action()
        }
    }
}
