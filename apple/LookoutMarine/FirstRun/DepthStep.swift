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
        feet ? [6, 12, 18, 30, 60, 120, 300] : [2, 5, 10, 20, 30, 50, 100]
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

    /// The shades the answers produce, on the chart itself.
    ///
    /// On the Mac this panel is a window. Setup stands over the running
    /// chart, so the flow lifts its scrim and its own surface out of this
    /// rectangle and the chart underneath shows through, shaded to the
    /// numbers on the left.
    private var water: some View {
        VStack(spacing: 0) {
            chartWindow
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
                        .allowsHitTesting(false)
                }
            Divider()
            HStack(spacing: 0) {
                key(Self.unsafeShade, "Unsafe", "0 – \(measure(safetyDepth))")
                key(Self.shallowShade, "Shallow", "\(measure(safetyDepth)) – \(measure(safetyContour))")
                key(Self.mediumShade, "Medium", "\(measure(safetyContour)) – \(measure(deepContour))")
                key(Self.deepShade, "Deep", "\(measure(deepContour)) +")
            }
        }
        .background(Chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.14)))
    }

    @ViewBuilder private var chartWindow: some View {
        #if os(macOS)
        // The flow draws setup as one layer. This removes the dim and the
        // card from the rectangle it occupies, leaving the chart.
        Rectangle()
            .fill(.black)
            .blendMode(.destinationOut)
            .overlay(alignment: .bottom) { Divider() }
        #else
        // A phone has no chart behind setup. It is the whole screen there.
        bands
        #endif
    }

    /// The four shades, approximating the day palette. A legend, and not the
    /// palette the engine draws with.
    private static let unsafeShade = Color(red: 0.38, green: 0.72, blue: 1.0)
    private static let shallowShade = Color(red: 0.51, green: 0.79, blue: 1.0)
    private static let mediumShade = Color(red: 0.65, green: 0.85, blue: 0.98)
    private static let deepShade = Color(red: 0.79, green: 0.93, blue: 1.0)
    private static let shore = Color(red: 0.84, green: 0.82, blue: 0.66)

    /// Water shoaling toward a shore, in the order a chart shades it.
    private var bands: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                Self.deepShade
                shoal(w: w, h: h, at: 0.95).fill(Self.mediumShade)
                shoal(w: w, h: h, at: 0.70).fill(Self.shallowShade)
                shoal(w: w, h: h, at: 0.46).fill(Self.unsafeShade)
                shoal(w: w, h: h, at: 0.22).fill(Self.shore)
            }
        }
    }

    /// One band of water, from the bottom left corner. The same shape at
    /// every depth, offset from the shore.
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
