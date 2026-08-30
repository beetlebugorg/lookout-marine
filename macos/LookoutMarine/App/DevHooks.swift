//  DevHooks.swift — the environment variables the screenshot protocol drives.
//
//  A screenshot run has no cursor to click with and no way to reach a menu, so
//  the chrome it wants photographed is named in the environment and opened
//  here. Nothing reads these unless they are set.
//
//  On the simulator, pass them with the SIMCTL_CHILD_ prefix.

import Foundation

@MainActor
enum DevHooks {

    /// LOOKOUT_ADD=PATH adds that folder as a chart set once the window is up,
    /// which is the Add Charts… panel without the panel. Raw cells bake, so
    /// this also drives the bake pill.
    ///
    /// LOOKOUT_REMOVE=PATH takes one off, as the Charts list does. "PATH@8"
    /// waits eight seconds first, which is the only way to run the case that
    /// matters — a set removed while its own charts are still baking.
    static func runChartSetHooks(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let add = env["LOOKOUT_ADD"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                model.addChartSet(add)
            }
        }
        guard let remove = env["LOOKOUT_REMOVE"] else { return }
        let parts = remove.split(separator: "@", maxSplits: 1)
        let path = String(parts[0])
        let after = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + after) {
            model.removeChartSet(path)
        }
    }

    /// LOOKOUT_SHOW=settings[:section],scale,search,pick,menu,marker,rename and
    /// the rest, as a comma-separated list. The caller waits for the chart
    /// before running this: a pick with no handle behind it reports nothing.
    static func show(_ spec: String, _ model: AppModel) {
        let items = spec.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for item in Set(items) {
            let part = item.split(separator: ":", maxSplits: 1).map(String.init)
            run(part, raw: spec, model)
        }
    }

    private static func run(_ part: [String], raw: String, _ model: AppModel) {
        switch part[0] {
        // settings:<section>, the section named as the core names it (display,
        // depths, text, charts, vessels, alarms, connections, advanced).
        // The section is named AFTER the window opens: on iOS openSettings puts
        // the form on its list of sections, and this is what pushes one.
        case "settings":
            model.openSettings()
            model.settingsTab = part.count > 1 ? part[1] : "display"
        case "scale":
            model.beginScaleEntry()
        case "search":
            model.searchOpen = true
        // scheme:1 dusk, scheme:2 night — the chrome must follow the chart's
        // hours, and a screenshot proves it.
        case "scheme":
            let n = part.count > 1 ? (Int(part[1]) ?? 1) : 1
            for _ in 0..<n { model.controller?.cycleScheme() }
        // install:<path> — a .lkplug straight to its consent sheet. Parsed
        // from the raw variable: a path keeps its case.
        case "install":
            if let r = raw.range(of: "install:", options: .caseInsensitive) {
                model.beginPluginInstall(String(raw[r.upperBound...]))
            }
        // pick at the centre, or at a fraction of the view: pick:0.5x0.85
        // lands low in the chart. ("x", because the comma splits the list.)
        case "pick":
            if let f = fraction(part) {
                model.overlay.pickAt(fx: f.x, fy: f.y)
            } else {
                model.overlay.pickAtCentre(lon: model.centerLon, lat: model.centerLat)
            }
        // The chart menu, a dropped mark, and the rename field on the newest
        // mark. Same fraction as pick, because the hook has no pointer to
        // press with: menu:0.5x0.5, marker:0.45x0.5, rename.
        case "menu":
            let f = fraction(part) ?? (x: 0.5, y: 0.5)
            model.overlay.showChartMenu(fx: f.x, fy: f.y)
        case "marker":
            let f = fraction(part) ?? (x: 0.5, y: 0.5)
            model.overlay.showDropMarker(fx: f.x, fy: f.y)
        case "rename":
            model.overlay.showRenameNewestMarker()
        // pick, then the next object's report 5s later: the way to watch the
        // selection move through a report with several objects in it.
        case "page":
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let o = model.overlay
                if o.pickIndex < o.pickResults.count - 1 { o.pickIndex += 1 }
            }
        default:
            runMacOnly(part, model)
        }
    }

    private static func runMacOnly(_ part: [String], _ model: AppModel) {
        #if os(macOS)
        switch part[0] {
        // table[:key[:sort[:desc]]] opens a plugin's declared dialog, the way
        // the menu item the declaration asked for does, with the sort a
        // mariner would click for.
        case "table":
            PluginTableWindowController.open(part.count > 1 ? part[1] : "", model: model)
        // target[:id] pins one declared row on the chart, the way a
        // double-click in the dialog does, without the dialog. No id takes the
        // first row of the declared sort.
        case "target":
            PluginTableWindowController.revealRow(part.count > 1 ? part[1] : "", model: model)
        // The licenses window, and the About panel that opens it.
        // licenses:<id> selects one component's entry.
        case "licenses":
            LicensesWindowController.shared.show()
            if part.count > 1 { LicensesWindowController.shared.select(part[1]) }
        case "about":
            AboutWindowController.shared.show()
        default:
            break
        }
        #endif
    }

    /// "0.5x0.85" as a fraction of the view, or nil when none was named.
    private static func fraction(_ part: [String]) -> (x: Double, y: Double)? {
        guard part.count > 1 else { return nil }
        let f = part[1].split(separator: "x").compactMap { Double($0) }
        return f.count == 2 ? (x: f[0], y: f[1]) : nil
    }
}
