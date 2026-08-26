//  Licenses.swift — the licenses screen.
//
//  lookout_licenses_json carries the list, baked in from
//  vendor/licenses/licenses.json, so nothing here needs a connection.
//
//  Search and the group headings appear above twelve entries and not below:
//  under that the headings outnumber the rows.
//
//  A license text is never truncated or reflowed by anything but the width of
//  the view. The app's own entry is not a component and stays out of the count.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - The manifest

/// One component the build carries.
struct LicenseComponent: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let group: String
    let summary: String
    /// Empty when the build could not determine the terms.
    let license: String
    /// A short form for a tight column. Empty when it is no shorter than `license`.
    let licenseShort: String
    let licenseNote: String
    let version: String
    let commit: String
    let pinnedIn: String
    let copyright: String
    let url: String
    let shells: [String]
    let text: String
    /// The component's NOTICE file, empty when it ships none.
    let notice: String

    enum CodingKeys: String, CodingKey {
        case id, name, group, summary, license, version, commit, copyright, url, shells, text, notice
        case licenseShort = "license_short"
        case licenseNote = "license_note"
        case pinnedIn = "pinned_in"
    }

    var licenseLabel: String { license.isEmpty ? "Not resolved" : license }

    /// The short form for the list column, falling back to the full label.
    var licenseColumnLabel: String {
        if license.isEmpty { return "Not resolved" }
        return licenseShort.isEmpty ? license : licenseShort
    }

    /// The version, or the commit when a component is pinned to one.
    var pinLabel: String {
        if !version.isEmpty { return version }
        return String(commit.prefix(7))
    }

}

/// This app's own terms.
struct LicenseApp: Decodable {
    let name: String
    let summary: String
    let license: String
    let copyright: String
    let url: String
    let text: String
}

struct LicenseManifest: Decodable {
    let app: LicenseApp
    let components: [LicenseComponent]

    /// The shell this build is, as the manifest names it.
    static var shell: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    /// The components this build carries. Static in the core, so it needs no
    /// chart open.
    static let current: LicenseManifest? = {
        var len = 0
        let p = lookout_licenses_json(&len)
        guard len > 0 else { return nil }
        let data = Data(UnsafeRawBufferPointer(start: p, count: len))
        guard let m = try? JSONDecoder().decode(LicenseManifest.self, from: data) else { return nil }
        return LicenseManifest(app: m.app, components: m.components.filter { $0.shells.contains(shell) })
    }()

