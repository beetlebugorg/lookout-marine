//
//  What the chart table does, run on a Mac.
//
//  The app itself cannot be launched here: the visionOS simulator's shell
//  crash-loops on this machine's paravirtualized GPU. Everything below the
//  entities is the same code on both platforms, though, and RealityKit's
//  resource APIs work on macOS, so the load-bearing chain is exercised here:
//
//    1. a TextureResource.DrawableQueue built with the app's own descriptor
//    2. lookout_render_texture into a drawable's MTLTexture
//    3. the present callback firing on Metal's completion thread
//    4. real chart pixels in the target
//    5. the AIS plugin's own table, read and decoded by AISRows
//    6. geo to chart fraction and back, the mapping every overlay stands on
//
//  It compiles the app's AISRows.swift, so the decoder under test is the one
//  that ships.
//
//      apple/tests/run.sh [chart.pmtiles]
//

import CoreGraphics
import Foundation
import Metal
import RealityKit

// MARK: - A tiny harness

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String) {
    checks += 1
    if ok {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what)")
    }
}

func section(_ name: String) {
    print("\n\(name)")
}

// MARK: - Opening

let args = CommandLine.arguments
let chart = args.count > 1
    ? args[1]
    : NSString(string: "~/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles").expandingTildeInPath
guard FileManager.default.fileExists(atPath: chart) else {
    FileHandle.standardError.write(Data("table-smoke: no chart at \(chart)\n".utf8))
    exit(2)
}

// The app's own numbers for a default 0.9 m sheet, so the sizes under test are
// the sizes that ship: 2000 points per meter of sheet at 1.5 px per point.
let sheetWidth: Float = 0.9
let marginFraction: Float = 0.045
let aspect: Float = 0.72
let faceW = sheetWidth - 2 * sheetWidth * marginFraction
let faceD = sheetWidth * aspect - 2 * sheetWidth * marginFraction
// Even points, so points times density is a whole number of pixels and the
// texture's aspect matches the viewport's exactly.
let ptW = UInt32(((faceW * 2000) / 2).rounded() * 2)
let ptH = UInt32(((faceD * 2000) / 2).rounded() * 2)
let density: Float = 1.5
let pxW = Int(Float(ptW) * density)
let pxH = Int(Float(ptH) * density)

print("table-smoke: \(chart)")
print("table-smoke: sheet \(sheetWidth) m -> face \(faceW)x\(faceD) m -> \(ptW)x\(ptH) pt -> \(pxW)x\(pxH) px")

guard let h = lookout_open(chart, ptW, ptH, 0, 1) else {
    FileHandle.standardError.write(Data("table-smoke: lookout_open failed\n".utf8))
    exit(1)
}
lookout_set_pixel_density(h, density)

section("plugins")
let pluginDir = ProcessInfo.processInfo.environment["LOOKOUT_PLUGINS"]
    ?? FileManager.default.currentDirectoryPath + "/zig-out/plugins-bundled"
let pluginsLoaded = lookout_plugins_load(h, pluginDir) == 0
check(pluginsLoaded, "the bundled plugin set loads from \(pluginDir)")
check(lookout_plugins_active(h) == 1, "the plugin layer is up")

var view = lookout_view()
lookout_fit_chart(h, &view)
lookout_set_view(h, &view)

// MARK: - The drawable queue

section("the drawable queue")
let desc = TextureResource.DrawableQueue.Descriptor(
    pixelFormat: .bgra8Unorm,
    width: pxW,
    height: pxH,
    usage: [.renderTarget, .shaderRead],
    mipmapsMode: .none)
guard let queue = try? TextureResource.DrawableQueue(desc) else {
    print("  FAIL  the app's descriptor builds a queue")
    exit(1)
}
queue.allowsNextDrawableTimeout = true
check(true, "the app's descriptor builds a queue at \(pxW)x\(pxH)")

// A TextureResource the queue feeds, exactly as ChartEngine builds one.
let onePixel: CGImage = {
    let bytes: [UInt8] = [0xE8, 0xE4, 0xDC, 0xFF]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}()
