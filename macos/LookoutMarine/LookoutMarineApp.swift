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

/// The app delegate exists for one job: files LaunchServices hands the app —
/// a double-clicked .lkplug, `open x.lkplug`, a chart dropped on the Dock
/// icon. A WindowGroup has no other hook for them. Files that arrive before
/// the content view has published the model wait here.
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

/// The chrome window's root controller, and the app's hardware keyboard.
///
/// A keyboard gets what the Mac menu bar gives: the chart commands, and
/// Escape and the arrows for the pick report. `ChartNSView.keyDown` is the
/// Mac equivalent. It also returns an unclaimed key to the responder chain.
///
/// The keys are read here because the chrome window is the key window.
/// `ChartUIView` is in the input window below it and receives no key.
///
/// The arrows and the command keys arrive in `pressesBegan`. Escape does not
/// arrive there, because a responder above this one claims it first, so
/// Escape needs a `UIKeyCommand`.
final class ChromeHostingController: UIHostingController<ContentView> {
    override var canBecomeFirstResponder: Bool { true }

    /// `canPerformAction` does not gate this command. The command does
    /// nothing when no report and no picture are open.
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(action: #selector(keyEscape), input: UIKeyCommand.inputEscape)]
    }

    @objc private func keyEscape() {
        let model = SceneDelegate.model
        if model.picture != nil { model.picture = nil; return }
        if model.pickPoint != nil { model.closePick() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unclaimed = presses.filter { !act(on: $0) }
        // An unclaimed key goes back to the chain, so a text field keeps its
        // caret keys and Escape still dismisses a sheet.
        if !unclaimed.isEmpty { super.pressesBegan(Set(unclaimed), with: event) }
    }

    /// True when the key did something.
    private func act(on press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        let model = SceneDelegate.model

        if key.modifierFlags.contains(.command) {
            // ⌘↑ is north-up, as on the Mac.
            if key.keyCode == .keyboardUpArrow { model.northUp(); return true }
            switch key.charactersIgnoringModifiers.lowercased() {
            case "+", "=": model.zoomIn()
            case "-":      model.zoomOut()
            case "0":      model.zoomToFit()
            case "l":      model.cycleScheme()
            case "i" where key.modifierFlags.contains(.shift): model.showRasterImporter = true
            case "i":      model.cycleRaster()
            case "h":      model.toggleChart()
            case "t":      model.toggleText()
            case "d":      model.toggleOtherCategory()
            case "o":      model.requestOpenPicker()
            case ",":      model.openSettings()
            case "s" where key.modifierFlags.contains(.shift): model.toggleSoundings()
            default:       return false
            }
            return true
        }

        // Escape by key code or by character. A simulated press can carry
        // the character and no key code.
        if key.keyCode == .keyboardEscape || key.charactersIgnoringModifiers == "\u{1b}" {
            if model.picture != nil { model.picture = nil; return true }
            if model.pickPoint != nil { model.closePick(); return true }
            return false
        }

        switch key.keyCode {
        // The selection in the pick's list, as 126/125 do on the Mac.
        case .keyboardUpArrow where model.pickResults.count > 1:
            model.pickIndex = max(0, model.pickIndex - 1)
            return true
        case .keyboardDownArrow where model.pickResults.count > 1:
            model.pickIndex = min(model.pickResults.count - 1, model.pickIndex + 1)
            return true
        default:
            return false
        }
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
        chrome.rootViewController = ChromeHostingController(
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
            // Dev hook: LOOKOUT_ADD=PATH adds that folder as a chart set once
            // the window is up, which is the Add Charts… panel without the
            // panel. Raw cells bake, so this also drives the bake pill.
            .onAppear {
                guard let add = ProcessInfo.processInfo.environment["LOOKOUT_ADD"] else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    model.addChartSet(add)
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

/// Opening, as a page.
///
/// The three waits are different work and the mariner should be able to see
/// which one they are in: the one-time symbol bake, mapping the library, and
/// tessellating the first scene. A single bar that fills and vanishes says
/// only that something happened.
///
/// It is a page, not a card over a scrim, for the same reason the first run is:
/// there is nothing behind it worth showing yet.
struct StartupLoader: View {
    let phase: AppModel.LoadPhase
    /// How many charts are being opened, when that is known.
    var cells: Int = 0

    /// S-52 NODATA (day). ChartNSView.makeBackingLayer, ChartUIView.init and the
    /// LaunchBackground color asset use the same value.
    static let nodata = Color(red: 0.576, green: 0.682, blue: 0.733)

    private var step: Int {
        switch phase {
        case .bakingAtlas: return 0
        case .mapping: return 1
        case .tessellating: return 2
        }
    }

    var body: some View {
        ZStack {
            Chrome.panel.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    CompassMark().frame(width: 24, height: 24)
                    Text(cells > 1 ? "Opening \(cells.formatted(.number)) charts" : "Opening the chart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                }

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Chrome.accent)
                    .frame(width: BakeDetail.width)

                VStack(alignment: .leading, spacing: 7) {
                    // The atlas bake happens on the first run only, so on every
                    // other run it is already true rather than skipped.
                    BakeStep(state: step > 0 ? .done : .running,
                             label: "Preparing chart symbols",
                             detail: step > 0 ? "" : "first run only")
                    BakeStep(state: step > 1 ? .done : (step == 1 ? .running : .waiting),
                             label: cells > 1 ? "Mapping \(cells.formatted(.number)) cells" : "Mapping the chart",
                             detail: step == 1 ? "not loading them, so this is quick" : "")
                    BakeStep(state: step == 2 ? .running : .waiting,
                             label: "Drawing the first scene")
                }
                .frame(width: BakeDetail.width, alignment: .leading)
            }
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

/// The chart work, in the two places a mariner looks for it.
///
/// ONE view, not two. Before there is a chart it stands in the middle of the
/// window, open, because the wait is the only thing on screen. Once charts are
/// drawing it moves to the top and closes to a line, because the chart is now
/// the thing worth looking at. Moving one panel is what makes those two states
/// read as the same work; swapping a big panel for a small one somewhere else
/// reads as two unrelated things.
struct ChartWorkPanel: View {
    let progress: BakeProgress
    /// True once a chart is drawing: the small form at the top.
    let compact: Bool
    let onCancel: () -> Void
    @State private var open = false
    @State private var cancelling = false

    private var title: String {
        switch progress.kind {
        case .removing: return "Removing \(progress.name)"
        case .finding: return "Finding charts in \(progress.name)"
        case .importing:
            return progress.total > 0 ? "Importing \(progress.name)" : "Finding charts in \(progress.name)"
        }
    }
    /// The detail shows always in the big form, and on request in the small one.
    private var showDetail: Bool { !compact || open }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            if compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { open.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(cancelling ? "Finishing this chart…" : title)
                            .font(.system(size: 13))
                            .foregroundStyle(Chrome.ink)
                        if progress.total > 0 {
                            Text("\(progress.done) of \(progress.total)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Chrome.muted)
                        } else {
                            // Nothing to count yet. A moving count is what says
                            // the app is working; with none, the pill is a line
                            // of text that sits there for seconds and reads as
                            // a hang, so it spins instead.
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        }
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Chrome.muted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(progress.done) of \(progress.total) charts")
                .accessibilityHint(open ? "Closes the details" : "Opens the details")
            } else {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
            }

            if showDetail {
                BakeDetail(progress: progress, onCancel: onCancel, cancelling: $cancelling)
            }

        }
        .padding(.horizontal, compact ? 14 : 0)
        .padding(.vertical, compact ? 10 : 0)
        // A card floats over something. On first run there is nothing under
        // it, so the big form is the page itself and only the pill, which
        // really does sit over a chart, keeps the surface.
        .panelSurface(cornerRadius: 14, enabled: compact)
    }
}

/// One step of the work, and where it has got to.
///
/// A step that is done says what it produced. The step running says how far in
/// it is. A step not started yet is dim and says nothing, because a number
/// against work that has not begun is noise.
private struct BakeStep: View {
    enum State { case done, running, waiting }
    let state: State
    let label: String
    /// The short fact beside the label: a count, or what the step produced.
    var detail: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                case .running:
                    Image(systemName: "circle.dotted.circle").foregroundStyle(.tint)
                case .waiting:
                    Image(systemName: "circle.dotted").foregroundStyle(Chrome.muted)
                }
            }
            .font(.system(size: 12))
            .frame(width: 14)

            Text(label)
                .font(.system(size: 12, weight: state == .running ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? Chrome.muted : Chrome.ink)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Chrome.muted)
            }
            Spacer(minLength: 0)
        }
        .opacity(state == .waiting ? 0.5 : 1)
    }
}

/// What a bake is doing, in full: the bar, the steps, and the way out.
///
/// One panel in two places. It is the body of the pill at the top of the chart
/// once opened, and it is the whole first-run panel while there is no chart to
/// put a pill over. The mariner reads the same thing either way.
struct BakeDetail: View {
    let progress: BakeProgress
    let onCancel: () -> Void
    @Binding var cancelling: Bool

