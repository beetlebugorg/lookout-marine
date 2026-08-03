//  PickReport.swift — the cursor pick report.
//
//  One object at a time, decoded for the mariner: the operative fact as the
//  title, the attributes in chart language, and the raw S-57 rows one fold
//  away. The copy button puts the raw text on the clipboard, which is how a
//  chart problem gets reported.
//
//  The report has two bodies over one content: PickCallout stands beside the
//  object on a wide view, and PickSheet holds an edge of a narrow one.

import SwiftUI

/// What one pick result shows. The ENGINE composes the report — the core
/// emits {"report":…,"s57":…} per feature, the decoded page beside the raw
/// payload — and this parses it. Nothing here decides what a mariner reads;
/// tile57_s57_report does, once, for every shell.
struct PickDecoded {
    struct ReportRow: Identifiable {
        let label: String
        let value: String
        let depth: Int
        let file: Bool
        let picture: Bool
        var id: String { "\(depth)/\(label)/\(value)" }
    }

    /// Why the body has nothing to read, when it does not.
    enum EmptyKind { case noAttributes, sourceOnly }

    let feature: PickFeature
    let title: String
    let subtitle: String?
    let chip: String
    let notes: [String]
    let reportRows: [ReportRow]
    let footnote: String
    let empty: EmptyKind?
    /// The payload as the cell states it, for the fold and the clipboard.
    let rawRows: [S57.Row]

    init(_ feature: PickFeature) {
        self.feature = feature
        let root = (try? JSONSerialization.jsonObject(with: Data(feature.s57.utf8)))
            as? [String: Any]
        let report = root?["report"] as? [String: Any]
        // A payload without the envelope is a raw object — the core's
        // fallback when a compose fails. The fold still shows everything.
        let raw = report != nil ? root?["s57"] : root as Any?
        title = report?["title"] as? String ?? feature.cls
        subtitle = report?["subtitle"] as? String
        chip = report?["chip"] as? String ?? feature.cls
        notes = report?["notes"] as? [String] ?? []
        reportRows = ((report?["rows"] as? [[String: Any]]) ?? []).map { r in
            ReportRow(label: r["label"] as? String ?? "",
                      value: r["value"] as? String ?? "",
                      depth: r["depth"] as? Int ?? 0,
                      file: r["file"] as? Bool ?? false,
                      picture: r["picture"] as? Bool ?? false)
        }
        footnote = report?["footnote"] as? String ?? feature.chart
        empty = switch report?["empty"] as? String {
        case "none": .noAttributes
        case "source": .sourceOnly
        default: nil
        }
        rawRows = S57.rows(of: raw)
    }
}

/// The copy control and the close control. Which object shows is the list's
/// business — the pick set is always in sight, as a column or as chips, so
/// there is no blind pager.
private struct PickControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Button { copyReport() } label: {
                Image(systemName: "square.on.square").font(.system(size: 13)).padding(5)
            }
            .buttonStyle(ChromeFlatStyle(cornerRadius: 6))
            .foregroundStyle(Chrome.muted)
            .help("Copy this report")
            .accessibilityLabel("Copy this report")

            Button { model.closePick() } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).padding(5)
            }
            .buttonStyle(ChromeFlatStyle(cornerRadius: 6))
            .foregroundStyle(Chrome.muted)
            .accessibilityLabel("Close the pick report")
        }
    }

    private func copyReport() {
        guard model.pickResults.indices.contains(model.pickIndex) else { return }
        Pasteboard.copy(S57.plainText(model.pickResults[model.pickIndex]))
    }
}

/// The decoded rows both bodies share: the notes, then the details. The
/// provenance footnote, the fold and the raw rows are separate views — the
/// callout pins the first two to its floor so they never move, and only what
/// is here (plus the opened raw rows) scrolls.
///
/// `onMeasure` reports this view's natural height. The report's size is held
/// while a pick is open — §5.2, the rule this panel exists to keep — so
/// nothing that appears or grows later may sit inside the measured subtree.
private struct PickContent: View {
    @ObservedObject var model: AppModel
    let decoded: PickDecoded
    var onMeasure: ((CGFloat) -> Void)? = nil

