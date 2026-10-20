import SwiftUI
import Observation

/// アプリ全体の tint に使う、少し紫がかった淡い水色(ペリウィンクル)。
/// 白文字を載せても読める濃さにしてあり、ライト・ダーク共通で使う。
enum CastorBrand {
    static let accent = Color(red: 0.33, green: 0.41, blue: 0.79)
}

/// Castor 共通の配色。ほんのり青みのある背景に、透明感のある淡い青紫を
/// アクセントとして選択状態・ボタン・メーターだけへ限定的に使う。
struct CastorPalette {
    let background: [Color]
    let primaryText: Color
    let secondaryText: Color
    let readoutBackground: Color
    let readoutBorder: Color
    let meterTrack: Color
    let meterFill: Color

    /// 淡い青紫のアクセント。meterFill と同一だが、意図を明示したい場面で使う。
    var accent: Color { meterFill }

    init(isDark: Bool) {
        if isDark {
            background = [
                Color(red: 0.055, green: 0.06, blue: 0.085),
                Color(red: 0.04, green: 0.045, blue: 0.065)
            ]
            primaryText = Color(red: 0.97, green: 0.96, blue: 0.96)
            secondaryText = Color(red: 0.62, green: 0.62, blue: 0.66)
            readoutBackground = Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.72)
            readoutBorder = Color.white.opacity(0.13)
            meterTrack = Color.white.opacity(0.12)
            meterFill = Color(red: 0.62, green: 0.70, blue: 1.0)
        } else {
            background = [
                Color(red: 0.965, green: 0.97, blue: 0.985),
                Color(red: 0.925, green: 0.93, blue: 0.955)
            ]
            primaryText = Color(red: 0.13, green: 0.13, blue: 0.14)
            secondaryText = Color(red: 0.45, green: 0.45, blue: 0.48)
            readoutBackground = Color.white.opacity(0.72)
            readoutBorder = Color.black.opacity(0.07)
            meterTrack = Color.black.opacity(0.08)
            meterFill = Color(red: 0.30, green: 0.37, blue: 0.75)
        }
    }
}

/// Mouse input changes only the backdrop's observation scope, not the editor.
@Observable
final class CastorAmbientLightTracking {
    var position: CGPoint?
}

struct CastorTrackedAmbientBackground: View {
    let accent: Color
    let isDark: Bool
    let tracking: CastorAmbientLightTracking

    var body: some View {
        CastorAmbientBackground(accent: accent, isDark: isDark, lightPosition: tracking.position)
    }
}

/// 「アンビエント・ハロー」の共通背景。スモーク調の無地に、現在のキャラクターの
/// アクセント色を光源としてにじませる。accent の変化はゆっくり色相移動する。
struct CastorAmbientBackground: View {
    let accent: Color
    let isDark: Bool
    let lightPosition: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let restingPosition = CGPoint(
                x: geometry.size.width * 0.5,
                y: geometry.size.height * 0.42
            )
            let targetPosition = reduceMotion
                ? restingPosition
                : lightPosition ?? restingPosition
            let trailingPosition = CGPoint(
                x: restingPosition.x + ((targetPosition.x - restingPosition.x) * 0.48),
                y: restingPosition.y + ((targetPosition.y - restingPosition.y) * 0.48) + 180
            )

            ZStack {
                (isDark
                    ? Color(red: 0.045, green: 0.05, blue: 0.075)
                    : Color(red: 0.95, green: 0.955, blue: 0.975))

                Circle()
                    .fill(accent.opacity(isDark ? 0.22 : 0.13))
                    .frame(width: 560, height: 560)
                    .blur(radius: 130)
                    .position(targetPosition)
                    .animation(
                        .spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0.12),
                        value: targetPosition
                    )

                Circle()
                    .fill(accent.opacity(isDark ? 0.12 : 0.07))
                    .frame(width: 900, height: 900)
                    .blur(radius: 180)
                    .position(trailingPosition)
                    .animation(
                        .spring(response: 0.72, dampingFraction: 0.86, blendDuration: 0.18),
                        value: trailingPosition
                    )

                LinearGradient(
                    colors: [Color.white.opacity(isDark ? 0.045 : 0.40), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 1.1), value: accent)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct AudioLevelMeter: View {
    let level: Double
    let trackColor: Color
    let fillColor: Color

    var body: some View {
        ZStack {
            Capsule()
                .fill(trackColor)
            Capsule()
                .fill(fillColor)
                .scaleEffect(
                    x: min(max(level, 0), 1),
                    y: 1,
                    anchor: .leading
                )
        }
    }
}
