import CastorCore
import SwiftUI

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
            .scrollClipDisabled()
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
