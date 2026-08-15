//
//  The lookout core, drawing into a RealityKit texture.
//
//  Every other Apple shell hands lookout a CAMetalLayer and lets it present.
//  A RealityKit host has no layer: the chart is a material on a mesh. So this
//  keeps a TextureResource.DrawableQueue, takes a drawable each frame, and
//  passes its MTLTexture to lookout_render_texture. The core records the frame
//  and presents the drawable from the Metal completion callback, when the
//  pixels exist.
//
//  The chart's own coordinates stay in POINTS, as on every other shell. The
//  sheet's physical size and the texture's pixel size are separate numbers:
//  see ChartSheet for how a sheet of a given width in meters decides both.
//

import CoreGraphics
import Foundation
import Metal
import RealityKit
import simd

/// Presents the drawable once the GPU has finished the frame. A C function
/// pointer, so it captures nothing: the drawable rides through as `user`,
/// retained by the caller and released here.
private let presentDrawable: @convention(c) (UnsafeMutableRawPointer?) -> Void = { user in
    guard let user else { return }
    Unmanaged<TextureResource.Drawable>.fromOpaque(user).takeRetainedValue().present()
}

@MainActor
final class ChartEngine {
    /// The core handle. Nil until open() succeeds.
    private(set) var handle: OpaquePointer?

    /// The chart's logical viewport, in points, and the pixel density it draws
    /// at. Points decide how large a symbol or a label is on the sheet; the
    /// density decides how many pixels each point gets.
    private(set) var pointSize: SIMD2<Float> = .init(1024, 768)
    private(set) var density: Float = 2.0

    /// The texture the chart draws into and the material that samples it.
    private(set) var texture: TextureResource?
    private var queue: TextureResource.DrawableQueue?

    /// Frames that found no free drawable. A queue that never drains means the
    /// consumer stopped, and the log names it once rather than every tick.
    private var starved = 0

    private(set) var chartName = ""

    /// Who made the charts and at what band, for the margin's title block.
    private(set) var chartNote = ""

    // MARK: - Lifecycle

    /// Open a chart library and build the drawable queue for a sheet of the
    /// given pixel size. `paths` is one .pmtiles file or many.
    func open(paths: [String], pixels: SIMD2<Int>, points: SIMD2<Float>, density: Float) -> Bool {
        guard !paths.isEmpty else { return false }
        self.pointSize = points
        self.density = density

        // The atlas bake and the tile cache want a writable directory. The
        // sandbox gives the app one; the platform default under HOME resolves
        // there too, but state it rather than infer it.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            lookout_set_cache_dir(caches.path)
        }

        let w = UInt32(points.x.rounded())
        let h = UInt32(points.y.rounded())
        // Offscreen open: no window, no swapchain. The device and the whole
        // renderer come up, and frames go wherever lookout_render_texture is
        // pointed. MSAA on: a chart is lines and text, and the sheet is held
        // close enough to read.
        handle = paths.withCStrings { ptrs in
            paths.count == 1
                ? lookout_open(ptrs[0], w, h, 0, 1)
                : lookout_open_charts(ptrs, paths.count, w, h, 0, 1)
        }
        guard let h = handle else {
            lkLog("open failed for \(paths.count) chart(s)")
            return false
        }
        lookout_set_pixel_density(h, density)
        chartName = URL(fileURLWithPath: paths[0]).deletingPathExtension().lastPathComponent
        chartNote = ChartLibrary.describe(paths)

