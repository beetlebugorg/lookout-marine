//  ChartLinksModel.swift — an online map AS the chart.
//
//  THE CORE OWNS ALL OF THIS. It probes the link, inlines TileJSON sources,
//  generates a wrapper style for bare tiles, fetches the sprite packs, builds
//  the credit line, templates the tile urls and persists the list. This renders
//  the snapshot and asks for changes.

import Foundation

/// The link list and the state beside it, as the core hands it over. One read,
/// because a resolve finishing on a fetch thread could free a borrowed field
/// under this shell.
struct ChartLinkSnapshot {
    var links: [ChartLinksModel.ChartLink]
    /// The picked link's url; nil draws the built-in chart.
    var active: String?
    var attribution: String
    var error: String
    var busy: Bool
}

@MainActor
@Observable
final class ChartLinksModel {
    /// One chart the mariner added by link, as the core reports it. Picking it
    /// renders that publisher's style INSTEAD of the built-in chart — Lookout's
    /// own chart is just the default entry in the same list.
    struct ChartLink: Identifiable, Hashable {
        var url: String
        var name: String
        var id: String { url }

        init(url: String, name: String) {
            self.url = url
            self.name = name
        }

        init(_ l: lookout_chart_link) {
            self.init(url: String(cString: l.url), name: String(cString: l.name))
        }
    }

    var list: [ChartLink] = []
    /// The picked link's url; nil draws the built-in chart.
    var active: String? = nil
    var busy = false
    var error: String? = nil
    /// The active link's source credits, drawn by the scale bar while the link
    /// draws (tile usage policies make the credit a condition of service). Nil
    /// when the Lookout chart is up.
    var attribution: String? = nil

    weak var engine: (any ChartLinkEngine)?

    private static let listKey = "lookout.chartlinks"
    private static let activeKey = "lookout.chartlinks.active"

    /// Hand the old UserDefaults list to the core, once, and then drop it.
    ///
    /// The core ignores the import when it already has a list of its own, so
    /// the window between handing it over and deleting the defaults replays
    /// harmlessly if the app dies in it.
    func migrate() {
        guard let data = Store.shared.data(Self.listKey) else { return }
        var doc: [String: Any] = [:]
        if let old = try? JSONSerialization.jsonObject(with: data) { doc["links"] = old }
        doc["active"] = Store.shared.string(Self.activeKey) ?? NSNull()
        guard let out = try? JSONSerialization.data(withJSONObject: doc),
              let json = String(data: out, encoding: .utf8) else { return }
        lkLog("chart links: handing \(data.count) B of the old store to the core")
        engine?.importChartLinks(json)
        Store.shared.remove(Self.listKey)
        Store.shared.remove(Self.activeKey)
    }

    /// Take the core's snapshot, if it changed. Called once per readout tick:
    /// the changed flag has one consumer.
    func poll() {
        guard let snap = engine?.chartLinksSnapshot() else { return }
        if list != snap.links { list = snap.links }
        if active != snap.active { active = snap.active }
        if busy != snap.busy { busy = snap.busy }
        let err = snap.error.isEmpty ? nil : snap.error
        if error != err { error = err }
        let credit = snap.attribution.isEmpty ? nil : snap.attribution
        if attribution != credit { attribution = credit }
    }

    /// Add a chart by its style link. The core reads it once and refuses a dead
    /// or non-style link, which surfaces as `error`. The new chart is picked
    /// immediately: adding it is the request to sail on it.
    func add(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        error = nil
        busy = true
        engine?.addChartLink(trimmed)
    }

    /// A style file the mariner picked. The same call as a link: the core tells
    /// a path from a url, and a path is the one thing it may read off disk.
    func importStyle(_ url: URL) {
        add(url.isFileURL ? url.path : url.absoluteString)
    }

    /// Read a linked chart again — its tile urls, zooms, sprites and credit. A
    /// link that does not answer leaves the chart as it was: a lost connection
    /// must not cost the mariner the chart they are sailing on.
    func refresh(_ url: String) {
        error = nil
        busy = true
        engine?.refreshChartLink(url)
    }

    func remove(_ url: String) {
        engine?.removeChartLink(url)
    }

    func select(_ url: String?) {
        // Selecting the link that is already drawn is a no-op: the settings
        // row fires on every click, and re-selecting would re-resolve the style
        // and every sprite pack for nothing. A selection whose last resolve
        // failed does retry.
        if url != nil, url == active, error == nil { return }
        error = nil
        if url != nil { busy = true }
        engine?.selectChartLink(url)
    }
}
