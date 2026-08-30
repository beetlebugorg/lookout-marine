//  AppModel+ChartLinks.swift — an online map AS the chart.
//
//  THE CORE OWNS ALL OF THIS. It probes the link, inlines TileJSON sources,
//  generates a wrapper style for bare tiles, fetches the sprite packs, builds
//  the credit line, templates the tile urls and persists the list. This renders
//  the snapshot and asks for changes.

import Foundation

@MainActor
extension AppModel {
    // MARK: - Chart links (an online map AS the chart)

    /// One chart the mariner added by link, as the core reports it. Picking it
    /// renders that publisher's style INSTEAD of the built-in chart — Lookout's
    /// own chart is just the default entry in the same list.
    ///
    /// THE CORE OWNS ALL OF THIS. It probes the link, inlines TileJSON
    /// sources, generates a wrapper style for bare tiles, fetches the sprite
    /// packs, builds the credit line, templates the tile urls and persists the
    /// list. This shell renders the snapshot and fetches urls
    /// (ChartLinkFetch.swift).
    struct ChartLink: Decodable, Identifiable, Hashable {
        var url: String
        var name: String
        var id: String { url }
    }

    /// The snapshot, as one document. One document because a resolve finishing
    /// on a fetch thread could free a borrowed field under this shell.
    private struct ChartLinksSnapshot: Decodable {
        var links: [ChartLink]
        var active: String?
        var attribution: String
        var error: String
        var busy: Bool
    }

    private static let chartLinksKey = "lookout.chartlinks"
    private static let chartLinkActiveKey = "lookout.chartlinks.active"

    /// Hand the old UserDefaults list to the core, once, and then drop it.
    ///
    /// The core ignores the import when it already has a list of its own, so
    /// the window between handing it over and deleting the defaults replays
    /// harmlessly if the app dies in it.
    func migrateChartLinks() {
        guard let data = Store.shared.data(Self.chartLinksKey) else { return }
        var doc: [String: Any] = [:]
        if let old = try? JSONSerialization.jsonObject(with: data) { doc["links"] = old }
        doc["active"] = Store.shared.string(Self.chartLinkActiveKey) ?? NSNull()
        guard let out = try? JSONSerialization.data(withJSONObject: doc),
              let json = String(data: out, encoding: .utf8) else { return }
        lkLog("chart links: handing \(data.count) B of the old store to the core")
        controller?.importChartLinks(json)
        Store.shared.remove(Self.chartLinksKey)
        Store.shared.remove(Self.chartLinkActiveKey)
    }

    /// Take the core's snapshot, if it changed. Called once per readout tick:
    /// the changed flag has one consumer.
    func pollChartLinks() {
        guard let json = controller?.chartLinksSnapshot(),
              let data = json.data(using: .utf8),
              let snap = try? JSONDecoder().decode(ChartLinksSnapshot.self, from: data) else { return }
        if chartLinks != snap.links { chartLinks = snap.links }
        if activeChartLink != snap.active { activeChartLink = snap.active }
        if chartLinkBusy != snap.busy { chartLinkBusy = snap.busy }
        let err = snap.error.isEmpty ? nil : snap.error
        if chartLinkError != err { chartLinkError = err }
        let credit = snap.attribution.isEmpty ? nil : snap.attribution
        if chartLinkAttribution != credit { chartLinkAttribution = credit }
    }

    /// Add a chart by its style link. The core reads it once and refuses a dead
    /// or non-style link, which surfaces as `chartLinkError`. The new chart is
    /// picked immediately: adding it is the request to sail on it.
    func addChartLink(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chartLinkError = nil
        chartLinkBusy = true
        controller?.addChartLink(trimmed)
    }

    /// Add a chart style the mariner has on disk. macOS opens a panel; iOS
    /// raises the form's own importer.
    func addChartStyleFile() {
        #if os(iOS)
        showSettingsStyleImporter = true
        #else
        presentChartStylePanel()
        #endif
    }

    /// A style file the mariner picked. The same call as a link: the core tells
    /// a path from a url, and a path is the one thing it may read off disk.
    func importChartStyle(_ url: URL) {
        addChartLink(url.isFileURL ? url.path : url.absoluteString)
    }

    /// Read a linked chart again — its tile urls, zooms, sprites and credit. A
    /// link that does not answer leaves the chart as it was: a lost connection
    /// must not cost the mariner the chart they are sailing on.
    func refreshChartLink(_ url: String) {
        chartLinkError = nil
        chartLinkBusy = true
        controller?.refreshChartLink(url)
    }

    func removeChartLink(_ url: String) {
        controller?.removeChartLink(url)
    }

    func selectChartLink(_ url: String?) {
        // Selecting the link that is already drawn is a no-op: the settings
        // row fires on every click, and re-selecting would re-resolve the style
        // and every sprite pack for nothing. A selection whose last resolve
        // failed does retry.
        if url != nil, url == activeChartLink, chartLinkError == nil { return }
        chartLinkError = nil
        if url != nil { chartLinkBusy = true }
        controller?.selectChartLink(url)
    }
}
