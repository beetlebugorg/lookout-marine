//  ChartController+ChartLinks.swift — an online map AS the chart.
//
//  The core's from end to end: it probes the link, inlines TileJSON sources,
//  fetches the sprite packs and keeps the list. These are the calls, and
//  ChartLinkFetch is the door they fetch through.

import Foundation

@MainActor
extension ChartController {
    // MARK: - Charts by link

    /// Add a chart by link. The core resolves it through this shell's fetcher
    /// and, on success, keeps it and selects it. Non-blocking: what happened
    /// arrives in the snapshot below.
    func addChartLink(_ link: String) {
        guard let h = handle else { return }
        link.withCString { lookout_chart_link_add(h, $0) }
        kick()
    }

    /// Draw one of the carried charts, or nil for Lookout's own.
    func selectChartLink(_ url: String?) {
        guard let h = handle else { return }
        if let url {
            url.withCString { lookout_chart_link_select(h, $0) }
        } else {
            lookout_chart_link_select(h, nil)
        }
        kick()
    }

    func removeChartLink(_ url: String) {
        guard let h = handle else { return }
        url.withCString { lookout_chart_link_remove(h, $0) }
        kick()
    }

    func refreshChartLink(_ url: String) {
        guard let h = handle else { return }
        url.withCString { lookout_chart_link_refresh(h, $0) }
        kick()
    }

    /// Hand the mariner's old UserDefaults list to the core, once. See
    /// AppModel.migrateChartLinks.
    func importChartLinks(_ json: String) {
        guard let h = handle else { return }
        json.withCString { lookout_chart_links_import(h, $0) }
    }

    /// Everything the chart list shows, or nil when nothing changed since the
    /// last poll. The flag has ONE consumer, so this is called from exactly one
    /// place: pushReadouts.
    func chartLinksSnapshot() -> String? {
        guard let h = handle, lookout_chart_links_changed(h) != 0 else { return nil }
        guard let c = lookout_chart_links_json(h) else { return nil }
        defer { lookout_string_free(c) }
        return String(cString: c)
    }

    /// Is a publisher's style the one being drawn?
    var altChartStyleActive: Bool {
        guard let h = handle else { return false }
        return lookout_alt_chart_style_active(h) != 0
    }
}
