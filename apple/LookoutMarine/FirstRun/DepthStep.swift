//  DepthStep.swift: the depth settings, asked as two questions about the boat.
//
//  The step asks for a draft and a clearance under the keel. It derives the
//  two S-52 numbers the engine draws with, the safety depth and the safety
//  contour, and states what each one does to the chart.
//
//  The core derives the numbers (lookout_depth_plan). The boat is held in
//  metres, and the plan returns it in the unit on screen for display.

import SwiftUI

struct DepthStep: View {
    @ObservedObject var m: MarinerSettings

    /// The boat, in metres. MarinerSettings keeps the numbers the chart
    /// draws with, and these two are the question behind them. A draft of
    /// zero is the core's starting keelboat.
    @State private var draftM = 0.0
    @State private var clearanceM = 0.0
    @State private var draftText = ""
    @State private var seeded = false

    private var feet: Bool { m.depthUnit == .feet }
    private var unit: String { feet ? "ft" : "m" }

    /// The settings for the boat, and the boat in the unit on screen.
    private var plan: lookout_depth_plan {
        var p = lookout_depth_plan()
        lookout_depth_plan(draftM, clearanceM, feet ? 1 : 0, &p)
        return p
    }

    private var draft: Double { plan.draft }
    private var clearance: Double { plan.clearance }

    /// The clearances offered, in the unit on screen.
    private var clearances: [Double] {
        let c = plan.clearances
        return [c.0, c.1, c.2, c.3]
    }

    private var safetyDepth: Double { plan.safety_depth }
    private var safetyContour: Double { plan.safety_contour }
    private var deepContour: Double { plan.deep_contour }

    /// Set the draft from a value in the unit on screen. The plan holds it
    /// between one step and the most the step accepts.
    private func setDraft(_ v: Double) {
        draftM = v * plan.metres_per_unit
        draftM = plan.draft_m
    }

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
                // Start Sailing reads the draft as typed. Parsing only on
                // Return left the seeded draft in the engine.
                .onChange(of: draftText) { _, now in
                    if let v = Self.parseDraft(now), v != draft { setDraft(v) }
                }
                .accessibilityIdentifier("draft")
            Text(unit)
                .font(.system(size: 15))
                .foregroundStyle(Chrome.muted)
                .padding(.horizontal, 8)
            Stepper("Draft") {
                setDraft(draft + plan.draft_step)
                showDraft()
            } onDecrement: {
                // Zero is the core's starting boat, so the step stops at one
                // press above it.
                setDraft(max(plan.draft_step, draft - plan.draft_step))
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
                Button { clearanceM = c * plan.metres_per_unit } label: {
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
            derivedRow(
                "Deep contour", measure(deepContour),
                "Water deeper than this draws in the lightest shade. Twice the safety contour, up the same ladder the safety contour came off.")
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
    /// the land under them, and the lines and soundings drawn over them.
    private var scheme: UInt32 { UInt32(m.scheme.rawValue) }
    private func token(_ name: String) -> Color { Chrome.s52(name, scheme: scheme) ?? .clear }
    private var unsafeShade: Color { token("DEPVS") }
    private var shallowShade: Color { token("DEPMS") }
    private var mediumShade: Color { token("DEPMD") }
    private var deepShade: Color { token("DEPDW") }
    private var land: Color { token("LANDA") }
    private var coastline: Color { token("CSTLN") }
    private var contourInk: Color { token("DEPCN") }

    /// The seabed and its soundings, from the core (lookout_depth_preview).
    private var preview: lookout_depth_preview {
        var p = plan
        var out = lookout_depth_preview()
        lookout_depth_preview(&p, &out)
        return out
    }

    private var seabed: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let v = preview
            ZStack {
                deepShade
                shoal(v, Int(LOOKOUT_DEPTH_LINE_DEEP_CONTOUR), w, h).fill(mediumShade)
                shoal(v, Int(LOOKOUT_DEPTH_LINE_SAFETY_CONTOUR), w, h).fill(shallowShade)
                shoal(v, Int(LOOKOUT_DEPTH_LINE_SAFETY_DEPTH), w, h).fill(unsafeShade)
                // The safety contour, drawn bold the way S-52 draws the
                // contour the boat is measured against.
                shoal(v, Int(LOOKOUT_DEPTH_LINE_SAFETY_CONTOUR), w, h)
                    .stroke(contourInk, lineWidth: 1.8)
                shoal(v, Int(LOOKOUT_DEPTH_LINE_DEEP_CONTOUR), w, h)
                    .stroke(contourInk.opacity(0.6), lineWidth: 0.8)
                shoal(v, Int(LOOKOUT_DEPTH_LINE_SHORE), w, h).fill(land)
                shoal(v, Int(LOOKOUT_DEPTH_LINE_SHORE), w, h)
                    .stroke(coastline, lineWidth: 1)
                soundings(v, w, h)
            }
        }
    }

