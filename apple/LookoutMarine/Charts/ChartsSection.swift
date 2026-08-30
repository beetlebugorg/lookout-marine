//  ChartsSection.swift — the charts aboard, in the settings form.
//
//  Which chart is DRAWN (Lookout's own, or a publisher's style by link), the
//  sets aboard with a switch each, the work while it runs, and the way to add
//  more. A picture and a survey are not different kinds of thing to ADD: they
//  arrive in the same folders and are switched on the same way.

import SwiftUI


// MARK: - Charts

/// Chart selection: the sets aboard, and the picker. iOS imports via
/// the form's OWN file importers (SettingsView attaches them, so they present
/// over the sheet); macOS uses the shared NSOpenPanel.
struct ChartsSections: View {
    var model: AppModel
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
                         picked: model.chartLinks.active == nil) { model.chartLinks.select(nil) }
            ForEach(model.chartLinks.list) { link in
                HStack(spacing: 8) {
                    chartPickRow(name: link.name, detail: link.url,
                                 picked: model.chartLinks.active == link.url) { model.chartLinks.select(link.url) }
                    Spacer(minLength: 4)
                    // Every chart can be re-read: a link goes back to the
                    // publisher, and a style file the mariner has aboard goes
                    // back to the path it came from. What a refresh brings is
                    // the publisher's edits — moved tiles, a wider zoom band, a
                    // changed credit.
                    Button { model.chartLinks.refresh(link.url) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.chartLinks.busy)
                    .help("Read this chart again — its tile urls, zooms and credit")
                    .accessibilityLabel("Refresh \(link.name)")
                    Button { model.chartLinks.remove(link.url) } label: {
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
                if model.chartLinks.busy {
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
            if let e = model.chartLinks.error {
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
                if model.chartLinks.active != nil {
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
            if model.charts.sets.isEmpty {
                Text(model.charts.scanning ? "Finding charts…" : "No charts")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.charts.sets) { set in
                    ChartSetRow(model: model, set: set)
                }
            }
            if let msg = model.charts.emptyPick {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Charts") }
        .confirmationDialog(
            "Remove \(model.charts.pendingRemoval?.name ?? "")?",
            isPresented: Binding(get: { model.charts.pendingRemoval != nil },
                                 set: { if !$0 { model.charts.pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove and delete prepared charts", role: .destructive) {
                if let s = model.charts.pendingRemoval { model.charts.removeChartSet(s.path) }
                model.charts.pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { model.charts.pendingRemoval = nil }
        } message: {
            if let s = model.charts.pendingRemoval {
                Text("Lookout deletes the \(s.cells.count + s.rasters.count) charts it prepared from this folder. Your original files are not touched, and you can add the folder again, which takes \(model.charts.rebuildEstimate(s)).")
            }
        }

        // The work, where it was started. This window stands over the chart,
        // so a bake begun here otherwise runs behind it: the mariner presses
        // Add Charts, nothing in front of them changes, and they press it
        // again.
        if let b = model.charts.chartWork {
            Section {
                BakeDetail(progress: b, onCancel: { model.charts.cancelBake() }, cancelling: $cancellingBake)
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
            .disabled(model.charts.chartWork != nil)
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
        model.chartLinks.add(raw)
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
    var model: AppModel
    let set: ChartSet

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { set.on },
                    set: { model.charts.setChartSetOn(set.path, $0) }
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
                    if set.isDerived { model.charts.pendingRemoval = set }
                    else { model.charts.removeChartSet(set.path) }
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
            ForEach(set.rasterGroups(label: RasterModel.providerLabel), id: \.name) { group in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { model.raster.groupOn(group.paths) },
                        set: { model.raster.setGroupEnabled(group.paths, $0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                    Text(group.name).font(.caption)
                        .foregroundStyle(model.raster.groupOn(group.paths) ? .primary : .secondary)
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
