//  NoaaWindow.swift — picking NOAA's waters, in a window of its own.
//
//  The picker is a map of the United States with a region under the cursor. In
//  the settings form it came up as a sheet over a 660pt window, which left the
//  map a column too narrow to tell the Gulf from the Atlantic. It opens beside
//  the form instead, at the width the map was drawn for.
//
//  The same window controller shape the mariner form uses: the app owns the
//  window, and one instance serves every time it is asked for.

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class NoaaWindowController: NSObject, NSWindowDelegate {
    static let shared = NoaaWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let picker = NoaaPickerSheet(model: model, noaa: model.noaa) { [weak self] in
            self?.window?.performClose(nil)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "NOAA Charts"
        window.contentView = NSHostingView(rootView: picker)
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false // the controller keeps it
        window.setFrameAutosaveName("noaa-charts")
        window.delegate = self
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
