//  SettingsView.swift — the mariner settings, and the navigation around them.
//
//  A SIDEBAR of sections on macOS, the same sections in the same order on iOS:
//  pushed one at a time on a phone, stood beside the list on an iPad. One
//  MarinerSettings behind all of them.
//
//  The sidebar is a slot list, not a fixed menu. The four core sections and
//  Advanced always exist; Vessels, Alarms and Connections appear only while
//  something puts settings in them, and today that something is a plugin. The
//  mariner is never told which: AIS settings are chart settings.

import SwiftUI

/// One entry in the sidebar. `core` sections are the app's own and are always
/// listed; the rest are listed only while they hold something. The ids are the
/// core's section names (src/plugin/host.zig, `Tab`), so a plugin and the shell
/// mean the same thing by "alarms".
struct SettingsSection: Identifiable {
    let id: String
    let label: String
    let icon: String
    let core: Bool

    /// Every section, in the order the sidebar shows them. Advanced is last:
    /// it is where anything unclaimed lands.
    static let all: [SettingsSection] = [
        .init(id: "display", label: "Display", icon: "paintpalette", core: true),
        .init(id: "depths", label: "Depths", icon: "water.waves", core: true),
        .init(id: "text", label: "Text", icon: "textformat", core: true),
        .init(id: "charts", label: "Charts", icon: "map", core: true),
        .init(id: "vessels", label: "Vessels", icon: "ferry", core: false),
        .init(id: "alarms", label: "Alarms", icon: "bell", core: false),
        .init(id: "connections", label: "Connections", icon: "antenna.radiowaves.left.and.right", core: false),
        // Plugins is the one section that talks ABOUT plugins: install,
        // grants, uninstall. It is the app's own, not a slot a schema fills.
        .init(id: "plugins", label: "Plugins", icon: "puzzlepiece.extension", core: true),
        .init(id: "advanced", label: "Advanced", icon: "slider.horizontal.3", core: true),
    ]
}



struct SettingsView: View {
    @Bindable var model: AppModel
    @StateObject private var m = MarinerSettings()
    @StateObject private var p: PluginSettings

    /// The Mac's window controller hands in the PluginSettings it holds, so it
    /// can stop the poll and the mDNS browse when the window closes. On iOS the
    /// form is a sheet and its own onDisappear is the whole story.
    @MainActor
    init(model: AppModel, plugins: PluginSettings? = nil) {
        self.model = model
        let made = plugins ?? PluginSettings()
        _p = StateObject(wrappedValue: made)
    }

    var body: some View {
        content
            .onAppear {
                m.bind(to: model.controller)
                p.bind(to: model.controller)
                // A connection's line moves on its own while the window is up.
                p.startPolling()
            }
            .onDisappear { p.stopPolling() }
            #if os(iOS)
            // The chart pickers, presented BY THE FORM. A sheet cannot present
            // another sheet from the window's own view, which is where the
            // chart's importers hang, so Add Charts had to dismiss the form
            // and time a re-present. These come up over the form and leave it
            // where it was.
            .fileImporter(isPresented: $model.showSettingsImporter,
                          allowedContentTypes: [.item, .folder]) { result in
                if case .success(let url) = result { model.openImported(url) }
            }
            // On its OWN view. Two .fileImporter modifiers on one view collide —
            // SwiftUI presents only the outer, so Add Charts silently did
            // nothing. A background node keeps the two importers apart.
            .background(
                Color.clear.fileImporter(isPresented: $model.showSettingsRasterImporter,
                              allowedContentTypes: [.item, .folder],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { model.importRasterCharts(urls) }
                }
            )
            // A third importer, so a third background node — see above.
            .background(
                Color.clear.fileImporter(isPresented: $model.showSettingsStyleImporter,
                              allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { model.chartLinks.importStyle(url) }
                }
            )
            // And a fourth, for a plugin package. Not filtered to the exported
            // type: a .lkplug that reached the device through a service that
            // does not know the type arrives as data, and greying it out would
            // leave the mariner unable to install a file they are holding.
            .background(
                Color.clear.fileImporter(isPresented: $model.showSettingsPluginImporter,
                              allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { model.importPluginPackage(url) }
                }
            )
            #endif
    }

    /// The one thing the whole window promises. It stands under the list of
    /// sections rather than repeating itself in every one of them.
    private static let promise = "Applies at once · kept for next launch"

    private var sections: [SettingsSection] {
        var filled = p.populatedTabs
        #if os(iOS)
        // A plugin that declares a table and no settings still fills the
        // section its table is opened from, since on a touch device that row is
        // the only way to reach it.
        filled.formUnion(model.plugins.tables.map { $0.menu.lowercased() })
        #endif
        return SettingsSection.all.filter { s in
            return s.core || filled.contains(s.id)
        }
    }

