//  DisplaySection.swift — the colour scheme, the display category, soundings.

import SwiftUI


// MARK: - Display

struct DisplaySections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section {
            SchemeSwatches(scheme: $m.scheme)
        } header: {
            SectionHead("Colour scheme", hint: "⌘L steps")
        } footer: {
            Text("The palettes switch instantly. Night keeps your eyes dark-adapted.").captionFooter()
        }

        Section {
            ForEach(MarinerDisplayCategory.allCases) { c in
                ChoiceRow(title: c.label, desc: c.desc, selected: m.displayCategory == c) {
                    m.displayCategory = c
                }
            }
        } header: {
            SectionHead("Display category", hint: "⌘D adds Other")
        } footer: {
            Text("Each category contains the one before it.").captionFooter()
        }

        Section {
            ForEach(MarinerSoundings.allCases) { s in
                ChoiceRow(title: s.label, desc: s.desc, selected: m.soundings == s) {
                    m.soundings = s
                }
            }
        } header: {
            SectionHead("Soundings", hint: "⌘⇧S steps")
        }
    }
}
