//  AdvancedSection.swift — safety and quality, sizing, dates, and About.
//
//  Where anything unclaimed lands, and where the licences are reached from.

import SwiftUI


// MARK: - Advanced

struct AdvancedSections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section("Safety & Quality") {
            Toggle("Data quality overlay", isOn: $m.dataQuality)
            Toggle("Isolated dangers in shallow water", isOn: $m.showIsolatedDangersShallow)
            Toggle("Information callouts", isOn: $m.showInformCallouts)
            Toggle("Meta boundaries", isOn: $m.showMetaBounds)
            Toggle("Overscale indication", isOn: $m.showOverscale)
        }
        Section("Sizing") {
            SizeRow("Overall size", $m.sizeScale)
            SizeRow("Text size", $m.textSizeScale)
            SizeRow("Sounding size", $m.soundingSizeScale)
        }
        Section {
            Toggle("Date-dependent features", isOn: $m.dateDependent)
            Toggle("Highlight date-dependent", isOn: $m.highlightDateDependent)
            LabeledContent("View date") {
                TextField("YYYYMMDD", text: $m.dateView)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Dates")
        } footer: { Text("Leave the date empty to use today.").captionFooter() }
        AboutSection()
    }
}



private struct AboutSection: View {
    private var engine: LicenseComponent? {
        LicenseManifest.current?.components.first { $0.id == "tile57" }
    }

    private var componentCount: Int { LicenseManifest.current?.components.count ?? 0 }

    var body: some View {
        Section {
            LabeledContent("Version", value: LicensesView.appVersion)
                .monospacedDigit()
            if let engine, !engine.pinLabel.isEmpty {
                LabeledContent("Chart engine") {
                    Text("\(engine.name) · \(engine.pinLabel)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            #if os(macOS)
            // The ellipsis is the platform's promise that a window opens.
            Button {
                LicensesWindowController.shared.show()
            } label: {
                LabeledContent("Licenses…", value: componentCount > 0 ? "\(componentCount) components" : "")
            }
            .buttonStyle(.plain)
            #else
            // The phone pushes the screen, so no ellipsis.
            NavigationLink {
                LicensesRoot()
            } label: {
                LabeledContent("Licenses",
                               value: componentCount > 0 ? "\(componentCount) components" : "")
            }
            #endif
        } header: {
            Text("About")
        }
    }
}



private struct SizeRow: View {
    let title: String
    @Binding var value: Double
    init(_ title: String, _ value: Binding<Double>) { self.title = title; self._value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f×", value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: 0.5...2.0)
        }
    }
}