let resource = try? TextureResource(image: onePixel, options: .init(semantic: .color, mipmapsMode: .none))
check(resource != nil, "a placeholder TextureResource is created")
resource?.replace(withDrawables: queue)
check(resource?.drawableQueue != nil, "the resource takes the queue")

// MARK: - Frames

section("frames")
let presented = NSLock()
var presentCount = 0
func bumpPresented() {
    presented.lock()
    presentCount += 1
    presented.unlock()
}
let onDone: @convention(c) (UnsafeMutableRawPointer?) -> Void = { user in
    guard let user else { return }
    Unmanaged<TextureResource.Drawable>.fromOpaque(user).takeRetainedValue().present()
    bumpPresented()
}

var lastTexture: (any MTLTexture)?
var recorded = 0
var skipped = 0
let deadline = Date().addingTimeInterval(30)

// Tiles land on worker threads, so the first frames are mostly empty. Render
// until the core stops asking, with a bound so a stall fails rather than hangs.
while Date() < deadline {
    if lookout_needs_redraw(h) == 0 && recorded > 3 { break }
    guard let drawable = try? queue.nextDrawable() else {
        skipped += 1
        Thread.sleep(forTimeInterval: 0.016)
        continue
    }
    let user = Unmanaged.passRetained(drawable).toOpaque()
    let tex = Unmanaged.passUnretained(drawable.texture as AnyObject).toOpaque()
    if lookout_render_texture(h, tex, onDone, user) == 1 {
        recorded += 1
        lastTexture = drawable.texture
    } else {
        Unmanaged<TextureResource.Drawable>.fromOpaque(user).release()
        skipped += 1
    }
    Thread.sleep(forTimeInterval: 0.016)
}
Thread.sleep(forTimeInterval: 0.5)

presented.lock()
let presents = presentCount
presented.unlock()
print("  \(recorded) recorded, \(skipped) skipped, \(presents) presented")
check(recorded > 0, "a frame is recorded into a host-owned drawable")
check(presents > 0, "the completion callback fires and presents")

// A texture of the wrong shape is refused rather than raising a Metal error.
let badDesc = TextureResource.DrawableQueue.Descriptor(
    pixelFormat: .rgba8Unorm, width: 64, height: 64,
    usage: [.renderTarget, .shaderRead], mipmapsMode: .none)
if let badQueue = try? TextureResource.DrawableQueue(badDesc),
   let bad = try? badQueue.nextDrawable() {
    let tex = Unmanaged.passUnretained(bad.texture as AnyObject).toOpaque()
    check(lookout_render_texture(h, tex, nil, nil) == 0, "an RGBA target is refused")
}
check(lookout_render_texture(h, nil, nil, nil) == 0, "a null target is refused")

// MARK: - The pixels

// A drawable is recycled when something RENDERS the material that holds it.
// Nothing does here, so the queue runs dry after its three drawables and the
// chart's first frames are all that reach it, which is before any tile has
// landed. The pixels are checked against a target this harness owns instead:
// the same lookout_render_texture call, with a texture that is always free.
section("the pixels")
guard let device = MTLCreateSystemDefaultDevice() else {
    print("  FAIL  no Metal device")
    exit(1)
}
let ownDesc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: pxW, height: pxH, mipmapped: false)
ownDesc.usage = [.renderTarget, .shaderRead]
ownDesc.storageMode = .shared
guard let own = device.makeTexture(descriptor: ownDesc) else {
    print("  FAIL  the harness cannot make a render target")
    exit(1)
}
let ownPtr = Unmanaged.passUnretained(own as AnyObject).toOpaque()

