//  PluginSettings.swift — the mariner's controls over the wasm plugins.
//
//  A plugin declares a settings schema in its manifest; the core hands it over
//  as JSON through lookout_plugins_json, and this file turns that into SwiftUI
//  controls. The app knows nothing about what any plugin does — a number field
//  with a unit and a range, or a toggle, is the whole vocabulary.
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
    let kind: Kind
    let unit: String
    let min: Double
    let max: Double
    let defaultValue: Double
    /// The value in force. A toggle is 0 or 1.
    var value: Double

    var id: String { key }
    var isOn: Bool { value != 0 }

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
    /// The plugin's own status line, `{"state":"running","detail":"..."}`.
    let status: String
    var fields: [PluginField]

    /// The status line as one phrase, for the section footer.
    var statusDetail: String {
        guard let d = status.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return status }
        let state = o["state"] as? String ?? ""
        let detail = o["detail"] as? String ?? ""
        if state.isEmpty { return detail }
        return detail.isEmpty ? state : "\(state) — \(detail)"
    }
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

    /// Re-read the status lines without disturbing the values being edited.
    /// A plugin's status moves on its own — "3 targets, alarms off" is how the
    /// mariner sees a setting take effect.
    func refreshStatus() {
        let fresh = Self.parse(controller?.pluginsJSON())
        for (i, p) in plugins.enumerated() {
            guard let f = fresh.first(where: { $0.id == p.id }), f.status != p.status else { continue }
            plugins[i] = PluginInfo(id: p.id, name: p.name, live: f.live, status: f.status, fields: p.fields)
        }
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

    /// Put one plugin back on the defaults its manifest declared.
    func resetToDefaults(_ pluginID: String) {
        guard let pi = plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        for i in plugins[pi].fields.indices {
            plugins[pi].fields[i].value = plugins[pi].fields[i].defaultValue
        }
    }

    /// True while any field of this plugin is off its manifest default.
    func isChanged(_ pluginID: String) -> Bool {
        guard let p = plugins.first(where: { $0.id == pluginID }) else { return false }
        return p.fields.contains { $0.value != $0.defaultValue }
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
        refreshStatus()
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
    /// line in a log reads better without it.
    private static func trimmed(_ v: Double) -> String {
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
        return PluginField(
            key: key,
            label: o["label"] as? String ?? key,
            kind: kind,
            unit: o["unit"] as? String ?? "",
            min: (o["min"] as? NSNumber)?.doubleValue ?? 0,
            max: (o["max"] as? NSNumber)?.doubleValue ?? 1,
            defaultValue: fallback,
            value: value
        )
    }
}
