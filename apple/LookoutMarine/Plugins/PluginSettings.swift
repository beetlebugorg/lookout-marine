//  PluginSettings.swift — the mariner's controls over the wasm plugins.
//
//  A plugin declares a settings schema in its manifest; the core hands it over
//  as JSON through lookout_plugins_json, and this file turns that into SwiftUI
//  controls. The app knows nothing about what any plugin does — a number field
//  with a unit and a range, or a toggle, is the whole vocabulary.
//
//  The mariner never meets the plugin system. A field names the SECTION of the
//  settings window it belongs in ("alarms", "vessels", …) and the heading it
//  sits under, so an AIS setting reads as a chart setting that happens to come
//  from a plugin. The section names are the core's, so every shell agrees.
//
//  Flow, the same one MarinerSettings uses: bind(to:) loads the schema, edits
//  auto-apply (debounced so a stepper drag does not push per tick) and SAVE.
//  Applying goes through lookout_plugin_config_set, which the plugin handles
//  live: no restart, and the AIS alarm gate re-evaluates at once.
//
//  Persistence is field-by-field under one versioned key, not the JSON the core
//  returned: the schema belongs to the plugin and may change, and a saved value
//  for a field that no longer exists is simply never applied. A LIST persists
//  under its own key, as the JSON array of rows the plugin will be given.
//
//  A list is a setting the mariner adds ROWS to — the NMEA connections are the
//  first. The rows are the shell's: it assigns each one an id when it is added,
//  keeps the id for the row's whole life, and sends the whole array on every
//  edit. The plugin reports each row's state back under the same id, which is
//  how "connected, 44 msg/s" finds its way to the right line on screen.

import Foundation
import Combine
import SwiftUI

/// One control, as the manifest declared it.
struct PluginField: Identifiable {
    enum Kind: String { case number, toggle, text }

    let key: String
    let label: String
    /// What the setting does for the person at the helm. Shown under the
    /// control. Empty when the manifest declares none.
    let desc: String
    let kind: Kind
    let unit: String
    /// The heading this field sits under, and the settings section it lands in.
    let group: String
    let tab: String
    let min: Double
    let max: Double
    let defaultValue: Double
    /// A text field's default, and whether it may be left empty. Both are only
    /// meaningful inside a list row.
    let defaultText: String
    let optional: Bool
    let placeholder: String
    /// The value in force. A toggle is 0 or 1.
    var value: Double

    var id: String { key }
    var isOn: Bool { value != 0 }

    /// The range, as the row shows it: "93–9260 m".
    var rangeText: String {
        let lo = PluginSettings.trimmed(min), hi = PluginSettings.trimmed(max)
        return unit.isEmpty ? "\(lo)–\(hi)" : "\(lo)–\(hi) \(unit)"
    }

    /// A stepper increment that suits the range: metres of CPA move in tens,
    /// minutes and knots one at a time.
    var step: Double {
        let span = max - min
        if span > 100 { return 10 }
        if span > 10 { return 1 }
        return 0.5
    }
}

/// One capability a plugin's manifest asked for, in the consent sheet's own
/// words, with the switch state the mariner holds over it.
struct PluginCapability: Identifiable {
    let cap: String
    /// The consent sentence, worded by the core so every shell says the same
    /// thing: "Read AIS traffic."
    let sentence: String
    /// The addresses a grant reaches. Parsed and shown nowhere, on this shell
    /// or on Android, alongside a capability's `ports` and a settings field's
    /// `placeholder` and `max_len`. Kept so the decision to show them is one
    /// somebody makes rather than one a deletion hides.
    let hosts: [String]
    var granted: Bool

    var id: String { cap }
}

/// One loaded plugin and the controls it asked for.
struct PluginInfo: Identifiable {
    let id: String
    let name: String
    /// The manifest's version string, or empty when it declares none.
    let version: String
    /// "bundled", "installed" or "developer". Only an installed plugin offers
    /// Uninstall; a developer copy says so beside its status.
    let origin: String
    let live: Bool
    /// What the plugin says about itself, parsed once. See PluginStatus.
    var status: PluginStatus
    /// The manifest's capabilities in consent wording, with the grant state.
    var capabilities: [PluginCapability]
    var fields: [PluginField]
    var lists: [PluginListSchema] = []
    /// The rows the core holds, by list key. The window edits its own copy.
    var rows: [String: [PluginRow]] = [:]
    /// The file extensions this plugin reads, ".grib2" and the like. The open
    /// panel names them so the mariner knows it takes more than charts; the
    /// core decides which plugin a chosen file goes to.
    var fileTypes: [String] = []

    /// The line under the plugin's name in the Plugins section: the state in a
    /// word, then the plugin's own detail. A dead plugin says so whatever its
    /// last words were.
    var statusLine: String {
        guard live else { return "Stopped" }
        let word = Self.stateWords[status.state]
            ?? (status.state.isEmpty ? "Running" : status.state)
        return status.detail.isEmpty ? word : "\(word) · \(status.detail)"
    }