    /// One width in both places, so the panel that moves to the top of the
    /// chart is recognisably the panel that was in the middle of it.
    static let width: CGFloat = 320
    private var width: CGFloat { Self.width }
    private var counted: Bool { progress.total > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 6) {
                // Counted or not, the bar has to look like work. A determinate
                // bar with nothing in it reads as stuck, which is exactly what
                // the seconds of looking through a big folder looked like.
                Group {
                    if counted {
                        ProgressView(value: progress.fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                HStack {
                    Text(counted ? "\(Int(progress.fraction * 100))%" : "")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Chrome.muted)
                    Spacer()
                    Text(progress.remaining ?? "")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Chrome.muted)
                }
            }
            .frame(width: width)

            VStack(alignment: .leading, spacing: 7) {
                if progress.kind == .removing {
                    BakeStep(
                        state: counted && progress.done >= progress.total ? .done : .running,
                        label: "Removing charts",
                        detail: counted ? "\(progress.done) of \(progress.total)" : "")
                } else {
                    BakeStep(
                        state: counted ? .done : .running,
                        label: "Finding charts",
                        detail: counted ? "\(progress.total) found" : "")
                    BakeStep(
                        state: !counted ? .waiting : (progress.done < progress.total ? .running : .done),
                        label: "Importing charts",
                        detail: counted ? "\(progress.done) of \(progress.total)" : "")
                }
            }
            .frame(width: width, alignment: .leading)

            // No way out of a removal: the set is already off the list and the
            // charts are already moved aside, so a Cancel here could only stop
            // the disk being freed — which is not a choice worth offering, and
            // a button that cannot undo what it appears to undo is a lie.
            if progress.kind != .removing {
                Divider().frame(width: width)

                HStack {
                    Spacer(minLength: 0)
                    Button(cancelling ? "Stopping…" : "Cancel") {
                        cancelling = true
                        onCancel()
                    }
                    .disabled(cancelling)
                    .controlSize(.small)
                }
                .frame(width: width)
            }
        }
    }
}