    var body: some View {
        let core = VStack(alignment: .leading, spacing: 0) {
            ForEach(decoded.notes, id: \.self) { note in
                NoteCallout(text: note)
            }
            // The engine's verdict: a body with nothing to read says why.
            // A blank body reads as a defect.
            if let empty = decoded.empty {
                Text(empty == .noAttributes
                     ? "The cell carries no attributes for this object."
                     : "The cell carries only source data for this object.")
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.muted)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(decoded.reportRows) { row in
                DecodedRow(model: model, row: row, cell: decoded.feature.chart)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        if let onMeasure {
            core.measureSize { onMeasure($0.height) }
        } else {
            core
        }
    }
}

/// The provenance as one muted line under a hairline, not a table: the
/// mariner reads it once, to decide how much to trust the rows above it.
private struct SourceFootnote: View {
    let decoded: PickDecoded

    var body: some View {
        Text(decoded.footnote)
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(Chrome.muted)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .overlay(alignment: .top) { Divider().overlay(Chrome.rule.opacity(0.7)) }
    }
}

/// The fold's control. A control keeps its place (§5.3), so the callout pins
/// this to its floor; the rows it opens live in the scrolling region.
private struct FoldButton: View {
    let count: Int
    @Binding var open: Bool

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("S-57 source attributes (\(count))")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Chrome.muted)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Hide the S-57 source attributes"
                                 : "Show the S-57 source attributes")
    }
}

/// The raw rows, as the cell states them. Nothing the decode did is a
/// substitute for the source.
private struct RawRows: View {
    let decoded: PickDecoded

    var body: some View {
        ForEach(decoded.rawRows) { row in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.value.isEmpty ? row.name : "\(row.name):")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Chrome.muted)
                    .frame(width: 92 - CGFloat(row.depth) * 12, alignment: .leading)
                Text(row.value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Chrome.ink)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18 + CGFloat(row.depth) * 12)
            .padding(.trailing, 18)
            .padding(.vertical, 3)
        }
    }
}

/// One row of the engine's report: the label on the left, the value beside
/// it. The engine decoded both; this only lays them out.
private struct DecodedRow: View {
    @ObservedObject var model: AppModel
    let row: PickDecoded.ReportRow
    let cell: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(row.label)
                .font(.system(size: 13))
                .foregroundStyle(Chrome.muted)
                // Narrow, and a long label wraps: the value owns the width —
                // a note or a name is the reading matter, not the label.
                .frame(width: 108 - CGFloat(row.depth) * 12, alignment: .leading)
            if row.file {
                AuxFileView(model: model, cell: cell, name: row.value,
                            isPicture: row.picture)
            } else {
                Text(row.value)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Chrome.ink)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18 + CGFloat(row.depth) * 12)
        .padding(.trailing, 18)
        .padding(.vertical, row.file ? 9 : 7)
        .frame(minHeight: 34, alignment: .center)
    }
}

/// A note the mariner reads before the attributes: INFORM, promoted.
private struct NoteCallout: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Chrome.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Chrome.amber.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Chrome.amber.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}

/// The report's header: the operative fact large, what the object is under
/// it, and the controls.
private struct PickHeader: View {
    @ObservedObject var model: AppModel
    let decoded: PickDecoded
    /// The sheet sets a smaller title.
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                // One line in a FIXED box, shrinking a little for a long
                // name, and the subtitle line reserved even when empty: the
                // header is the same height for every object, so the space
                // between the title and the rows cannot shift as the pager
                // moves. The box matters: a scaled-down title has a smaller
                // line box, which quietly varied the header's height.
                Text(decoded.title)
                    .font(.system(size: compact ? 17 : 19, weight: .bold))
                    .foregroundStyle(Chrome.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: compact ? 21 : 23, alignment: .bottomLeading)
                Text(decoded.subtitle ?? " ")
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(Chrome.muted)
                    .lineLimit(1)
                    .frame(height: compact ? 15 : 17, alignment: .topLeading)
            }
            Spacer(minLength: 8)
            PickControls(model: model)
        }
        .padding(.horizontal, 18)
        .padding(.top, compact ? 10 : 16)
        .padding(.bottom, compact ? 8 : 13)
    }
}