    /// The groups in the order the manifest lists them, each with its rows.
    var groups: [(name: String, items: [LicenseComponent])] {
        var order: [String] = []
        var byGroup: [String: [LicenseComponent]] = [:]
        for c in components {
            if byGroup[c.group] == nil { order.append(c.group) }
            byGroup[c.group, default: []].append(c)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

}

// MARK: - What a row can be

/// The screen's selection: this app, or one of the components.
enum LicenseSelection: Hashable {
    case app
    case component(String)
}

/// Held outside the view so the window can be opened on a named entry.
@MainActor
final class LicensesNav: ObservableObject {
    static let shared = LicensesNav()
    @Published var selection: LicenseSelection? = .app
}

// MARK: - The screen

/// The screen, or a line saying why there is none. An entry point that does
/// nothing would hide a build whose list will not decode.
struct LicensesRoot: View {
    var body: some View {
        if let manifest = LicenseManifest.current {
            LicensesView(manifest: manifest)
        } else {
            ContentUnavailableView("License list unavailable",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("This build's list could not be read."))
                .navigationTitle("Licenses")
        }
    }
}

/// The list and the detail. macOS puts them side by side in their own window;
/// iOS pushes the detail from the list.
struct LicensesView: View {
    let manifest: LicenseManifest
    @ObservedObject private var nav = LicensesNav.shared
    @State private var search = ""

    private var searchable: Bool { manifest.components.count > 12 }
    private var grouped: Bool { manifest.components.count > 12 }

    /// Every row that matches the search, in manifest order, ungrouped.
    private var flat: [LicenseComponent] { groups.flatMap(\.items) }

    private var groups: [(name: String, items: [LicenseComponent])] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return manifest.groups }
        return manifest.groups.compactMap { g in
            let hits = g.items.filter {
                $0.name.lowercased().contains(term)
                || $0.id.lowercased().contains(term)
                || $0.summary.lowercased().contains(term)
                || $0.license.lowercased().contains(term)
            }
            return hits.isEmpty ? nil : (g.name, hits)
        }
    }

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            detail
        }
        #else
        sidebar
        #endif
    }

    // MARK: List

    /// The selection the list draws highlighted. Only the Mac has one: there
    /// the selection IS the navigation, and the detail follows it. iOS pushes
    /// instead, so a bound selection only left the app's own row sitting
    /// permanently grey, as though it had been tapped and nothing happened.
    private var listSelection: Binding<LicenseSelection?> {
        #if os(macOS)
        return $nav.selection
        #else
        return .constant(nil)
        #endif
    }

    private var sidebar: some View {
        let list = List(selection: listSelection) {
            Section("This app") {
                rowLink(.app) {
                    row(name: manifest.app.name,
                        summary: manifest.app.copyright,
                        trailing: manifest.app.license,
                        pin: Self.appVersion,
                        strong: true)
                }
            }

            if grouped {
                ForEach(groups, id: \.name) { g in
                    Section(g.name) { componentRows(g.items) }
                }
            } else {
                Section("Components") {
                    componentRows(flat)
                }
            }

            if groups.isEmpty && !search.isEmpty {
                Text("Nothing matches “\(search)”.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Licenses")
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        #endif

        let searched = Group {
            if searchable {
                list.searchable(text: $search, prompt: "Search \(manifest.components.count) components")
            } else {
                list
            }
        }

        return searched
    }

    @ViewBuilder
    private func componentRows(_ items: [LicenseComponent]) -> some View {
        ForEach(items) { c in
            rowLink(.component(c.id)) {
                row(name: c.name,
                    summary: c.summary,
                    trailing: c.licenseColumnLabel,
                    pin: c.pinLabel,
                    unresolved: c.license.isEmpty)
            }
        }
    }

    /// How a row reaches its detail: the split view's selection on the Mac,
    /// a push on the phone.
    ///
    /// The push carries its destination rather than a value. A value-based
    /// link needs the enclosing NavigationStack to hold this type, and the one
    /// the licenses land in is the settings form's, whose path is [String] for
    /// its own sections. A LicenseSelection has nowhere to go in that path, so
    /// every row was inert: it highlighted on touch and stayed where it was.
    @ViewBuilder
    private func rowLink(_ sel: LicenseSelection, @ViewBuilder label: () -> some View) -> some View {
        #if os(macOS)
        label().tag(sel)
        #else
        NavigationLink {
            detailFor(sel).navigationTitle(titleFor(sel)).navigationBarTitleDisplayMode(.inline)
        } label: {
            label()
        }
        #endif
    }

    /// One row: what it is on the left, its license and pin on the right.
    private func row(name: String, summary: String, trailing: String, pin: String,
                     strong: Bool = false, unresolved: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(strong ? .semibold : .regular)
                if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(unresolved ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if !pin.isEmpty {
                    Text(pin).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let selection = nav.selection {
            detailFor(selection)
        } else {
            ContentUnavailableView("No component selected", systemImage: "doc.plaintext")
        }
    }

    @ViewBuilder private func detailFor(_ sel: LicenseSelection) -> some View {
        switch sel {
        case .app:
            AppLicenseDetail(app: manifest.app)
        case .component(let id):
            if let c = manifest.components.first(where: { $0.id == id }) {
                ComponentLicenseDetail(component: c)
            } else {
                ContentUnavailableView("No component selected", systemImage: "doc.plaintext")
            }
        }
    }

    private func titleFor(_ sel: LicenseSelection) -> String {
        switch sel {
        case .app: return manifest.app.name
        case .component(let id): return manifest.components.first { $0.id == id }?.name ?? "Licenses"
        }
    }

    // MARK: Facts about this build

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static var platformName: String {
        #if os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }
}

// MARK: - The detail panes

/// This app's own terms.
private struct AppLicenseDetail: View {
    let app: LicenseApp

    var body: some View {
        LicenseScroll {
            LicenseHeading(name: app.name, summary: app.summary)
            LicenseFacts(rows: [
                ("License", app.license, false),
                ("Version", LicensesView.appVersion, true),
                ("Copyright", app.copyright, false),
            ])
            UpstreamBlock(url: app.url)
            LicenseBody(title: app.license, note: "", text: app.text)
        }
        .navigationTitle(app.name)
    }
}

/// One component: what it is, how it is pinned, and its terms.
private struct ComponentLicenseDetail: View {
    let component: LicenseComponent

    private var facts: [(String, String, Bool)] {
        var rows: [(String, String, Bool)] = [("License", component.licenseLabel, false)]
        if !component.version.isEmpty { rows.append(("Version", component.version, true)) }
        if !component.commit.isEmpty { rows.append(("Commit", component.commit, true)) }
        rows.append(("Pinned in", component.pinnedIn, true))
        rows.append(("Copyright", component.copyright, false))
        return rows
    }

    var body: some View {
        LicenseScroll {
            LicenseHeading(name: component.name, summary: component.summary)

            if component.license.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("License not resolved").fontWeight(.semibold)
                        Text(component.licenseNote).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            LicenseFacts(rows: facts)
            UpstreamBlock(url: component.url)
            if !component.notice.isEmpty {
                NoticeBlock(text: component.notice)
            }
            LicenseBody(title: component.licenseLabel,
                        note: component.license.isEmpty ? "" : component.licenseNote,
                        text: component.text)
        }
        .navigationTitle(component.name)
    }

}

// MARK: - Detail pieces

/// The detail pane's scroll. The license text sits in the page rather than in
/// a box that scrolls inside it.
private struct LicenseScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        // Forces SwiftUI to clear the content past the toolbar's glass
        // material instead of letting the first rows render (and blur)
        // underneath it.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 0) }
    }
}

private struct LicenseHeading: View {
    let name: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.title2).fontWeight(.semibold)
            if !summary.isEmpty {
                Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The label-and-value rows. A commit, a path or a version is monospaced and
/// selectable.
private struct LicenseFacts: View {
    /// Label, value, and whether the value is a literal to be copied.
    let rows: [(String, String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(r.0)
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(r.1)
                        .font(r.2 ? .system(.callout, design: .monospaced) : .callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The upstream address as selectable text, with its own copy button. Opening
/// it needs a connection; copying it does not.
private struct UpstreamBlock: View {
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upstream")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let real = URL(string: url) {
                    Link(url, destination: real)
                } else {
                    Text(url).textSelection(.enabled)
                }
                Button {
                    copy(url)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .help("Copy address")
                .accessibilityLabel("Copy address")
                Spacer(minLength: 0)
            }
            .font(.system(.callout, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The component's NOTICE. A separate obligation from the license, so it sits
/// above it.
private struct NoticeBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOTICE")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The license itself, whole.
private struct LicenseBody: View {
    let title: String
    let note: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if text.isEmpty {
                Text("No license text.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(title.uppercased())
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if !note.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// The clipboard, on whichever platform this is.
private func copy(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}

// MARK: - The window

#if os(macOS)
/// Its own window rather than a settings pane: the license text runs at its
/// own width, and the About panel opens the same window.
@MainActor
final class LicensesWindowController {
    static let shared = LicensesWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Licenses"
        window.contentView = NSHostingView(rootView: LicensesRoot())
        // Wide enough that an 80-column license needs no reflowing.
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false // the controller keeps it
        window.setFrameAutosaveName("licenses")
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Select one component by id, or this app's own entry for an empty id.
    func select(_ id: String) {
        LicensesNav.shared.selection = id.isEmpty ? .app : .component(id)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}
#endif
