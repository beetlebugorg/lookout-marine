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

    static let ink = Color(red: 0.102, green: 0.102, blue: 0.102)      // #1A1A1A
    static let muted = Color(red: 0.420, green: 0.420, blue: 0.420)    // #6B6B6B
    static let accent = Color(red: 0.106, green: 0.286, blue: 0.769)   // #1B49C4
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)    // #F59E0B
    static let overscale = Color(red: 0.847, green: 0.231, blue: 0.004) // #D83B01
    static let surface = Color.white
    /// Panel fill (XAML #F2F8F8F8 / #F5F8F8F8 over the chart).
    static let panel = Color(red: 0.973, green: 0.973, blue: 0.973)
    /// Hairline separators inside the capsule (XAML #DDDDDD).
    static let rule = Color(red: 0.867, green: 0.867, blue: 0.867)
    /// Panel border (XAML #33000000).
    static let edge = Color.black.opacity(0.20)

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
    /// The WinUI 3 `Bubble` style: an opaque 48pt white circle. Apply it to the
    /// glyph. The tap target is the full circle.
    func bubbleSurface() -> some View {
        frame(width: Chrome.bubble, height: Chrome.bubble)
            .contentShape(Circle())
            .background(Chrome.surface, in: Circle())
            .overlay(Circle().strokeBorder(Chrome.edge.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }

    /// The WinUI 3 floating panel style: identify, empty state, and loader.
    func panelSurface(cornerRadius r: CGFloat = 8) -> some View {
        background(Chrome.panel.opacity(0.95),
                   in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Chrome.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
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
                .bubbleSurface()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The north bubble. The mark turns with the view. A tap sets the chart to
/// north-up. It is always visible, as in the WinUI 3 shell.
struct NorthBubble: View {
    let rotationDeg: Double
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            VStack(spacing: -1) {
                Image(systemName: "triangle.fill").font(.system(size: 8))
                Text("N").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Chrome.ink)
            .rotationEffect(.degrees(-rotationDeg))
            .bubbleSurface()
        }
        .buttonStyle(.plain)
        .help("Reset to north-up")
        .accessibilityLabel("Reset to north-up")
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
