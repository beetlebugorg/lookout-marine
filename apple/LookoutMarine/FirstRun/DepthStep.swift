//  DepthStep.swift: the depth settings, asked as two questions about the boat.
//
//  The step asks for a draft and a clearance under the keel. It derives the
//  two S-52 numbers the engine draws with, the safety depth and the safety
//  contour, and states what each one does to the chart.
//
//  The engine is always given metres, so feet convert on the way out.

import SwiftUI

struct DepthStep: View {
    @ObservedObject var m: MarinerSettings

    /// The boat, in the unit on screen. MarinerSettings keeps the numbers the
    /// chart draws with, and these two are the question behind them.
    ///
    /// Held in the unit on screen so every number displays round. A metric
    /// list converted into feet gave a 4.9 ft clearance and a 16.4 ft
    /// contour.
    @State private var draft = 5.5
    @State private var clearance = 2.0
    @State private var draftText = ""
    @State private var seeded = false

    private var feet: Bool { m.depthUnit == .feet }
    private var unit: String { feet ? "ft" : "m" }

    /// The clearances offered, in the unit on screen. Round in both units.
    private var clearances: [Double] { feet ? [1, 2, 3, 5] : [0.3, 0.6, 1, 1.5] }

    /// The contours an S-57 survey draws, in the unit on screen. The safety
    /// contour is the first of these at or past the safety depth, because the
    /// chart shades on a contour the survey has.
    private var ladder: [Double] {
        feet
            ? [6, 12, 18, 30, 60, 90, 120, 180, 240, 300]
            : [2, 5, 10, 20, 30, 50, 75, 100]
    }

    private var safetyDepth: Double { draft + clearance }
    private var safetyContour: Double {
        ladder.first { $0 >= safetyDepth } ?? ladder.last!
    }

    /// The deep contour. The step does not ask for it, so it comes off the
    /// same ladder as the safety contour and displays round.
    private var deepContour: Double {
        let want = safetyContour * 3
        return ladder.first { $0 >= want } ?? ladder.last!
    }