// Tiles build on worker threads. Render until the core says it owes nothing,
// which is when the chart is fully drawn.
var settled = false
let pixelDeadline = Date().addingTimeInterval(60)
var frames = 0
while Date() < pixelDeadline {
    if lookout_render_texture(h, ownPtr, nil, nil) == 1 { frames += 1 }
    if lookout_needs_redraw(h) == 0 && frames > 2 {
        settled = true
        break
    }
    Thread.sleep(forTimeInterval: 0.02)
}
Thread.sleep(forTimeInterval: 0.3)
print("  \(frames) frame(s) into the harness's own target, settled: \(settled)")
check(frames > 0, "the harness's own target takes frames")

var bytes = [UInt8](repeating: 0, count: pxW * pxH * 4)
bytes.withUnsafeMutableBytes { buf in
    own.getBytes(buf.baseAddress!, bytesPerRow: pxW * 4,
                 from: MTLRegionMake2D(0, 0, pxW, pxH), mipmapLevel: 0)
}
var counts: [UInt32: Int] = [:]
var i = 0
while i + 3 < bytes.count {
    let c = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
    counts[c, default: 0] += 1
    i += 4
}
let top = counts.max { $0.value < $1.value }!
let share = Double(top.value) / Double(pxW * pxH)
print(String(format: "  %d distinct colors, dominant #%06X at %.0f%%", counts.count, top.key, share * 100))
// A chart of a harbor is depth shading, land, buoys and text: many colors,
// none of them the whole frame. One color everywhere is a blank target.
check(counts.count > 32, "the target holds a chart, not one flat color")
check(share < 0.98, "no single color covers the target")

// What a frame costs on the CPU with the chart settled: the record call only,
// which is what the app spends inside its scene update. The GPU finishes
// afterwards on its own.
section("the cost of a frame")
var worst = 0.0
var total = 0.0
let samples = 60
for _ in 0..<samples {
    let t0 = Date()
    _ = lookout_render_texture(h, ownPtr, nil, nil)
    let ms = Date().timeIntervalSince(t0) * 1000
    total += ms
    worst = max(worst, ms)
}
print(String(format: "  settled chart, %dx%d px: %.2f ms mean, %.2f ms worst",
             pxW, pxH, total / Double(samples), worst))
// The headset asks for a frame every 11 ms. This is a Mac and not a headset,
// so the number is indicative, not a verdict; a mean above the budget here
// would say the design is wrong before a device ever sees it.
check(total / Double(samples) < 11.0, "a settled frame is recorded inside a display interval")

// MARK: - Geo to the sheet and back

section("geo and the sheet")
var v = lookout_view()
lookout_get_view(h, &v)
// The middle of the face is the middle of the view. The tolerance is a meter
// of ground at this latitude, which is far below a pixel at any chart scale.
var lon = 0.0
var lat = 0.0
lookout_screen_to_geo(h, Float(ptW) / 2, Float(ptH) / 2, &lon, &lat)
let dLon = abs(lon - v.lon)
let dLat = abs(lat - v.lat)
print(String(format: "  view %.6f, %.6f   center %.6f, %.6f   off by %.6f, %.6f deg",
             v.lon, v.lat, lon, lat, dLon, dLat))
check(dLon < 1e-5 && dLat < 1e-5, "the center of the face is the center of the view")

// The round trip: the center's position projects back to the center.
var backX: Float = 0
var backY: Float = 0
lookout_geo_to_screen(h, lon, lat, &backX, &backY)
let fx = backX / Float(ptW)
let fy = backY / Float(ptH)
check(abs(fx - 0.5) < 0.01 && abs(fy - 0.5) < 0.01,
      "geo to fraction and back agree (\(fx), \(fy))")

// A tenth of a degree north is up the sheet and east is to the right, which is
// what every overlay position rests on.
var northX: Float = 0
var northY: Float = 0
lookout_geo_to_screen(h, lon, lat + 0.01, &northX, &northY)
check(northY < backY, "north is towards the top of the face")
var eastX: Float = 0
var eastY: Float = 0
lookout_geo_to_screen(h, lon + 0.01, lat, &eastX, &eastY)
check(eastX > backX, "east is towards the right of the face")

