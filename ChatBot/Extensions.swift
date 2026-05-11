import SwiftUI

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((value >> 8) * 17, (value >> 4 & 0xF) * 17, (value & 0xF) * 17)
        case 6:
            (r, g, b) = (value >> 16, value >> 8 & 0xFF, value & 0xFF)
        default:
            (r, g, b) = (128, 128, 128)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

// MARK: - Animation presets  (macOS 14+ spring(duration:bounce:) API)

extension Animation {
    /// Standard interactive spring — snappy but not overdamped.
    static let uiSpring     = Animation.spring(duration: 0.32, bounce: 0.20)
    /// Faster micro-interaction spring (hover, toggles).
    static let quickSpring  = Animation.spring(duration: 0.22, bounce: 0.16)
    /// Playful, elastic spring for feedback (button taps, icon bounces).
    static let bouncySpring = Animation.spring(duration: 0.38, bounce: 0.38)
    /// Smooth, overdamped spring for layout transitions.
    static let smoothSpring = Animation.spring(duration: 0.48, bounce: 0.04)
    /// Fast easeOut for scroll anchoring.
    static let scrollEase   = Animation.easeOut(duration: 0.16)
}

// MARK: - View helpers

extension View {
    /// Accent-coloured focus ring matching NSTextView style.
    func focusRing(_ isFocused: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isFocused ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 2.5)
        )
    }

    /// macOS 26: uses `.glassEffect(in:)` when available; falls back to
    /// thin material + border on older systems.
    /// NOTE: Do NOT add an extra .shadow on top of this — the glass surface
    /// already carries its own elevation on macOS 26, and we add one below
    /// on older systems via the fallback path.
    @ViewBuilder
    func adaptiveGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(in: shape)
                .clipShape(shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background(Color.white.opacity(0.04), in: shape)
                .overlay(shape.stroke(.white.opacity(0.30), lineWidth: 1))
                .clipShape(shape)
        }
    }

    /// Canonical "floating panel" shadow — used for agent chat, dock panels, etc.
    /// Replaces ad-hoc .shadow(radius: 28-32) calls so every surface is consistent.
    func floatingShadow() -> some View {
        self.shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 10)
    }

    /// Lighter card-level shadow — for rows / inline cards.
    func cardShadow() -> some View {
        self.shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
    }

    /// Scales down on press — gives native interactive feel.
    func pressScaleEffect() -> some View {
        self.modifier(PressScaleModifier())
    }
}

// MARK: - PressScaleModifier

private struct PressScaleModifier: ViewModifier {
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .animation(.quickSpring, value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded   { _ in isPressed = false }
            )
    }
}
