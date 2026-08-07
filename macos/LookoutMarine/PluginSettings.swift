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
//  for a field that no longer exists is simply never applied.

import Foundation
import Combine
import SwiftUI

/// One control, as the manifest declared it.
struct PluginField: Identifiable {
    enum Kind: String { case number, toggle }

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

/// One loaded plugin and the controls it asked for.
struct PluginInfo: Identifiable {
    let id: String
    let name: String
    let live: Bool
    /// The plugin's own status line, `{"state":"running","detail":"..."}`. Not
    /// shown in settings: a mariner does not manage plugins. It goes to the log.
    let status: String
    var fields: [PluginField]
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

    private static let defaultsKey = "plugins.v1"

    // MARK: - Binding

    /// Load the schemas from the live chart, then auto-apply and save edits.
    func bind(to controller: ChartController?) {
        applyCancellable = nil                       // don't echo the load below
        self.controller = controller
        plugins = Self.parse(controller?.pluginsJSON())
        applyCancellable = objectWillChange
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyAndSave() }
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

    /// The sections that have something in them.
    var populatedTabs: Set<String> {
        Set(plugins.flatMap { $0.fields }.map(\.tab))
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
    func resetToDefaults(_ group: PluginGroup) {
        guard let pi = plugins.firstIndex(where: { $0.id == group.pluginID }) else { return }
        for f in group.fields {
            guard let fi = plugins[pi].fields.firstIndex(where: { $0.key == f.key }) else { continue }
            plugins[pi].fields[fi].value = plugins[pi].fields[fi].defaultValue
        }
    }

    /// True while any field of this group is off its manifest default.
    func isChanged(_ group: PluginGroup) -> Bool {
        group.fields.contains { f in (value(group.pluginID, f.key) ?? f.defaultValue) != f.defaultValue }
    }

    // MARK: - Apply and persist

    private func applyAndSave() {
        guard let controller else { return }
        var saved: [String: [String: Double]] = [:]
        for p in plugins where !p.fields.isEmpty {
            controller.setPluginConfig(p.id, Self.configJSON(p.fields))
            var one: [String: Double] = [:]
            for f in p.fields { one[f.key] = f.value }
            saved[p.id] = one
        }
        UserDefaults.standard.set(saved, forKey: Self.defaultsKey)
    }

    /// Push the saved settings into the plugins that just came up. Called once
    /// per chart open, after the plugin layer exists. A saved key the schema no
    /// longer declares is ignored by the core.
    static func applySaved(to controller: ChartController) {
        guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return }
        for p in parse(controller.pluginsJSON()) where !p.fields.isEmpty {
            guard let one = saved[p.id] as? [String: Double] else { continue }
            var fields = p.fields
            for i in fields.indices {
                if let v = one[fields[i].key] { fields[i].value = v }
            }
            controller.setPluginConfig(p.id, configJSON(fields))
        }
    }

    /// `{"cpa_limit":926,"cpa_alarm":true}` — a toggle crosses as a JSON bool,
    /// which is the only shape the core accepts for one.
    static func configJSON(_ fields: [PluginField]) -> String {
        let body = fields.map { f -> String in
            switch f.kind {
            case .toggle: return "\"\(f.key)\":\(f.isOn ? "true" : "false")"
            case .number: return "\"\(f.key)\":\(trimmed(f.value))"
            }
        }
        return "{" + body.joined(separator: ",") + "}"
    }

    /// A number with no trailing ".0": the core takes either, and a settings
    /// line in a log reads better without it. The range a row shows uses it
    /// too, off the main actor.
    nonisolated static func trimmed(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15
            ? String(Int64(v.rounded()))
            : String(format: "%g", v)
    }

    // MARK: - Parsing the registry JSON

    static func parse(_ json: String?) -> [PluginInfo] {
        guard let json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["plugins"] as? [[String: Any]]
        else { return [] }

        return list.compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            return PluginInfo(
                id: id,
                name: o["name"] as? String ?? id,
                live: o["live"] as? Bool ?? false,
                status: o["status"] as? String ?? "",
                fields: (o["settings"] as? [[String: Any]] ?? []).compactMap(field(from:))
            )
        }
    }

    private static func field(from o: [String: Any]) -> PluginField? {
        guard let key = o["key"] as? String,
              let kindText = o["kind"] as? String,
              let kind = PluginField.Kind(rawValue: kindText)
        else { return nil }
        let value: Double, fallback: Double
        switch kind {
        case .toggle:
            value = (o["value"] as? Bool ?? false) ? 1 : 0
            fallback = (o["default"] as? Bool ?? false) ? 1 : 0
        case .number:
            value = (o["value"] as? NSNumber)?.doubleValue ?? 0
            fallback = (o["default"] as? NSNumber)?.doubleValue ?? value
        }
        // A schema that declares no label, description, group or section still
        // renders: the key names the control and the core's fallback section
        // takes it.
        return PluginField(
            key: key,
            label: o["label"] as? String ?? key,
            desc: o["desc"] as? String ?? "",
            kind: kind,
            unit: o["unit"] as? String ?? "",
            group: o["group"] as? String ?? "",
            tab: o["tab"] as? String ?? "advanced",
            min: (o["min"] as? NSNumber)?.doubleValue ?? 0,
            max: (o["max"] as? NSNumber)?.doubleValue ?? 1,
            defaultValue: fallback,
            value: value
        )
    }
}
