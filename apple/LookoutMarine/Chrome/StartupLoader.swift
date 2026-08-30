//  StartupLoader.swift — opening, as a page.
//
//  The three waits are different work and the mariner should be able to see
//  which one they are in: the one-time symbol bake, mapping the library, and
//  tessellating the first scene. A single bar that fills and vanishes says only
//  that something happened.

import SwiftUI


/// Opening, as a page.
///
/// The three waits are different work and the mariner should be able to see
/// which one they are in: the one-time symbol bake, mapping the library, and
/// tessellating the first scene. A single bar that fills and vanishes says
/// only that something happened.
///
/// It is a page, not a card over a scrim, for the same reason the first run is:
/// there is nothing behind it worth showing yet.
struct StartupLoader: View {
    let phase: ChartsModel.LoadPhase
    /// How many charts are being opened, when that is known.
    var cells: Int = 0

    /// S-52 NODATA (day). ChartNSView.makeBackingLayer, ChartUIView.init and the
    /// LaunchBackground color asset use the same value.
    static let nodata = Color(red: 0.576, green: 0.682, blue: 0.733)

    private var step: Int {
        switch phase {
        case .bakingAtlas: return 0
        case .mapping: return 1
        case .tessellating: return 2
        }
    }

    var body: some View {
        ZStack {
            Chrome.panel.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    CompassMark().frame(width: 24, height: 24)
                    Text(cells > 1 ? "Opening \(cells.formatted(.number)) charts" : "Opening the chart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                }

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Chrome.accent)
                    .frame(width: BakeDetail.width)

                VStack(alignment: .leading, spacing: 7) {
                    // The atlas bake happens on the first run only, so on every
                    // other run it is already true rather than skipped.
                    BakeStep(state: step > 0 ? .done : .running,
                             label: "Preparing chart symbols",
                             detail: step > 0 ? "" : "first run only")
                    BakeStep(state: step > 1 ? .done : (step == 1 ? .running : .waiting),
                             label: cells > 1 ? "Mapping \(cells.formatted(.number)) cells" : "Mapping the chart",
                             detail: step == 1 ? "not loading them, so this is quick" : "")
                    BakeStep(state: step == 2 ? .running : .waiting,
                             label: "Drawing the first scene")
                }
                .frame(width: BakeDetail.width, alignment: .leading)
            }
        }
        .accessibilityIdentifier("startup-loader")
    }
}



/// The compass rose of the loader. It is drawn, not an SF Symbol, so that the
/// shape is the same on each platform.
struct CompassMark: View {
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().strokeBorder(Chrome.accent.opacity(0.35), lineWidth: 2)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(Chrome.accent.opacity(0.35))
                        .frame(width: 1.5, height: r * 0.28)
                        .offset(y: -r * 0.72)
                        .rotationEffect(.degrees(Double(i) * 90))
                }
                // The north needle. A chart compass rose uses the same red.
                Path { p in
                    p.move(to: CGPoint(x: r, y: r * 0.28))
                    p.addLine(to: CGPoint(x: r * 0.7, y: r * 1.32))
                    p.addLine(to: CGPoint(x: r * 1.3, y: r * 1.32))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.831, green: 0.180, blue: 0.180))
            }
            .frame(width: r * 2, height: r * 2)
        }
    }
}



/// The tessellation indicator at the top center. It is the BuildingPill of the
/// WinUI 3 shell.
struct BuildingPill: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Building chart…")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.ink)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .panelSurface(cornerRadius: 14)
    }
}