    /// Green while it works, amber while degraded, red when it broke, grey
    /// when it stopped. The same palette the connection rows use.
    var statusTint: Color {
        guard live else { return .secondary }
        switch status.state {
        case "running", "": return .green
        case "starting": return .secondary
        case "degraded": return .orange
        case "stopped": return .secondary
        default: return .red
        }
    }

    private static let stateWords = [
        "running": "Running",
        "starting": "Starting",
        "degraded": "Degraded",
        "disabled": "Disabled",
        "stopped": "Stopped",
    ]

    /// What the plugin says about each row of its lists, by row id.
    var statusItems: [String: PluginStatusItem] { status.items }
}

/// A plugin's status document, parsed ONCE.
///
/// `{"state":"running","detail":"…","items":[…]}`. Every row on screen asks for
/// its own line, so parsing this where it is read meant one JSONSerialization
/// per row per recomposition: a boat with six connections reparsed six
/// documents on every frame of the settings window.
struct PluginStatus: Equatable {
    /// The document as the plugin wrote it. The poll compares this to decide
    /// whether anything moved.
    let raw: String
    let state: String
    let detail: String
    let items: [String: PluginStatusItem]

    init(_ raw: String) {
        self.raw = raw
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else {
            // A plugin that writes a plain sentence is running and says so.
            state = ""; detail = ""; items = [:]
            return
        }
        state = o["state"] as? String ?? ""
        detail = o["detail"] as? String ?? ""
        var found: [String: PluginStatusItem] = [:]
        for it in o["items"] as? [[String: Any]] ?? [] {
            guard let id = it["id"] as? String else { continue }
            found[id] = PluginStatusItem(id: id,
                                         state: it["state"] as? String ?? "",
                                         detail: it["detail"] as? String ?? "")
        }
        items = found
    }

    static func == (a: PluginStatus, b: PluginStatus) -> Bool { a.raw == b.raw }
}

/// What one row of a list is doing, in the plugin's own words.
struct PluginStatusItem {
    let id: String
    /// "connected", "paused", "reconnecting", "unreachable", "no_address".
    let state: String
    let detail: String

    /// The line under the row: "connected · 44 msg/s".
    var line: String {
        let name = Self.words[state] ?? state
        return detail.isEmpty ? name : "\(name) · \(detail)"
    }

    /// Green while it is working, grey while it is switched off, amber while
    /// it is trying, red when it has given up.
    var tint: Color {
        switch state {
        case "connected": return .green
        case "paused": return .secondary
        case "reconnecting": return .orange
        default: return .red
        }
    }

    private static let words = [
        "connected": "Connected",
        "paused": "Paused",
        "reconnecting": "Reconnecting",
        "unreachable": "Unreachable",
        "no_address": "No address",
    ]
}

/// One service type a list is browsed for.
struct PluginDiscover {
    let service: String
    /// The values a discovered item takes beyond its address, in their fields'
    /// own kinds. A Signal K server announces its websocket, so an item added
    /// from one arrives with that field on.
    let set: [String: PluginValue]
}

/// A repeating group the mariner adds rows to.
struct PluginListSchema: Identifiable {
    let pluginID: String
    let key: String
    /// The section heading, and the settings section it lands in.
    let group: String
    let tab: String
    /// The columns of one row.
    let itemFields: [PluginField]
    /// The plugin's own wording around its rows. Empty when the manifest
    /// declared none, in which case the window falls back to a generic line:
    /// two lists on one tab must not share one plugin's sentences.
    let footer: String
    let empty: String
    let addLabel: String
    /// Which toggle column is the row's own on/off switch. Empty means the
    /// first toggle column, which is what a list with one toggle wants.
    let switchKey: String
    /// What to browse the boat's network for, and what a row takes from a
    /// find beyond its name, address and port.
    let discover: [PluginDiscover]
    /// How many rows the CORE will keep. Past this the host drops the row and
    /// logs, and the mariner is left with a connection that looks like every
    /// other one and never connects, so the window stops offering Add here
    /// instead. Zero means a core that did not say, which offers Add as before.
    let maxRows: Int

    var id: String { "\(pluginID)/\(key)" }

    /// What this list calls ONE of its rows, taken from the wording it already
    /// declared for Add. The window used to say "connection" for every list;
    /// Connections holds two, and the Signal K list adds a server, so a row of
    /// it that said "Remove Connection" was the window contradicting the
    /// button directly above it. A list that declared no Add label gets the
    /// generic wording below instead of a noun invented for it.
    var itemNoun: String {
        let add = addLabel.trimmingCharacters(in: .whitespaces)
        guard add.count > 4, add.lowercased().hasPrefix("add ") else { return "" }
        return String(add.dropFirst(4))
    }

    /// The title of a row with no address yet.
    var newLabel: String { itemNoun.isEmpty ? "New item" : "New \(itemNoun)" }

    /// The button that takes a row away.
    var removeLabel: String { itemNoun.isEmpty ? "Remove" : "Remove \(itemNoun)" }
}

