//  ChartPreviewEngine.swift: pictures of charts, drawn off to one side.
//
//  A chart list wants a picture of every chart on it, and the engine the
//  mariner is looking at draws one chart at a time. This opens a second engine
//  with no window (lookout_open_charts, want_window 0), points it at a style,
//  ticks it until the tiles have landed, and reads the pixels back.
//
//  Nothing here reaches the chart on screen. The style goes in through
//  lookout_chart_link_draw, which keeps no link and writes no list.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ChartPreviewEngine {
    /// The size a picture is rendered at, in pixels. A card draws it about
    /// 400pt wide, and this covers that at 2x. It is also the size of the
    /// pictures in ChartCatalog, so a render replacing a shipped one is the
    /// same picture at the same sharpness.
    private static let size = (w: 960, h: 720)
    /// How long one chart has to resolve its style and fetch its tiles: the
    /// style, its sprite sheets and a screen of tiles, over the network.
    private static let patience = 70
    /// The frame loop reports idle before the style has even been asked for,
    /// so settling counts only after this many ticks.
    private static let warmup = 10
    private static let tick = Duration.milliseconds(100)

    private var handle: OpaquePointer?
    private let fetch = ChartLinkFetch()

    deinit { }

    /// A picture kept from a previous run, if there is one for this chart at
    /// this water. Reading one costs a file open, so a list of charts looked
    /// at before draws at once.
    static func cached(link: String, lon: Double, lat: Double, zoom: Double) -> Image? {
        guard let url = cacheURL(link: link, lon: lon, lat: lat, zoom: zoom),
              let data = try? Data(contentsOf: url)
        else { return nil }
        #if os(macOS)
        guard let native = NSImage(data: data) else { return nil }
        return Image(nsImage: native)
        #else
        guard let native = UIImage(data: data) else { return nil }
        return Image(uiImage: native)
        #endif
    }

    /// Where a picture of this chart at this water is kept. The key holds the
    /// link and the tile the water falls in, so a mariner who has moved gets a
    /// picture of where they are now.
    private static func cacheURL(link: String, lon: Double, lat: Double, zoom: Double) -> URL? {
        guard let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LookoutMarine/ChartPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var hash: UInt64 = 5381
        for byte in "\(link)|\(Int(lon * 4))|\(Int(lat * 4))|\(Int(zoom))".utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return dir.appendingPathComponent(String(hash, radix: 36) + ".png")
    }

    /// Draw one style and read it back. Returns nil when the style fails, or
    /// when the engine cannot open.
    func render(link: String, lon: Double, lat: Double, zoom: Double) async -> Image? {
        guard let h = open() else { return nil }
        var view = lookout_view(lon: lon, lat: lat, zoom: zoom, rotation_deg: 0)
        lookout_set_view(h, &view)
        link.withCString { lookout_chart_link_draw(h, $0) }

        // Tick the frame loop: it is what adopts the style and the tiles as
        // the fetches land. A windowed host does this on its display link.
        var pixels = [UInt8](repeating: 0, count: Self.size.w * Self.size.h * 4)
        var settled = 0
        var drawn = false
        for i in 0..<Self.patience {
            try? await Task.sleep(for: Self.tick)
            if Task.isCancelled { return nil }
            var f = lookout_frame()
            lookout_frame_next(h, &f)
            // Render every tick. Asking for a frame is what works out which
            // tiles the view needs, so a loop that only ticks and snapshots at
            // the end never asks for one and draws an empty style.
            // 0 is success here, unlike the rest of this ABI.
            let ok = pixels.withUnsafeMutableBufferPointer {
                lookout_snapshot_rgba(h, $0.baseAddress, $0.count)
            }
            drawn = drawn || ok == 0
            guard i >= Self.warmup else { continue }
            if f.verdict == LOOKOUT_FRAME_IDLE && f.building == 0 {
                settled += 1
                if settled >= 4 { break }
            } else {
                settled = 0
            }
        }
        guard drawn else { return nil }
        guard let cg = Self.bitmap(w: Self.size.w, h: Self.size.h, rgba: pixels) else { return nil }
        Self.keep(cg, link: link, lon: lon, lat: lat, zoom: zoom)
        #if os(macOS)
        return Image(nsImage: NSImage(cgImage: cg,
                                      size: NSSize(width: Self.size.w, height: Self.size.h)))
        #else
        return Image(uiImage: UIImage(cgImage: cg))
        #endif
    }

    /// Open the engine, once, and keep it for the rest of the previews.
    private func open() -> OpaquePointer? {
        if let handle { return handle }
        let opened = lookout_open_charts(nil, 0,
                                         UInt32(Self.size.w), UInt32(Self.size.h),
                                         0 /* no window */, 0 /* no msaa */)
        guard let h = opened else { return nil }
        fetch.attach(to: h) { }
        handle = h
        return h
    }

    /// Close the engine. The fetcher is detached first, so no answer arrives
    /// into a handle that is going away.
    func close() {
        guard let h = handle else { return }
        handle = nil
        fetch.detach()
        lookout_close(h)
    }

    /// Write the picture where the next run finds it.
    private static func keep(_ cg: CGImage, link: String,
                             lon: Double, lat: Double, zoom: Double) {
        guard let url = cacheURL(link: link, lon: lon, lat: lat, zoom: zoom) else { return }
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        #else
        guard let data = UIImage(cgImage: cg).pngData() else { return }
        #endif
        try? data.write(to: url)
    }

    private static func bitmap(w: Int, h: Int, rgba: [UInt8]) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: space, bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent)
        else { return nil }
        return cg
    }
}