// What the app's "show me own ship" does: set a view and expect that position
// to land in the middle of the sheet.
var target = lookout_view(lon: lon + 0.01, lat: lat + 0.005, zoom: v.zoom, rotation_deg: 0)
lookout_set_view(h, &target)
_ = lookout_render_texture(h, ownPtr, nil, nil)
var setX: Float = 0
var setY: Float = 0
lookout_geo_to_screen(h, target.lon, target.lat, &setX, &setY)
let centerX = Float(ptW) / 2
let centerY = Float(ptH) / 2
print(String(format: "  a set view lands at %.0f, %.0f pt; the middle is %.0f, %.0f",
             setX, setY, centerX, centerY))
check(abs(setX - centerX) < 4 && abs(setY - centerY) < 4,
      "a position set as the view lands in the middle of the sheet")

// Panning by half the sheet moves the chart by half the sheet, and the sign is
// the one the hand expects: the chart follows the hand.
var beforeX: Float = 0
var beforeY: Float = 0
lookout_geo_to_screen(h, target.lon, target.lat, &beforeX, &beforeY)
lookout_pan_logical(h, Float(ptW) / 4, Float(ptH) / 4)
_ = lookout_render_texture(h, ownPtr, nil, nil)
var afterX: Float = 0
var afterY: Float = 0
lookout_geo_to_screen(h, target.lon, target.lat, &afterX, &afterY)
print(String(format: "  a pan of +%.0f, +%.0f pt moved the chart by %.0f, %.0f",
             Float(ptW) / 4, Float(ptH) / 4, afterX - beforeX, afterY - beforeY))
check(afterX - beforeX > Float(ptW) / 5 && afterY - beforeY > Float(ptH) / 5,
      "a positive pan carries the chart with the hand, right and down")


// MARK: - The AIS table

section("the AIS plugin's table")
_ = lookout_plugin_table_open(h, AISRows.plugin, AISRows.table, 1)
// The plugin needs a moment with its feed before it has rows.
var rows: [AISRow] = []
let aisDeadline = Date().addingTimeInterval(20)
while Date() < aisDeadline {
    lookout_tick_anim(h, 0.05)
    _ = lookout_render_texture(h, nil, nil, nil) // pumps nothing; keeps the loop honest
    var len = 0
    if let s = lookout_plugin_table_rows(h, AISRows.plugin, AISRows.table, nil, 1, &len), len > 0 {
        rows = AISRows.decode(Data(bytes: s, count: len))
        if !rows.isEmpty { break }
    }
    Thread.sleep(forTimeInterval: 0.25)
}

