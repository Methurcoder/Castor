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

                halo(opacity: isDark ? 0.16 : 0.095, radius: 440)
                    .scaleEffect(x: 1, y: 0.74)
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

                    AmbientParticleWave(phase: phase, strength: strength, accent: accent, isDark: isDark)
                        .frame(width: 720, height: 240)
                        .rotationEffect(.degrees(-12))
                        .opacity(strength)

                }
                .position(targetPosition)
                .animation(.spring(response: 0.9, dampingFraction: 0.7), value: targetPosition)

                halo(opacity: isDark ? 0.085 : 0.05, radius: 650)
                    .scaleEffect(x: 1, y: 0.74)
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
            waveStrength = min(1, max(0.32, residual, distance / 18))
            lastMovement = now
            waveActive = true
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { waveActive = false }
        }
        .task(id: waveActive) {
            guard waveActive, !reduceMotion else { return }
            // One settling task per interaction, rather than cancelling and
            // creating a new task for every mouse event.
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                    if Date().timeIntervalSince(lastMovement) >= 3 {
                        waveActive = false
                        return
                    }
                }
            } catch { /* View removal or reduced motion cancels the task. */ }
        }
    }

    private func halo(opacity: Double, radius: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: accent.opacity(opacity), location: 0),
                .init(color: accent.opacity(opacity * 0.58), location: 0.4),
                .init(color: accent.opacity(opacity * 0.14), location: 0.75),
                .init(color: .clear, location: 1)
            ], center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
    }
}

/// A fixed field of small round particles. Only their coordinates change;
/// one Canvas batches the dots into eight paths, with no blur or per-dot views.
private struct AmbientParticleWave: View {
    let phase: Double
    let strength: CGFloat
    let accent: Color
    let isDark: Bool

    private struct Particle: Sendable {
        let u: CGFloat
        let row: CGFloat
        let seed: Double
        let radius: CGFloat
    }

    private static let particles: [Particle] = (0..<196).map { index in
        let column = index % 28
        let row = index / 28
        // Stable, deliberately uneven spacing; never reseeded during a frame.
        let seed = Double((index * 73 + 41) % 197) / 197
        let jitter = CGFloat(seed - 0.5)
        return Particle(u: (CGFloat(column) + 0.5 + jitter * 0.6) / 28,
                        row: CGFloat(row - 3) + jitter * 0.45,
                        seed: seed * .pi * 2,
                        radius: 0.85 + CGFloat((index * 31) % 17) / 17 * 1.15)
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            var dots = Array(repeating: Path(), count: 8)
            for particle in Self.particles {
                let u = particle.u
                let taper = pow(sin(.pi * u), 2)
                let wave = sin(Double(u) * .pi * 2.4 - phase + Double(particle.row) * 0.12)
                let drift = sin(phase * 0.7 + particle.seed)
                let x = u * size.width + CGFloat(drift) * (3 + 4 * strength) * taper
                let y = size.height * 0.5 + particle.row * 14
                    + CGFloat(wave) * (18 + 25 * strength) * taper
                    + CGFloat(cos(phase * 0.85 + particle.seed)) * 3
                let shimmer = 0.75 + 0.25 * sin(phase * 0.6 + particle.seed)
                let rowFade = 1 - abs(particle.row) / 5
                let brightness = taper * rowFade * CGFloat(shimmer)
                let bucket = min(7, max(0, Int(brightness * 8)))
                let radius = particle.radius * (0.92 + 0.08 * CGFloat(drift))
                dots[bucket].addEllipse(in: CGRect(x: x - radius, y: y - radius,
                    width: radius * 2, height: radius * 2))
            }
            for index in dots.indices {
                let alpha = (Double(index) + 0.5) / 8 * (isDark ? 0.68 : 0.50)
                context.fill(dots[index], with: .color(accent.opacity(alpha)))
            }
        }
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
