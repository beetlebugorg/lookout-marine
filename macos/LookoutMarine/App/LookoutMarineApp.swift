//  LookoutMarineApp.swift — the macOS entry point.
//
//  A WindowGroup over the chart view, the menu bar, and the app delegate that
//  exists for one job: files LaunchServices hands the app. Only one copy runs
//  per machine, because two share one preferences domain and one plugin storage
//  directory.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel? {
        didSet { deliverPending() }
    }
    private static var pending: [String] = []

    /// Hand the chart to the copy already running, and go.
    ///
    /// Two copies share one preferences domain and one plugin storage
    /// directory, so the second to quit overwrites what the first saved: a
    /// mariner loses connections, alarm limits and raster choices without
    /// being told. They also compete for the instrument feed, which serves
    /// one client.
    ///
    /// LOOKOUT_MULTI lifts it. The screenshot protocol takes every frame from
    /// its own instance and needs several at once, and a developer comparing
    /// two builds side by side needs the same.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["LOOKOUT_MULTI"] == nil else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        guard let first = others.first else { return }
        lkLog("another copy is running (pid \(first.processIdentifier)); handing over to it")
        first.activate(options: [.activateAllWindows])
        // exit rather than NSApp.terminate: nothing is open yet to unwind, and
        // terminate part way through launching runs a teardown against state
        // that was never built.
        exit(0)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.pending.append(contentsOf: urls.map(\.path))
        Self.deliverPending()
    }

    private static func deliverPending() {
        guard let model else { return }
        let paths = pending
        pending = []
        for p in paths { model.openFileOrChart(p) }
    }
}



@main
struct LookoutMarineApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    // Held as @State so the controller (and its lookout* handle / display link)
    // survives view-tree rebuilds.
    @State private var controller = ChartController()

    init() {
        // A dev build is often launched as a bare executable (build-dev.sh, a
        // terminal) rather than through LaunchServices. Without this the app
        // comes up as a background-ish process: no focus until clicked twice,
        // flaky key-window behavior, unreliable full-screen. Make it a regular,
        // active app regardless of how it was started.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, controller: controller)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear { MacAppDelegate.model = model }
        }
        // A chart needs room. The default window was 900×520, which is the
        // minimum size, not a working size.
        .defaultSize(width: 1280, height: 800)
        .commands {
            AppCommands(model: model)
        }
    }
}

#endif