/// The wide-screen report: a card beside the object of the pick, bound to it
/// by the tail the overlay draws. The card takes the height of the object on
/// show — a two-row buoy is a short card, not a tall blank one.
///
/// What holds still while the mariner pages is the panel's TOP: the
/// placement anchors it beside the point without regard to height, and the
/// pager, the copy and the close live in the header, so the controls stay
/// under the cursor (§5.3) while the card's floor follows the content.
struct PickCallout: View {
    @ObservedObject var model: AppModel
    /// The width the callout takes, and the room from its top to the free
    /// area's floor — its content scrolls past that.
    let width: CGFloat
    let roomBelow: CGFloat
    /// One report per pick. Keyed here, on the content, and never on the view
    /// that carries the chrome hit region: a keyed hit region can lose its
    /// entry when a new pick's registration lands before the old removal.
    let anchor: CGPoint

    @State private var foldOpen = false
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0
    @State private var notesHeight: CGFloat = 0
    @State private var detailHeight: CGFloat = 0
    /// The tallest the card has stood for this pick. The card grows when a
    /// selection needs more room and keeps that height after: a card that
    /// shrinks under the pointer moves the controls and the chart below it.
    @State private var heightFloor: CGFloat = 0
    /// The footnote and the fold control, which stand under the rows.
    @State private var floorHeight: CGFloat = 0

    static let maxWidth: CGFloat = 420
    static let listWidth: CGFloat = 200
    static let detailWidth: CGFloat = 430

    /// The card's width for a pick: the detail column, with the list beside
    /// it when the pick found several objects.
    static func width(for count: Int, in viewWidth: CGFloat) -> CGFloat {
        let want = count > 1 ? listWidth + 1 + detailWidth : maxWidth
        return min(want, max(280, viewWidth - Chrome.margin * 2))
    }

    private var feature: PickFeature? {
        guard model.pickResults.indices.contains(model.pickIndex) else { return nil }
        return model.pickResults[model.pickIndex]
    }

