//  SettingsRows.swift — the row grammar the settings window is built from, and
//  the drawn colour-scheme swatches.
//
//  Every row says what the setting DOES for the person at the helm, under the
//  control, and names the keystroke that reaches the same thing from the chart.
//  The structure is ours; the colours, fonts and control shapes are the
//  platform's, so the window is a Mac window at night as well as by day.
//
//  Plugin-contributed rows use the same grammar as the app's own. A mariner
//  never learns which settings came from a plugin.

import SwiftUI

// MARK: - Headings and rows

/// A section heading, with the keystroke that does the same job on the chart.
struct SectionHead: View {
    let title: String
    var hint: String?

    init(_ title: String, hint: String? = nil) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            // A hint names a KEYSTROKE, and the platform it is written for is
            // the one with a menu bar. A phone shows a chord beside a heading
            // it has no way to type, so the hint stays on the Mac.
            #if os(macOS)
            if let hint {
                Spacer()
                Text(hint).font(.caption).foregroundStyle(.tertiary)
            }
            #endif
        }
    }
}

/// A choice out of two or three, drawn as segments. macOS puts the label
/// beside the control the way every other row in this window does; iOS DROPS
/// a segmented picker's label entirely — the segments arrive with nothing
/// saying what they set — so there the label stands above them and the
/// control keeps the width it needs.
struct SegmentedRow<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    let options: Options

    init(_ title: String,
         selection: Binding<Selection>,
         @ViewBuilder options: () -> Options) {
        self.title = title
        self._selection = selection
        self.options = options()
    }

    var body: some View {
        #if os(macOS)
        Picker(title, selection: $selection) { options }
            .pickerStyle(.segmented)
        #else
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Picker(title, selection: $selection) { options }
                .pickerStyle(.segmented)
                .labelsHidden()
        }
        #endif
    }
}

