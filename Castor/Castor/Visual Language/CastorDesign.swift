import SwiftUI

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

/// カーソルの光に淡い波を重ねる。動いたときだけ揺れ、停止後は静かに収まる。
struct CastorAmbientBackground: View {
    let accent: Color
    let isDark: Bool
    let lightPosition: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var waveClockOrigin = Date()
    @State private var lastMovement = Date.distantPast
    @State private var waveStrength: CGFloat = 0
    @State private var waveActive = false

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

                Ellipse()
                    .fill(accent.opacity(isDark ? 0.19 : 0.11))
                    .frame(width: 620, height: 440)
                    .blur(radius: 130)
                    .position(targetPosition)
                    .animation(
                        .spring(response: 0.65, dampingFraction: 0.74),
                        value: targetPosition
                    )

                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !waveActive)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(lastMovement))
                    let envelope = reduceMotion || !waveActive ? 0 : exp(-elapsed * 1.65)
                    let strength = waveStrength * envelope
                    let phase = context.date.timeIntervalSince(waveClockOrigin) * 1.4

                    ZStack {
                        AmbientLightWave(phase: phase, amplitude: 16 + 26 * strength, thickness: 64)
                            .fill(accent.opacity(isDark ? 0.14 : 0.085))
                            .blur(radius: 40)
                        AmbientLightWave(phase: phase - 1.1, amplitude: 13 + 20 * strength, thickness: 90)
                            .fill(accent.opacity(isDark ? 0.085 : 0.05))
                            .offset(x: -55, y: 55)
                            .blur(radius: 60)
                    }
                    .frame(width: 720, height: 220)
                    .rotationEffect(.degrees(-12))
                    .opacity(strength)
                }
                .position(targetPosition)
                .animation(.spring(response: 0.9, dampingFraction: 0.7), value: targetPosition)

                Ellipse()
                    .fill(accent.opacity(isDark ? 0.10 : 0.06))
                    .frame(width: 940, height: 680)
                    .blur(radius: 180)
                    .position(trailingPosition)
                    .animation(
                        .spring(response: 1.05, dampingFraction: 0.78),
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
        .onChange(of: lightPosition) { previous, current in
            guard !reduceMotion, let previous, let current else { return }
            let distance = hypot(current.x - previous.x, current.y - previous.y)
            guard distance > 0.5 else { return }
            let now = Date()
            let residual = waveStrength * exp(-max(0, now.timeIntervalSince(lastMovement)) * 1.65)
            waveStrength = min(1, max(residual, distance / 24))
            lastMovement = now
            waveActive = true
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { waveActive = false }
        }
        .task(id: lastMovement) {
            guard waveActive, !reduceMotion else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                waveActive = false
            } catch {
                // New movement replaces the settling timer; removal cancels it too.
            }
        }
    }
}

/// 両端が細くなる柔らかい帯。輪郭をぼかし、背景の光としてだけ見せる。
private struct AmbientLightWave: Shape {
    let phase: Double
    let amplitude: CGFloat
    let thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let samples = 48
        func point(_ index: Int, side: CGFloat) -> CGPoint {
            let u = CGFloat(index) / CGFloat(samples)
            let taper = pow(sin(.pi * u), 2)
            let wave = sin(Double(u) * .pi * 2.1 - phase)
                + 0.25 * sin(Double(u) * .pi * 4.2 - phase * 0.7)
            return CGPoint(
                x: rect.minX + u * rect.width,
                y: rect.midY + CGFloat(wave) * amplitude * taper + side * thickness * 0.5 * taper
            )
        }
        var path = Path()
        path.move(to: point(0, side: -1))
        for index in 1...samples { path.addLine(to: point(index, side: -1)) }
        for index in stride(from: samples, through: 0, by: -1) { path.addLine(to: point(index, side: 1)) }
        path.closeSubpath()
        return path
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
