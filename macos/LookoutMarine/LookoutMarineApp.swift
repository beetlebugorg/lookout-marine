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
        // A chart needs room. The default window was 900×520, which is the
        // minimum size, not a working size.
        .defaultSize(width: 1280, height: 800)
        .commands {
            AppCommands(model: model)
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
            #if os(macOS)
            // Dev hook, as LOOKOUT_OPEN_SETTINGS in the WinUI 3 shell: open the
            // mariner form for the settings screenshot.
            .onAppear {
                guard ProcessInfo.processInfo.environment["LOOKOUT_OPEN_SETTINGS"] != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.openSettings() }
            }
            #endif
    }
}

/// The startup loader. It shows from launch until the first scene renders.
/// A later rebuild shows the BuildingPill only.
///
/// The loader fills the window with the NODATA blue of the chart. The Metal
/// layer clears to that color and the iOS launch screen uses it. The launch
/// screen, the loader and the first frame are therefore one surface.
struct StartupLoader: View {
    let phase: AppModel.LoadPhase

    /// S-52 NODATA (day). ChartNSView.makeBackingLayer, ChartUIView.init and the
    /// LaunchBackground color asset use the same value.
    static let nodata = Color(red: 0.576, green: 0.682, blue: 0.733)

    var body: some View {
        ZStack {
            Self.nodata.ignoresSafeArea()
            // The scrim separates the card from the chart color behind it.
            Color.black.opacity(0.22).ignoresSafeArea()
            VStack(spacing: 16) {
                CompassMark()
                    .frame(width: 56, height: 56)
                Text("Lookout Marine")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                Text(phase.title)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Chrome.muted)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Chrome.accent)
                    .frame(width: 240)
                    .background(Chrome.ink.opacity(0.12), in: Capsule())
                if let note = phase.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .background(Chrome.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Chrome.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        }
        .accessibilityIdentifier("startup-loader")
    }
}

/// The compass rose of the loader. It is drawn, not an SF Symbol, so that the
/// shape is the same on each platform.
struct CompassMark: View {
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().strokeBorder(Chrome.accent.opacity(0.35), lineWidth: 2)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(Chrome.accent.opacity(0.35))
                        .frame(width: 1.5, height: r * 0.28)
                        .offset(y: -r * 0.72)
                        .rotationEffect(.degrees(Double(i) * 90))
                }
                // The north needle. A chart compass rose uses the same red.
                Path { p in
                    p.move(to: CGPoint(x: r, y: r * 0.28))
                    p.addLine(to: CGPoint(x: r * 0.7, y: r * 1.32))
                    p.addLine(to: CGPoint(x: r * 1.3, y: r * 1.32))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.831, green: 0.180, blue: 0.180))
            }
            .frame(width: r * 2, height: r * 2)
        }
    }
}

/// The tessellation indicator at the top center. It is the BuildingPill of the
/// WinUI 3 shell.
struct BuildingPill: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Building chart…")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.ink)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .panelSurface(cornerRadius: 14)
    }
}

/// First-run affordance when no chart is loaded and no default was found.
struct EmptyChartState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Text("No chart open")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Chrome.ink)
            Text("Open a baked chart (.pmtiles) or a folder of cells.")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button { model.requestOpenPicker() } label: {
                Label("Open Charts…", systemImage: "folder")
                    .frame(maxWidth: 180)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o", modifiers: .command)
            .padding(.top, 4)

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
        .padding(24)
        .panelSurface(cornerRadius: 12)
    }
}