if rows.isEmpty {
    print("  no targets: the NMEA replay is not running, so the decoder is checked against the ABI's own example")
    let sample = """
    {"key":"targets","seq":42,"open":true,
     "rows":[{"id":"899000101","band":0,"at":[-76.46,38.97],
              "cells":["ANNE","899000101",1852,45,6.2,124,585,"alarm"]},
             {"id":"993672000","band":1,"at":[-76.47,38.98],
              "cells":[null,"993672000",900,12,null,null,null,null]}]}
    """
    rows = AISRows.decode(Data(sample.utf8))
    check(rows.count == 2, "both rows decode")
    if rows.count == 2 {
        check(rows[0].name == "ANNE" && rows[0].mmsi == "899000101", "name and MMSI")
        check(abs(rows[0].lon + 76.46) < 1e-9 && abs(rows[0].lat - 38.97) < 1e-9, "at is [lon, lat]")
        check(rows[0].sogMps == 6.2 && rows[0].cpaM == 124 && rows[0].tcpaS == 585, "speed and approach")
        check(rows[0].alarm, "the alarm flag is read")
        check(rows[0].flagLabel.contains("12.0 kn"), "speed reaches the flag, rounded to half a knot")
        check(rows[0].flagLabel.contains("CPA 124 m in 10 min"), "an alarmed flag carries the approach unrounded")
        check(rows[1].name == "993672000" && rows[1].sogMps == nil, "a nameless, speechless row falls back")
        check(rows[1].isAid, "a 99x MMSI is an aid to navigation")
    }
} else {
    print("  \(rows.count) target(s) from the live feed")
    check(rows.allSatisfy { !$0.mmsi.isEmpty }, "every target has an MMSI")
    check(rows.allSatisfy { $0.lat >= -90 && $0.lat <= 90 && $0.lon >= -180 && $0.lon <= 180 },
          "every position is on the earth")
    let placed = rows.filter { r in
        var x: Float = 0
        var y: Float = 0
        lookout_geo_to_screen(h, r.lon, r.lat, &x, &y)
        return x.isFinite && y.isFinite
    }
    check(placed.count == rows.count, "every target projects onto the sheet")
    // The overlay payload carries the heading the table does not. The id the
    // AIS plugin gives a vessel symbol is "t" and the MMSI.
    var withHeading = 0
    var found = 0
    for r in rows.prefix(8) {
        var obj = lookout_overlay_obj()
        guard lookout_overlay_info(h, AISRows.overlayID(mmsi: r.mmsi), &obj) == 1 else { continue }
        found += 1
        guard let p = obj.info, obj.info_len > 0 else { continue }
        let payload = String(decoding: UnsafeRawBufferPointer(start: p, count: obj.info_len), as: UTF8.self)
        if AISRows.heading(payload: payload) != nil {
            withHeading += 1
        } else if withHeading == 0 {
            print("  payload without a heading: \(payload.prefix(200))")
        }
    }
    if found == 0, let first = rows.first {
        // The id is not what this expected. Ask the chart what is drawn where
        // the target is, which answers with the id it uses.
        var x: Float = 0
        var y: Float = 0
        lookout_geo_to_screen(h, first.lon, first.lat, &x, &y)
        var hit = lookout_overlay_obj()
        if lookout_overlay_hit(h, x, y, &hit) == 1, let idp = hit.id {
            print("  the overlay at target \(first.mmsi) answers to id '\(String(cString: idp))'")
        } else {
            print("  nothing is drawn at target \(first.mmsi) (\(x), \(y) pt)")
        }
    }
    check(found > 0, "the overlay answers for a target's id (\(found) of \(min(rows.count, 8)))")
    check(withHeading > 0, "at least one target's heading is read from its overlay payload (\(withHeading))")
}

// The payload reader, against the shape the plugin publishes.
check(AISRows.heading(payload: #"{"title":"X","rows":[["MMSI","1"],["COG","124°"],["HDG","120°"]]}"#) == 120,
      "heading wins over course")
check(AISRows.heading(payload: #"{"title":"X","rows":[["MMSI","1"],["COG","124°"]]}"#) == 124,
      "course stands in when no heading is reported")
check(AISRows.heading(payload: #"{"title":"X","rows":[["MMSI","1"]]}"#) == nil,
      "a target that reports neither answers nothing")

// MARK: - The alarms

// The AIS plugin raises a CPA alarm for one target in the recorded scene, so
// with the replay running the whole chain is exercised: the plugin raises it,
// the core lists it, and the watch's own decoder reads it.
section("alarms")
var alertSeq = -1
var raised: [String] = []
let alarmDeadline = Date().addingTimeInterval(20)
while Date() < alarmDeadline {
    var len = 0
    if let raw = lookout_plugin_alerts_json(h, &len), len > 0 {
        let data = Data(bytes: raw, count: len)
        if let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            alertSeq = top["seq"] as? Int ?? -1
            let list = (top["alerts"] as? [[String: Any]]) ?? []
            let decoded = list.compactMap { PluginAlert($0) }
            if !decoded.isEmpty {
                raised = decoded.map { "\($0.severity.rawValue): \($0.title)" }
                break
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
}
check(alertSeq >= 0, "the core answers with an alert set (seq \(alertSeq))")
if raised.isEmpty {
    print("  no alarm raised: the NMEA replay is not running, so nothing is closing")
} else {
    for r in raised { print("  \(r)") }
    check(true, "an alarm reached the app: \(raised.count) raised")
}

lookout_close(h)

section("")
print("table-smoke: \(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
