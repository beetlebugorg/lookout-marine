//  PluginManageSection.swift — Settings > Plugins.
//
//  The one section that talks ABOUT plugins: the live status, a switch per
//  granted capability, and Uninstall for what install wrote. Everywhere else
//  their settings pass as chart settings.
//
//  Only what the mariner PUT there is listed. The shipped set is the product:
//  it takes no consent surface and never appears here.

import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif


/// Settings > Plugins, in the connection-list grammar: one calm row per
/// plugin — the name and its live status, nothing else at rest — and
/// everything about managing it behind the row's disclosure: the grant
/// switches in consent wording, one quiet line of provenance, and Uninstall
/// where install wrote the files.
///
/// Only what the mariner PUT there is listed: installed plugins, and the
/// developer copies LOOKOUT_PLUGINS brings. The shipped set is the product —
/// it takes no consent surface and never appears here.
struct PluginsManageSections: View {
    @ObservedObject var p: PluginSettings
    @ObservedObject var model: AppModel
    /// The id waiting on the uninstall confirmation, if any.
    @State private var confirmUninstall: String?

    private var managed: [PluginInfo] {
        p.plugins.filter { $0.origin != "bundled" }
    }

    var body: some View {
        Section {
            if managed.isEmpty {
                Text("No plugins installed.")
                    .foregroundStyle(.secondary)
            }
            ForEach(managed) { plug in
                PluginManageRow(p: p, pluginID: plug.id, confirmUninstall: $confirmUninstall)
            }
            #if os(macOS)
            Button { model.presentInstallPluginPanel() } label: {
                Label("Install Plugin…", systemImage: "plus")
            }
            #endif
        } header: {
            SectionHead("Plugins")
        } footer: {
            #if os(macOS)
            Text("A plugin file (.lkplug) can also be opened from the Finder or dropped on the chart. Nothing is installed before its permissions are shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
        .confirmationDialog(
            "Uninstall \(confirmName)?",
            isPresented: Binding(
                get: { confirmUninstall != nil },
                set: { if !$0 { confirmUninstall = nil } }),
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                if let id = confirmUninstall { p.uninstall(id) }
                confirmUninstall = nil
            }
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
        } message: {
            Text("Removes the plugin and everything it drew.")
        }
    }

    private var confirmName: String {
        guard let id = confirmUninstall else { return "" }
        return p.plugins.first { $0.id == id }?.name ?? id
    }
}



/// One plugin's row, in the disclosure grammar the connection rows wear.
/// Collapsed it is the name and the live status, nothing else. Expanded it
/// adds the grant switches in consent wording, one quiet line saying where
/// the copy came from and what files it reads, and — for what install wrote —
/// Uninstall at the bottom. The plugin's declared settings are NOT here: they
/// stay filed under the mariner tabs, where they read as chart settings.
struct PluginManageRow: View {
    @ObservedObject var p: PluginSettings
    let pluginID: String
    @Binding var confirmUninstall: String?
    @State private var open = false

    /// The children's inset, aligning them under the title.
    private static let childInset: CGFloat = 35

    var body: some View {
        if let plug = p.plugins.first(where: { $0.id == pluginID }) {
            VStack(alignment: .leading, spacing: 8) {
                header(plug)
                if open {
                    if plug.capabilities.isEmpty {
                        Text("This plugin only draws its own settings pages.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, Self.childInset)
                    }
                    ForEach(plug.capabilities) { c in
                        Toggle(isOn: p.grant(plug.id, c.cap)) {
                            Text(verbatim: c.sentence)
                        }
                        .padding(.leading, Self.childInset)
                    }
                    Text(verbatim: aboutLine(plug))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, Self.childInset)
                    if plug.origin == "installed" {
                        Button(role: .destructive) { confirmUninstall = plug.id } label: {
                            Label("Uninstall…", systemImage: "trash")
                        }
                        .padding(.leading, Self.childInset)
                    }
                }
            }
        }
    }

    private func header(_ plug: PluginInfo) -> some View {
        Button { open.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 9)
                Circle()
                    .fill(plug.statusTint)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: plug.name)
                    Text(verbatim: statusCaption(plug))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plug.name)
        .accessibilityHint(open ? "Hide what it may do" : "Show what it may do")
    }

    /// The status line, carrying the one provenance a mariner must see at
    /// rest: install.md wants a developer copy named where the status is.
    private func statusCaption(_ plug: PluginInfo) -> String {
        plug.origin == "developer" ? plug.statusLine + " · developer copy" : plug.statusLine
    }

    /// One quiet line about the copy itself: version, where it came from, and
    /// the files it reads. Everything that is not a control, in one breath.
    /// Bundled plugins never reach this section, so origin is two-valued here.
    private func aboutLine(_ plug: PluginInfo) -> String {
        var parts: [String] = []
        if !plug.version.isEmpty { parts.append("Version " + plug.version) }
        parts.append(plug.origin == "developer"
            ? "developer copy from LOOKOUT_PLUGINS"
            : "installed from a plugin file")
        if !plug.fileTypes.isEmpty {
            parts.append("reads \(plug.fileTypes.joined(separator: ", ")) files you open")
        }
        var line = parts.joined(separator: " · ")
        line = line.prefix(1).uppercased() + line.dropFirst()
        return line
    }
}



#if os(macOS)
extension AppModel {
    /// Settings > Plugins > Install Plugin…: a picker filtered to .lkplug,
    /// then the same consent sheet every other entry point lands on.
    func presentInstallPluginPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.title = "Install Plugin"
        panel.message = "Choose a plugin package (.lkplug). Nothing is installed before its permissions are shown."
        if let t = UTType(filenameExtension: "lkplug") {
            panel.allowedContentTypes = [t]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginPluginInstall(url.path)
    }
}
#endif
