//  ChartsSection.swift: the installed charts, in the settings form.
//
//  Which chart draws, the sets it is built from, the work while it runs, and
//  the ways to add more. A picture and a survey are the same kind of thing to
//  add: they arrive in the same folders and switch on the same way.

import SwiftUI


// MARK: - Charts

/// Chart selection: the gallery, the installed sets, and the ways to add more.
/// iOS imports through the form's own file importers, which SettingsView
/// attaches so they present over the sheet. macOS uses the shared NSOpenPanel.
struct ChartsSections: View {
    var model: AppModel
    /// Held here so the Cancel button reads "Stopping…" while tile57 finishes
    /// the charts already in flight.
    @State private var cancellingBake = false
    @State private var showAddChart = false
    @State private var newChartLink = ""

    /// The picker, in a window on the Mac and a sheet on a phone.
    private func openNoaaPicker() {
        #if os(macOS)
        NoaaWindowController.shared.show(model: model)
        #else
        model.chrome.showSettingsNoaaPicker = true
        #endif
    }

    var body: some View {
        // Which chart DRAWS. Lookout's own chart is built from the sets below;
        // a link is a publisher's style drawn instead of it. One draws at a
        // time, because two whole charts cannot share the water.
        Section {
            ChartGallery(model: model) { showAddChart = true }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            if let e = model.chartLinks.error {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Active chart") } footer: {
            // Only while a link draws, because that is when the rest of this
            // window stops shaping the chart and the mariner is owed a reason.
            // That a tile draws when it is picked needs no saying.
            if model.chartLinks.active != nil {
                Text("While a linked chart draws, the display, depth and symbol settings do not shape it. You are seeing its publisher's own portrayal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // The installed sets. A set is a folder the mariner added; switching
        // one off keeps it installed and removes it from the chart.
        Section {
            if model.charts.sets.isEmpty {
                Text(model.charts.scanning ? "Finding charts…" : "No chart sets")
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
        } header: {
            HStack {
                Text("Your chart sets")
                Spacer()
                if let total = setsSummary {
                    Text(total).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
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
                Text("Lookout deletes the \(s.cells.count + s.rasters.count) charts it prepared from this folder. Your original files stay where they are, and you can add the folder again, which takes \(model.charts.rebuildEstimate(s)).")
            }
        }

        // A NOAA download, where it was started. This window stands over the
        // chart, so a transfer begun here otherwise runs behind it.
        if model.noaa.state.phase == .downloading {
            Section {
                NoaaProgressRow(model: model)
            } header: { Text("Downloading from NOAA") }
        }

        // The bake, for the same reason.
        if let b = model.charts.chartWork {
            Section {
                BakeDetail(progress: b, onCancel: { model.charts.cancelBake() }, cancelling: $cancellingBake)
                    .padding(.vertical, 4)
            } header: {
                Text(b.title)
            }
        }

        Section {
            Button { openNoaaPicker() } label: {
                AddChartRow(icon: "cloud",
                            title: "Get charts from NOAA…",
                            detail: "Pick the waters you sail. Lookout downloads the cells and prepares them. Free.",
                            trailing: checkedText)
            }
            .buttonStyle(.plain)
            .disabled(model.charts.chartWork != nil || model.noaa.state.phase == .downloading)
            .accessibilityIdentifier("get-charts-noaa")

            Button { model.addChartsFromSettings() } label: {
                AddChartRow(icon: "folder.badge.plus",
                            title: addFromDeviceTitle,
                            detail: addFromDeviceDetail,
                            trailing: nil)
            }
            .buttonStyle(.plain)
            .disabled(model.charts.chartWork != nil)
            .accessibilityIdentifier("add-charts-files")
        } header: { Text("Add charts") } footer: {
            Text("S-57 and S-101 cells (.000 with their updates) · charts Lookout has already prepared (.pmtiles) · imagery and vendor charts (.mbtiles) · BSB/KAP raster sheets (.kap, .bsb). Cells and raster sheets are converted once on the way in. Encrypted S-63 cells are not supported.")
                .captionFooter()
        }
        .sheet(isPresented: $showAddChart) {
            AddChartSheet(model: model, link: $newChartLink)
        }

        // NO SEPARATE RASTER SECTION. A picture and a survey are different
        // kinds of chart, and the row says which, but they are the same kind
        // of THING TO ADD: they arrive in the same folders and switch on the
        // same way. Two lists made the mariner remember which panel a file had
        // gone into, and a folder holding both could only be half added.
        //
        // Where they differ is what a switch MEANS. Surveys compose, so a set
        // is on or off. Only one picture can cover a piece of water, so the
        // pictures inside a set get a switch each, by whoever made them.
    }

    /// What every installed set holds, together.
    private var setsSummary: String? {
        let sets = model.charts.sets
        guard !sets.isEmpty else { return nil }
        let cells = sets.reduce(0) { $0 + $1.cells.count + $1.rasters.count }
        let bytes = sets.reduce(Int64(0)) { sum, s in
            sum + s.cells.reduce(0) { $0 + $1.bytes } + s.rasters.reduce(0) { $0 + $1.bytes }
        }
        return "\(cells) charts · \(NoaaModel.sizeText(UInt64(max(bytes, 0))))"
    }

    /// When NOAA's catalog was last read.
    private var checkedText: String? {
        guard let at = model.noaa.state.checkedAt else { return nil }
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDateInToday(at) ? .none : .short
        f.timeStyle = .short
        return Calendar.current.isDateInToday(at)
            ? "Checked today \(f.string(from: at))"
            : "Checked \(f.string(from: at))"
    }

    #if os(macOS)
    private var addFromDeviceTitle: String { "Add charts from this Mac…" }
    private var addFromDeviceDetail: String {
        "Or drop a folder anywhere in this window."
    }
    #else
    private var addFromDeviceTitle: String { "Add from Files…" }
    private var addFromDeviceDetail: String {
        "A folder of cells, or a chart already prepared."
    }
    #endif
}


/// One way to add charts: what it does, and what it costs to find out.
private struct AddChartRow: View {
    let icon: String
    let title: String
    let detail: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(Chrome.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Chrome.muted)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}


/// A NOAA download in flight: how far it has got, and the way to stop it.
private struct NoaaProgressRow: View {
    var model: AppModel

    var body: some View {
        let s = model.noaa.state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(s.done) of \(s.total) charts")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Chrome.ink)
                    .monospacedDigit()
                if s.failed > 0 {
                    Text("\(s.failed) failed")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.overscale)
                        .monospacedDigit()
                }
                Spacer()
                Button("Cancel") { model.noaa.cancel() }
            }
            ProgressView(value: Double(s.done), total: Double(max(s.total, 1)))
        }
        .padding(.vertical, 4)
        .task(id: s.phase) {
            // The core reports progress and accepts no callback across the C
            // ABI. The poll ends with the download.
            while model.noaa.state.phase == .downloading {
                try? await Task.sleep(for: .milliseconds(500))
                model.noaa.poll()
            }
        }
    }
}


/// Adding a chart: a link the mariner pasted, or a style file they hold.
private struct AddChartSheet: View {
    var model: AppModel
    @Binding var link: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a chart")
                .font(.system(size: 17, weight: .semibold))
            Text("An online map can be the chart. Paste its MapLibre style link, or a TileJSON tile link. A style draws exactly what its publisher styled; bare tiles get a plain generated look. Either way the content comes from whoever made it, depths, symbols and warnings included.")
                .font(.system(size: 12.5))
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("https://…/style.json", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(submit)
                    .accessibilityIdentifier("add-chart-link")
                if model.chartLinks.busy { ProgressView().controlSize(.small) }
            }
            Button {
                model.addChartStyleFile()
                dismiss()
            } label: {
                Label("Add a style file from this device", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Chrome.accent)
            .font(.system(size: 13))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(minWidth: 420)
    }

    private func submit() {
        let raw = link
        link = ""
        model.chartLinks.add(raw)
        dismiss()
    }
}


/// One set: a switch, what it holds, and how far down the scales it goes.
private struct ChartSetRow: View {
    var model: AppModel
    let set: ChartSet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    // office share a title, so the folder still shows.
                    Text(set.title == set.name ? set.summary : "\(set.name) · \(set.summary)")
                        .font(.caption)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    // A set Lookout prepared is work to do again. Ask. A folder
                    // of the mariner's own files is a list entry, so it goes
                    // without a question.
                    if set.isDerived { model.charts.pendingRemoval = set }
                    else { model.charts.removeChartSet(set.path) }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(set.isDerived
                      ? "Remove. The charts this app prepared are deleted; your own cells stay where they are."
                      : "Take these charts out of the list. Your files stay where they are.")
                .accessibilityLabel("Remove \(set.title)")
                .accessibilityHint(set.isDerived
                                   ? "The prepared charts are deleted. Your own cells stay where they are."
                                   : "Your files stay where they are.")
            }

            if !set.bandCounts.isEmpty {
                BandRamp(counts: set.bandCounts)
                    .padding(.leading, 30)
                    .opacity(set.on ? 1 : 0.5)
            }

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
            // hundred tiles from one survey is one decision.
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
        .padding(.vertical, 3)
    }
}