/// One choice out of several, with the sentence that explains it. A stack of
/// these instead of a segmented control: the explanation needs the width, and
/// a mariner choosing how much chart to draw should read what each choice adds.
struct ChoiceRow: View {
    let title: String
    let desc: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                    if !desc.isEmpty {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A control with its label and explanation on the left. The explanation is
/// part of the row, not a section footer: it belongs to this one setting.
struct DescribedRow<Content: View>: View {
    let title: String
    let desc: String
    @ViewBuilder let content: Content

    var body: some View {
        LabeledContent {
            content
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !desc.isEmpty {
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A typed value — an address, a port — with its label and explanation.
///
/// The Mac keeps its controls in one column down the right of the form, and
/// the label and its sentence fit beside a 190pt field. A phone has no such
/// column: a full sentence and a field cannot share 402pt, so LabeledContent
/// truncated whichever it liked per row and the fields came out at three
/// different widths with dead space beside them. Here the label and sentence
/// stand above a field that fills the row, which is what every other iOS form
/// does with a field this size.
struct FieldRow<Content: View>: View {
    let title: String
    let desc: String
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        DescribedRow(title: title, desc: desc) { content }
        #else
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            content.frame(maxWidth: .infinity)
        }
        #endif
    }
}

// MARK: - Plugin contributions

/// The groups a plugin put in this section of the window. Each group is one
/// Section with its own heading and its own reset — the mariner sees settings
/// about the chart, never a list of plugins. A section nothing contributes to
/// renders nothing at all.
struct PluginSections: View {
    @ObservedObject var p: PluginSettings
    let tab: String

    var body: some View {
        ForEach(p.groups(tab: tab)) { g in
            Section {
                ForEach(g.fields) { f in
                    switch f.kind {
                    case .toggle:
                        // Two Texts is the platform's title-and-subtitle
                        // toggle. One Text when the schema gave no sentence.
                        if f.desc.isEmpty {
                            Toggle(f.label, isOn: p.toggle(g.pluginID, f.key))
                        } else {
                            Toggle(isOn: p.toggle(g.pluginID, f.key)) {
                                Text(f.label)
                                Text(f.desc)
                            }
                        }
                    case .number:
                        PluginNumberRow(field: f, value: p.number(g.pluginID, f.key))
                    case .text:
                        // Only ever a column of a list; the core refuses a
                        // scalar one. Nothing to draw here.
                        EmptyView()
                    }
                }
                if p.isChanged(g) {
                    Button("Reset to defaults") { p.resetToDefaults(g) }
                }
            } header: {
                SectionHead(g.title)
            }
        }
    }
}

/// The lists a plugin put in this section: connections, and anything else
/// there can be more than one of. One Section per list, with the rows the
/// mariner keeps and a control to add another.
struct PluginListSections: View {
    @ObservedObject var p: PluginSettings
    let tab: String

    var body: some View {
        ForEach(p.lists(tab: tab)) { list in
            Section {
                let rows = p.rows(list)
                if rows.isEmpty {
                    Text(list.empty.isEmpty ? "Nothing here yet." : list.empty)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    // A row with no address cannot work yet, so it opens
                    // itself: the mariner has to type one, and hunting for a
                    // disclosure triangle to find that out is not a task.
                    PluginRowEditor(p: p, list: list, rowID: row.id,
                                    startOpen: row.text("host").isEmpty)
                }
                // WHAT IS ALREADY ANSWERING on the boat's network, offered
                // ready to add. A Signal K server announces itself, so the
                // mariner should not have to find out its address to use it.
                // Nothing found shows nothing: at a desk that is the ordinary
                // case, and an empty "Nearby" heading is a question nobody
                // asked.
                ForEach(p.nearby(list)) { service in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.name)
                            // String(port), not the port itself: a number
                            // interpolated into a Text is localised, and a
                            // port is not a quantity — 10110 read "10,110".
                            Text("\(service.host):" + String(service.port))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            p.addRow(list, from: service)
                        } label: {
                            Label("Add \(service.name)", systemImage: "plus.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    p.addRow(list)
                } label: {
                    Label(list.addLabel.isEmpty ? "Add" : list.addLabel, systemImage: "plus")
                }
                // AT THE CAP THERE IS NOTHING TO ADD. The core keeps
                // `max_rows` and drops the rest, so a mariner who typed a
                // ninth gateway address would be left with a row that looks
                // like the other eight and never connects.
                .disabled(p.isFull(list))
            } header: {
                SectionHead(list.group)
            } footer: {
                // The plugin's sentence, never the window's. Connections holds
                // two lists now — NMEA gateways and Signal K servers — and a
                // line about WiFi gateways under a list of Signal K servers is
                // an instruction that sends the mariner to the wrong port.
                VStack(alignment: .leading, spacing: 4) {
                    if p.isFull(list) {
                        Text("\(list.maxRows) is the most this list holds. Remove one to add another.")
                    }
                    if !list.footer.isEmpty {
                        Text(list.footer)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One row of a list: what it is called, what it is doing right now, a switch
/// that pauses it, and — folded away until it is wanted — the address behind
/// it. The mariner reads the first line and touches nothing else most days.
///
/// The chevron is DRAWN HERE rather than taken from a DisclosureGroup. A
/// disclosure centres its chevron on the whole label, and this label is two
/// lines deep, so the chevron floated half a line below the dot and the title
/// — out of step with every other row in this window, where the leading
/// control sits on the title's line. The rows that open are ordinary Form
/// rows, so they get the window's own separators.
struct PluginRowEditor: View {
    @ObservedObject var p: PluginSettings
    let list: PluginListSchema
    let rowID: String
    var startOpen = false
    @State private var open = false

    private var row: PluginRow? { p.rows(list).first { $0.id == rowID } }

    /// What the mariner named it, or the address it dials.
    private var title: String {
        guard let row else { return "" }
        let name = row.text("name")
        if !name.isEmpty { return name }
        let host = row.text("host")
        // The list's own word for one of its rows, never this window's: the
        // Signal K list adds a SERVER, and calling its empty row a connection
        // is the window telling the mariner the wrong thing about the plugin.
        if host.isEmpty { return list.newLabel }
        return "\(host):\(PluginSettings.trimmed(row.number("port")))"
    }

    /// How far the opened rows sit inside their row's leading edge, so they
    /// read as belonging to it. The platform insets a disclosure's children to
    /// its label, and this is that distance: the chevron (9) and the state dot
    /// (8) and the two 8pt gaps and the 2pt the dot's frame adds.
    private static let childInset: CGFloat = 35

    var body: some View {
        header
        if open {
            ForEach(list.itemFields) { f in
                switch f.kind {
                case .text:
                    FieldRow(title: f.label, desc: f.desc) {
                        CommitTextField(
                            placeholder: !f.placeholder.isEmpty ? f.placeholder : (f.optional ? "Optional" : ""),
                            value: p.cellText(list, rowID, f.key)
                        )
                        .textFieldStyle(.roundedBorder)
                        #if os(macOS)
                        .frame(width: 190)
                        #endif
                    }
                    .padding(.leading, Self.childInset)
                case .number:
                    FieldRow(title: f.label, desc: f.desc) {
                        TextField("", value: p.cellNumber(list, rowID, f.key), format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            #if os(macOS)
                            .frame(width: 80)
                            #else
                            // A port is digits. The full QWERTY it raised
                            // otherwise has no business here, and the number
                            // pad it raises instead has no Return key — hence
                            // the Done above it.
                            .keyboardType(.numberPad)
                            .keyboardDone()
                            #endif
                    }
                    .padding(.leading, Self.childInset)
                case .toggle:
                    // Every toggle but the row's own on/off switch, which is
                    // drawn on the row's line where it is read at a glance.
                    if f.key == rowSwitch?.key {
                        EmptyView()
                    } else {
                        DescribedRow(title: f.label, desc: f.desc) {
                            // The label is a sibling Text, which leaves the
                            // switch itself unnamed to VoiceOver — the same
                            // gap the row's own pause switch had.
                            Toggle(f.label, isOn: p.cellToggle(list, rowID, f.key))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .accessibilityHint(f.desc)
                        }
                        .padding(.leading, Self.childInset)
                    }
                }
            }
            Button(role: .destructive) {
                p.removeRow(list, rowID)
            } label: {
                Label(list.removeLabel, systemImage: "trash")
            }
            .padding(.leading, Self.childInset)
        }
    }

    /// The column the list named as the row's on/off switch, or its first
    /// toggle. Named rather than positional since a list grew a second toggle:
    /// "the first toggle is the pause switch" put the Signal K transport
    /// switch on the row's line and hid the one that pauses it.
    private var rowSwitch: PluginField? {
        if !list.switchKey.isEmpty,
           let named = list.itemFields.first(where: { $0.key == list.switchKey && $0.kind == .toggle }) {
            return named
        }
        return list.itemFields.first(where: { $0.kind == .toggle })
    }

    /// The line the mariner reads: state, name, and the pause switch. Clicking
    /// anywhere but the switch opens the address behind it.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                open.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 9)
                    StatusDot(item: p.status(list, rowID))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(p.status(list, rowID)?.line ?? "not started")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(open ? "Hide the address" : "Show the address")

            // The pause switch: off closes the socket and stops the retries,
            // on dials again. Outside the button, or it could not be touched.
            if let sw = rowSwitch {
                Toggle(sw.label, isOn: p.cellToggle(list, rowID, sw.key))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    // .help is a POINTER tooltip, and a phone has no pointer.
                    // A switch drawn with its label hidden and no label given
                    // announces as an unnamed switch, so the words travel on
                    // the control itself: which row, which switch, and the
                    // plugin's sentence as the hint.
                    .help(sw.desc)
                    .accessibilityLabel("\(sw.label), \(title)")
                    .accessibilityHint(sw.desc)
            }
        }
        .onAppear { if startOpen { open = true } }
    }
}

/// A text field that commits when the mariner is FINISHED — on return, or when
/// the field loses focus. Not per keystroke: an address pushed letter by letter
/// would have the plugin dialling "1", then "10", then "10.0" on the way to
/// "10.0.0.9".
struct CommitTextField: View {
    let placeholder: String
    @Binding var value: String
    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        // The explicit prompt, not the title: with .labelsHidden() macOS
        // drops the title entirely instead of ghosting it in the field.
        TextField("", text: $draft, prompt: placeholder.isEmpty ? nil : Text(placeholder))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .focused($editing)
            .onSubmit { value = draft }
            #if os(iOS)
            // An address is TYPED, not written. Autocapitalisation turns
            // raymarine.local into Raymarine.local and autocorrect turns a
            // dotted quad into words, and either way the plugin dials a host
            // that does not exist. The URL keyboard also puts the dot and the
            // slash on the row the thumbs are already on.
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .toolbar {
                if editing {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { editing = false }
                    }
                }
            }
            #endif
            .onChange(of: editing) { _, nowEditing in
                if nowEditing { draft = value } else { value = draft }
            }
            .onChange(of: value) { _, fresh in
                if !editing { draft = fresh }
            }
            .onAppear { draft = value }
    }
}

#if os(iOS)
/// A Done button over the keyboard. The number pads these fields raise have
/// no Return key, so without one the keyboard covers the form until the
/// mariner finds somewhere harmless to tap — and the fields commit on Return
/// or on losing focus, so "somewhere harmless" is also how the value lands.
///
/// Only the FOCUSED field puts a bar up. Every number field in the window
/// declaring one unconditionally would leave several fighting over the same
/// slot.
private struct KeyboardDone: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .toolbar {
                if focused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }
                    }
                }
            }
    }
}
#endif

extension View {
    /// The keyboard's own Done button, on the platform that has a keyboard to
    /// put away. Nothing on macOS.
    func keyboardDone() -> some View {
        #if os(iOS)
        modifier(KeyboardDone())
        #else
        self
        #endif
    }
}

/// The coloured dot beside a row: green working, grey paused, amber trying,
/// red given up. Colour is never the only signal — the words are right beside
/// it — because a colour alone fails a mariner who cannot tell red from green.
private struct StatusDot: View {
    let item: PluginStatusItem?

    var body: some View {
        Circle()
            .fill(item?.tint ?? Color.secondary)
            .frame(width: 8, height: 8)
            .padding(.top, 4)
            .accessibilityLabel(item?.line ?? "not started")
    }
}

/// A number a plugin asked for: typed or stepped, inside the range the schema
/// declares, with its unit beside it and the range under it. Same shape as the
/// depth rows, because a mariner should not have to learn a second kind of
/// number field.
struct PluginNumberRow: View {
    let field: PluginField
    @Binding var value: Double

    var body: some View {
        DescribedRow(title: field.label, desc: field.desc) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .frame(width: 68)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        // Borderless, a number reads as a printed value rather
                        // than something to change. The row editors already
                        // wear the border; these match them.
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .keyboardDone()
                        #endif
                    Stepper("", value: $value, in: field.min...field.max, step: field.step)
                        .labelsHidden()
                    // The units line up in a column, but the column may not
                    // CLIP one: 24pt fits a Mac's 13pt "min" and folds it to
                    // "mi / n" at iOS body size, and at an accessibility text
                    // size it would fold anything.
                    Text(field.unit).foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(minWidth: 24, alignment: .leading)
                }
                Text(field.rangeText).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Colour scheme

/// The three schemes DRAWN, not named: each swatch is a piece of chart in that
/// scheme's own colours, so the choice is made by eye. Day is unreadable at
/// night and night is unreadable by day — the swatches say so without words.
struct SchemeSwatches: View {
    @Binding var scheme: MarinerScheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(MarinerScheme.allCases) { s in
                Button {
                    scheme = s
                } label: {
                    VStack(spacing: 6) {
                        SchemeSwatch(palette: .of(s))
                            .frame(height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(s == scheme ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                                  lineWidth: s == scheme ? 3 : 1)
                            }
                        Text(s.label)
                            .font(.subheadline)
                            .fontWeight(s == scheme ? .semibold : .regular)
                            .foregroundStyle(s == scheme ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(s == scheme ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A shore in one scheme: the four depth shades out to deep water, then land
/// behind a curved coastline. A piece of chart, not a colour chip.
private struct SchemeSwatch: View {
    let palette: SchemePalette

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                VStack(spacing: 0) {
                    palette.deep.frame(height: h * 0.36)
                    palette.medium.frame(height: h * 0.18)
                    palette.shallow.frame(height: h * 0.16)
                    palette.veryShallow
                }
                shore(w, h).fill(palette.land)
                shore(w, h).stroke(palette.coastline, lineWidth: 1.5)
            }
        }
    }

    /// The shoreline: a bay open to the top-left, land filling the corner.
    private func shore(_ w: CGFloat, _ h: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.80))
        p.addCurve(to: CGPoint(x: w, y: h * 0.52),
                   control1: CGPoint(x: w * 0.35, y: h * 0.74),
                   control2: CGPoint(x: w * 0.60, y: h * 0.44))
        p.addLine(to: CGPoint(x: w, y: h))
        p.closeSubpath()
        return p
    }
}

/// The chart colours of one scheme. These are the presentation library's own
/// sRGB values (S-101 colour profile, tokens DEPDW/DEPMD/DEPMS/DEPVS/LANDA/
/// CSTLN), copied so a swatch can be drawn without opening a chart. They are a
/// legend of the palette, not the palette itself: the engine draws from the
/// tables in the chart.
struct SchemePalette {
    let deep: Color, medium: Color, shallow: Color, veryShallow: Color
    let land: Color, coastline: Color

    static func of(_ s: MarinerScheme) -> SchemePalette {
        switch s {
        case .day:
            return .init(deep: hex(0xc9edff), medium: hex(0xa7d9fb), shallow: hex(0x82caff),
                         veryShallow: hex(0x61b7ff), land: hex(0xbfbe8f), coastline: hex(0x4c5b63))
        case .dusk:
            return .init(deep: hex(0x000000), medium: hex(0x0f1b21), shallow: hex(0x1d3246),
                         veryShallow: hex(0x1e4165), land: hex(0x40402e), coastline: hex(0x6b7f89))
        case .night:
            return .init(deep: hex(0x000000), medium: hex(0x03070a), shallow: hex(0x050e16),
                         veryShallow: hex(0x071727), land: hex(0x17160e), coastline: hex(0x252d31))
        }
    }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xff) / 255,
              green: Double((v >> 8) & 0xff) / 255,
              blue: Double(v & 0xff) / 255)
    }
}

/// A section footer's type. Used from every section file, so it lives here with
/// the rest of the row grammar.
extension Text {
    func captionFooter() -> some View { self.font(.caption).foregroundStyle(.secondary) }
}
