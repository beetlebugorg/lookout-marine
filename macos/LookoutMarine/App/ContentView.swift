//  ContentView.swift — the chart view, and the window-level chrome over it.
//
//  There is no toolbar. The title bar shows the app name; the chrome bubbles
//  and the menu bar hold the actions. The dev hooks the screenshot protocol
//  drives are attached here.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif



struct ContentView: View {
    @ObservedObject var model: AppModel
    let controller: ChartController

    var body: some View {
        // The chart surface hosts its own floating chrome (OverlayLayer) in an
        // AppKit view above the Metal layer, so the HUD/zoom/search stay visible
        // once SDL is presenting. ContentView only adds window-level chrome.
        // There is no toolbar. The title bar shows the app name only. The chrome
        // bubbles and the menu bar hold the actions.
        ChartView(model: model, controller: controller)
            .navigationTitle("Lookout Marine")
            .alert("Couldn't open chart", isPresented: Binding(
                get: { model.openError != nil },
                set: { if !$0 { model.openError = nil } })) {
                Button("OK", role: .cancel) { model.openError = nil }
            } message: {
                Text(model.openError ?? "")
            }
            // The .lkplug consent sheet. Every install entry point sets
            // pendingInstall; the sheet is the only way from there to disk.
            .sheet(item: Binding(
                get: { model.pendingInstall },
                set: { model.pendingInstall = $0 })) { pkg in
                PluginConsentSheet(model: model, pkg: pkg)
            }
            .alert("Couldn't install plugin", isPresented: Binding(
                get: { model.installError != nil },
                set: { if !$0 { model.installError = nil } })) {
                Button("OK", role: .cancel) { model.installError = nil }
            } message: {
                Text(model.installError ?? "")
            }
            #if os(macOS)
            // A file dropped on the chart takes the path the Open panel takes:
            // the core decides what it is, and a .lkplug goes to consent.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { model.openFileOrChart(url.path) }
                    }
                }
                return !providers.isEmpty
            }
            #endif
            // Dev hooks: LOOKOUT_ADD=PATH adds that folder as a chart set once
            // the window is up, which is the Add Charts… panel without the
            // panel. Raw cells bake, so this also drives the bake pill.
            // LOOKOUT_REMOVE=PATH takes one off, as the Charts list does;
            // "PATH@8" waits eight seconds first, which is the only way to run
            // the case that matters — a set removed while its own charts are
            // still baking.
            .onAppear {
                let env = ProcessInfo.processInfo.environment
                if let add = env["LOOKOUT_ADD"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        model.addChartSet(add)
                    }
                }
                if let remove = env["LOOKOUT_REMOVE"] {
                    let parts = remove.split(separator: "@", maxSplits: 1)
                    let path = String(parts[0])
                    let after = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2 + after) {
                        model.removeChartSet(path)
                    }
                }
            }
            // Dev hook for the screenshot protocol: LOOKOUT_SHOW=settings[:tab],
            // scale, search, pick, menu, marker, rename opens that chrome once
            // the chart is up. On the simulator, pass it as
            // SIMCTL_CHILD_LOOKOUT_SHOW.
            .onAppear {
                guard let show = ProcessInfo.processInfo.environment["LOOKOUT_SHOW"] else { return }
                let want = Set(show.lowercased().split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) })
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    for item in want {
                        let part = item.split(separator: ":", maxSplits: 1).map(String.init)
                        switch part[0] {
                        // settings:<section>, the section named as the core
                        // names it (display, depths, text, charts, vessels,
                        // alarms, connections, advanced).
                        // The section is named AFTER the window opens: on iOS
                        // openSettings puts the form on its list of sections,
                        // and this is what pushes one of them.
                        case "settings":
                            let want = part.count > 1 ? part[1] : "display"
                            model.openSettings()
                            model.settingsTab = want
                        case "scale": model.beginScaleEntry()
                        // table[:key[:sort[:desc]]] opens a plugin's declared
                        // dialog, the way the menu item the declaration asked
                        // for does, with the sort a mariner would click for.
                        #if os(macOS)
                        case "table":
                            model.openPluginTable(part.count > 1 ? part[1] : "")
                        // target[:id] pins one declared row on the chart, the
                        // way a double-click in the dialog does, without the
                        // dialog. No id takes the first row of the declared
                        // sort.
                        case "target":
                            model.revealTableRow(part.count > 1 ? part[1] : "")
                        // The licenses window, and the About panel that opens
                        // it. licenses:<id> selects one component's entry.
                        case "licenses":
                            LicensesWindowController.shared.show()
                            if part.count > 1 { LicensesWindowController.shared.select(part[1]) }
                        case "about":
                            AboutWindowController.shared.show()
                        #endif
                        // scheme:1 dusk, scheme:2 night — the chrome must
                        // follow the chart's hours, and a screenshot proves it.
                        case "scheme":
                            let n = part.count > 1 ? (Int(part[1]) ?? 1) : 1
                            for _ in 0..<n { model.controller?.cycleScheme() }
                        case "search": model.searchOpen = true
                        // install:<path> — a .lkplug straight to its consent
                        // sheet, for the screenshot protocol. Parsed from the
                        // raw variable: a path keeps its case.
                        case "install":
                            if let r = show.range(of: "install:", options: .caseInsensitive) {
                                model.beginPluginInstall(String(show[r.upperBound...]))
                            }
                        // pick at the centre, or at a fraction of the view:
                        // pick:0.5x0.85 lands low in the chart. ("x", because
                        // the comma splits the LOOKOUT_SHOW list itself.)
                        case "pick":
                            let f = part.count > 1
                                ? part[1].split(separator: "x").compactMap { Double($0) } : []
                            if f.count == 2 { model.pickAt(fx: f[0], fy: f[1]) }
                            else { model.pickAtCentre() }
                        // The chart menu, a dropped mark, and the rename field
                        // on the newest mark. Same fraction as pick, because
                        // the hook has no pointer to press with:
                        // menu:0.5x0.5, marker:0.45x0.5, rename.
                        case "menu":
                            let f = part.count > 1
                                ? part[1].split(separator: "x").compactMap { Double($0) } : []
                            model.showChartMenu(fx: f.count == 2 ? f[0] : 0.5,
                                                fy: f.count == 2 ? f[1] : 0.5)
                        case "marker":
                            let f = part.count > 1
                                ? part[1].split(separator: "x").compactMap { Double($0) } : []
                            model.showDropMarker(fx: f.count == 2 ? f[0] : 0.5,
                                                 fy: f.count == 2 ? f[1] : 0.5)
                        case "rename":
                            model.showRenameNewestMarker()
                        // pick, then the next object's report 5s later: the
                        // screenshot protocol's way of watching the selection.
                        case "page":
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                if model.pickIndex < model.pickResults.count - 1 {
                                    model.pickIndex += 1
                                }
                            }
                        default: break
                        }
                    }
                }
            }
    }
}
