//  Chrome.swift — the chart chrome for macOS and iOS.
//
//  The sizes and colors come from the WinUI 3 shell
//  (windows/ui/MainWindow.xaml). The Mac, the iPad and the PC must look the same.
//
//  The chrome is opaque white with a dark glyph in all chart schemes. It does
//  not use a system material, because a material takes its color from the chart
//  below it and differs on each platform.

import SwiftUI

/// Sizes and colors from MainWindow.xaml.
enum Chrome {
    /// Bubble diameter (XAML `Bubble` style: 48×48, CornerRadius 24).
    static let bubble: CGFloat = 48
    /// Gap between chrome items (XAML Spacing="10").
    static let gap: CGFloat = 10
    /// Distance from chrome to the window edge (XAML Margin="16").
    static let margin: CGFloat = 16
    /// Readout capsule height (XAML HudPill Height="44", CornerRadius 22).
    static let capsule: CGFloat = 44

    /// A colour that follows the view's colour scheme. The chrome renders in
    /// the dark palette whenever the view's scheme is dark — which the
    /// overlay derives from the chart's own scheme (dusk and night are dark)
    /// and, in the day scheme, from the OS appearance.
    private static func dyn(light: (Double, Double, Double, Double),
                            dark: (Double, Double, Double, Double)) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let m = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = m ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #else
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #endif
    }

    static let ink = dyn(light: (0.102, 0.102, 0.102, 1),      // #1A1A1A
                         dark: (0.839, 0.824, 0.784, 1))       // #D6D2C8
    static let muted = dyn(light: (0.420, 0.420, 0.420, 1),    // #6B6B6B
                           dark: (0.561, 0.545, 0.514, 1))     // #8F8B83
    static let accent = dyn(light: (0.106, 0.286, 0.769, 1),   // #1B49C4
                            dark: (0.494, 0.631, 0.961, 1))    // #7EA1F5
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)    // #F59E0B
    static let overscale = dyn(light: (0.847, 0.231, 0.004, 1), // #D83B01
                               dark: (0.957, 0.416, 0.204, 1))
    /// S-52 highlights in magenta.
    static let magenta = Color(red: 0.858, green: 0.098, blue: 0.549)
    static let surface = dyn(light: (1, 1, 1, 1),
                             dark: (0.086, 0.094, 0.110, 1))   // #16181C
    /// Panel fill (XAML #F2F8F8F8 over the chart; its dark twin).
    static let panel = dyn(light: (0.973, 0.973, 0.973, 1),    // #F8F8F8
                           dark: (0.118, 0.129, 0.149, 1))     // #1E2126
    /// Hairline separators inside the capsule (XAML #DDDDDD).
    static let rule = dyn(light: (0.867, 0.867, 0.867, 1),
                          dark: (0.227, 0.239, 0.259, 1))      // #3A3D42
    /// Panel border (XAML #33000000).
    static let edge = dyn(light: (0, 0, 0, 0.20),
                          dark: (1, 1, 1, 0.28))
    /// A control's fill as the pointer finds and presses it.
    static let hoverFill = dyn(light: (0.95, 0.95, 0.95, 1),
                               dark: (0.165, 0.176, 0.196, 1))
    static let pressFill = dyn(light: (0.87, 0.87, 0.87, 1),
                               dark: (0.216, 0.227, 0.247, 1))

    /// The overlay coordinate space. chromeHitRegion writes the frames of the
    /// controls in this space. The pass-through hosts hit-test against it.
    static let space = "lookout.chrome"

    /// Ground metres per logical point at a 1:N display scale.
    ///
    /// The engine gives the OGC/WMTS denominator: metres per camera pixel
    /// divided by 0.00028, the standard 0.28 mm pixel. One camera pixel is one
    /// logical point (see lookout_resize). This constant inverts that math, so
    /// the bar is correct at any display density.
    static let metresPerPointAt1to1 = 0.00028
}

extension View {
    /// Report this view's laid-out size, and each later change of it.
    ///
    /// Not a preference: a value published with `preference` from inside a
    /// `background` never reaches its `onPreferenceChange` here — the sink is
    /// called once with the DEFAULT and never again, while the reader plainly
    /// sees the real size. The pick report placed itself against that default
    /// for as long as it has existed. `onGeometryChange` also beats the old
    /// GeometryReader-in-background route: it reports within the layout
    /// update, initial value included, so a panel placed from a measurement
    /// no longer spends its first frame at an estimated position.
    func measureSize(_ perform: @escaping (CGSize) -> Void) -> some View {
        onGeometryChange(for: CGSize.self, of: \.size) { perform($0) }
    }

