//  TextSection.swift — feature names, light descriptions, and the symbols.

import SwiftUI


// MARK: - Text & Symbols

struct SymbolsSections: View {
    @ObservedObject var m: MarinerSettings
    /// The label languages the open charts state, from the chart model.
    var languages: [String] = []

    private var choice: MarinerSettings.LanguageChoice {
        MarinerSettings.languageChoice(for: languages)
    }

    /// What the footer says about the name language, which depends on what the
    /// open charts offer. A library with nothing to offer gets no footer, so
    /// the section does not explain a row that is not there.
    private var nameLanguageNote: String? {
        switch choice {
        case .none:
            return nil
        case .nationalToggle:
            return "These charts carry a name in the local language beside the English one."
        case .pick:
            return "These charts name their features in more than one language."
        }
    }

    var body: some View {
        Section {
            Toggle("Feature names", isOn: $m.textNames)
            Toggle("Light descriptions", isOn: $m.showLightDescriptions)
            Toggle("Other text", isOn: $m.textOther)
            NameLanguageRow(m: m, choice: choice)
        } header: {
            Text("Text")
        } footer: {
            if let note = nameLanguageNote { Text(note).captionFooter() }
        }
        Section("Symbols") {
            Toggle("Simplified point symbols", isOn: $m.simplifiedPoints)
            SegmentedRow("Boundaries", selection: $m.boundaryStyle) {
                ForEach(MarinerBoundaryStyle.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Full light-sector lines", isOn: $m.showFullSectorLines)
        }
    }
}


/// The name-language row, in whichever form the OPEN charts call for.
///
/// A row that is always a menu would offer one entry on the S-57 charts most
/// mariners sail on, because S-57 files every national name under `und` and
/// there is nothing to choose between. Those charts get a switch instead, and
/// a library that names nothing outside English gets no row at all.
private struct NameLanguageRow: View {
    @ObservedObject var m: MarinerSettings
    let choice: MarinerSettings.LanguageChoice

    var body: some View {
        switch choice {
        case .none:
            EmptyView()
        case .nationalToggle:
            Toggle("Local language names", isOn: Binding(
                get: { m.nationalNames },
                set: { m.nationalNames = $0 }))
        case .pick(let codes):
            Picker("Name language", selection: $m.preferredLanguage) {
                Text("English").tag("")
                ForEach(offered(codes), id: \.self) { Text(MarinerSettings.languageName($0)).tag($0) }
            }
        }
    }

    /// The codes to list. A setting kept from another library names a language
    /// these charts do not, and a Picker with no tag matching its selection
    /// draws an empty row, so the standing choice is listed whether or not the
    /// charts state it.
    private func offered(_ codes: [String]) -> [String] {
        let held = m.preferredLanguage
        if held.isEmpty || codes.contains(held) { return codes }
        return codes + [held]
    }
}
