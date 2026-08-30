//  PluginConsentSheet.swift — what a .lkplug will be able to do.
//
//  Every install entry point lands here: name and id, version, then one
//  sentence per capability in the core's own wording. Nothing touches the disk
//  until Install; Cancel deletes nothing. On a reinstall the delta is called
//  out, downgrades included.

import SwiftUI

/// What lookout_plugin_inspect said about one package: everything the consent
/// sheet shows, or the sentence the package was refused with.
struct PluginPackage: Identifiable {
    let path: String
    let pkgID: String
    let name: String
    let version: String
    /// One sentence per capability, in the core's words and order.
    let sentences: [String]
    /// The running copy's version, when this id is already loaded.
    let installedVersion: String?
    let installedOrigin: String?
    /// The grant delta against the running copy, as consent sentences.
    let adds: [String]
    let drops: [String]
    let downgrade: Bool
    let error: String?

    var id: String { path }
    var isReinstall: Bool { installedVersion != nil }

    static func parse(_ json: String, path: String) -> PluginPackage {
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let installed = o["installed"] as? [String: Any]
        return PluginPackage(
            path: path,
            pkgID: o["id"] as? String ?? "",
            name: o["name"] as? String ?? "",
            version: o["version"] as? String ?? "",
            sentences: o["sentences"] as? [String] ?? [],
            installedVersion: installed?["version"] as? String,
            installedOrigin: installed?["origin"] as? String,
            adds: installed?["adds"] as? [String] ?? [],
            drops: installed?["drops"] as? [String] ?? [],
            downgrade: installed?["downgrade"] as? Bool ?? false,
            error: o["error"] as? String
        )
    }
}



/// The consent sheet: who this is, what it will be able to do, Install or
/// Cancel. On a reinstall the delta is called out, downgrades included.
struct PluginConsentSheet: View {
    var model: AppModel
    let pkg: PluginPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: pkg.name)
                        .font(.title3.weight(.semibold))
                    Text(verbatim: pkg.pkgID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !pkg.version.isEmpty {
                    Text("Version \(pkg.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let was = pkg.installedVersion {
                Label {
                    Text(reinstallNote(was))
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(pkg.downgrade ? Color.orange : Color.secondary)
                }
                .font(.callout)
            }

            Divider()

            Text(pkg.isReinstall ? "After this install it can:" : "This plugin can:")
                .font(.subheadline.weight(.semibold))
            if pkg.sentences.isEmpty {
                Text("This plugin only draws its own settings pages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                sentenceList(pkg.sentences, mark: "checkmark.circle", tint: .secondary)
            }

            if !pkg.adds.isEmpty {
                Text("New since the installed version:")
                    .font(.subheadline.weight(.semibold))
                sentenceList(pkg.adds, mark: "plus.circle.fill", tint: .orange)
            }
            if !pkg.drops.isEmpty {
                Text("No longer asks to:")
                    .font(.subheadline.weight(.semibold))
                sentenceList(pkg.drops, mark: "minus.circle", tint: .secondary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    model.pendingInstall = nil
                    model.dropPluginCopy()
                }
                    .keyboardShortcut(.cancelAction)
                Button("Install") { model.confirmPluginInstall() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        // 440 is the Mac panel's width. A phone is 402pt across, so a fixed
        // 440 puts a consent sentence and the Install button past the edge of
        // the screen the mariner is being asked to consent on.
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: 440)
        #endif
    }

    private func reinstallNote(_ was: String) -> String {
        let name = was.isEmpty ? "the installed copy" : "the installed version \(was)"
        var note = pkg.downgrade
            ? "Replaces \(name). This is a downgrade."
            : "Replaces \(name)."
        if pkg.installedOrigin == "developer" {
            note += " The developer copy keeps running until its override is dropped."
        }
        return note
    }

    @ViewBuilder
    private func sentenceList(_ items: [String], mark: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: mark)
                        .foregroundStyle(tint)
                    Text(verbatim: s)
                }
                .font(.callout)
            }
        }
        .padding(.leading, 2)
    }
}
