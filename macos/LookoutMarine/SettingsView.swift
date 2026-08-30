//  SettingsView.swift — the mariner settings window: a SIDEBAR of sections on
//  macOS (Display / Depths / Text / Charts / … / Advanced), the same sections
//  in the same order on iOS, pushed one at a time on a phone and stood beside
//  the sidebar on an iPad. One MarinerSettings model behind all of them:
//  bind() loads the engine state, edits auto-apply (debounced) and SAVE.
//
//  The sidebar is a slot list, not a fixed menu. The four core sections and
//  Advanced always exist; Vessels, Alarms and Connections appear only while
//  something puts settings in them, and today that something is a plugin. The
//  mariner is never told which: AIS settings are chart settings.
//
//  The Depths section explains the S-52 shading model instead of assuming it:
//  the single most-reported "bug" was a safety-contour change not turning
//  water white — which is FOUR-shade semantics (white starts at the DEEP
//  contour) plus chart-ladder snapping, not a bug. The band preview makes the
//  model visible where the knobs are.

import SwiftUI

/// One entry in the sidebar. `core` sections are the app's own and are always
/// listed; the rest are listed only while they hold something. The ids are the
/// core's section names (src/plugin/host.zig, `Tab`), so a plugin and the shell
/// mean the same thing by "alarms".
struct SettingsSection: Identifiable {
    let id: String
    let label: String
    let icon: String
    let core: Bool

    /// Every section, in the order the sidebar shows them. Advanced is last:
    /// it is where anything unclaimed lands.
    static let all: [SettingsSection] = [
        .init(id: "display", label: "Display", icon: "paintpalette", core: true),
        .init(id: "depths", label: "Depths", icon: "water.waves", core: true),
        .init(id: "text", label: "Text", icon: "textformat", core: true),
        .init(id: "charts", label: "Charts", icon: "map", core: true),
        .init(id: "vessels", label: "Vessels", icon: "ferry", core: false),
        .init(id: "alarms", label: "Alarms", icon: "bell", core: false),
        .init(id: "connections", label: "Connections", icon: "antenna.radiowaves.left.and.right", core: false),
        // Plugins is the one section that talks ABOUT plugins: install,
        // grants, uninstall. It is the app's own, not a slot a schema fills.
        .init(id: "plugins", label: "Plugins", icon: "puzzlepiece.extension", core: true),
        .init(id: "advanced", label: "Advanced", icon: "slider.horizontal.3", core: true),
    ]
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var m = MarinerSettings()
    @StateObject private var p = PluginSettings()

    var body: some View {
        content
            .onAppear {
                m.bind(to: model.controller)
                p.bind(to: model.controller)
                // A connection's line moves on its own while the window is up.
                p.startPolling()
            }
            .onDisappear { p.stopPolling() }
            #if os(iOS)
            // The chart pickers, presented BY THE FORM. A sheet cannot present
            // another sheet from the window's own view, which is where the
            // chart's importers hang, so Add Charts had to dismiss the form
            // and time a re-present. These come up over the form and leave it
            // where it was.
            .fileImporter(isPresented: $model.showSettingsImporter,
                          allowedContentTypes: [.item, .folder]) { result in
                if case .success(let url) = result { model.openImported(url) }
            }
            // On its OWN view. Two .fileImporter modifiers on one view collide —
            // SwiftUI presents only the outer, so Add Charts silently did
            // nothing. A background node keeps the two importers apart.
            .background(
                Color.clear.fileImporter(isPresented: $model.showSettingsRasterImporter,
                              allowedContentTypes: [.item, .folder],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { model.importRasterCharts(urls) }
                }
            )
            // A third importer, so a third background node — see above.
            .background(
                Color.clear.fileImporter(isPresented: $model.showSettingsStyleImporter,
                              allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { model.importChartStyle(url) }
                }
            )
            #endif
    }

    /// The one thing the whole window promises. It stands under the list of
    /// sections rather than repeating itself in every one of them.
    private static let promise = "Applies at once · kept for next launch"

    private var sections: [SettingsSection] {
        let filled = p.populatedTabs
        return SettingsSection.all.filter { s in
            #if os(iOS)
            // NOTHING ON IOS INSTALLS A PLUGIN: the app claims no .lkplug
            // type, there is no Finder to open one from and no panel to pick
            // one with. On a device carrying only the shipped set the section
            // could say nothing but "No plugins installed" under a heading
            // with no button, which reads as a broken page rather than an
            // empty one. So it follows the rule Vessels, Alarms and
            // Connections already follow — a section appears while it holds
            // something — and a developer copy or an installed plugin brings
            // it back with its grant switches, which is the part that matters.
            if s.id == "plugins" { return p.plugins.contains { $0.origin != "bundled" } }
            #endif
            return s.core || filled.contains(s.id)
        }
    }

