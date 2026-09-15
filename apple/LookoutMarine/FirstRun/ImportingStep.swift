//  ImportingStep.swift: the wait, while charts arrive and convert.
//
//  A cell holds survey data rather than a drawn chart, so each one converts on
//  the way in. Setup stays open through it: the chart opens when the import
//  finishes, so closing the sheet at Download left the mariner waiting on a
//
//  chart that had yet to open.
//
//  Two columns. On the left the phases, in the terms the core reports them: a
//  NOAA run downloads before it finds and imports, a dropped folder starts at
//  finding. On the right the usage bands. lookout_bake_order runs the bake
//  coarse band first, so the bake's done count says how far down that list it
//  has reached. BakeProgress.bandProgress reads it.

import SwiftUI

struct ImportingStep: View {
    var model: AppModel
    @Bindable var flow: FirstRunModel

    /// The last report the bake made.
    ///
    /// chartWork goes nil the moment the bake ends, and the panel outlives it.
    /// Reading it live emptied the counts and the band list on the frame the
    /// import finished.
    @State private var lastWork: BakeProgress?

    /// The bake as it is running, or nil once it has stopped.
    private var live: BakeProgress? { model.charts.chartWork }
    /// The numbers to draw: the running bake, else its last report.
    private var work: BakeProgress? { live ?? lastWork }
    private var running: Bool { live != nil }
    private var noaa: NoaaState { model.noaa.state }
    private var downloading: Bool { noaa.phase == .downloading }
    /// The NOAA order this run began with, or nil for a dropped folder.
    private var order: FirstRunModel.NoaaOrder? { flow.noaaOrder }
    private var fromNoaa: Bool { order != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Preparing your charts",
                blurb: "A cell holds survey data, not a drawn chart, so Lookout converts each one on the way in. This happens once per set.",
                centered: centered)
                .padding(.top, topInset)

