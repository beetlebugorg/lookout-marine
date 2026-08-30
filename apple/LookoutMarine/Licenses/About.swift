//  About.swift — the About panel.
//
//  The app's own panel rather than the AppKit standard one, which takes no
//  button and so cannot reach the licenses.

#if os(macOS)
import AppKit
import SwiftUI

struct AboutView: View {
    private var engine: LicenseComponent? {
        LicenseManifest.current?.components.first { $0.id == "tile57" }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text("Lookout Marine").font(.title2).fontWeight(.semibold)
                Text("Version \(LicensesView.appVersion)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if let engine, !engine.pinLabel.isEmpty {
                    Text("Chart engine \(engine.name) · \(engine.pinLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text("NOT FOR NAVIGATION")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.orange)

            HStack(spacing: 10) {
                Button("Licenses…") { LicensesWindowController.shared.show() }
                Link("Source", destination: URL(string: "https://github.com/beetlebugorg/lookout-marine")!)
                    .buttonStyle(.link)
            }

            Text("Copyright © 2026 Jeremy Collins")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 340)
    }
}

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "About Lookout Marine"
        window.contentView = NSHostingView(rootView: AboutView())
        window.isReleasedWhenClosed = false // the controller keeps it
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