    /// A depth on screen converted to metres, for the engine.
    private func metres(_ v: Double) -> Double { feet ? v / 3.28084 : v }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "How deep does your boat sit?",
                blurb: "Lookout shades water your boat cannot cross. It needs one number to do that, and everything else follows from it.",
                centered: centered)
                .padding(.top, topInset)

            columns.padding(.top, 24)
            warning.padding(.top, 18)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 22)
        .onAppear(perform: seed)
        .onChange(of: safetyDepth) { _, _ in apply() }
    }

    @ViewBuilder private var columns: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 26) {
            boat.frame(width: 334)
            water
        }
        #else
        VStack(alignment: .leading, spacing: 20) {
            boat
            water
        }
        #endif
    }

    // MARK: The boat

    private var boat: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("Draft")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                    .frame(width: 62, alignment: .leading)
                draftField
            }
            .padding(.bottom, 9)

            HStack(spacing: 14) {
                Text("Units")
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.muted)
                    .frame(width: 62, alignment: .leading)
                Picker("Units", selection: $m.depthUnit) {
                    ForEach(MarinerDepthUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: m.depthUnit) { _, now in convert(to: now) }
                .accessibilityIdentifier("depth-unit")
            }
            .padding(.bottom, 8)

            caption("Deepest point of the hull below the waterline, keel included.")
                .padding(.bottom, 18)

            Text("Clearance under the keel")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .padding(.bottom, 9)
            clearancePills
            caption("How much water you want left under the keel at the shallowest point of a passage.")
                .padding(.top, 9)

            derived.padding(.top, 16)
        }
    }

    private var draftField: some View {
        HStack(spacing: 0) {
            TextField("", text: $draftText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Chrome.ink)
                .frame(width: 84)
                .padding(.leading, 13)
                .onSubmit(readDraft)
                .accessibilityIdentifier("draft")
            Text(unit)
                .font(.system(size: 15))
                .foregroundStyle(Chrome.muted)
                .padding(.horizontal, 8)
            Stepper("Draft") {
                draft = min(30, draft + stepSize)
                showDraft()
            } onDecrement: {
                draft = max(stepSize, draft - stepSize)
                showDraft()
            }
            .labelsHidden()
            .padding(.trailing, 8)
        }
        .frame(height: 44)
        .background(Chrome.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Chrome.accent, lineWidth: 1.5))
    }

    private var clearancePills: some View {
        HStack(spacing: 8) {
            ForEach(clearances, id: \.self) { c in
                Button { clearance = c } label: {
                    Text(measure(c))
                        .font(.system(size: 13.5, weight: clearance == c ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(clearance == c ? Color.white : Chrome.ink)
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background(clearance == c ? Chrome.accent : Chrome.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(
                            clearance == c ? Color.clear : Color.primary.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(clearance == c ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// What the two answers come to, in the engine's own terms.
    private var derived: some View {
        VStack(alignment: .leading, spacing: 0) {
            derivedRow(
                "Safety depth", measure(safetyDepth),
                "Soundings at or shallower than this print bold. It does not shade water.")
            derivedRow(
                "Safety contour", measure(safetyContour),
                "Water shallower than this shades as unsafe. Rounded up to a contour the survey draws, so \(measure(safetyDepth)) reads as \(measure(safetyContour)).")
        }
    }

    private func derivedRow(_ name: String, _ value: String, _ blurb: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.muted)
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Chrome.ink)
                    .contentTransition(.numericText())
            }
            caption(blurb)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Divider() }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Chrome.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The water

    /// What the two answers do to a chart, drawn from the numbers.
    ///
    /// A seabed shoaling to a shore, shaded at the derived contours, with
    /// spot depths on it. The depth range follows the deep contour, so all
    /// four shades are in frame whatever the boat draws. A window onto the
    /// live chart went here first, and the view the engine opens on is wide
    /// enough to hold one shade and no soundings.
    private var water: some View {
        VStack(spacing: 0) {
            seabed
                .frame(height: 210)
                .overlay(alignment: .topLeading) {
                    Text("Your water at \(measure(safetyDepth))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Chrome.surface.opacity(0.92),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                }
                .overlay(alignment: .bottom) { Divider() }
            HStack(spacing: 0) {
                key(unsafeShade, "Unsafe", "0 – \(measure(safetyDepth))")
                key(shallowShade, "Shallow", "\(measure(safetyDepth)) – \(measure(safetyContour))")
                key(mediumShade, "Medium", "\(measure(safetyContour)) – \(measure(deepContour))")
                key(deepShade, "Deep", "\(measure(deepContour)) +")
            }
        }
        .background(Chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14)))
    }

    /// The S-52 tokens the engine shades four-shade water with, deepest last,
    /// and the land under them.
    private var unsafeShade: Color { s52("DEPVS", fallback: .init(red: 0.38, green: 0.72, blue: 1)) }
    private var shallowShade: Color { s52("DEPMS", fallback: .init(red: 0.51, green: 0.79, blue: 1)) }
    private var mediumShade: Color { s52("DEPMD", fallback: .init(red: 0.65, green: 0.85, blue: 0.98)) }
    private var deepShade: Color { s52("DEPDW", fallback: .init(red: 0.79, green: 0.93, blue: 1)) }
    private var shore: Color { s52("LANDA", fallback: .init(red: 0.75, green: 0.75, blue: 0.56)) }
    private var contourInk: Color { s52("DEPCN", fallback: .init(red: 0.46, green: 0.55, blue: 0.59)) }
    private var soundingInk: Color { s52("SNDG2", fallback: .black) }

    /// One colour out of the engine's own palette, in the scheme on screen.
    /// The legend and the chart then cannot drift apart.
    private func s52(_ token: String, fallback: Color) -> Color {
        var rgba: [Float] = [0, 0, 0, 1]
        let ok = token.withCString { t in
            rgba.withUnsafeMutableBufferPointer {
                lookout_s52_color(t, UInt32(m.scheme.rawValue), $0.baseAddress)
            }
        }
        guard ok != 0 else { return fallback }
        return Color(.sRGB, red: Double(rgba[0]), green: Double(rgba[1]),
                     blue: Double(rgba[2]), opacity: Double(rgba[3]))
    }

    /// The seabed, as a fixed slope measured in safety contours.
    ///
    /// The soundings are the seabed and hold still; the shading is the
    /// mariner's and moves over them. Their depths are read off this slope, so
    /// they change only when the contour steps to the next one the survey
    /// draws. A chart behaves the same way when a boat changes.
    ///
    /// Measured in contours rather than metres because the answers span a
    /// dinghy and a ship: a fixed 40 m slope puts a 5 ft contour in the first
    /// pixel of the panel and a 30 ft one halfway up it.
    private static let shoreAt: CGFloat = 0.14
    /// How steeply the slope falls away. Shallow water gets most of the
    /// panel, because that is where both contours fall.
    private static let slopeK = 2.07

    /// The deepest water drawn, half again past the deep contour so the last
    /// shade has water in it.
    private var floor: Double { deepContour * 1.5 }

    /// How far out a depth lies, as a fraction of the panel.
    private func reach(_ depth: Double) -> CGFloat {
        guard floor > 0 else { return Self.shoreAt }
        let f = pow(max(0, min(1, depth / floor)), 1 / Self.slopeK)
        return Self.shoreAt + (1 - Self.shoreAt) * CGFloat(f)
    }

    private var seabed: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                deepShade
                shoal(w: w, h: h, at: reach(deepContour)).fill(mediumShade)
                shoal(w: w, h: h, at: reach(safetyContour)).fill(shallowShade)
                shoal(w: w, h: h, at: reach(safetyDepth)).fill(unsafeShade)
                // The safety contour, drawn bold the way S-52 draws the
                // contour the boat is measured against.
                shoal(w: w, h: h, at: reach(safetyContour))
                    .stroke(Color.black.opacity(0.45), lineWidth: 1.8)
                shoal(w: w, h: h, at: reach(deepContour))
                    .stroke(Color.black.opacity(0.18), lineWidth: 0.8)
                shoal(w: w, h: h, at: Self.shoreAt).fill(shore)
                shoal(w: w, h: h, at: Self.shoreAt)
                    .stroke(Color.black.opacity(0.45), lineWidth: 1)
                soundings(w: w, h: h)
            }
        }
    }

    /// Spot depths across the seabed, each reporting the water it stands in.
    ///
    /// Bold at or shallower than the safety depth. That is what the safety
    /// depth does to a chart, and the only way to watch the number move.
    private func soundings(w: CGFloat, h: CGFloat) -> some View {
        ForEach(Self.spots, id: \.0) { spot in
            let depth = safetyContour * spot.1
            let at = curvePoint(w: w, h: h, t: reach(depth), u: spot.2)
            Text(sounding(depth))
                .font(.system(size: 10.5,
                              weight: depth <= safetyDepth ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(Color.black.opacity(depth <= safetyDepth ? 0.8 : 0.55))
                .position(x: at.x, y: at.y)
        }
    }

    /// Each spot depth: an id, its depth as a multiple of the safety contour,
    /// and how far along its line it stands.
    ///
    /// Multiples, so a sounding holds both its place and its number while the
    /// mariner works, and moves only when the contour steps to the next one
    /// the survey draws. The shading is what answers every keystroke.
    private static let spots: [(Int, Double, CGFloat)] = [
        (0, 0.15, 0.30), (1, 0.22, 0.72), (2, 0.30, 0.16), (3, 0.40, 0.52),
        (4, 0.55, 0.86), (5, 0.70, 0.34), (6, 0.90, 0.64), (7, 1.10, 0.20),
        (8, 1.40, 0.46), (9, 1.75, 0.80), (10, 2.20, 0.28), (11, 2.70, 0.60),
        (12, 3.30, 0.40), (13, 3.90, 0.74),
    ]

    /// A sounding as a chart prints it, in the unit on screen: tenths in the
    /// shallows, whole numbers once the boat has water under it.
    private func sounding(_ v: Double) -> String {
        if feet || v >= 10 { return "\(Int(v.rounded()))" }
        return String(format: "%.1f", (v * 10).rounded() / 10)
    }

    /// One depth line, from the shore out. The same shape at every depth,
    /// moved further out as the water deepens.
    private func shoal(w: CGFloat, h: CGFloat, at t: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: h))
            p.addLine(to: CGPoint(x: 0, y: h - h * t))
            p.addCurve(to: CGPoint(x: w, y: h - h * t * 0.42),
                       control1: CGPoint(x: w * 0.34, y: h - h * t * 1.18),
                       control2: CGPoint(x: w * 0.62, y: h - h * t * 0.22))
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
        }
    }

    /// A point on one depth line, `u` of the way along it.
    private func curvePoint(w: CGFloat, h: CGFloat, t: CGFloat, u: CGFloat) -> CGPoint {
        let p0 = CGPoint(x: 0, y: h - h * t)
        let c1 = CGPoint(x: w * 0.34, y: h - h * t * 1.18)
        let c2 = CGPoint(x: w * 0.62, y: h - h * t * 0.22)
        let p3 = CGPoint(x: w, y: h - h * t * 0.42)
        let v = 1 - u
        let x = v * v * v * p0.x + 3 * v * v * u * c1.x + 3 * v * u * u * c2.x + u * u * u * p3.x
        let y = v * v * v * p0.y + 3 * v * v * u * c1.y + 3 * v * u * u * c2.y + u * u * u * p3.y
        return CGPoint(x: x, y: y)
    }

    private func key(_ color: Color, _ name: String, _ range: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 11, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.primary.opacity(0.12)))
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
            }
            Text(range)
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.muted)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .overlay(alignment: .leading) { Divider() }
    }

    // MARK: The warning

    private var warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.amber)
            (Text("Shading is not a depth sounder. ")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Chrome.ink)
             + Text("Soundings are not corrected for tide, surge or squat, and a survey can be decades old. Keep your own margin.")
                .font(.system(size: 12))
                .foregroundColor(Chrome.muted))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.amber.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Numbers

    /// One step of the draft field: half a foot, or a tenth of a metre.
    private var stepSize: Double { feet ? 0.5 : 0.1 }

    /// A depth on screen, with its unit on it.
    private func measure(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        let text = rounded == rounded.rounded()
            ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        return "\(text) \(unit)"
    }

    /// The draft alone, for the field, with no unit on it.
    private func showDraft() {
        let rounded = (draft * 10).rounded() / 10
        draftText = rounded == rounded.rounded()
            ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }

    private func readDraft() {
        guard let v = Double(draftText.trimmingCharacters(in: .whitespaces)), v > 0 else {
            showDraft()
            return
        }
        draft = min(feet ? 100 : 30, v)
        showDraft()
    }

    /// Convert the boat on a change of unit, and snap the clearance to one of
    /// the choices the new unit offers.
    private func convert(to now: MarinerDepthUnit) {
        let toFeet = now == .feet
        let f = toFeet ? 3.28084 : 1 / 3.28084
        draft = ((draft * f) * 2).rounded() / 2
        let want = clearance * f
        clearance = clearances.min { abs($0 - want) < abs($1 - want) } ?? clearances[1]
        showDraft()
        apply()
    }

    /// Start at a small keelboat. The stored safety depth is no help here.
    /// It starts at the engine's 10 m, and a draft read back out of that
    /// gave 9.7 m.
    private func seed() {
        guard !seeded else { return }
        seeded = true
        if !feet { draft = 1.7; clearance = 0.6 }
        showDraft()
        apply()
    }

    /// Write the numbers the engine draws with. The shallow contour follows
    /// the safety depth, which makes the first shade the water the boat
    /// cannot cross.
    private func apply() {
        m.safetyDepth = metres(safetyDepth)
        m.shallowContour = metres(safetyDepth)
        m.safetyContour = metres(safetyContour)
        m.deepContour = metres(deepContour)
        m.fourShadeWater = true
    }

    #if os(macOS)
    private var centered: Bool { true }
    private var topInset: CGFloat { 34 }
    private var horizontalInset: CGFloat { 48 }
    #else
    private var centered: Bool { false }
    private var topInset: CGFloat { 20 }
    private var horizontalInset: CGFloat { 18 }
    #endif
}
