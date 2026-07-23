//  LookoutMarineApp.swift — @main SwiftUI entry point.
//
//  A ZStack: the GPU ChartView fills the window; the HUD, zoom controls and
//  search float over it as native SwiftUI. The Settings scene (⌘,) hosts the
//  mariner form. The single ChartController is created here and shared with the
//  model + chart view (it owns the lookout* handle for the app's lifetime).

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)

@main
struct LookoutMarineApp: App {
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
        }
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

#else

// iOS uses the UIKit lifecycle, not WindowGroup: the gesture surface must be a
// plain UIKit window. SwiftUI's hosting view swallows the touch stream for its
// whole window (hit-testing returns the hosting view; neither subview- nor
// window-attached UIKit recognizers ever fire — measured, see the UITests), so
// a chart embedded under SwiftUI can render but never hear a gesture.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        lkLog("app did finish launching; SceneDelegate runtime name = \(NSStringFromClass(SceneDelegate.self)); plist-name lookup = \(NSClassFromString("LookoutMarine.SceneDelegate").map(NSStringFromClass) ?? "NIL")")
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        lkLog("configurationForConnecting role=\(connectingSceneSession.role.rawValue)")
        let cfg = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        cfg.delegateClass = SceneDelegate.self
        return cfg
    }
}

/// The iOS window stack, bottom → top:
///   1. lookout/SDL's chart UIWindow (created at open; renders the chart),
///   2. the INPUT window — ChartUIView in plain UIKit, so its gesture
///      recognizers actually receive touches and pointer events,
///   3. the CHROME window — the SwiftUI overlay in a PassThroughWindow:
///      controls are interactive, empty areas fall through to the input window.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    @MainActor static let model = AppModel()
    @MainActor static let controller = ChartController()

    var inputWindow: UIWindow?
    var chromeWindow: PassThroughWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        lkLog("scene connected — building input + chrome windows")
        let model = Self.model
        let controller = Self.controller
        controller.model = model
        model.controller = controller

        let chart = ChartUIView()
        chart.model = model
        chart.controller = controller
        let inputVC = UIViewController()
        inputVC.view = chart
        let input = UIWindow(windowScene: ws)
        input.rootViewController = inputVC
        input.windowLevel = .normal + 1
        input.isOpaque = false
        input.backgroundColor = .clear
        input.isHidden = false
        inputWindow = input

        let chrome = PassThroughWindow(windowScene: ws)
        chrome.rootViewController = UIHostingController(
            rootView: ContentView(model: model, controller: controller))
        chrome.windowLevel = .normal + 2
        chrome.isOpaque = false
        chrome.backgroundColor = .clear
        chrome.rootViewController?.view.backgroundColor = .clear
        chrome.makeKeyAndVisible()
        chromeWindow = chrome
        chart.chromeWindow = chrome
    }
}

#endif

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
            Button {
                #if os(macOS)
                model.presentOpenPanel()
                #else
                model.showImporter = true
                #endif
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
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .frame(width: 180)
            }
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
    }
}
