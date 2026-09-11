//  NoaaDownloadPanel.swift: a NOAA download, over the chart.
//
//  Setup closes when the download starts, so the transfer has to report itself
//  somewhere the mariner is looking. This stands where ChartWorkPanel does and
//  hands over to it: the download fills a directory, then the bake reads it.

import SwiftUI

struct NoaaDownloadPanel: View {
    var model: AppModel
    /// True once a chart is drawing: the small form at the top.
    let compact: Bool

    private var state: NoaaState { model.noaa.state }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title)
                    .font(.system(size: compact ? 13 : 15, weight: .medium))
                    .foregroundStyle(Chrome.ink)
                Spacer(minLength: 12)
                Button("Cancel") { model.noaa.cancel() }
                    .controlSize(.small)
            }
            ProgressView(value: Double(state.done + state.failed),
                         total: Double(max(state.total, 1)))
                .frame(width: compact ? 240 : 320)
            if !compact {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                    .monospacedDigit()
            }
        }
        .padding(compact ? 12 : 18)
        .panelSurface(cornerRadius: 10, opaque: !compact)
        .task(id: state.phase) {
            // The core reports progress and accepts no callback across the C
            // ABI. The poll ends with the download.
            while model.noaa.state.phase == .downloading {
                try? await Task.sleep(for: .milliseconds(400))
                model.noaa.poll()
            }
        }
    }

    private var title: String {
        "Downloading \(state.done) of \(state.total) charts from NOAA"
    }

    private var detail: String {
        var s = "\(NoaaModel.sizeText(state.bytesDone)) of \(NoaaModel.sizeText(state.bytesTotal))"
        if state.failed > 0 { s += " · \(state.failed) failed" }
        return s + ". Lookout prepares them when the download finishes."
    }
}
