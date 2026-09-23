//  ChartController+ChartLinks.swift — an online map AS the chart.
//
//  The core's from end to end: it probes the link, inlines TileJSON sources,
//  fetches the sprite packs and keeps the list. These are the calls, and
//  ChartLinkFetch is the door they fetch through.

import Foundation
import SwiftUI

@MainActor
extension ChartController {
    // MARK: - Charts by link

    /// Add a chart by link. The core resolves it through this shell's fetcher
    /// and, on success, keeps it and selects it. Non-blocking: what happened
    /// arrives in the snapshot below.
    @discardableResult
    func addChartLink(_ link: String) -> Bool {
        guard let h = handle else { return false }
        link.withCString { lookout_chart_link_add(h, $0) }
        kick()
        return true
    }

    /// Draw one of the carried charts, or nil for Lookout's own.
    @discardableResult
    func selectChartLink(_ url: String?) -> Bool {
        guard let h = handle else { return false }
        if let url {
            url.withCString { lookout_chart_link_select(h, $0) }
        } else {
            lookout_chart_link_select(h, nil)
        }
        kick()
        return true
    }

    @discardableResult
    func removeChartLink(_ url: String) -> Bool {
        guard let h = handle else { return false }
        url.withCString { lookout_chart_link_remove(h, $0) }
        kick()
        return true
    }

    @discardableResult
    func refreshChartLink(_ url: String) -> Bool {
        guard let h = handle else { return false }
        url.withCString { lookout_chart_link_refresh(h, $0) }
        kick()
        return true
    }

    /// Hand the mariner's old UserDefaults list to the core, once. See
    /// AppModel.migrateChartLinks.
    func importChartLinks(_ json: String) {
        guard let h = handle else { return }
        json.withCString { lookout_chart_links_import(h, $0) }
    }

    /// One chart's picture, drawn by the core. A pending one restarts the
    /// frame loop, and the loop draws it.
    func chartLinkPicture(_ url: String, kind: ChartPictureKind, lon: Double, lat: Double,
                          zoom: Double, width: Int, height: Int) -> ChartPicture {
        guard let h = handle, width > 0, height > 0 else { return .none }
        let k = kind == .tile ? LOOKOUT_PICTURE_TILE : LOOKOUT_PICTURE_RENDER
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let r = url.withCString { u in
            pixels.withUnsafeMutableBufferPointer {
                lookout_chart_link_picture(h, u, Int32(k), lon, lat, zoom,
                                           Int32(width), Int32(height), $0.baseAddress)
            }
        }
        switch r {
        case LOOKOUT_PICTURE_READY:
            return Self.image(w: width, h: height, rgba: pixels).map { .ready($0) } ?? .none
        case LOOKOUT_PICTURE_PENDING:
            kick()
            return .pending
        default:
            return .none
        }
    }

    func cancelChartLinkPictures() {
        guard let h = handle else { return }
        lookout_chart_link_pictures_cancel(h)
    }

    private static func image(w: Int, h: Int, rgba: [UInt8]) -> Image? {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: space, bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent)
        else { return nil }
        #if os(macOS)
        return Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: w, height: h)))
        #else
        return Image(uiImage: UIImage(cgImage: cg))
        #endif
    }

    /// Where the chart is now. Every tile pictures the same water, so the
    /// styles are what differ between them.
    func viewCenter() -> (lon: Double, lat: Double)? {
        guard let h = handle else { return nil }
        var v = lookout_view()
        lookout_get_view(h, &v)
        return (v.lon, v.lat)
    }

    /// Everything the chart list shows, or nil while the changed flag is
    /// clear. The flag has ONE consumer, ChartLinksModel.poll.
    func chartLinksSnapshot() -> ChartLinkSnapshot? {
        guard let h = handle, lookout_chart_links_changed(h) != 0 else { return nil }
        guard let read = lookout_links_read(h), let st = lookout_links_state(read) else { return nil }
        defer { lookout_links_free(read) }
        var n = 0
        var links: [ChartLinksModel.ChartLink] = []
        if let all = lookout_links_all(read, &n) {
            links = (0..<n).compactMap { all[$0].map { ChartLinksModel.ChartLink($0.pointee) } }
        }
        // The core writes an empty url for lookout's own chart, because a url
        // is never empty.
        let active = String(cString: st.pointee.active)
        return ChartLinkSnapshot(links: links,
                                 active: active.isEmpty ? nil : active,
                                 attribution: String(cString: st.pointee.attribution),
                                 error: String(cString: st.pointee.error),
                                 busy: st.pointee.busy != 0)
    }

    /// Is a publisher's style the one being drawn?
    var altChartStyleActive: Bool {
        guard let h = handle else { return false }
        return lookout_alt_chart_style_active(h) != 0
    }
}
