//  SettingsWindow.swift — the mariner form window on macOS.
//
//  The app owns this window. It does not use the SwiftUI `Settings` scene,
//  because the scene opens only through the AppKit settings action, and that
//  action is not reachable from the chrome: the overlay is hosted outside the
//  scene tree (see ChartNSView.installOverlay), and sending the action to the
//  responder chain opened nothing. The gear bubble and ⌘, now take the same
//  route, and it works from any responder state.

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    /// Held here rather than made by the view, so closing the window can stop
    /// the poll and the mDNS browse.
    ///
    /// The controller keeps one hosting view for the life of the app and
    /// closing the window only orders it out, so whether SwiftUI runs the
    /// view's onDisappear is an implementation detail. Discovery's own rule is
    /// that a browse nobody is watching is a radio left on, and that must not
    /// depend on one.
    private let plugins = PluginSettings()

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Mariner Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model, plugins: plugins))
        window.contentMinSize = NSSize(width: 660, height: 520)
        window.isReleasedWhenClosed = false // the controller keeps it
        window.setFrameAutosaveName("mariner-settings")
        window.delegate = self
        window.setContentSize(NSSize(width: 660, height: 560))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        plugins.stopPolling()
    }
}
#endif