/// One value in a row. A row is not a settings field: it holds text as well as
/// numbers and toggles, so it cannot ride in the scalar `Double`.
enum PluginValue: Equatable {
    case number(Double)
    case toggle(Bool)
    case text(String)

    init(_ raw: Any?, _ f: PluginField) {
        switch f.kind {
        case .number: self = .number((raw as? NSNumber)?.doubleValue ?? f.defaultValue)
        case .toggle: self = .toggle(raw as? Bool ?? (f.defaultValue != 0))
        case .text: self = .text(raw as? String ?? f.defaultText)
        }
    }

    var number: Double { if case let .number(v) = self { return v }; return 0 }
    var isOn: Bool { if case let .toggle(v) = self { return v }; return false }
    var text: String { if case let .text(v) = self { return v }; return "" }

    var json: String {
        switch self {
        case let .number(v): return PluginSettings.trimmed(v)
        case let .toggle(v): return v ? "true" : "false"
        case let .text(v): return PluginSettings.jsonString(v)
        }
    }
}

/// One row of a list. The id is the shell's and never changes once assigned:
/// the plugin echoes it in its status so each row's line finds its row.
struct PluginRow: Identifiable, Equatable {
    var id: String
    var cells: [String: PluginValue]

    func text(_ key: String) -> String { cells[key]?.text ?? "" }
    func number(_ key: String) -> Double { cells[key]?.number ?? 0 }
    func isOn(_ key: String) -> Bool { cells[key]?.isOn ?? false }
}

/// One heading's worth of controls inside a settings section — the unit the
/// window draws, and the unit "Reset to defaults" acts on. A plugin whose
/// schema spans sections contributes one of these to each.
struct PluginGroup: Identifiable {
    let pluginID: String
    /// The heading. The plugin's name when the schema declares no group.
    let title: String
    let tab: String
    var fields: [PluginField]

    var id: String { "\(pluginID)/\(tab)/\(title)" }
}

@MainActor
final class PluginSettings: ObservableObject {
    @Published var plugins: [PluginInfo] = []

    private weak var controller: ChartController?
    private var applyCancellable: AnyCancellable?
    private var pollCancellable: AnyCancellable?
    /// What is answering on the boat's network right now. It browses only
    /// while the window is open, and this republishes what it finds.
    private let discovery = Discovery()
    private var discoveryCancellable: AnyCancellable?
    /// Fires on an EDIT, never on a status poll: applying must be caused by
    /// the mariner, not by a plugin reporting its rate.
    private let edits = PassthroughSubject<Void, Never>()

    private static let defaultsKey = "plugins.v1"
    /// The rows of every list, as JSON per plugin and list key. Separate from
    /// `plugins.v1` because a row is not a number: one key, one shape.
    private static let listsKey = "plugins.lists.v1"

    /// True while the core is not answering. Kept so the log line is written
    /// once, on the way into trouble and on the way out: the status poll asks
    /// every second, and a line a second is a line nobody reads.
    private var registryUnread = false

    // MARK: - Binding

