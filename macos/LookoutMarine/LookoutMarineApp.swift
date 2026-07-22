//  LookoutMarineApp.swift — @main SwiftUI entry point.
//
//  A ZStack: the GPU ChartView fills the window; the HUD, zoom controls and
//  search float over it as native SwiftUI. The Settings scene (⌘,) hosts the
//  mariner form. The single ChartController is created here and shared with the
//  model + chart view (it owns the lookout* handle for the app's lifetime).

import SwiftUI

@main
struct LookoutMarineApp: App {
    @StateObject private var model = AppModel()
    // Held as @State so the controller (and its lookout* handle / display link)
    // survives view-tree rebuilds.
    @State private var controller = ChartController()

    init() {
        #if os(macOS)
        // A dev build is often launched as a bare executable (build-dev.sh, a
        // terminal) rather than through LaunchServices. Without this the app
        // comes up as a background-ish process: no focus until clicked twice,
        // flaky key-window behavior, unreliable full-screen. Make it a regular,
        // active app regardless of how it was started.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, controller: controller)
                .frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            #if os(macOS)
            AppCommands(model: model)
            #endif
        }

        #if os(macOS)
        Settings {
            SettingsView(model: model)
        }
        #endif
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    let controller: ChartController

    var body: some View {
        // The chart surface hosts its own floating chrome (OverlayLayer) in an
        // AppKit view above the Metal layer, so the HUD/zoom/search stay visible
        // once SDL is presenting. ContentView only adds window-level chrome.
        ChartView(model: model, controller: controller)
            .navigationTitle(model.chartPath.map { ($0 as NSString).lastPathComponent } ?? "lookout-marine")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { model.presentOpenPanel() } label: { Image(systemName: "folder") }
                        .help("Open Chart…")
                }
                ToolbarItemGroup {
                    Menu {
                        Button("Day") { model.setScheme(0) }
                        Button("Dusk") { model.setScheme(1) }
                        Button("Night") { model.setScheme(2) }
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .help("Color scheme")
                    .disabled(!model.hasChart)

                    Button { model.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Zoom to fit")
                        .disabled(!model.hasChart)
                }
            }
            #endif
            .alert("Couldn't open chart", isPresented: Binding(
                get: { model.openError != nil },
                set: { if !$0 { model.openError = nil } })) {
                Button("OK", role: .cancel) { model.openError = nil }
            } message: {
                Text(model.openError ?? "")
            }
    }
}

/// Small "building the chart" indicator shown top-center while tessellating.
struct BuildingPill: View {
    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("Building chart…").font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator))
    }
}

/// First-run affordance when no chart is loaded and no default was found.
struct EmptyChartState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "map")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("No chart open").font(.title2.weight(.semibold))
            Text("Open a baked .pmtiles chart, or a folder of cells, to get started.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            #if os(macOS)
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open Chart…", systemImage: "folder")
                    .frame(maxWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)

            if !model.recents.isEmpty {
                Menu("Recent Charts") {
                    ForEach(model.recents, id: \.self) { p in
                        Button((p as NSString).lastPathComponent) { model.openChart(p) }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 180)
            }
            #endif
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
    }
}
