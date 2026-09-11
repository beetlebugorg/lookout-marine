//  ChartPreviews.swift: one tile of each chart, for the chart list.
//
//  The engine draws one chart at a time, so a list of six cannot ask for six
//  renders. The core reads each style for where its tiles come from
//  (lookout_chart_link_preview_url) and this fetches one of them.
//
//  Every chart is pictured at the SAME point, the one the mariner is looking
//  at, so what differs between the tiles is the portrayal.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class ChartPreviews {
    /// The picture for each link url, once it has arrived.
    private(set) var images: [String: Image] = [:]
    /// Links whose style names no raster tiles. They draw their kind instead.
    private(set) var unavailable: Set<String> = []
    /// Links being drawn now, so a card says it is working.
    private(set) var drawing: Set<String> = []

    /// The zoom the tiles are fetched at. Low enough that one tile holds a
    /// recognisable stretch of coast, high enough to carry a chart's detail.
    private static let zoom = 9

    private var inFlight: Set<String> = []
    /// A second engine with no window, for drawing charts the mariner has not
    /// picked. Opened at the first preview and closed with the view.
    private let offscreen = ChartPreviewEngine()
    private var rendering: Task<Void, Never>?
    /// The point every picture was fetched at. The mariner moves, and a
    /// preview of water they have left says nothing about the style.
    private var center: (lon: Double, lat: Double)?

    weak var engine: (any ChartLinkEngine)?

    func bind(to engine: (any ChartLinkEngine)?) {
        self.engine = engine
    }

    /// The chart being drawn, as the engine draws it. The key is the link's
    /// url, or "" for Lookout's own chart.
    ///
    /// The one true picture of a publisher's portrayal. A style that layers
    /// its own work over somebody else's raster base otherwise previews as
    /// that base, another map under this publisher's name.
    @discardableResult
    func capture(active: String?) -> Bool {
        guard let engine, let shot = engine.snapshot() else { return false }
        images[active ?? ""] = shot
        unavailable.remove(active ?? "")
        return true
    }

    /// Keep capturing the chart being drawn while it settles. A link resolves
    /// its style and fetches its tiles first, so the frame at the moment it
    /// was picked is the chart it replaced.
    ///
    /// `drawing` says whether that chart is still the one on screen. A style
    /// the core refuses drops the pick, and the frame then holds whatever came
    /// back: filing it under the link that failed puts another chart's picture
    /// under its name.
    func watch(active: String?, drawing: @escaping () -> Bool) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(900))
            if Task.isCancelled { return }
            guard drawing() else { return }
            capture(active: active)
        }
    }

    /// Draw every chart that has no picture, one at a time, on an engine of
    /// its own. Nothing here changes the chart on screen.
    func renderAll(_ links: [String], lon: Double, lat: Double, zoom: Double) {
        rendering?.cancel()
        // What was drawn on a previous run, at once. A style takes seconds to
        // resolve, fetch and draw, and paying that on every visit to the list
        // is the difference between a picture and a wait.
        for url in links where images[url] == nil {
            if let kept = ChartPreviewEngine.cached(link: url, lon: lon, lat: lat, zoom: zoom) {
                images[url] = kept
            }
        }
        rendering = Task { [weak self] in
            for url in links {
                guard let self, !Task.isCancelled else { return }
                if self.images[url] != nil { continue }
                self.drawing.insert(url)
                defer { self.drawing.remove(url) }
                guard let shot = await self.offscreen.render(
                    link: url, lon: lon, lat: lat, zoom: zoom)
                else {
                    self.unavailable.insert(url)
                    continue
                }
                self.images[url] = shot
                self.unavailable.remove(url)
            }
            self?.offscreen.close()
        }
    }

    /// Stop drawing and close the second engine.
    func stopRendering() {
        rendering?.cancel()
        rendering = nil
        offscreen.close()
    }

    /// Ask for what is missing. Called when the chart list goes on screen.
    ///
    /// The core reads each style over the network, so a template is rarely
    /// there on the first ask. This waits for them rather than deciding on the
    /// first answer that a chart has no picture.
    func refresh(_ links: [String]) {
        watch?.cancel()
        watch = Task { [weak self] in
            for attempt in 0..<Self.tries {
                guard let self else { return }
                if self.ask(links) { return }
                if attempt == 0 { self.engine?.previewChartLinks() }
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
            }
            // Out of patience: whatever has no picture draws its kind.
            guard let self else { return }
            for url in links where self.images[url] == nil { self.unavailable.insert(url) }
        }
    }

    /// Fetch what the core can name. True once every link is answered.
    private func ask(_ links: [String]) -> Bool {
        guard let engine, let now = engine.viewCenter() else { return false }
        if let was = center, !sameTile(was, now) {
            images.removeAll()
            unavailable.removeAll()
        }
        center = now
        var settled = true
        for url in links {
            // A picture the engine drew stands. It is this chart, rather than
            // one of the sources it draws from.
            if images[url] != nil || inFlight.contains(url) {
                if images[url] == nil { settled = false }
                continue
            }
            guard let tile = engine.chartLinkPreviewURL(
                url, lon: now.lon, lat: now.lat, zoom: Self.zoom)
            else {
                settled = false
                continue
            }
            unavailable.remove(url)
            fetch(tile, for: url)
            settled = false
        }
        return settled
    }

    /// How many times to look for a template before giving up on one.
    private static let tries = 20
    private var watch: Task<Void, Never>?

    /// True while both points fall in the same preview tile, so a mariner
    /// working the chart does not re-fetch every list on every pan.
    private func sameTile(_ a: (lon: Double, lat: Double),
                          _ b: (lon: Double, lat: Double)) -> Bool {
        tileXY(a) == tileXY(b)
    }

    private func tileXY(_ p: (lon: Double, lat: Double)) -> [Int] {
        let n = pow(2.0, Double(Self.zoom))
        let x = (p.lon + 180) / 360 * n
        let lat = min(max(p.lat, -85.05112878), 85.05112878) * .pi / 180
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n
        return [Int(x.rounded(.down)), Int(y.rounded(.down))]
    }

    /// Tile bytes as something SwiftUI draws. Both platforms decode a PNG or
    /// a JPEG here; a publisher serving anything else draws no picture.
    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        guard let native = NSImage(data: data) else { return nil }
        return Image(nsImage: native)
        #else
        guard let native = UIImage(data: data) else { return nil }
        return Image(uiImage: native)
        #endif
    }

    private func fetch(_ tile: String, for url: String) {
        guard let request = URL(string: tile) else {
            unavailable.insert(url)
            return
        }
        inFlight.insert(url)
        Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.inFlight.remove(url) } }
            var req = URLRequest(url: request)
            req.timeoutInterval = 20
            // A public tile host asks who is calling, and some refuse a
            // request that does not say.
            req.setValue("LookoutMarine", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  let http = response as? HTTPURLResponse, http.statusCode / 100 == 2,
                  let image = Self.image(from: data)
            else {
                await MainActor.run { [weak self] in self?.unavailable.insert(url) }
                return
            }
            await MainActor.run { [weak self] in self?.images[url] = image }
        }
    }
}