            columns.padding(.top, 24)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 22)
        .task {
            // The core reports progress and accepts no callback across the C
            // ABI. The poll ends when the download does; the bake has a poll
            // of its own inside ChartBakeJob.
            // Only while the transfer runs. Polling for the life of the step
            // re-rendered it several times a second after everything had
            // finished. The row's finished count comes from the order.
            while model.noaa.state.phase == .downloading {
                try? await Task.sleep(for: .milliseconds(400))
                model.noaa.poll()
            }
            model.noaa.poll()
        }
        .onChange(of: model.charts.chartWork) { _, now in
            guard let now else { return }
            flow.sawBake = true
            // Keep the bake's own reports. ChartsModel rescans the set once
            // the bake finishes, and that scan reports through chartWork with
            // no total and no bands, which emptied the panel at the end.
            guard now.total > 0, !now.bands.isEmpty else { return }
            lastWork = now
        }
    }

    @ViewBuilder private var columns: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 26) {
            leftColumn.frame(width: 330)
            bandPanel
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            leftColumn
            bandPanel
        }
        #endif
    }

    // MARK: The phases

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(setName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .lineLimit(1).truncationMode(.middle)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Chrome.muted)
                .monospacedDigit()
                .padding(.top, 3)

            bar.padding(.top, 16)

            HStack {
                Text(percentText)
                Spacer()
                Text(running ? (work?.remaining ?? "") : "")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Chrome.muted)
            .monospacedDigit()
            .frame(height: 13)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(phases, id: \.title) { PhaseRow(phase: $0) }
            }
            .padding(.top, 18)

            if let refused = refusedText {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.amber)
                    Text(refused)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Chrome.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Chrome.amber.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 16)
            }

            Spacer(minLength: 16)

            Text("Lookout stores the prepared charts in its own folder and never writes to your download.")
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
    }

    /// Determinate once something has counted the charts. A dropped folder has
    /// no count until the scan finishes, so the bar runs until then.
    ///
    /// Both states are a bar across the panel. Left to itself an indeterminate
    /// ProgressView draws a small circular spinner on iOS, which sat at the
    /// left of the row where the bar goes and read as a mistake.
    @ViewBuilder private var bar: some View {
        Group {
            if let total = barTotal, total > 0 {
                ProgressView(value: Double(barDone), total: Double(total))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
    }

    private var barDone: Int {
        if downloading { return Int(noaa.done) }
        guard let w = work else { return 0 }
        return running ? w.done : w.total
    }
    private var barTotal: Int? {
        if downloading { return Int(noaa.total) }
        guard let w = work, w.total > 0 else { return nil }
        return w.total
    }

    private var percentText: String {
        guard let total = barTotal, total > 0 else { return "" }
        return "\(Int((Double(barDone) / Double(total) * 100).rounded()))%"
    }

    private var setName: String {
        if let o = order, !o.regions.isEmpty { return o.regions }
        if let w = work, !w.name.isEmpty { return w.name }
        return "Your charts"
    }

    /// NOAA states where the charts came from and what they cost. A folder the
    /// mariner dropped has neither, so it states what is known.
    private var subtitle: String {
        if let o = order {
            return "NOAA · \(o.charts) charts · \(NoaaModel.sizeText(o.bytes))"
        }
        if let w = work, w.total > 0 { return "\(w.total) charts" }
        return "Reading the folder"
    }

    /// Named only once the bake has finished, because the core counts what
    /// landed at the end (src/bakejob.zig).
    private var refusedText: String? {
        let n = model.charts.lastBakeRefused
        guard n > 0 else { return nil }
        return "\(n) chart\(n == 1 ? "" : "s") refused. The rest are unaffected."
    }

    private var phases: [Phase] {
        var out: [Phase] = []
        if let o = order {
            // The transfer's own count while it runs, and the order once it
            // has stopped reporting.
            let n = downloading ? noaa.done : o.charts
            out.append(Phase(title: "Downloading charts",
                             detail: "\(n) of \(o.charts)",
                             state: downloading ? .active : .done))
        }
        // With no bake reported yet, the two import phases have either not
        // started or already finished. flow.sawBake tells them apart.
        let finding = running && (live?.kind == .finding || live?.total == 0)
        let importing = running && !finding
        let pending = work == nil && !flow.sawBake
        out.append(Phase(title: "Finding charts",
                         detail: findingDetail,
                         state: downloading || pending ? .waiting : (finding ? .active : .done)))
        out.append(Phase(title: "Importing charts",
                         detail: importCount,
                         state: importing ? .active
                             : (downloading || pending || finding ? .waiting : .done)))
        return out
    }

    private var findingDetail: String {
        guard let w = work, w.total > 0 else { return "" }
        return "\(w.total) found"
    }

    /// The running count, and the finished total once the bake has stopped.
    private var importCount: String {
        guard let w = work, w.total > 0 else { return "" }
        return running ? "\(w.done) of \(w.total)" : "\(w.total) of \(w.total)"
    }

    // MARK: The bands

    private var bandPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("By band")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                Text("Wide-area charts are prepared first, so stopping partway still leaves charts that cover the whole passage.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Chrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 11)
            Divider()
            if bands.isEmpty {
                Text("Counted once the folder has been read.")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                    .padding(16)
            } else {
                VStack(spacing: 0) {
                    ForEach(bands) { BandRow(band: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Chrome.edge.opacity(0.7), lineWidth: 1))
    }

    /// Every band, with the bake's reach into it. A finished bake has reached
    /// all of them.
    private var bands: [BandTotal] {
        guard let w = work else { return [] }
        if running { return w.bandProgress }
        return w.bands.map { BandTotal(band: $0.band, name: $0.name, total: $0.total, done: $0.total) }
    }

    #if os(macOS)
    private var centered: Bool { true }
    private var topInset: CGFloat { 30 }
    private var horizontalInset: CGFloat { 40 }
    #else
    private var centered: Bool { false }
    private var topInset: CGFloat { 16 }
    private var horizontalInset: CGFloat { 18 }
    #endif
}


/// One phase of the work, and how far it has got.
struct Phase {
    enum State { case done, active, waiting }
    let title: String
    let detail: String
    let state: State
}

private struct PhaseRow: View {
    let phase: Phase

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                switch phase.state {
                case .done:
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Chrome.accent)
                case .active:
                    ProgressView().controlSize(.mini)
                case .waiting:
                    Image(systemName: "circle")
                        .foregroundStyle(Chrome.ink.opacity(0.25))
                }
            }
            .font(.system(size: 12))
            .frame(width: 14)

            Text(phase.title)
                .font(.system(size: 12, weight: phase.state == .active ? .semibold : .regular))
                .foregroundStyle(Chrome.ink)
            Text(phase.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.muted)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .opacity(phase.state == .waiting ? 0.45 : 1)
    }
}


/// One usage band: its ramp color, its name, and how much of it is prepared.
private struct BandRow: View {
    let band: BandTotal

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(BandRamp.color(band.band))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Chrome.edge.opacity(0.5), lineWidth: 1))
                    .frame(width: 11, height: 11)
                Text(band.name)
                    .font(.system(size: 12.5, weight: inProgress ? .semibold : .regular))
                    .foregroundStyle(Chrome.ink)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Chrome.muted)
                    .monospacedDigit()
                if band.isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Chrome.accent)
                        .frame(width: 13)
                } else {
                    Color.clear.frame(width: 13, height: 1)
                }
            }
            if inProgress {
                ProgressView(value: Double(band.done), total: Double(max(band.total, 1)))
                    .padding(.leading, 21)
            }
        }
        .padding(.vertical, 8)
        .opacity(band.isWaiting ? 0.45 : 1)
    }

    private var inProgress: Bool { !band.isComplete && !band.isWaiting }

    private var detail: String {
        if band.isComplete { return "\(band.total) charts" }
        if band.isWaiting { return "\(band.total) waiting" }
        return "\(band.done) of \(band.total)"
    }
}