        guard makeQueue(pixels: pixels) else {
            close()
            return false
        }
        loadBundledPlugins()
        lkLog("open: \(paths.count) chart(s), \(w)x\(h) pt at \(density)x -> \(pixels.x)x\(pixels.y) px")
        return true
    }

    func close() {
        if let h = handle { lookout_close(h) }
        handle = nil
        queue = nil
        texture = nil
    }

    /// The plugin set that travels in the bundle: own ship, AIS, NMEA 0183,
    /// Signal K and laylines. Without it the table shows a chart and no
    /// traffic.
    @discardableResult
    private func loadBundledPlugins() -> Bool {
        guard let h = handle,
              let dir = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.path)
        else {
            lkLog("no bundled plugins in this build")
            return false
        }
        let ok = lookout_plugins_load(h, dir.path) == 0
        lkLog("bundled plugins: \(ok ? "live" : "failed")")
        return ok
    }

    // MARK: - The drawable queue

    /// Build (or rebuild) the queue at a pixel size. Called on open and
    /// whenever the sheet is resized to a size the current texture cannot
    /// serve sharply.
    private func makeQueue(pixels: SIMD2<Int>) -> Bool {
        let w = max(64, min(pixels.x, ChartEngine.maxTextureSide))
        let h = max(64, min(pixels.y, ChartEngine.maxTextureSide))
        do {
            // BGRA8Unorm is what charttable's pipelines are built for; any
            // other format is refused at the render call. The texture is both
            // a render target and a sampled texture: lookout draws into it and
            // the material reads it.
            let desc = TextureResource.DrawableQueue.Descriptor(
                pixelFormat: .bgra8Unorm,
                width: w,
                height: h,
                usage: [.renderTarget, .shaderRead],
                mipmapsMode: .none)
            let q = try TextureResource.DrawableQueue(desc)
            // A drawable that nobody consumes must not block the render loop.
            q.allowsNextDrawableTimeout = true

            // A TextureResource cannot be created empty, so one opaque pixel
            // stands in until the first frame lands.
            let tex = try TextureResource(
                image: ChartEngine.onePixel(),
                options: .init(semantic: .color, mipmapsMode: .none))
            tex.replace(withDrawables: q)
            queue = q
            texture = tex
            return true
        } catch {
            lkLog("drawable queue \(w)x\(h) failed: \(error)")
            return false
        }
    }

    /// Metal's texture limit on this family. A sheet stretched past it stops
    /// gaining pixels and starts gaining blur, which is worth saying once.
    static let maxTextureSide = 8192

    private static func onePixel() -> CGImage {
        let bytes: [UInt8] = [0xE8, 0xE4, 0xDC, 0xFF]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    // MARK: - Frames

    /// True while the chart owes a frame: the view moved, tiles are landing,
    /// a style change is pending, or an animation is running.
    var needsRedraw: Bool {
        guard let h = handle else { return false }
        return lookout_needs_redraw(h) != 0
    }

    /// Record one frame into the next drawable. Returns false when the chart
    /// owes nothing, no drawable is free, or the frame could not be recorded.
    @discardableResult
    func renderFrame(force: Bool = false) -> Bool {
        guard let h = handle, let queue else { return false }
        guard force || needsRedraw else { return false }
        guard let drawable = try? queue.nextDrawable() else {
            starved += 1
            if starved == 60 { lkLog("drawable queue starved for 60 frames") }
            return false
        }
        starved = 0
        let user = Unmanaged.passRetained(drawable).toOpaque()
        let tex = Unmanaged.passUnretained(drawable.texture as AnyObject).toOpaque()
        let ok = lookout_render_texture(h, tex, presentDrawable, user)
        if ok != 1 {
            // Nothing was recorded, so no completion callback will run and the
            // retain above is this function's to give back.
            Unmanaged<TextureResource.Drawable>.fromOpaque(user).release()
            return false
        }
        return true
    }

    /// Advance animations (fling, zoom easing) by `dt` seconds.
    func tick(_ dt: Double) {
        guard let h = handle else { return }
        if lookout_animating(h) != 0 { lookout_tick_anim(h, dt) }
    }

    // MARK: - Geometry

    /// Resize the chart's logical viewport and rebuild the texture for a new
    /// pixel size. A wider sheet shows MORE chart at the same scale, the way
    /// unrolling a larger sheet of paper does, so the viewport grows with it.
    func resize(points: SIMD2<Float>, pixels: SIMD2<Int>, density: Float) {
        guard let h = handle else { return }
        self.pointSize = points
        self.density = density
        lookout_set_pixel_density(h, density)
        _ = lookout_resize(h, UInt32(points.x.rounded()), UInt32(points.y.rounded()))
        _ = makeQueue(pixels: pixels)
    }

    /// Where a position draws on the sheet, as a fraction of the chart face
    /// (0,0 top left to 1,1 bottom right). Values outside 0...1 are off the
    /// sheet. Nil when there is no chart.
    ///
    /// UNITS. lookout_geo_to_screen and lookout_screen_to_geo answer in the
    /// same space the handle was opened and resized in, which for this host is
    /// POINTS. The density scales pixels in the texture, not these
    /// coordinates: dividing by it here puts every overlay at 2/3 of its
    /// distance from the top left corner.
    func fractionFor(lon: Double, lat: Double) -> SIMD2<Float>? {
        guard let h = handle else { return nil }
        var x: Float = 0
        var y: Float = 0
        lookout_geo_to_screen(h, lon, lat, &x, &y)
        guard x.isFinite, y.isFinite else { return nil }
        return SIMD2<Float>(x / pointSize.x, y / pointSize.y)
    }

    /// The reverse: what a point on the face is a position of.
    func geoFor(fraction: SIMD2<Float>) -> (lon: Double, lat: Double)? {
        guard let h = handle else { return nil }
        var lon = 0.0
        var lat = 0.0
        lookout_screen_to_geo(h, fraction.x * pointSize.x, fraction.y * pointSize.y, &lon, &lat)
        guard lon.isFinite, lat.isFinite else { return nil }
        return (lon, lat)
    }

    // MARK: - The mariner's controls

    func pan(dxPoints: Float, dyPoints: Float) {
        guard let h = handle else { return }
        lookout_pan_logical(h, dxPoints, dyPoints)
    }

    /// Start a momentum pan, in chart points per second. Zero stops a coast.
    func fling(vx: Double, vy: Double) {
        guard let h = handle else { return }
        lookout_fling_start(h, vx, vy)
    }

    /// Zoom by `dz` levels about a point on the face, given as a fraction.
    func zoom(_ dz: Double, atFraction f: SIMD2<Float>) {
        guard let h = handle else { return }
        lookout_zoom_at_logical(h, dz, f.x * pointSize.x, f.y * pointSize.y)
    }

    func setRotation(degrees: Double) {
        guard let h = handle else { return }
        var v = lookout_view()
        lookout_get_view(h, &v)
        v.rotation_deg = degrees
        lookout_set_view(h, &v)
    }

    var rotationDegrees: Double {
        guard let h = handle else { return 0 }
        var v = lookout_view()
        lookout_get_view(h, &v)
        return v.rotation_deg
    }

    func fitChart() {
        guard let h = handle else { return }
        var v = lookout_view()
        lookout_fit_chart(h, &v)
        lookout_set_view(h, &v)
    }

    func setView(lon: Double, lat: Double, zoom: Double) {
        guard let h = handle else { return }
        var v = lookout_view(lon: lon, lat: lat, zoom: zoom, rotation_deg: rotationDegrees)
        lookout_set_view(h, &v)
    }

    var view: lookout_view {
        guard let h = handle else { return lookout_view() }
        var v = lookout_view()
        lookout_get_view(h, &v)
        return v
    }

    /// The chart scale as a denominator: 20000 reads 1:20,000.
    var scaleDenominator: Double {
        guard let h = handle else { return 0 }
        return lookout_scale_denominator(h)
    }

    func cycleScheme() {
        guard let h = handle else { return }
        lookout_cycle_scheme(h)
    }

    /// Own ship's position, when a plugin is publishing one.
    var ownShip: (lon: Double, lat: Double)? {
        guard let h = handle else { return nil }
        var lon = 0.0
        var lat = 0.0
        guard lookout_own_ship(h, &lon, &lat) == 1 else { return nil }
        return (lon, lat)
    }

    // MARK: - What the settings form drives

    /// The mariner's full S-52 state, as the engine holds it.
    func getMariner() -> tile57_mariner {
        var m = tile57_mariner()
        guard let h = handle else {
            lookout_mariner_defaults(&m)
            return m
        }
        lookout_get_mariner(h, &m)
        return m
    }

    func setMariner(_ m: tile57_mariner) {
        guard let h = handle else { return }
        var v = m
        lookout_set_mariner(h, &v)
        renderFrame(force: true)
    }

    /// Every loaded plugin with its settings schema and the values in force.
    func pluginsJSON() -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let s = lookout_plugins_json(h, &len), len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: s, count: len), as: UTF8.self)
    }

    @discardableResult
    func setPluginConfig(_ id: String, _ json: String) -> Bool {
        guard let h = handle else { return false }
        return lookout_plugin_config_set(h, id, json) == 0
    }

    @discardableResult
    func setPluginGrant(_ id: String, _ cap: String, _ on: Bool) -> Bool {
        guard let h = handle else { return false }
        return lookout_plugin_grant_set(h, id, cap, on ? 1 : 0) == 0
    }

    @discardableResult
    func uninstallPlugin(_ id: String) -> Bool {
        guard let h = handle else { return false }
        return lookout_plugin_uninstall(h, id) == 0
    }

    /// Every alarm the plugins have raised, with the sequence the core stamps
    /// on the set. A collision alarm arrives here.
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])? {
        guard let h = handle else { return nil }
        var len = 0
        guard let raw = lookout_plugin_alerts_json(h, &len), len > 0 else { return nil }
        // Borrowed until the next plugin query, so decode before anything else
        // runs.
        let data = Data(bytes: raw, count: len)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["alerts"] as? [[String: Any]] else { return nil }
        return (top["seq"] as? Int ?? 0, list.compactMap { PluginAlert($0) })
    }

    @discardableResult
    func acknowledgeAlert(_ id: UInt64) -> Bool {
        guard let h = handle else { return false }
        return lookout_plugin_alert_ack(h, id) == 0
    }

    // MARK: - Plugin data

    /// The rows of a plugin table, as JSON. The AIS plugin's "targets" table
    /// carries one row per vessel with its position, name and approach.
    func tableRows(plugin: String, key: String) -> Data? {
        guard let h = handle else { return nil }
        var len = 0
        guard let s = lookout_plugin_table_rows(h, plugin, key, nil, 1, &len), len > 0 else { return nil }
        return Data(bytes: s, count: len)
    }

    /// Tell a plugin its table is being read. A plugin builds rows only while
    /// one is open.
    func setTableOpen(plugin: String, key: String, open: Bool) {
        guard let h = handle else { return }
        _ = lookout_plugin_table_open(h, plugin, key, open ? 1 : 0)
    }

    /// What an overlay object says now: where it draws and its payload. The
    /// AIS plugin's vessel ids are "t" followed by the MMSI.
    func overlayInfo(id: String) -> (lon: Double, lat: Double, info: String)? {
        guard let h = handle else { return nil }
        var obj = lookout_overlay_obj()
        guard lookout_overlay_info(h, id, &obj) == 1 else { return nil }
        var payload = ""
        if let p = obj.info, obj.info_len > 0 {
            payload = String(decoding: UnsafeRawBufferPointer(start: p, count: obj.info_len), as: UTF8.self)
        }
        return (obj.lon, obj.lat, payload)
    }

    /// What the chart reports at a position, best first. The core decides what
    /// a pick reports and in what order, so every shell shows the same thing.
    func pick(lon: Double, lat: Double) -> [PickDecoded] {
        guard let h = handle else { return [] }
        var found: [PickFeature] = []
        withUnsafeMutablePointer(to: &found) { ctx in
            var cb = tile57_query_cb(
                ctx: UnsafeMutableRawPointer(ctx),
                feature: { c, cls, clsLen, s57, s57Len, chart, chartLen in
                    guard let c else { return }
                    let arr = c.assumingMemoryBound(to: [PickFeature].self)
                    func str(_ p: UnsafePointer<CChar>?, _ n: Int) -> String {
                        guard let p, n > 0 else { return "" }
                        return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
                    }
                    arr.pointee.append(PickFeature(cls: str(cls, clsLen),
                                                   chart: str(chart, chartLen),
                                                   s57: str(s57, s57Len)))
                })
            lookout_pick_ranked(h, lon, lat, &cb)
        }
        return found.map(PickDecoded.init)
    }
}

extension Array where Element == String {
    /// Run `body` with a C array of NUL-terminated copies of these strings.
    func withCStrings<R>(_ body: ([UnsafePointer<CChar>?]) -> R) -> R {
        let cs = map { strdup($0) }
        defer { cs.forEach { free($0) } }
        return body(cs.map { UnsafePointer($0) })
    }
}

/// The settings form reads and writes the chart through these.
extension ChartEngine: MarinerSettingsHost, PluginSettingsHost, AlertHost {}
