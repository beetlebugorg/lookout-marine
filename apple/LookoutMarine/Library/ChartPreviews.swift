//  ChartPreviews.swift: a picture of each chart, for a list of charts.
//
//  The core draws the pictures (lookout_chart_link_picture). This keeps what
//  came back, by link url, for the views. A picture still being drawn comes
//  back when the chart-link list model's revision changes.

import SwiftUI

@MainActor
@Observable
final class ChartPreviews {
    /// The picture for each link url, and "" for Lookout's own chart.
    private(set) var images: [String: Image] = [:]
    /// Links whose picture the core is still drawing.
    private(set) var drawing: Set<String> = []

    weak var engine: (any ChartLinkEngine)?

    func bind(to engine: (any ChartLinkEngine)?) {
        self.engine = engine
    }

    /// Ask the core for each chart's picture at one point and size, in
    /// pixels. The core keeps what it drew, so asking again is a copy.
    func ask(_ urls: [String], kind: ChartPictureKind, lon: Double, lat: Double,
             zoom: Double, width: Int, height: Int) {
        guard let engine else { return }
        for url in urls {
            switch engine.chartLinkPicture(url, kind: kind, lon: lon, lat: lat, zoom: zoom,
                                           width: width, height: height) {
            case .ready(let image):
                images[url] = image
                drawing.remove(url)
            case .pending:
                drawing.insert(url)
            case .none:
                images[url] = nil
                drawing.remove(url)
            }
        }
    }

    /// Stop drawing. Called when the list leaves the screen.
    func stop() {
        engine?.cancelChartLinkPictures()
        drawing.removeAll()
    }
}
