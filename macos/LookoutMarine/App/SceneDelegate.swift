//  SceneDelegate.swift — the iOS entry point, and the window stack.
//
//  iOS uses the UIKit lifecycle, not WindowGroup: the gesture surface must be a
//  plain UIKit window. SwiftUI's hosting view swallows the touch stream for its
//  whole window, so a chart embedded under SwiftUI can render and never hear a
//  gesture.
//
//  Bottom to top: the INPUT window, ChartUIView in plain UIKit, whose backing
//  layer is the chart's; and the CHROME window, the SwiftUI overlay in a
//  PassThroughWindow. This file also holds the app's hardware keyboard, which
//  gets what the Mac menu bar gives.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif


#if os(iOS)

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
