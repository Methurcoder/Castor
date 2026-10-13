import SwiftUI

/// 控えめな Liquid Glass surface。macOS 26 の `glassEffect` を弱め
/// (tint なし・細い縁取り・浅い影)に使い、Apple 的な静かな質感に保つ。
struct CastorGlassSurfaceModifier: ViewModifier {
    let palette: CastorPalette
    let cornerRadius: CGFloat
    let borderColor: Color?
    let borderWidth: CGFloat
    let isElevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .glassEffect(.regular, in: shape)
            .overlay {
                shape.strokeBorder(
                    borderColor ?? palette.readoutBorder,
                    lineWidth: borderWidth
                )
            }
            .shadow(
                color: Color.black.opacity(isElevated ? 0.10 : 0.05),
                radius: isElevated ? 10 : 5,
                x: 0,
                y: isElevated ? 4 : 2
            )
    }
}

struct CastorGlassTileModifier: ViewModifier {
    let palette: CastorPalette
    let accentColor: Color
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        content
            .glassEffect(
                isSelected ? .regular.tint(accentColor.opacity(0.18)) : .regular,
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    isSelected ? accentColor.opacity(0.75) : palette.readoutBorder,
                    lineWidth: isSelected ? 1.25 : 1
                )
            }
            .shadow(
                color: isSelected ? accentColor.opacity(0.10) : Color.black.opacity(0.04),
                radius: isSelected ? 5 : 3,
                y: 2
            )
    }
}

extension View {
    func castorGlassSurface(
        palette: CastorPalette,
        cornerRadius: CGFloat = 12,
        borderColor: Color? = nil,
        borderWidth: CGFloat = 1,
        isElevated: Bool = true
    ) -> some View {
        modifier(
            CastorGlassSurfaceModifier(
                palette: palette,
                cornerRadius: cornerRadius,
                borderColor: borderColor,
                borderWidth: borderWidth,
                isElevated: isElevated
            )
        )
    }

    func castorGlassTile(
        palette: CastorPalette,
        accentColor: Color,
        isSelected: Bool
    ) -> some View {
        modifier(
            CastorGlassTileModifier(
                palette: palette,
                accentColor: accentColor,
                isSelected: isSelected
            )
        )
    }
}