    /// Load the schemas from the live chart, then auto-apply and save edits.
    func bind(to controller: ChartController?) {
        self.controller = controller
        if let fresh = readRegistry() { plugins = fresh }
        guard applyCancellable == nil else { return }
        applyCancellable = edits
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyAndSave() }
    }

    /// The registry as the core has it, or nil when the core did not answer.
    ///
    /// NIL IS NOT AN EMPTY REGISTRY. `lookout_plugins_read` answers NULL with
    /// no chart open and in a build with the plugin layer compiled out; a core
    /// holding no plugins answers a read with no rows. Reading the two the
    /// same way is what
    /// emptied this whole window — Vessels, Alarms, Connections and every
    /// plugin row — the moment one read came back nil, which looked from the
    /// outside like a trapping plugin taking the settings schema with it.
    private func readRegistry() -> [PluginInfo]? {
        guard let fresh = controller?.withPlugins({ Self.registry($0) }) ?? nil else {
            noteUnreadable()
            return nil
        }
        noteReadable(fresh.count)
        return fresh
    }

    /// Said once on the way into trouble and once on the way out. The status
    /// poll asks every second, and a line a second is a line nobody reads.
    private func noteUnreadable() {
        guard !registryUnread else { return }
        registryUnread = true
        lkLog("plugins: the core did not answer; keeping the last registry, \(plugins.count) plugin(s)")
    }

    private func noteReadable(_ count: Int) {
        guard registryUnread else { return }
        registryUnread = false
        lkLog("plugins: the core is answering again, \(count) plugin(s)")
    }

    /// An edit happened. Debounced so a stepper drag does not push per tick.
    private func edited() { edits.send() }

    // MARK: - Live status

    /// Watch what the plugins report, while the settings window is open. A
    /// connection's line has to move on its own: "reconnecting" that never
    /// becomes "connected" is how a mariner learns the address is wrong.
    ///
    /// Only the STATUS is taken from the poll. The values and rows on screen
    /// are the mariner's, and overwriting those mid-edit would fight the
    /// keyboard.
    func startPolling() {
        guard pollCancellable == nil else { return }
        pollCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshStatus() }
        discoveryCancellable = discovery.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
        browseDeclared()
    }

    /// Browse for what the loaded lists declare, and for nothing else. Only
    /// while the window is watching: `startPolling` and a plugin installed
    /// under an open window are the two moments the set can change.
    private func browseDeclared() {
        discovery.browse(plugins.flatMap { $0.lists }.flatMap { $0.discover }.map(\.service))
    }

    /// True while the window is watching. The Mac's window controller stops the
    /// poll from windowWillClose as well as the view's onDisappear, so this has
    /// to be safe to call twice.
    var isPolling: Bool { pollCancellable != nil }

    func stopPolling() {
        pollCancellable?.cancel()
        pollCancellable = nil
        discoveryCancellable?.cancel()
        discoveryCancellable = nil
        discovery.stop()
    }

    /// The poll wants one string per plugin. Building the whole registry for
    /// that allocated every settings field, list schema and declared row once a
    /// second and threw them all away; this reads the status out of the
    /// document and nothing else.
    private func refreshStatus() {
        guard let fresh = controller?.withPlugins({ Self.statuses($0) }) ?? nil else {
            noteUnreadable()
            return
        }
        noteReadable(fresh.count)
        for (i, p) in plugins.enumerated() {
            guard let raw = fresh[p.id], raw != p.status.raw else { continue }
            plugins[i].status = PluginStatus(raw)
        }
    }

    // MARK: - Install, grants, uninstall

    /// Re-read the registry whole. After an install or an uninstall the plugin
    /// LIST changed, not just a status line. A read that fails leaves the last
    /// good one on screen, which is the only thing a mariner can act on.
    func reload() {
        guard let fresh = readRegistry() else { return }
        plugins = fresh
        if discoveryCancellable != nil { browseDeclared() }
    }

    /// The switch over one grant. Flipping it off revokes live — the plugin
    /// keeps running and the call it lost simply answers -1 — and flipping it
    /// back restores it. The state persists beside the plugin.
    func grant(_ pluginID: String, _ cap: String) -> Binding<Bool> {
        Binding(
            get: {
                self.plugins.first { $0.id == pluginID }?
                    .capabilities.first { $0.cap == cap }?.granted ?? false
            },
            set: { self.setGrant(pluginID, cap, $0) }
        )
    }

    private func setGrant(_ pluginID: String, _ cap: String, _ on: Bool) {
        guard let controller, controller.setPluginGrant(pluginID, cap, on),
              let pi = plugins.firstIndex(where: { $0.id == pluginID }),
              let ci = plugins[pi].capabilities.firstIndex(where: { $0.cap == cap })
        else { return }
        plugins[pi].capabilities[ci].granted = on
    }

    /// Uninstall: the core removes the directory, the plugin's storage and
    /// everything it drew; the window drops the row.
    func uninstall(_ pluginID: String) {
        guard let controller, controller.uninstallPlugin(pluginID) else { return }
        reload()
    }

    // MARK: - What each settings section holds

    /// The groups that land in one section, in load then declaration order. A
    /// section with none of these is not shown at all.
    func groups(tab: String) -> [PluginGroup] {
        var out: [PluginGroup] = []
        for p in plugins {
            for f in p.fields where f.tab == tab {
                let title = f.group.isEmpty ? p.name : f.group
                if let i = out.firstIndex(where: { $0.pluginID == p.id && $0.title == title }) {
                    out[i].fields.append(f)
                } else {
                    out.append(PluginGroup(pluginID: p.id, title: title, tab: tab, fields: [f]))
                }
            }
        }
        return out
    }

    /// The sections that have something in them — a group of controls, or a
    /// list the mariner can add rows to.
    var populatedTabs: Set<String> {
        Set(plugins.flatMap { $0.fields }.map(\.tab))
            .union(plugins.flatMap { $0.lists }.map(\.tab))
    }

    /// The lists that land in one section, in load order.
    func lists(tab: String) -> [PluginListSchema] {
        plugins.flatMap { $0.lists }.filter { $0.tab == tab }
    }

    // MARK: - Rows of a list

    func rows(_ list: PluginListSchema) -> [PluginRow] {
        plugins.first { $0.id == list.pluginID }?.rows[list.key] ?? []
    }

    /// The plugin's line for one row: what that connection is doing now.
    func status(_ list: PluginListSchema, _ rowID: String) -> PluginStatusItem? {
        plugins.first { $0.id == list.pluginID }?.statusItems[rowID]
    }

    /// True when the list holds every row the core will keep. The window
    /// stops offering Add here: a row past the cap is dropped by the host and
    /// the mariner is never told which of their connections is the dead one.
    func isFull(_ list: PluginListSchema) -> Bool {
        list.maxRows > 0 && rows(list).count >= list.maxRows
    }

    /// Add a row on the schema's defaults. The id is minted here and never
    /// changes again: it is what the plugin's status items point at.
    func addRow(_ list: PluginListSchema) {
        if isFull(list) { return }
        guard let pi = plugins.firstIndex(where: { $0.id == list.pluginID }) else { return }
        var cells: [String: PluginValue] = [:]
        for f in list.itemFields { cells[f.key] = PluginValue(nil, f) }
        let row = PluginRow(id: "row-" + UUID().uuidString.prefix(8).lowercased(), cells: cells)
        plugins[pi].rows[list.key, default: []].append(row)
        edited()
    }

    /// What this list could be filled in from: the services answering for one
    /// of its types, less the ones it already holds.
    ///
    /// A host the list already points at is not offered again, whatever port
    /// the row uses. One server announces the port it wants to be reached on
    /// and is often reachable on another — a Signal K server announces its
    /// websocket on 3000 and carries the same boat on 8375 — and offering a
    /// second row to a machine already connected is offering to publish
    /// everything on it twice.
    func nearby(_ list: PluginListSchema) -> [DiscoveredService] {
        if list.discover.isEmpty || isFull(list) { return [] }
        let types = Set(list.discover.map(\.service))
        let held = Set(rows(list).map { $0.text("host").lowercased() })
        return discovery.found
            .filter { types.contains($0.service) }
            .filter { !held.contains($0.host.lowercased()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Add what the browse found: the schema's defaults, the address it
    /// answered on, and whatever else its service type says a row of this list
    /// takes.
    func addRow(_ list: PluginListSchema, from service: DiscoveredService) {
        if isFull(list) { return }
        guard let pi = plugins.firstIndex(where: { $0.id == list.pluginID }) else { return }
        var cells: [String: PluginValue] = [:]
        for f in list.itemFields { cells[f.key] = PluginValue(nil, f) }
        let preset = list.discover.first { $0.service == service.service }?.set ?? [:]
        for f in list.itemFields {
            if let v = preset[f.key] { cells[f.key] = v }
        }
        if let f = list.itemFields.first(where: { $0.key == "host" }) {
            cells[f.key] = PluginValue(service.host, f)
        }
        if let f = list.itemFields.first(where: { $0.key == "port" }), preset["port"] == nil {
            cells[f.key] = PluginValue(service.port, f)
        }
        if let f = list.itemFields.first(where: { $0.key == "name" }) {
            cells[f.key] = PluginValue(service.name, f)
        }
        let row = PluginRow(id: "row-" + UUID().uuidString.prefix(8).lowercased(), cells: cells)
        plugins[pi].rows[list.key, default: []].append(row)
        edited()
    }

    func removeRow(_ list: PluginListSchema, _ rowID: String) {
        guard let pi = plugins.firstIndex(where: { $0.id == list.pluginID }) else { return }
        plugins[pi].rows[list.key]?.removeAll { $0.id == rowID }
        edited()
    }

    func setCell(_ list: PluginListSchema, _ rowID: String, _ key: String, _ value: PluginValue) {
        guard let pi = plugins.firstIndex(where: { $0.id == list.pluginID }),
              let ri = plugins[pi].rows[list.key]?.firstIndex(where: { $0.id == rowID }),
              let f = list.itemFields.first(where: { $0.key == key })
        else { return }
        // The core clamps too. Doing it here as well keeps the control and the
        // value it shows in step without a round trip.
        let clamped: PluginValue
        switch value {
        case let .number(v): clamped = .number(Swift.min(Swift.max(v, f.min), f.max))
        default: clamped = value
        }
        if plugins[pi].rows[list.key]?[ri].cells[key] == clamped { return }
        plugins[pi].rows[list.key]?[ri].cells[key] = clamped
        edited()
    }

    func cellText(_ list: PluginListSchema, _ rowID: String, _ key: String) -> Binding<String> {
        Binding(
            get: { self.rows(list).first { $0.id == rowID }?.text(key) ?? "" },
            set: { self.setCell(list, rowID, key, .text($0)) }
        )
    }

    func cellNumber(_ list: PluginListSchema, _ rowID: String, _ key: String) -> Binding<Double> {
        Binding(
            get: { self.rows(list).first { $0.id == rowID }?.number(key) ?? 0 },
            set: { self.setCell(list, rowID, key, .number($0)) }
        )
    }

    func cellToggle(_ list: PluginListSchema, _ rowID: String, _ key: String) -> Binding<Bool> {
        Binding(
            get: { self.rows(list).first { $0.id == rowID }?.isOn(key) ?? false },
            set: { self.setCell(list, rowID, key, .toggle($0)) }
        )
    }

    func value(_ pluginID: String, _ key: String) -> Double? {
        guard let p = plugins.first(where: { $0.id == pluginID }),
              let f = p.fields.first(where: { $0.key == key }) else { return nil }
        return f.value
    }

    func setValue(_ pluginID: String, _ key: String, _ v: Double) {
        guard let pi = plugins.firstIndex(where: { $0.id == pluginID }),
              let fi = plugins[pi].fields.firstIndex(where: { $0.key == key }) else { return }
        let f = plugins[pi].fields[fi]
        let clamped = f.kind == .toggle ? (v != 0 ? 1 : 0) : Swift.min(Swift.max(v, f.min), f.max)
        if clamped == f.value { return }
        plugins[pi].fields[fi].value = clamped
        edited()
    }

    /// A binding for one control. Writing it moves the published model, which
    /// the debounced sink then pushes to the plugin.
    func number(_ pluginID: String, _ key: String) -> Binding<Double> {
        Binding(
            get: { self.value(pluginID, key) ?? 0 },
            set: { self.setValue(pluginID, key, $0) }
        )
    }

    func toggle(_ pluginID: String, _ key: String) -> Binding<Bool> {
        Binding(
            get: { (self.value(pluginID, key) ?? 0) != 0 },
            set: { self.setValue(pluginID, key, $0 ? 1 : 0) }
        )
    }

    /// Put one group back on the defaults its manifest declared. The group is
    /// what the mariner sees, so it is what the reset acts on: resetting the
    /// collision alarm must not move the target vectors in another section.
    /// A LIST is not touched by this. A reset puts the controls back where the
    /// manifest had them; it does not throw away the connections the mariner
    /// typed in, which nothing else could get back.
    func resetToDefaults(_ group: PluginGroup) {
        guard let pi = plugins.firstIndex(where: { $0.id == group.pluginID }) else { return }
        for f in group.fields {
            guard let fi = plugins[pi].fields.firstIndex(where: { $0.key == f.key }) else { continue }
            plugins[pi].fields[fi].value = plugins[pi].fields[fi].defaultValue
        }
        edited()
    }

    /// True while any field of this group is off its manifest default.
    func isChanged(_ group: PluginGroup) -> Bool {
        group.fields.contains { f in (value(group.pluginID, f.key) ?? f.defaultValue) != f.defaultValue }
    }

    // MARK: - Apply and persist

    private func applyAndSave() {
        guard let controller else { return }
        var saved: [String: [String: Double]] = [:]
        var savedRows: [String: [String: String]] = [:]
        for p in plugins where !p.fields.isEmpty || !p.lists.isEmpty {
            controller.setPluginConfig(p.id, Self.configJSON(p.fields, p.lists, p.rows))
            var one: [String: Double] = [:]
            for f in p.fields { one[f.key] = f.value }
            if !one.isEmpty { saved[p.id] = one }
            var lists: [String: String] = [:]
            for l in p.lists { lists[l.key] = Self.rowsJSON(l, p.rows[l.key] ?? []) }
            if !lists.isEmpty { savedRows[p.id] = lists }
        }
        Store.shared.set(saved, Self.defaultsKey)
        Store.shared.set(savedRows, Self.listsKey)
    }

    /// Push the saved settings into the plugins that just came up. Called once
    /// per chart open, after the plugin layer exists. A saved key the schema no
    /// longer declares is ignored by the core.
    static func applySaved(to controller: ChartController) {
        // LOOKOUT_CLEAN leaves every plugin on its manifest defaults and on the
        // connection the host seeded, ignoring what this machine has saved.
        // The screenshot protocol needs it: a saved connection list points at
        // the developer's own instruments, and a frame taken through one
        // publishes other people's vessel names, MMSIs and positions.
        if ProcessInfo.processInfo.environment["LOOKOUT_CLEAN"] != nil { return }
        let saved = Store.shared.dictionary(defaultsKey) ?? [:]
        let savedRows = Store.shared.dictionary(listsKey) ?? [:]
        if saved.isEmpty && savedRows.isEmpty { return }
        let loaded = controller.withPlugins { Self.registry($0) } ?? []
        for p in loaded where !p.fields.isEmpty || !p.lists.isEmpty {
            var fields = p.fields
            if let one = saved[p.id] as? [String: Double] {
                for i in fields.indices {
                    if let v = one[fields[i].key] { fields[i].value = v }
                }
            }
            // A saved list REPLACES what the core holds, including the row the
            // host seeded from LOOKOUT_NMEA: the mariner's list is the truth
            // once there is one.
            var body = configBody(fields)
            for l in p.lists {
                guard let text = (savedRows[p.id] as? [String: String])?[l.key] else { continue }
                body.append("\"\(l.key)\":\(text)")
            }
            if body.isEmpty { continue }
            controller.setPluginConfig(p.id, "{" + body.joined(separator: ",") + "}")
        }
    }

    /// `{"cpa_limit":926,"cpa_alarm":true,"connections":[…]}` — a toggle
    /// crosses as a JSON bool, which is the only shape the core accepts for
    /// one, and a list crosses as its whole array of rows.
    nonisolated static func configJSON(_ fields: [PluginField],
                           _ lists: [PluginListSchema] = [],
                           _ rows: [String: [PluginRow]] = [:]) -> String {
        var body = configBody(fields)
        for l in lists { body.append("\"\(l.key)\":\(rowsJSON(l, rows[l.key] ?? []))") }
        return "{" + body.joined(separator: ",") + "}"
    }

    nonisolated private static func configBody(_ fields: [PluginField]) -> [String] {
        fields.map { f -> String in
            switch f.kind {
            case .toggle: return "\"\(f.key)\":\(f.isOn ? "true" : "false")"
            case .number: return "\"\(f.key)\":\(trimmed(f.value))"
            case .text: return "\"\(f.key)\":\"\""  // never a scalar; see the core
            }
        }
    }

    /// A list as the core takes it: every row, every column the schema
    /// declares, and the row id the shell assigned.
    nonisolated static func rowsJSON(_ list: PluginListSchema, _ rows: [PluginRow]) -> String {
        let body = rows.map { row -> String in
            var cells = ["\"id\":\(jsonString(row.id))"]
            for f in list.itemFields {
                let v = row.cells[f.key] ?? PluginValue(nil, f)
                cells.append("\"\(f.key)\":\(v.json)")
            }
            return "{" + cells.joined(separator: ",") + "}"
        }
        return "[" + body.joined(separator: ",") + "]"
    }

    /// A quoted, escaped JSON string. A host name is whatever was typed.
    nonisolated static func jsonString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }

    /// A number with no trailing ".0": the core takes either, and a settings
    /// line in a log reads better without it. The range a row shows uses it
    /// too, off the main actor.
    nonisolated static func trimmed(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15
            ? String(Int64(v.rounded()))
            : String(format: "%g", v)
    }

    // MARK: - Reading the registry
    //
    // Pure, so `nonisolated`: they read the core's typed answer and build value
    // types, touch nothing this class owns, and are called from `bind` on the
    // main actor and from the tests off it.
    //
    // A READ IS NOT AN EMPTY REGISTRY. `lookout_plugins_read` answers NULL with
    // no chart open and in a build with the plugin layer compiled out; a core
    // holding no plugins answers a read with no rows. Reading the two the same
    // way is what emptied this whole window — Vessels, Alarms, Connections and
    // every plugin row — the moment one read came back nil.

    /// Every plugin the read holds.
    nonisolated static func registry(_ read: OpaquePointer) -> [PluginInfo] {
        var n = 0
        guard let all = lookout_plugins_all(read, &n) else { return [] }
        var out: [PluginInfo] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let p = all[i] else { continue }
            out.append(info(p))
        }
        return out
    }

    /// Every plugin's status document, by id, WITHOUT building the registry.
    /// The poll wants one string per plugin, and building the whole registry
    /// for that allocated every settings field, list schema and declared item
    /// once a second and threw them all away.
    nonisolated static func statuses(_ read: OpaquePointer) -> [String: String] {
        var n = 0
        guard let all = lookout_plugins_all(read, &n) else { return [:] }
        var out: [String: String] = [:]
        for i in 0..<n {
            guard let p = all[i] else { continue }
            out[String(cString: p.pointee.id)] = String(cString: p.pointee.status)
        }
        return out
    }

    /// One plugin: what it is, what it asked consent for, and what it lets the
    /// mariner set.
    nonisolated private static func info(_ p: UnsafePointer<lookout_plugin>) -> PluginInfo {
        let id = String(cString: p.pointee.id)
        var fields: [PluginField] = []
        var lists: [PluginListSchema] = []
        var rows: [String: [PluginRow]] = [:]

        var n = 0
        if let settings = lookout_plugin_settings(p, &n) {
            for i in 0..<n {
                guard let s = settings[i] else { continue }
                if s.pointee.kind == LOOKOUT_PLUGIN_SETTING_LIST {
                    let schema = listSchema(s, pluginID: id)
                    lists.append(schema)
                    rows[schema.key] = items(s)
                } else {
                    fields.append(field(s))
                }
            }
        }

        let caps = capabilities(p)
        return PluginInfo(
            id: id,
            name: String(cString: p.pointee.name),
            version: String(cString: p.pointee.version),
            origin: originName(p.pointee.origin),
            live: p.pointee.live != 0,
            status: PluginStatus(String(cString: p.pointee.status)),
            capabilities: caps,
            fields: fields,
            lists: lists,
            rows: rows,
            // The extensions the `files` capability may open. A manifest that
            // claims file types needs that capability, so its allowlist is
            // where they are.
            fileTypes: caps.first { $0.cap == "files" }?.hosts ?? []
        )
    }

    nonisolated private static func capabilities(
        _ p: UnsafePointer<lookout_plugin>
    ) -> [PluginCapability] {
        var n = 0
        guard let caps = lookout_plugin_capabilities(p, &n) else { return [] }
        var out: [PluginCapability] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let c = caps[i] else { continue }
            out.append(PluginCapability(
                cap: String(cString: c.pointee.name),
                sentence: String(cString: c.pointee.sentence),
                hosts: allowlist(c),
                granted: c.pointee.granted != 0))
        }
        return out
    }

    /// What the mariner consented to for one capability: the addresses it may
    /// dial, the topics it may publish, the ports it may listen on, the
    /// extensions it may open.
    nonisolated private static func allowlist(
        _ c: UnsafePointer<lookout_plugin_capability>
    ) -> [String] {
        var n = 0
        guard let allows = lookout_plugin_capability_allows(c, &n) else { return [] }
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let s = allows[i] else { continue }
            out.append(String(cString: s))
        }
        return out
    }

    nonisolated private static func field(
        _ s: UnsafePointer<lookout_plugin_setting>
    ) -> PluginField {
        let f = s.pointee
        return PluginField(
            key: String(cString: f.key),
            label: String(cString: f.label),
            desc: String(cString: f.desc),
            kind: kindOf(f.kind),
            unit: String(cString: f.unit),
            group: String(cString: f.group),
            tab: sectionName(f.section),
            min: f.min,
            max: f.max,
            defaultValue: f.default_number,
            defaultText: String(cString: f.default_text),
            optional: f.optional != 0,
            placeholder: String(cString: f.placeholder),
            value: f.value)
    }

    /// A setting the mariner adds more of: its wording, the shape of one item,
    /// and what to browse the network for.
    nonisolated private static func listSchema(
        _ s: UnsafePointer<lookout_plugin_setting>,
        pluginID: String
    ) -> PluginListSchema {
        let l = s.pointee
        var n = 0
        var itemFields: [PluginField] = []
        if let fs = lookout_plugin_setting_fields(s, &n) {
            for i in 0..<n {
                guard let f = fs[i] else { continue }
                itemFields.append(field(f))
            }
        }
        return PluginListSchema(
            pluginID: pluginID,
            key: String(cString: l.key),
            group: String(cString: l.group),
            tab: sectionName(l.section),
            itemFields: itemFields,
            footer: String(cString: l.footer),
            empty: String(cString: l.empty),
            addLabel: String(cString: l.add_label),
            switchKey: String(cString: l.switch_key),
            discover: services(s),
            maxRows: Int(l.max_items))
    }

    nonisolated private static func services(
        _ s: UnsafePointer<lookout_plugin_setting>
    ) -> [PluginDiscover] {
        var n = 0
        guard let found = lookout_plugin_setting_services(s, &n) else { return [] }
        var out: [PluginDiscover] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let svc = found[i] else { continue }
            var m = 0
            var set: [String: PluginValue] = [:]
            if let vals = lookout_plugin_service_values(svc, &m) {
                for j in 0..<m {
                    guard let v = vals[j] else { continue }
                    set[String(cString: v.pointee.key)] = value(v)
                }
            }
            out.append(PluginDiscover(service: String(cString: svc.pointee.type), set: set))
        }
        return out
    }

    /// The items in force, each with one value per field of its list.
    nonisolated private static func items(
        _ s: UnsafePointer<lookout_plugin_setting>
    ) -> [PluginRow] {
        var n = 0
        guard let all = lookout_plugin_setting_items(s, &n) else { return [] }
        var out: [PluginRow] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let it = all[i] else { continue }
            var m = 0
            var cells: [String: PluginValue] = [:]
            if let vals = lookout_plugin_item_values(it, &m) {
                for j in 0..<m {
                    guard let v = vals[j] else { continue }
                    cells[String(cString: v.pointee.key)] = value(v)
                }
            }
            out.append(PluginRow(id: String(cString: it.pointee.id), cells: cells))
        }
        return out
    }

    nonisolated private static func value(
        _ v: UnsafePointer<lookout_plugin_value>
    ) -> PluginValue {
        switch v.pointee.kind {
        case LOOKOUT_PLUGIN_SETTING_TOGGLE: return .toggle(v.pointee.number != 0)
        case LOOKOUT_PLUGIN_SETTING_TEXT:   return .text(String(cString: v.pointee.text))
        default:                            return .number(v.pointee.number)
        }
    }

    nonisolated private static func kindOf(_ k: lookout_plugin_setting_kind) -> PluginField.Kind {
        switch k {
        case LOOKOUT_PLUGIN_SETTING_TOGGLE: return .toggle
        case LOOKOUT_PLUGIN_SETTING_TEXT:   return .text
        default:                            return .number
        }
    }

    /// The core's own section names, which are the ids the settings window
    /// files its own sections under.
    nonisolated private static func sectionName(_ s: lookout_section) -> String {
        switch s {
        case LOOKOUT_SECTION_DISPLAY:     return "display"
        case LOOKOUT_SECTION_DEPTHS:      return "depths"
        case LOOKOUT_SECTION_TEXT:        return "text"
        case LOOKOUT_SECTION_CHARTS:      return "charts"
        case LOOKOUT_SECTION_VESSELS:     return "vessels"
        case LOOKOUT_SECTION_ALARMS:      return "alarms"
        case LOOKOUT_SECTION_CONNECTIONS: return "connections"
        default:                          return "advanced"
        }
    }

    nonisolated private static func originName(_ o: lookout_plugin_origin) -> String {
        switch o {
        case LOOKOUT_ORIGIN_INSTALLED: return "installed"
        case LOOKOUT_ORIGIN_DEVELOPER: return "developer"
        default:                       return "bundled"
        }
    }
}
