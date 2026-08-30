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
    var model: AppModel
    let controller: ChartController

    /// Run `body` once the chart is drawing, or once it is clear none is
    /// coming, or after `timeout` either way.
    ///
    /// The dev hooks act on a chart: a pick with no handle behind it reports
    /// nothing and a table has no plugin to build rows. Polling the model beats
    /// a fixed delay, which is dead time on an idle machine and a lost race on
    /// a loaded one.
    ///
    /// The settings form and the licenses screen need no chart, and the app is
    /// often started with none. `grace` is how long to let an open declare
    /// itself before giving up on one.
    private func whenChartIsUp(timeout: TimeInterval = 30, grace: TimeInterval = 1.5,
                               _ body: @escaping () -> Void) {
        let started = Date()
        func poll() {
            let waited = Date().timeIntervalSince(started)
            let drawing = model.charts.hasChart && model.charts.firstBuildDone
            let noneComing = waited >= grace && !model.charts.isOpening && !model.charts.hasChart
            if drawing || noneComing || waited >= timeout {
                body()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    var body: some View {
        // The chart surface hosts its own floating chrome (OverlayLayer) in an
        // AppKit view above the Metal layer, so the HUD/zoom/search stay visible
        // once SDL is presenting. ContentView only adds window-level chrome.
        // There is no toolbar. The title bar shows the app name only. The chrome
        // bubbles and the menu bar hold the actions.
        ChartView(model: model, controller: controller)
            .navigationTitle("Lookout Marine")
            .alert("Couldn't open chart", isPresented: Binding(
                get: { model.charts.openError != nil },
                set: { if !$0 { model.charts.openError = nil } })) {
                Button("OK", role: .cancel) { model.charts.openError = nil }
            } message: {
                Text(model.charts.openError ?? "")
            }
            // The .lkplug consent sheet. Every install entry point sets
            // pendingInstall; the sheet is the only way from there to disk.
            .sheet(item: Binding(
                get: { model.plugins.pendingInstall },
                set: { model.plugins.pendingInstall = $0 })) { pkg in
                PluginConsentSheet(model: model, pkg: pkg)
            }
            .alert("Couldn't install plugin", isPresented: Binding(
                get: { model.plugins.installError != nil },
                set: { if !$0 { model.plugins.installError = nil } })) {
                Button("OK", role: .cancel) { model.plugins.installError = nil }
            } message: {
                Text(model.plugins.installError ?? "")
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
            // The screenshot protocol's hooks, which are read only when they
            // are set. LOOKOUT_SHOW waits for the chart rather than for a
            // fixed three seconds: a pick with no handle behind it reports
            // nothing, and three seconds is both too long on an idle machine
            // and too short on a loaded one — two UI tests lost that race.
            .onAppear {
                DevHooks.runChartSetHooks(model)
                guard let show = ProcessInfo.processInfo.environment["LOOKOUT_SHOW"]
                else { return }
                whenChartIsUp { DevHooks.show(show, model) }
            }
    }
}