    /// The section on screen. A section can go away — a plugin that never came
    /// up takes its section with it — so a stale selection falls back.
    private var selected: String {
        sections.contains { $0.id == model.settingsTab } ? model.settingsTab : "display"
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        NavigationSplitView {
            List(sections, selection: $model.settingsTab) { s in
                Label(s.label, systemImage: s.icon)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 220)
            // No collapse control: the list IS the navigation, and a window
            // with it hidden has no way back to another section.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                Text(Self.promise)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            pane(selected)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 560)
        #else
        // iOS never had this sidebar. It had a TabView, and a tab bar holds
        // FOUR of nine sections before the rest go behind More — on the
        // 13-inch iPad as well as the phone — so Connections, the one a
        // mariner opens at the dock with a gateway in front of them, was two
        // taps down an overflow menu with no title on the page it landed on.
        //
        // The same sections in the same order, in this platform's own
        // navigation instead: a phone pushes a section onto a stack, and a
        // sheet wide enough to hold both columns stands the list beside the
        // pane, which is the shape of the Mac window.
        GeometryReader { geo in
            if geo.size.width >= Self.splitWidth {
                splitLayout
            } else {
                stackLayout
            }
        }
        #endif
    }

    #if os(iOS)
    /// Narrower than this and two columns leave the pane nothing to stand in,
    /// so the sections push instead. An iPhone sheet is 402pt wide; the
    /// settings sheet on a 13-inch iPad is 571pt.
    private static let splitWidth: CGFloat = 500

    /// A phone: the list of sections, and one section pushed onto it.
    ///
    /// The path IS `settingsTab` — one section deep, or none while the list
    /// itself is on screen — so the screenshot hook's `settings:connections`
    /// comes up already on Connections, and Back puts the list back.
    private var stackLayout: some View {
        NavigationStack(path: pushedSection) {
            List {
                Section {
                    ForEach(sections) { s in
                        NavigationLink(value: s.id) {
                            Label(s.label, systemImage: s.icon)
                        }
                    }
                } footer: {
                    Text(Self.promise).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Mariner Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                pane(id)
                    .navigationTitle(sectionLabel(id))
                    .navigationBarTitleDisplayMode(.inline)
                    // Every pane carries its own: a pushed view does not
                    // inherit the root's toolbar, and a mariner two taps into
                    // Connections must be able to shut the form from there.
                    .toolbar { doneItem }
            }
            .toolbar { doneItem }
        }
    }

    /// An iPad: the list beside the pane, the Mac window's own shape.
    private var splitLayout: some View {
        NavigationSplitView {
            List(sections, selection: sidebarSelection) { s in
                Label(s.label, systemImage: s.icon)
            }
            .navigationTitle("Mariner Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            // No collapse control, for the Mac window's reason: the list IS
            // the navigation, and a sheet with it hidden has no way back to
            // another section.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                Text(Self.promise)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar { doneItem }
        } detail: {
            NavigationStack {
                pane(selected)
                    .navigationTitle(sectionLabel(selected))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // A SHEET IS COMPACT EVEN ON A 13-INCH IPAD, and a compact split view
        // collapses to a stack. The sheet was measured above and is wide
        // enough for two columns, so it says so.
        .environment(\.horizontalSizeClass, .regular)
    }

    /// The stack's path: the section on screen, or nothing while the list is.
    private var pushedSection: Binding<[String]> {
        Binding(
            get: { sections.contains { $0.id == model.settingsTab } ? [model.settingsTab] : [] },
            set: { model.settingsTab = $0.last ?? "" }
        )
    }

    /// The sidebar's selection. `selected` already falls back when a section
    /// goes away with the plugin that filled it, and the pane follows the same
    /// value, so the two can never disagree.
    private var sidebarSelection: Binding<String?> {
        Binding(get: { selected }, set: { model.settingsTab = $0 ?? selected })
    }

    /// A section's own name, for the title of its pane. Until now a pushed
    /// pane carried nothing but a floating back chevron.
    private func sectionLabel(_ id: String) -> String {
        SettingsSection.all.first { $0.id == id }?.label ?? "Settings"
    }

    /// The sheet's Done. It came from the presenting view's NavigationStack
    /// while that view owned the container; the form owns it now.
    @ToolbarContentBuilder private var doneItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { model.showSettings = false }
        }
    }
    #endif

    /// One section's form: the app's own settings for it, then whatever a
    /// plugin contributed to the same section.
    @ViewBuilder private func pane(_ id: String) -> some View {
        Form {
            switch id {
            case "display": DisplaySections(m: m)
            case "depths": DepthsSections(m: m)
            case "text": SymbolsSections(m: m)
            case "charts": ChartsSections(model: model)
            case "plugins": PluginsManageSections(p: p, model: model)
            case "advanced": AdvancedSections(m: m)
            default: EmptyView()
            }
            PluginSections(p: p, tab: id)
            PluginListSections(p: p, tab: id)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Charts

/// Chart selection: the sets aboard, and the picker. iOS imports via
/// the form's OWN file importers (SettingsView attaches them, so they present
/// over the sheet); macOS uses the shared NSOpenPanel.
private struct ChartsSections: View {
    @ObservedObject var model: AppModel
    /// Held here so the Cancel button reads "Stopping…" while tile57 finishes
    /// the charts already in flight.
    @State private var cancellingBake = false
    @State private var newChartLink = ""

    var body: some View {
        // Which chart is DRAWN. Lookout's own chart — built from the sets
        // below — is the default entry; a link added here is an alternative
        // chart, rendered instead of it. One is picked at a time: two whole
        // charts cannot share the water.
        Section {
            chartPickRow(name: "Lookout chart", detail: "Built from your chart sets below",
                         picked: model.activeChartLink == nil) { model.selectChartLink(nil) }
            ForEach(model.chartLinks) { link in
                HStack(spacing: 8) {
                    chartPickRow(name: link.name, detail: link.url,
                                 picked: model.activeChartLink == link.url) { model.selectChartLink(link.url) }
                    Spacer(minLength: 4)
                    // Every chart can be re-read: a link goes back to the
                    // publisher, and a style file the mariner has aboard goes
                    // back to the path it came from. What a refresh brings is
                    // the publisher's edits — moved tiles, a wider zoom band, a
                    // changed credit.
                    Button { model.refreshChartLink(link.url) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.chartLinkBusy)
                    .help("Read this chart again — its tile urls, zooms and credit")
                    .accessibilityLabel("Refresh \(link.name)")
                    Button { model.removeChartLink(link.url) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(link.name)")
                }
            }
            HStack(spacing: 8) {
                TextField("https://…/style.json", text: $newChartLink)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { submitChartLink() }
                if model.chartLinkBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add") { submitChartLink() }
                        .disabled(newChartLink.trimmingCharacters(in: .whitespaces).isEmpty)
                    // A style can also be a file the mariner already has —
                    // saved from a publisher, or written themselves. Same
                    // chart either way, so it goes in the same list rather
                    // than a section of its own.
                    Button { model.addChartStyleFile() } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Add a style file from this device")
                    .accessibilityLabel("Add a chart style file")
                }
            }
            if let e = model.chartLinkError {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Chart") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("An online map can be the chart: paste its MapLibre style link, or a TileJSON tile link. A style you already have on this device can be added with the folder button. A style draws exactly what its publisher styled; bare tiles get a plain generated look. Either way the content comes from whoever made it — depths, symbols and warnings included.")
                // Said only while one is picked, because that is when the rest
                // of this window stops working and the mariner is owed a
                // reason. Every other pane — colours, depths, symbols, text —
                // shapes Lookout's own chart; a linked chart is drawn the way
                // its publisher styled it and nothing here reaches inside it.
                if model.activeChartLink != nil {
                    Text("While a linked chart is picked, the display, depth and symbol settings do not shape it — you are seeing its publisher's own portrayal.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // The sets aboard. A set is a folder the mariner added; switching one
        // off keeps it aboard and takes it out of the chart. Every set here
        // has been looked through and holds charts, so none of them is a dead
        // entry the mariner has to discover by clicking it.
        Section {
            if model.chartSets.isEmpty {
                Text(model.scanning ? "Finding charts…" : "No charts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.chartSets) { set in
                    ChartSetRow(model: model, set: set)
                }
            }
            if let msg = model.emptyPick {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Charts") }
        .confirmationDialog(
            "Remove \(model.pendingRemoval?.name ?? "")?",
            isPresented: Binding(get: { model.pendingRemoval != nil },
                                 set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove and delete prepared charts", role: .destructive) {
                if let s = model.pendingRemoval { model.removeChartSet(s.path) }
                model.pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            if let s = model.pendingRemoval {
                Text("Lookout deletes the \(s.cells.count + s.rasters.count) charts it prepared from this folder. Your original files are not touched, and you can add the folder again, which takes \(model.rebuildEstimate(s)).")
            }
        }

        // The work, where it was started. This window stands over the chart,
        // so a bake begun here otherwise runs behind it: the mariner presses
        // Add Charts, nothing in front of them changes, and they press it
        // again.
        if let b = model.chartWork {
            Section {
                BakeDetail(progress: b, onCancel: { model.cancelBake() }, cancelling: $cancellingBake)
                    .padding(.vertical, 4)
            } header: {
                Text(b.title)
            }
        }

        Section {
            Button {
                model.addChartsFromSettings()
            } label: {
                Label("Add Charts…", systemImage: "plus")
            }
            .disabled(model.chartWork != nil)
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text("A folder joins the chart as one library. Both kinds of chart go in here.").captionFooter()
                Text("S-57 and S-101 cells (.000 with their updates) · charts Lookout has already prepared (.pmtiles) · imagery and vendor charts (.mbtiles) · BSB/KAP raster sheets (.kap, .bsb). Cells and raster sheets are converted once on the way in. Encrypted S-63 cells are not supported.").captionFooter()
            }
        }

        // NO SEPARATE RASTER SECTION. A picture and a survey are different
        // kinds of chart, and the row says which, but they are not different
        // kinds of THING TO ADD: they arrive in the same folders and are
        // switched on the same way. Two lists made the mariner remember which
        // panel a file had gone into, and a folder holding both could only be
        // half added.
        //
        // Where they still differ is what a switch MEANS. Surveys compose, so
        // a set is on or off. Only one picture can cover a piece of water, so
        // the pictures inside a set get a switch each, by whoever made them.
    }

    private func submitChartLink() {
        let raw = newChartLink
        newChartLink = ""
        model.addChartLink(raw)
    }

    @ViewBuilder
    private func chartPickRow(name: String, detail: String, picked: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).fontWeight(.medium).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One set: a switch, what it holds, and how deep its detail goes.
///
/// The band ladder is the part a mariner reads first. A set that stops at
/// Coastal will not draw the harbor a passage ends in, and the count per band
/// says so without opening anything.
private struct ChartSetRow: View {
    @ObservedObject var model: AppModel
    let set: ChartSet

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { set.on },
                    set: { model.setChartSetOn(set.path, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Draw \(set.title)")

                VStack(alignment: .leading, spacing: 1) {
                    Text(set.title)
                        .fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(set.on ? .primary : .secondary)
                    // Where it came from, under what it is. Two sets from one
                    // office share a title, so the folder still has to show.
                    Text(set.title == set.name ? set.summary : "\(set.name) · \(set.summary)")
                        .font(.caption)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    // A set Lookout prepared is work that has to be done
                    // again. Ask. A folder of the mariner's own files is only
                    // a list entry, so it goes without a question.
                    if set.isDerived { model.pendingRemoval = set }
                    else { model.removeChartSet(set.path) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(set.isDerived
                      ? "Remove. The charts this app prepared are deleted; your own cells are untouched."
                      : "Take these charts out of the list. Your files stay where they are.")
                .accessibilityLabel("Remove \(set.title)")
                .accessibilityHint(set.isDerived
                                   ? "The prepared charts are deleted. Your own cells are untouched."
                                   : "Your files stay where they are.")
            }

            HStack(spacing: 4) {
                ForEach(set.bandCounts, id: \.band) { b in
                    Text("\(b.name) \(b.count)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 30)
            .opacity(set.on ? 1 : 0.5)

            if set.refusedCount > 0 {
                // Already prepared once; whatever is still unread is unreadable.
                Label("\(set.refusedCount) file\(set.refusedCount == 1 ? "" : "s") Lookout could not read",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 30)
            } else if set.needsBake > 0 {
                Label("\(set.needsBake) to prepare", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
            // The pictures in this set, by provider. One switch each: a
            // provider is what covers a piece of water, and a folder of two
            // hundred tiles from one survey is one decision, not two hundred.
            ForEach(set.rasterGroups(label: AppModel.providerLabel), id: \.name) { group in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { model.rasterGroupOn(group.paths) },
                        set: { model.setRasterGroupEnabled(group.paths, $0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                    Text(group.name).font(.caption)
                        .foregroundStyle(model.rasterGroupOn(group.paths) ? .primary : .secondary)
                    Spacer()
                    Text(group.paths.count == 1 ? "1 file" : "\(group.paths.count) files")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Display

private struct DisplaySections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section {
            SchemeSwatches(scheme: $m.scheme)
        } header: {
            SectionHead("Colour scheme", hint: "⌘L steps")
        } footer: {
            Text("The palettes switch instantly. Night keeps your eyes dark-adapted.").captionFooter()
        }

        Section {
            ForEach(MarinerDisplayCategory.allCases) { c in
                ChoiceRow(title: c.label, desc: c.desc, selected: m.displayCategory == c) {
                    m.displayCategory = c
                }
            }
        } header: {
            SectionHead("Display category", hint: "⌘D adds Other")
        } footer: {
            Text("Each category contains the one before it.").captionFooter()
        }

        Section {
            ForEach(MarinerSoundings.allCases) { s in
                ChoiceRow(title: s.label, desc: s.desc, selected: m.soundings == s) {
                    m.soundings = s
                }
            }
        } header: {
            SectionHead("Soundings", hint: "⌘⇧S steps")
        }
    }
}

// MARK: - Depths

private struct DepthsSections: View {
    @ObservedObject var m: MarinerSettings
    private var feet: Bool { m.depthUnit == .feet }
    private var unit: String { feet ? "ft" : "m" }

    /// The ENGINE always takes metres (S-57 depths are metres; the unit only
    /// changes sounding and contour labels). Feet mode edits through this
    /// converted binding, in WHOLE feet — a depth read to fractions of a foot
    /// is noise, and the previous form sent "ft" values as metres.
    private func depth(_ b: Binding<Double>) -> Binding<Double> {
        guard feet else { return b }
        return Binding(
            get: { (b.wrappedValue * 3.28084).rounded() },
            set: { b.wrappedValue = $0.rounded() / 3.28084 }
        )
    }

    var body: some View {
        Section {
            SegmentedRow("Depth unit", selection: $m.depthUnit) {
                ForEach(MarinerDepthUnit.allCases) { Text($0.label).tag($0) }
            }
            SegmentedRow("Water shading", selection: $m.fourShadeWater) {
                Text("Two shades").tag(false)
                Text("Four shades").tag(true)
            }
        } footer: {
            Text(m.fourShadeWater
                 ? "Four shades: white (safe) water starts at the DEEP contour; the safety contour separates the two middle blues."
                 : "Two shades: water deeper than the safety contour is white (safe), everything shallower is blue.")
                .captionFooter()
        }

        Section {
            BandPreview(m: m)
                .listRowInsets(EdgeInsets())
        } footer: {
            Text("Shading follows the depth areas in the chart: the effective safety contour is the next DEEPER contour available in the data, drawn bold.").captionFooter()
        }

        Section {
            if m.fourShadeWater {
                DepthRow("Shallow contour", depth($m.shallowContour), unit, whole: feet)
            }
            DepthRow("Safety contour", depth($m.safetyContour), unit, whole: feet)
            if m.fourShadeWater {
                DepthRow("Deep contour", depth($m.deepContour), unit, whole: feet)
            }
            DepthRow("Safety depth", depth($m.safetyDepth), unit, whole: feet)
        } header: {
            Text("Contours (\(unit))")
        } footer: {
            Text("Safety depth bolds soundings at or shallower than it; it does not shade water.").captionFooter()
        }
    }
}

/// Schematic of the S-52 depth bands for the CURRENT settings: which shades
/// exist, and which contour separates each pair. Colours approximate the day
/// palette — this is a legend, not the palette itself.
private struct BandPreview: View {
    @ObservedObject var m: MarinerSettings
    private var feet: Bool { m.depthUnit == .feet }

    private func label(_ metres: Double) -> String {
        feet ? "\(Int((metres * 3.28084).rounded())) ft" : String(format: "%g m", metres)
    }

    var body: some View {
        let bands: [(Color, String)] = m.fourShadeWater
            ? [
                (Color(red: 0.55, green: 0.80, blue: 0.60), "drying"),
                (Color(red: 0.45, green: 0.75, blue: 0.93), "0–\(label(min(m.shallowContour, m.safetyContour)))"),
                (Color(red: 0.55, green: 0.82, blue: 0.97), "–\(label(m.safetyContour))"),
                (Color(red: 0.75, green: 0.90, blue: 0.99), "–\(label(max(m.deepContour, m.safetyContour)))"),
                (Color.white, "deeper"),
            ]
            : [
                (Color(red: 0.55, green: 0.80, blue: 0.60), "drying"),
                (Color(red: 0.45, green: 0.75, blue: 0.93), "0–\(label(m.safetyContour))"),
                (Color.white, "deeper"),
            ]
        HStack(spacing: 0) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                band.0
                    .overlay(alignment: .bottom) {
                        Text(band.1)
                            .font(.system(size: 9))
                            .foregroundStyle(.black.opacity(0.75))
                            .padding(.bottom, 2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
            }
        }
        .frame(height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .padding(10)
    }
}

// MARK: - Text & Symbols

private struct SymbolsSections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section("Text") {
            Toggle("Feature names", isOn: $m.textNames)
            Toggle("Light descriptions", isOn: $m.showLightDescriptions)
            Toggle("Other text", isOn: $m.textOther)
        }
        Section("Symbols") {
            Toggle("Simplified point symbols", isOn: $m.simplifiedPoints)
            SegmentedRow("Boundaries", selection: $m.boundaryStyle) {
                ForEach(MarinerBoundaryStyle.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Full light-sector lines", isOn: $m.showFullSectorLines)
        }
    }
}

// MARK: - Advanced

private struct AdvancedSections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section("Safety & Quality") {
            Toggle("Data quality overlay", isOn: $m.dataQuality)
            Toggle("Isolated dangers in shallow water", isOn: $m.showIsolatedDangersShallow)
            Toggle("Information callouts", isOn: $m.showInformCallouts)
            Toggle("Meta boundaries", isOn: $m.showMetaBounds)
            Toggle("Overscale indication", isOn: $m.showOverscale)
        }
        Section("Sizing") {
            SizeRow("Overall size", $m.sizeScale)
            SizeRow("Text size", $m.textSizeScale)
            SizeRow("Sounding size", $m.soundingSizeScale)
        }
        Section {
            Toggle("Date-dependent features", isOn: $m.dateDependent)
            Toggle("Highlight date-dependent", isOn: $m.highlightDateDependent)
            LabeledContent("View date") {
                TextField("YYYYMMDD", text: $m.dateView)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Dates")
        } footer: { Text("Leave the date empty to use today.").captionFooter() }
        AboutSection()
    }
}

private struct AboutSection: View {
    private var engine: LicenseComponent? {
        LicenseManifest.current?.components.first { $0.id == "tile57" }
    }

    private var componentCount: Int { LicenseManifest.current?.components.count ?? 0 }

    var body: some View {
        Section {
            LabeledContent("Version", value: LicensesView.appVersion)
                .monospacedDigit()
            if let engine, !engine.pinLabel.isEmpty {
                LabeledContent("Chart engine") {
                    Text("\(engine.name) · \(engine.pinLabel)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            #if os(macOS)
            // The ellipsis is the platform's promise that a window opens.
            Button {
                LicensesWindowController.shared.show()
            } label: {
                LabeledContent("Licenses…", value: componentCount > 0 ? "\(componentCount) components" : "")
            }
            .buttonStyle(.plain)
            #else
            // The phone pushes the screen, so no ellipsis.
            NavigationLink {
                LicensesRoot()
            } label: {
                LabeledContent("Licenses",
                               value: componentCount > 0 ? "\(componentCount) components" : "")
            }
            #endif
        } header: {
            Text("About")
        }
    }
}

// MARK: - Rows

private struct DepthRow: View {
    let title: String
    @Binding var value: Double
    let unit: String
    let whole: Bool
    init(_ title: String, _ value: Binding<Double>, _ unit: String, whole: Bool) {
        self.title = title; self._value = value; self.unit = unit; self.whole = whole
    }
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value,
                          format: .number.precision(.fractionLength(whole ? 0...0 : 0...1)))
                    .labelsHidden()
                    .frame(width: 62)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    // Borderless, a contour depth reads as a printed value
                    // rather than something to change. The row editors wear
                    // the border already; these match them.
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(whole ? .numberPad : .decimalPad)
                    .keyboardDone()
                    #endif
                Stepper("", value: $value, in: 0...660, step: 1).labelsHidden()
                Text(unit).foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(minWidth: 20, alignment: .leading)
            }
        }
    }
}

private struct SizeRow: View {
    let title: String
    @Binding var value: Double
    init(_ title: String, _ value: Binding<Double>) { self.title = title; self._value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f×", value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: 0.5...2.0)
        }
    }
}

private extension Text {
    func captionFooter() -> some View { self.font(.caption).foregroundStyle(.secondary) }
}
