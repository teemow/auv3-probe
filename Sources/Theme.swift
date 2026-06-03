import SwiftUI

// The signalwave design language, expressed as SwiftUI primitives.
//
// Aesthetic: "Bauhaus × Signalwave" — an engineering terminal / signal sniffer,
// not a glossy app-store product. Deep charcoal field, one cyber-green signal
// accent, muted slate grid lines, monospaced lowercase chrome, hard edges and
// bold geometry. See docs/signalwave.md.
//
// Convention used across the UI:
// - Chrome (labels, buttons, section headers, prompts) is lowercased monospace —
//   the command-line register.
// - Data (plugin names, FourCC codes, parameter counts) is shown verbatim in
//   monospace: "no obfuscation, show the raw data".

enum Signalwave {
    /// Primary background — deep charcoal / obsidian.
    static let bg = Color(hex: 0x121212)
    /// A slightly raised surface for armed/active rows.
    static let surface = Color(hex: 0x1B1B1B)
    /// Grid lines / dividers — muted slate.
    static let grid = Color(hex: 0x2A2A2A)
    /// Signal accent (primary) — high-visibility cyber green.
    static let green = Color(hex: 0x00FF66)
    /// Signal accent (alt) — industrial amber. Reserved for warning/failure
    /// states so the primary green stays the "all clear" signal.
    static let amber = Color(hex: 0xFF7A00)
    /// Foreground type — near-white on charcoal (avoid mid-grays for fg type).
    static let fg = Color(white: 0.92)
    /// Dimmed foreground for secondary/metadata text.
    static let dim = Color(white: 0.55)

    /// A monospaced font at a given text style, tracking the system's dynamic
    /// type sizing.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}

extension Color {
    /// Build a color from a 24-bit `0xRRGGBB` literal.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Logo / probe glyph

/// The signalwave motif: a high-contrast wave intercepted by a solid node (the
/// "probe" tapping the signal). Drawn as a vector so it scales crisply and stays
/// monochrome per the design language.
struct WaveGlyph: View {
    var color: Color = Signalwave.green
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let amp = size.height * 0.32
            let cycles = 2.0

            var wave = Path()
            let steps = 64
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let x = t * size.width
                let y = midY - sin(t * cycles * 2 * .pi) * amp
                if i == 0 { wave.move(to: CGPoint(x: x, y: y)) }
                else { wave.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(wave, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // The probe node: a solid circle sitting on the baseline, the point
            // where the wave is being tapped.
            let r = size.height * 0.16
            let node = CGRect(x: size.width / 2 - r, y: midY - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: node), with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Button styles

/// The primary call-to-action: a solid green block with charcoal text — a
/// screen-printed hardware label, square-ish corners, no gloss.
struct SignalPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Signalwave.mono(.headline, weight: .semibold))
            .foregroundStyle(isEnabled ? Signalwave.bg : Signalwave.dim)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isEnabled ? Signalwave.green : Signalwave.grid)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A secondary, outlined "ghost" button: accent-colored text inside a thin
/// stroked rectangle. Used for inline actions (test, rescan, all/none, save).
struct SignalGhostButtonStyle: ButtonStyle {
    var accent: Color = Signalwave.green
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tint = isEnabled ? accent : Signalwave.dim
        configuration.label
            .font(Signalwave.mono(.subheadline))
            .foregroundStyle(tint)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.55), lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(configuration.isPressed ? tint.opacity(0.12) : .clear)
            )
    }
}

extension ButtonStyle where Self == SignalGhostButtonStyle {
    static var signalGhost: SignalGhostButtonStyle { SignalGhostButtonStyle() }
    static func signalGhost(_ accent: Color) -> SignalGhostButtonStyle {
        SignalGhostButtonStyle(accent: accent)
    }
}

extension ButtonStyle where Self == SignalPrimaryButtonStyle {
    static var signalPrimary: SignalPrimaryButtonStyle { SignalPrimaryButtonStyle() }
}

// MARK: - Surfaces

extension View {
    /// A terminal-style input/field surface: charcoal fill, slate hairline
    /// border, hard-ish corners. Replaces system field chrome on the dark field.
    func signalField() -> some View {
        self
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Signalwave.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Signalwave.grid, lineWidth: 1)
            )
    }
}

/// A comment-style section header: `// receiver`, dim slate-green monospace.
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text("// \(title)")
            .font(Signalwave.mono(.footnote, weight: .semibold))
            .foregroundStyle(Signalwave.green.opacity(0.8))
            .textCase(.lowercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
