//  ChartCatalog.swift: the online charts the app offers on a fresh install.
//
//  A first run has no links, so the online chart step showed an empty shelf
//  until the mariner pasted a style url. These entries give the step charts to
//  pick from on the day the app is installed.
//
//  Lookout does not run these services. A card names the publisher and shows
//  the url its tiles come from, so an entry offers a link to somebody else's
//  chart rather than a chart of Lookout's.
//
//  Each entry ships a picture of its style, rendered by ChartPreviewEngine and
//  saved into the asset catalog, so the step draws its cards before a single
//  tile is fetched. A render of the mariner's own water replaces the shipped
//  picture once it arrives.

import SwiftUI

enum ChartCatalog {
    /// One chart the app knows about before the mariner adds anything.
    struct Entry: Identifiable, Hashable {
        let name: String
        let url: String
        /// The asset catalog name of the picture shipped for this style.
        let art: String
        var id: String { url }
    }

    /// Listed in the order the step draws them.
    static let entries: [Entry] = [
        Entry(name: "Open Waters Seascape",
              url: "https://tiles.openwaters.io/seascape/style.json",
              art: "SeascapePreview"),
        Entry(name: "Open Waters Seamap",
              url: "https://tiles.openwaters.io/seamap/style.json",
              art: "SeamapPreview"),
    ]

    /// The picture shipped for this link, if the app has one.
    static func art(for url: String) -> Image? {
        guard let entry = entries.first(where: { $0.url == url }) else { return nil }
        return Image(entry.art)
    }
}