    var body: some View {
        if let feature {
            HStack(alignment: .top, spacing: 0) {
                if model.pickResults.count > 1 {
                    // The detail column is measured; the list column follows
                    // its height. One direction only — a column that also
                    // pushed back gave layout two answers, and the card
                    // flickered between them.
                    // Every column stops at the free area's floor. The list
                    // scrolls past it, and the height floor cannot carry a
                    // taller value across a window resize.
                    let columnH = min(roomBelow, max(heightFloor, detailHeight, notesHeight + 96))
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                listColumn.measureSize { listHeight = $0.height }
                            }
                            // The arrows walk the list; the list keeps the
                            // selection in sight.
                            .onChange(of: model.pickIndex) {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    proxy.scrollTo(model.pickIndex)
                                }
                            }
                        }
                        .frame(height: listHeight > 0
                               ? min(listHeight, max(60, min(columnH, roomBelow) - notesHeight))
                               : nil, alignment: .top)
                        // The notes hold the column's floor; the slack sits
                        // between the objects and them, not under them.
                        Spacer(minLength: 0)
                        notesShelf.measureSize { notesHeight = $0.height }
                    }
                    .frame(width: Self.listWidth)
                    .frame(height: detailHeight > 0 ? columnH : nil, alignment: .top)
                    .background(Chrome.panel)
                    Divider().overlay(Chrome.rule)
                }
                detail(feature)
                    .measureSize { detailHeight = $0.height }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: width)
            .measureSize { size in
                if size.height > heightFloor { heightFloor = size.height }
            }
            .frame(minHeight: heightFloor > 0 ? min(heightFloor, roomBelow) : nil,
                   alignment: .top)
            // The report keeps the height its content asks for, whatever
            // space the placement leaves it: without this a card placed low
            // lays out into what is left and reports THAT as its size.
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .panelSurface(cornerRadius: 12, opaque: true)
            .id(anchor)
            #if os(macOS)
            .onExitCommand { model.closePick() }
            #endif
        }
    }

    /// The pick's objects, always in sight beside the report, as a column —
    /// the main data in each row, the object on show held selected. There is
    /// no pager to walk blind and nothing to go "back" from.
    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.pickResults.count) OBJECTS")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Chrome.muted)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)
            ForEach(Array(model.pickResults.enumerated()), id: \.element.id) { i, f in
                if !f.cls.hasPrefix("M_") { listRow(i, f) }
            }
            Spacer(minLength: 8)
        }
    }

    /// The chart's notes, pinned at the column's floor: every pick carries
    /// them, so they keep one place and never scroll away with a long list.
    @ViewBuilder private var notesShelf: some View {
        if model.pickResults.contains(where: { $0.cls.hasPrefix("M_") }) {
            VStack(alignment: .leading, spacing: 0) {
                Divider().overlay(Chrome.rule)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 5)
                ForEach(Array(model.pickResults.enumerated()), id: \.element.id) { i, f in
                    if f.cls.hasPrefix("M_") { listRow(i, f) }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func listRow(_ i: Int, _ f: PickFeature) -> some View {
        let d = PickDecoded(f)
        let selected = i == model.pickIndex
        let isNote = f.cls.hasPrefix("M_")
        return Button { model.pickIndex = i } label: {
            HStack(spacing: 7) {
                if isNote {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Chrome.accent : Chrome.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNote ? d.chip : d.title)
                        .font(.system(size: 13, weight: isNote ? .medium : .semibold))
                        .foregroundStyle(selected ? Chrome.accent
                                         : isNote ? Chrome.muted : Chrome.ink)
                        .lineLimit(1)
                    if !isNote, let sub = d.subtitle {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Chrome.muted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Chrome.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 9)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .id(i)
        .accessibilityLabel("Show \(d.chip)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func detail(_ feature: PickFeature) -> some View {
        let decoded = PickDecoded(feature)
        let cap = max(48, roomBelow - headerHeight - floorHeight)
        return VStack(alignment: .leading, spacing: 0) {
            PickHeader(model: model, decoded: decoded)
                .measureSize { headerHeight = $0.height }
            Divider().overlay(Chrome.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PickContent(model: model, decoded: decoded)
                    if foldOpen { RawRows(decoded: decoded) }
                }
                // The raw rows are inside the measurement: opening the fold
                // grows the card to the room the view has, and scrolls past
                // that — not inside a two-row object's letterbox.
                .measureSize { contentHeight = $0.height }
            }
            .frame(height: contentHeight > 0 ? min(cap, contentHeight) : nil,
                   alignment: .top)
            VStack(alignment: .leading, spacing: 0) {
                SourceFootnote(decoded: decoded)
                FoldButton(count: decoded.rawRows.count, open: $foldOpen)
            }
            .measureSize { floorHeight = $0.height }
        }
    }
}

/// Which edge a sheet holds.
enum SheetSide {
    case bottom   // a narrow view: a phone upright, a squeezed window
    case leading  // a wide short view: a phone on its side
}

/// The narrow-screen report: a sheet against an edge, the pick set as chips,
/// and the HUD readouts folded into its footer — the sheet and the capsule
/// must not fight for the bottom of a phone. The sheet's size is fixed by the
/// view, not measured, so the pager rule holds by construction.
struct PickSheet: View {
    @ObservedObject var model: AppModel
    let side: SheetSide
    let sheetSize: CGSize
    let anchor: CGPoint
    let onScaleTap: () -> Void

    @State private var foldOpen = false

    private var feature: PickFeature? {
        guard model.pickResults.indices.contains(model.pickIndex) else { return nil }
        return model.pickResults[model.pickIndex]
    }

    var body: some View {
        if let feature {
            let decoded = PickDecoded(feature)
            VStack(alignment: .leading, spacing: 0) {
                PickHeader(model: model, decoded: decoded, compact: true)
                if model.pickResults.count > 1 { chips }
                Divider().overlay(Chrome.rule)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PickContent(model: model, decoded: decoded)
                        SourceFootnote(decoded: decoded)
                        FoldButton(count: decoded.rawRows.count, open: $foldOpen)
                        if foldOpen { RawRows(decoded: decoded) }
                    }
                    .id(anchor)
                }
                Divider().overlay(Chrome.rule)
                footer
            }
            .frame(width: sheetSize.width, height: sheetSize.height, alignment: .top)
            .background(Chrome.surface, in: corners)
            .overlay(corners.strokeBorder(Chrome.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: side == .bottom ? -2 : 0)
            #if os(macOS)
            .onExitCommand { model.closePick() }
            #endif
        }
    }

    /// The sheet rounds only the corners that face the chart.
    private var corners: UnevenRoundedRectangle {
        side == .bottom
            ? UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
            : UnevenRoundedRectangle(bottomTrailingRadius: 14, topTrailingRadius: 14)
    }

    /// Every object under the point, by name. The chips replace the blind
    /// pager: the mariner picks the light over the topmark in one tap.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.pickResults.enumerated()), id: \.element.id) { i, f in
                    let selected = i == model.pickIndex
                    let chip = PickDecoded(f).chip
                    Button { model.pickIndex = i } label: {
                        Text(chip)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? Chrome.accent : Chrome.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? Chrome.accent.opacity(0.10) : .clear,
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                selected ? Chrome.accent.opacity(0.6) : Chrome.rule,
                                lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(chip)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// The readouts the capsule shows when no sheet covers its ground: band,
    /// scale, zoom and position. The scale still opens the scale entry.
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text(CoordFormat.band(model.scaleDenominator))
                .foregroundStyle(Chrome.muted)
            Button(action: onScaleTap) {
                Text(CoordFormat.scale(model.scaleDenominator))
                    .fontWeight(.semibold)
                    .foregroundStyle(Chrome.accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .buttonStyle(ChromeFlatStyle(cornerRadius: 5))
            .accessibilityLabel("Scale \(CoordFormat.scale(model.scaleDenominator)). Zoom to a scale.")
            Text(String(format: "z%.1f", model.zoomLevel))
                .foregroundStyle(Chrome.muted)
            Text(CoordFormat.position(lat: model.centerLat, lon: model.centerLon))
                .foregroundStyle(Chrome.ink)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Chrome.panel)
    }
}

/// The diamond that binds a sheet to its mark. It is drawn UNDER the sheet:
/// half of it, and half of its border, hide behind the opaque surface, which
/// leaves a clean pointed tab on the sheet's edge.
struct PickTail: View {
    static let size: CGFloat = 15

    var body: some View {
        ZStack {
            Rectangle().fill(Chrome.surface)
            Rectangle().strokeBorder(Chrome.edge, lineWidth: 1)
        }
        .frame(width: Self.size, height: Self.size)
        .rotationEffect(.degrees(45))
        .allowsHitTesting(false)
    }
}

/// The leader that binds the mark to its report: ()────[report]. Not a line
/// drawn OVER the chart — a thin ribbon of the card's own material, with the
/// card's surface, hairline and shadow, so it reads as a piece of the chrome
/// reaching out to the circle. A stroked line in any colour read as chart
/// symbology.
struct PickLeader: Shape {
    var from: CGPoint
    var to: CGPoint
    var width: CGFloat = 7

    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