    /// The section on screen. A section can go away — a plugin that never came
    /// up takes its section with it — so a stale selection falls back.
    private var selected: String {
        sections.contains { $0.id == model.settingsTab } ? model.settingsTab : "display"
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        NavigationSplitView {
            List(sections, selection: $model.settingsTab) { s in
                Label(s.label, systemImage: s.icon)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 220)
            // No collapse control: the list IS the navigation, and a window
            // with it hidden has no way back to another section.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                Text(Self.promise)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            pane(selected)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 560)
        #else
        // iOS never had this sidebar. It had a TabView, and a tab bar holds
        // FOUR of nine sections before the rest go behind More — on the
        // 13-inch iPad as well as the phone — so Connections, the one a
        // mariner opens at the dock with a gateway in front of them, was two
        // taps down an overflow menu with no title on the page it landed on.
        //
        // The same sections in the same order, in this platform's own
        // navigation instead: a phone pushes a section onto a stack, and a
        // sheet wide enough to hold both columns stands the list beside the
        // pane, which is the shape of the Mac window.
        GeometryReader { geo in
            if geo.size.width >= Self.splitWidth {
                splitLayout
            } else {
                stackLayout
            }
        }
        #endif
    }

    #if os(iOS)
    /// Narrower than this and two columns leave the pane nothing to stand in,
    /// so the sections push instead. An iPhone sheet is 402pt wide; the
    /// settings sheet on a 13-inch iPad is 571pt.
    private static let splitWidth: CGFloat = 500

    /// A phone: the list of sections, and one section pushed onto it.
    ///
    /// The path IS `settingsTab` — one section deep, or none while the list
    /// itself is on screen — so the screenshot hook's `settings:connections`
    /// comes up already on Connections, and Back puts the list back.
    private var stackLayout: some View {
        NavigationStack(path: pushedSection) {
            List {
                Section {
                    ForEach(sections) { s in
                        NavigationLink(value: s.id) {
                            Label(s.label, systemImage: s.icon)
                        }
                    }
                } footer: {
                    Text(Self.promise).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Mariner Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                pane(id)
                    .navigationTitle(sectionLabel(id))
                    .navigationBarTitleDisplayMode(.inline)
                    // Every pane carries its own: a pushed view does not
                    // inherit the root's toolbar, and a mariner two taps into
                    // Connections must be able to shut the form from there.
                    .toolbar { doneItem }
            }
            .toolbar { doneItem }
        }
    }

    /// An iPad: the list beside the pane, the Mac window's own shape.
    private var splitLayout: some View {
        NavigationSplitView {
            List(sections, selection: sidebarSelection) { s in
                Label(s.label, systemImage: s.icon)
            }
            .navigationTitle("Mariner Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            // No collapse control, for the Mac window's reason: the list IS
            // the navigation, and a sheet with it hidden has no way back to
            // another section.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                Text(Self.promise)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar { doneItem }
        } detail: {
            NavigationStack {
                pane(selected)
                    .navigationTitle(sectionLabel(selected))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // A SHEET IS COMPACT EVEN ON A 13-INCH IPAD, and a compact split view
        // collapses to a stack. The sheet was measured above and is wide
        // enough for two columns, so it says so.
        .environment(\.horizontalSizeClass, .regular)
    }

    /// The stack's path: the section on screen, or nothing while the list is.
    private var pushedSection: Binding<[String]> {
        Binding(
            get: { sections.contains { $0.id == model.settingsTab } ? [model.settingsTab] : [] },
            set: { model.settingsTab = $0.last ?? "" }
        )
    }

    /// The sidebar's selection. `selected` already falls back when a section
    /// goes away with the plugin that filled it, and the pane follows the same
    /// value, so the two can never disagree.
    private var sidebarSelection: Binding<String?> {
        Binding(get: { selected }, set: { model.settingsTab = $0 ?? selected })
    }

    /// A section's own name, for the title of its pane. Until now a pushed
    /// pane carried nothing but a floating back chevron.
    private func sectionLabel(_ id: String) -> String {
        SettingsSection.all.first { $0.id == id }?.label ?? "Settings"
    }

    /// The sheet's Done. It came from the presenting view's NavigationStack
    /// while that view owned the container; the form owns it now.
    @ToolbarContentBuilder private var doneItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { model.showSettings = false }
        }
    }
    #endif

    /// One section's form: the app's own settings for it, then whatever a
    /// plugin contributed to the same section.
    @ViewBuilder private func pane(_ id: String) -> some View {
        Form {
            switch id {
            case "display": DisplaySections(m: m)
            case "depths": DepthsSections(m: m)
            case "text": SymbolsSections(m: m)
            case "charts": ChartsSections(model: model)
            case "plugins": PluginsManageSections(p: p, model: model)
            case "advanced": AdvancedSections(m: m)
            default: EmptyView()
            }
            PluginSections(p: p, tab: id)
            PluginListSections(p: p, tab: id)
            #if os(iOS)
            // The Mac opens a declared table from the menu bar. A touch device
            // has none, so the declaration becomes a row here.
            PluginTableRows(model: model, tab: id)
            #endif
        }
        .formStyle(.grouped)
    }
}