/// One fact under the first-run panel's buttons: an icon and a line.
private struct EmptyStateNote<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content

    init(icon: String, text: String) where Content == Text {
        self.icon = icon
        self.content = Text(text)
    }
    init(icon: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Chrome.muted)
                .frame(width: 15)
            content
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 7)
    }
}

/// The first thing a mariner sees, before any chart is aboard.
///
/// It answers three questions in the order they are asked. What is this
/// program for. Why is it empty. What do I do now. The old panel answered only
/// the third, and answered it in file extensions.
///
/// It does not offer to download anything, because nothing here can yet. A
/// door that does not open is worse than no door, so where charts come from is
/// stated as a fact instead.
struct EmptyChartState: View {
    @ObservedObject var model: AppModel

    /// NOAA's ENC download page: the whole country, a state, or one cell.
    static let noaaDownloads = URL(string: "https://www.charts.noaa.gov/ENCs/ENCs.shtml")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "map")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 12)

            Text("No charts yet")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .padding(.bottom, 6)

            Text("Lookout draws official S-57 and S-101 ENC charts. It does not come with any, so point it at yours.")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            if let msg = model.emptyPick {
                // A folder that held nothing has to say so HERE. This page is
                // where the mariner pressed the button, and a message that
                // only appears in the settings window is a message they never
                // see.
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                    Text(msg)
                }
                .font(.system(size: 12))
                .foregroundStyle(Chrome.overscale)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                Button { model.requestOpenPicker() } label: {
                    Label("Choose Charts…", systemImage: "folder")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)

                Text("or drop them anywhere in this window")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
            }
            .padding(.bottom, 14)

            // What actually works, in the words of what the mariner has in
            // hand rather than the words of the file format.
            // Where the charts come from goes first: a mariner with none needs
            // that before they need a list of file extensions.
            // One Text, not a row of them: pieces in an HStack each wrap on
            // their own and the sentence comes apart. The URL is written out
            // rather than interpolated, because markdown is only parsed in a
            // literal and an interpolated link does not open.
            EmptyStateNote(icon: "globe.americas") {
                Text("NOAA publishes every United States chart at no cost, at [charts.noaa.gov](https://www.charts.noaa.gov/ENCs/ENCs.shtml). Most other offices sell theirs.")
            }
            EmptyStateNote(
                icon: "square.stack.3d.up",
                text: "A folder of cells (.000), prepared charts (.pmtiles), imagery (.mbtiles) or BSB/KAP sheets. Cells and sheets are converted once on the way in, a few seconds each.")

            // Last, and set apart. It is the one thing on this page that is
            // not about getting started, and the one a mariner must not skim.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Chrome.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOT FOR NAVIGATION")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(Chrome.ink)
                    Text("By importing charts you accept that Lookout is a prototype and not a certified navigation system, and that the charts it prepares are processed for display and are not the official ENC. They do not meet chart carriage regulations. You remain responsible for the safe navigation of your vessel and for keeping clear of every danger. Verify everything shown here against official, up-to-date charts and publications, and keep a paper backup.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Chrome.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    // NOAA's own terms, in their words. They apply to their
                    // charts whoever prepared them.
                    Text("NOAA ENC® charts come from the NOAA Office of Coast Survey and are updated weekly on a best-efforts basis; you are responsible for holding the current edition and the latest updates. NOAA makes no warranty and assumes no liability for their use. See the [NOAA ENC User Agreement](https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml).")
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Chrome.amber.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Chrome.amber.opacity(0.55), lineWidth: 1))
            .padding(.top, 10)

            if !model.chartSets.isEmpty {
                Divider().padding(.vertical, 12)
                Text("Switched off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Chrome.muted)
                ForEach(model.chartSets) { set in
                    Toggle(set.name, isOn: Binding(
                        get: { set.on },
                        set: { model.setChartSetOn(set.path, $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))
                }
            }
        }
        .frame(maxWidth: 430, alignment: .leading)
    }
}