    /// Spot depths across the seabed, each reporting the water it stands in.
    ///
    /// Bold at or shallower than the safety depth. That is what the safety
    /// depth does to a chart, and the only way to watch the number move.
    private func soundings(_ v: lookout_depth_preview, _ w: CGFloat, _ h: CGFloat) -> some View {
        let xs = Self.doubles(v.spot_x), ys = Self.doubles(v.spot_y)
        let n = Self.ints(v.spot_sounding), bold = Self.ints(v.spot_bold)
        return ForEach(0..<xs.count, id: \.self) { i in
            Text("\(n[i])")
                .font(.system(size: 10.5, weight: bold[i] != 0 ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(token(bold[i] != 0 ? "SNDG2" : "SNDG1"))
                .position(x: xs[i] * w, y: ys[i] * h)
        }
    }

    /// One depth line across the panel, closed along the bottom so it fills.
    private func shoal(_ v: lookout_depth_preview, _ line: Int, _ w: CGFloat, _ h: CGFloat) -> Path {
        let ys = withUnsafeBytes(of: v.y) { raw in
            Array(raw.bindMemory(to: Double.self)
                .dropFirst(line * Int(LOOKOUT_DEPTH_PREVIEW_POINTS))
                .prefix(Int(LOOKOUT_DEPTH_PREVIEW_POINTS)))
        }
        let last = CGFloat(ys.count - 1)
        return Path { p in
            p.move(to: CGPoint(x: 0, y: h))
            for (i, y) in ys.enumerated() {
                p.addLine(to: CGPoint(x: CGFloat(i) / last * w, y: y * h))
            }
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
        }
    }

    private static func doubles<T>(_ tuple: T) -> [CGFloat] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Double.self)).map { CGFloat($0) } }
    }

    private static func ints<T>(_ tuple: T) -> [Int] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Int32.self)).map(Int.init) }
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

    /// The caution in two weights, as one paragraph that wraps.
    private var caution: Text {
        let lead = Text("Shading is not a depth sounder. ")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Chrome.ink)
        let rest = Text("Soundings are not corrected for tide, surge or squat, and a survey can be decades old. Keep your own margin.")
            .font(.system(size: 12))
            .foregroundColor(Chrome.muted)
        return Text("\(lead)\(rest)")
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.amber)
            caution
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.amber.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Numbers

    /// A depth on screen, with its unit on it.
    private func measure(_ v: Double) -> String {
        TextFormat.depth(v * plan.metres_per_unit, feet: feet)
    }

    /// The draft alone, for the field, with no unit on it.
    private func showDraft() {
        draftText = TextFormat.depth(draftM, feet: feet, bare: true)
    }

    private func readDraft() {
        guard let v = Self.parseDraft(draftText) else {
            showDraft()
            return
        }
        setDraft(v)
        showDraft()
    }

    /// The draft in the field, or nil for text that is not a positive
    /// number. The plan caps it.
    static func parseDraft(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return v
    }

    /// Convert the boat on a change of unit: the draft to the nearest half
    /// unit, and the clearance to one of the choices the new unit offers.
    private func convert(to now: MarinerDepthUnit) {
        let p = plan
        draftM = p.draft_rounded_m
        clearanceM = p.clearance_m
        showDraft()
        apply()
    }

    /// Start at the core's small keelboat. The stored safety depth is no help
    /// here. It starts at the engine's 10 m, and a draft read back out of that
    /// gave 9.7 m.
    private func seed() {
        guard !seeded else { return }
        seeded = true
        let p = plan
        draftM = p.draft_m
        clearanceM = p.clearance_m
        showDraft()
        apply()
    }

    /// Write the numbers the engine draws with.
    private func apply() {
        let p = plan
        m.safetyDepth = p.safety_depth_m
        m.shallowContour = p.shallow_contour_m
        m.safetyContour = p.safety_contour_m
        m.deepContour = p.deep_contour_m
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