    /// The WinUI 3 floating panel style: pick report, empty state, and loader.
    /// A report is opaque: the chart showing through a table of numbers makes
    /// both hard to read.
    func panelSurface(cornerRadius r: CGFloat = 8, opaque: Bool = false) -> some View {
        background(opaque ? Chrome.surface : Chrome.panel.opacity(0.95),
                   in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Chrome.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// The WinUI 3 `Bubble` style: an opaque 48pt white circle that answers the
/// pointer. A plain button style draws no hover and no pressed state, which
/// makes a control look like a painted shape. WinUI tints its bubbles the same
/// way, so the states are parity, not decoration.
struct ChromeButtonStyle: ButtonStyle {
    /// The resting fill of a bubble whose mode is ON. nil is the plain bubble.
    var activeFill: Color?

    func makeBody(configuration: Configuration) -> some View {
        Bubble(configuration: configuration, activeFill: activeFill)
    }

    private struct Bubble: View {
        let configuration: ButtonStyleConfiguration
        let activeFill: Color?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: Chrome.bubble, height: Chrome.bubble)
                .contentShape(Circle())
                .background(fill, in: Circle())
                .overlay(Circle().strokeBorder(Chrome.edge.opacity(hovering ? 0.5 : 0.35),
                                               lineWidth: 0.5))
                .shadow(color: .black.opacity(configuration.isPressed ? 0.10 : 0.18),
                        radius: configuration.isPressed ? 3 : 5,
                        y: configuration.isPressed ? 1 : 2)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            if let activeFill {
                return configuration.isPressed ? activeFill.opacity(0.75) : activeFill
            }
            if configuration.isPressed { return Chrome.pressFill }
            return hovering ? Chrome.hoverFill : Chrome.surface
        }
    }
}

/// A flat chrome control: a preset chip, a close button, or the scale readout.
/// It answers the pointer like the bubbles do.
struct ChromeFlatStyle: ButtonStyle {
    var resting: Color = .clear
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        Flat(configuration: configuration, resting: resting, cornerRadius: cornerRadius)
    }

    private struct Flat: View {
        let configuration: ButtonStyleConfiguration
        let resting: Color
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .contentShape(shape)
                .background(fill, in: shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var fill: Color {
            if configuration.isPressed { return Chrome.ink.opacity(0.16) }
            if hovering { return Chrome.ink.opacity(0.10) }
            return resting
        }
    }
}

/// One circular chrome button.
struct ChromeBubble: View {
    let system: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Chrome.ink)
        }
        .buttonStyle(ChromeButtonStyle())
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// How the chart is held: free, locked to own ship north-up, or locked to own
/// ship with its course up the screen.
enum Orientation {
    case unlocked
    /// Locked, but with no fix to lock to yet — armed and waiting.
    case armed
    case northUp
    case courseUp
}

/// The compass bubble, which is also the lock. The mark turns with the view,
/// so it always points at north. A tap locks the chart to own ship and then
/// cycles north-up and course-up; a pan unlocks it again, which the core
/// reports and this draws.
struct NorthBubble: View {
    let rotationDeg: Double
    var orientation: Orientation = .unlocked
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Armed: follow is on and waiting for a fix. A ring, not a
                // fill: nothing is being followed yet.
                if orientation == .armed {
                    Circle().strokeBorder(Chrome.accent, lineWidth: 2)
                        .frame(width: Chrome.bubble - 4, height: Chrome.bubble - 4)
                }
                // The letter names what is up: north, or own ship's course.
                // Under N the mark turns with the view and points at north;
                // under C the course is up by definition, so it stands still.
                VStack(spacing: -1) {
                    Image(systemName: "triangle.fill").font(.system(size: 8))
                    Text(orientation == .courseUp ? "C" : "N")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(ink)
                .rotationEffect(.degrees(orientation == .courseUp ? 0 : rotationDeg))
            }
        }
        .buttonStyle(ChromeButtonStyle(activeFill: locked ? Chrome.accent : nil))
        .help(help)
        .accessibilityLabel(help)
    }

    private var locked: Bool { orientation == .northUp || orientation == .courseUp }
    private var ink: Color { locked ? .white : Chrome.ink }

    private var help: String {
        switch orientation {
        case .unlocked: return "Follow own ship"
        case .armed: return "Following own ship, waiting for a fix"
        case .northUp: return "Following own ship, north up. Tap for course up"
        case .courseUp: return "Following own ship, course up. Tap for north up"
        }
    }
}

/// The mark on the chart under an open pick report. S-52 highlights in
/// magenta; the white ring under it keeps the mark visible on a night chart.
struct PickMarker: View {
    static let size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 4)
            Circle().strokeBorder(Chrome.magenta, lineWidth: 2)
        }
        .frame(width: Self.size, height: Self.size)
        .allowsHitTesting(false)
    }
}

/// Distance bar: four alternating black and white segments below a label. The
/// width comes from the 1:N scale.
struct ScaleBarView: View {
    let scaleDenominator: Double

    private static let nice: [Double] = [10, 20, 50, 100, 200, 500, 1000, 2000, 5000,
                                         10_000, 20_000, 50_000, 100_000, 200_000, 500_000]
    /// The bar is 140pt or less. The distance rounds down to a nice number, so
    /// the label is always a round distance.
    private static let targetPoints = 140.0

    private var bar: (label: String, width: CGFloat)? {
        guard scaleDenominator > 0 else { return nil }
        let metresPerPoint = scaleDenominator * Chrome.metresPerPointAt1to1
        let target = Self.targetPoints * metresPerPoint
        let metres = Self.nice.last { $0 <= target } ?? Self.nice[0]
        // Each nice number of 1000 or more is a whole number of kilometres.
        let label = metres >= 1000 ? "\(Int(metres) / 1000) km" : "\(Int(metres)) m"
        return (label, CGFloat(metres / metresPerPoint))
    }

    var body: some View {
        if let bar {
            VStack(alignment: .leading, spacing: 3) {
                Text(bar.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                    // The chart below the label can be light or dark. The white
                    // shadow keeps the label readable.
                    .shadow(color: .white.opacity(0.9), radius: 2)
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle()
                            .fill(i.isMultiple(of: 2) ? Chrome.ink : Chrome.surface)
                            .frame(width: bar.width / 4, height: 6)
                    }
                }
                .overlay(Rectangle().stroke(Chrome.ink, lineWidth: 1))
            }
            .allowsHitTesting(false)
        }
    }
}
