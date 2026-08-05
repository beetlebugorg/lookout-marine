//! lookout demo: open a baked tile57 chart and render snapshots via Metal.
//!   lookout <chart.pmtiles> [--png OUT] [--lon L --lat L --zoom Z]
//! Renders day + night PNGs (night proves palette swap needs no
//! re-tessellation) and a zoomed frame, then exits. The interactive host is
//! the macOS app (macos/) — the demo is the headless render/parity tool.
const std = @import("std");
const cc = @import("c.zig").c;
const lk = @import("root.zig");
const gpuTicksUs = @import("gpu.zig").ticksUs;

const DEFAULT_CHART = "/home/claude/.cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles";

const USAGE =
    \\lookout — render a baked tile57 chart to PNG snapshots (Metal, headless)
    \\
    \\usage: lookout <chart.pmtiles> [options]
    \\
    \\  <chart.pmtiles>   a baked tile57 PMTiles archive (or a directory of them)
    \\  --width W --height H   render size in pixels (default 1600x1200)
    \\  --png OUT         day PNG output path (default lookout.png)
    \\  --lon L --lat L --zoom Z   explicit view center + zoom (else fit the cell)
    \\  --raster FILE     a picture chart (.mbtiles) under the chart; repeatable
    \\  -h, --help        this help
    \\
    \\Writes lookout.png (day), lookout-night.png (palette swap, no
    \\re-tessellation) and lookout-zoom.png (MVP zoom, no re-tessellation),
    \\then exits. The interactive host is the macOS app (macos/).
    \\
;

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isDir(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

// Enumerate baked archives under a directory (host glue — tile57 composes the
// paths we hand it; it does the mmap + ownership partition).
fn scanPmtiles(alloc: std.mem.Allocator, dir: []const u8) ![][:0]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var w = try d.walk(alloc);
    defer w.deinit();
    var list: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }
    while (try w.next(io)) |e| {
        if (e.kind == .directory or !std.mem.endsWith(u8, e.basename, ".pmtiles")) continue;
        try list.append(alloc, try std.fs.path.joinZ(alloc, &.{ dir, e.path }));
    }
    return list.toOwnedSlice(alloc);
}

// Open a single baked chart, or compose a directory of them.
fn openTarget(alloc: std.mem.Allocator, path: [:0]const u8, opts: lk.OpenOptions) !*lk.Lookout {
    if (isDir(path)) {
        const paths = try scanPmtiles(alloc, path);
        defer {
            for (paths) |p| alloc.free(p);
            alloc.free(paths);
        }
        if (paths.len == 0) return error.NoBakedCharts;
        std.debug.print("composing {d} charts from {s}\n", .{ paths.len, path });
        return lk.Lookout.openCharts(alloc, paths, opts);
    }
    return lk.Lookout.open(alloc, path, opts);
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var chart_path: ?[:0]const u8 = null;
    var png_out: []const u8 = "lookout.png";
    var lon: ?f64 = null;
    var lat: ?f64 = null;
    var zoom: ?f64 = null;
    var width: u32 = 1600;
    var height: u32 = 1200;
    // --safety N: set the mariner's safety contour before the first build —
    // the depth-band verification hook (bands must move when it does).
    var safety: ?f64 = null;
    // --raster PATH: a picture chart the mariner supplied, drawn under the
    // vector chart. Repeatable — several files group into sets by provider.
    var rasters: std.ArrayList([:0]const u8) = .empty;
    defer rasters.deinit(alloc);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{USAGE});
            return;
        } else if (std.mem.eql(u8, a, "--png") and i + 1 < args.len) {
            i += 1;
            png_out = args[i];
        } else if (std.mem.eql(u8, a, "--lon") and i + 1 < args.len) {
            i += 1;
            lon = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, a, "--lat") and i + 1 < args.len) {
            i += 1;
            lat = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, a, "--zoom") and i + 1 < args.len) {
            i += 1;
            zoom = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, a, "--width") and i + 1 < args.len) {
            i += 1;
            width = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--height") and i + 1 < args.len) {
            i += 1;
            height = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--safety") and i + 1 < args.len) {
            i += 1;
            safety = std.fmt.parseFloat(f64, args[i]) catch null;
        } else if (std.mem.eql(u8, a, "--raster") and i + 1 < args.len) {
            i += 1;
            try rasters.append(alloc, args[i][0.. :0]);
        } else if (a[0] != '-') {
            chart_path = args[i][0.. :0];
        }
    }

    // Resolve the chart: the positional arg, else the built-in default if it
    // happens to exist on this machine.
    const chart = chart_path orelse blk: {
        if (fileExists(DEFAULT_CHART)) break :blk @as([:0]const u8, DEFAULT_CHART);
        std.debug.print("error: no chart given.\n\n{s}", .{USAGE});
        return error.NoChart;
    };

    const l = openTarget(alloc, chart, .{ .want_window = false, .width = width, .height = height }) catch {
        std.debug.print("error: could not open chart(s) '{s}'.\n", .{chart});
        return error.ChartOpenFailed;
    };
    defer l.close();

    for (rasters.items) |rp| {
        if (l.addRaster(rp)) {
            std.debug.print("raster: {s}\n", .{rp});
        } else {
            std.debug.print("raster: FAILED {s}\n", .{rp});
        }
    }

    const v = if (lon != null and lat != null and zoom != null)
        lk.View{ .lon = lon.?, .lat = lat.?, .zoom = zoom.? }
    else
        l.fitChart();
    std.debug.print("view: lon={d:.5} lat={d:.5} zoom={d:.2}\n", .{ v.lon, v.lat, v.zoom });
    l.setView(v);
    if (safety) |sc| {
        var m = l.getMariner();
        m.safety_contour = sc;
        l.setMariner(m);
        std.debug.print("safety contour = {d}\n", .{sc});
    }

    // --zoomscan: at the FIXED center, build every half-zoom from 4 to 14 and
    // report whether the CENTER of the render is chart or NODATA. The center
    // pixel is the same geo point at every zoom, so a point that reads chart
    // at one zoom and NODATA at a deeper one — while chart again deeper still —
    // is ground that vanishes when it shouldn't, caught without a device or an
    // eyeball. (NODATA = the clear colour; sampled as a 5x5 majority.)
    for (args) |a2| {
        if (std.mem.eql(u8, a2, "--zoomscan")) {
            const px_n: usize = @as(usize, l.g.width) * l.g.height * 4;
            const buf = try alloc.alloc(u8, px_n);
            defer alloc.free(buf);
            var zz: f64 = 4.0;
            while (zz <= 14.01) : (zz += 0.5) {
                l.setView(.{ .lon = v.lon, .lat = v.lat, .zoom = zz });
                try l.snapshotRgba(buf);
                var nodata_ct: u32 = 0;
                const cx = l.g.width / 2;
                const cy = l.g.height / 2;
                var dy: i32 = -2;
                while (dy <= 2) : (dy += 1) {
                    var dx: i32 = -2;
                    while (dx <= 2) : (dx += 1) {
                        const xx: usize = @intCast(@as(i32, @intCast(cx)) + dx);
                        const yy: usize = @intCast(@as(i32, @intCast(cy)) + dy);
                        const o = (yy * l.g.width + xx) * 4;
                        const r = buf[o];
                        const g = buf[o + 1];
                        const b = buf[o + 2];
                        // NODATA day palette ~ (147,174,187)
                        if (@abs(@as(i32, r) - 147) < 4 and @abs(@as(i32, g) - 174) < 4 and @abs(@as(i32, b) - 187) < 4) nodata_ct += 1;
                    }
                }
                std.debug.print("zoomscan z={d:.1} {s}\n", .{ zz, if (nodata_ct >= 13) "NODATA" else "chart" });
            }
            return;
        }
    }

    // --tour: a long pan+zoom SESSION in one process — hop the camera along
    // the coast at several zooms per stop, building every view. The leak
    // detector: run it and watch the process RSS; a healthy engine plateaus.
    for (args) |a2| {
        if (std.mem.eql(u8, a2, "--tour")) {
            const stops = [_][2]f64{
                .{ -83.1, 45.6 },  .{ -82.5, 44.0 },  .{ -79.5, 43.3 },  .{ -76.3, 39.0 },
                .{ -76.0, 37.0 },  .{ -75.5, 35.2 },  .{ -79.9, 32.7 },  .{ -81.4, 30.4 },
                .{ -80.1, 25.8 },  .{ -82.5, 27.8 },  .{ -88.0, 30.3 },  .{ -90.1, 29.1 },
                .{ -93.3, 29.8 },  .{ -95.0, 29.3 },  .{ -122.4, 37.8 }, .{ -123.0, 44.6 },
                .{ -122.3, 47.6 }, .{ -149.9, 61.2 }, .{ -157.9, 21.3 }, .{ -70.9, 42.3 },
            };
            var round: usize = 0;
            while (round < 3) : (round += 1) {
                for (stops) |st| {
                    var zz: f64 = 5.0;
                    while (zz <= 13.0) : (zz += 2.0) { // zoom IN...
                        l.setView(.{ .lon = st[0], .lat = st[1], .zoom = zz });
                        try l.build();
                    }
                    while (zz >= 5.0) : (zz -= 2.0) { // ...and back OUT
                        l.setView(.{ .lon = st[0], .lat = st[1], .zoom = zz });
                        try l.build();
                    }
                }
                std.debug.print("tour round {d} done\n", .{round + 1});
            }
            return;
        }
    }

    // --sweep: drive a zoom SESSION (many sequential builds through the
    // engine's per-tile geometry cache, like a real pinch), then land on the
    // requested view and snapshot. Repros cache-assembly bugs a single build
    // never sees.
    for (args) |a2| {
        if (std.mem.eql(u8, a2, "--sweep")) {
            var zz: f64 = v.zoom + 4.5;
            while (zz > v.zoom - 2.0) : (zz -= 0.31) {
                l.setView(.{ .lon = v.lon, .lat = v.lat, .zoom = zz });
                try l.build();
            }
            l.setView(v);
            break;
        }
    }

    // --bench: render the settled scene offscreen 60 times and report per-frame
    // cost. Offscreen serializes CPU encode + GPU + readback per frame, so this
    // is an upper bound on frame cost, comparable across encoder changes.
    for (args) |a2| {
        if (std.mem.eql(u8, a2, "--bench")) {
            const px_n: usize = @as(usize, l.g.width) * l.g.height * 4;
            const buf = try alloc.alloc(u8, px_n);
            defer alloc.free(buf);
            try l.snapshotRgba(buf); // build + warm
            const t0 = gpuTicksUs();
            var fi: usize = 0;
            while (fi < 60) : (fi += 1) try l.snapshotRgba(buf);
            const dt = gpuTicksUs() - t0;
            std.debug.print("bench: {d:.2} ms/frame over 60 offscreen frames\n", .{@as(f64, @floatFromInt(dt)) / 1000.0 / 60.0});
            return;
        }
    }

    // day (first render lazily builds the scene)
    try l.snapshotPng(png_out);
    std.debug.print("wrote {s} (day)\n", .{png_out});
    // night — set the mariner scheme; a palette swap only, NO re-tessellation
    var m = l.getMariner();
    m.scheme = cc.TILE57_SCHEME_NIGHT;
    l.setMariner(m);
    try l.snapshotPng("lookout-night.png");
    std.debug.print("wrote lookout-night.png (night, no re-tessellation)\n", .{});
    // camera demo: zoom 2 levels via the MVP only, no rebuild
    m.scheme = cc.TILE57_SCHEME_DAY;
    l.setMariner(m);
    l.zoomAt(2.0, @as(f32, @floatFromInt(l.g.width)) * 0.5, @as(f32, @floatFromInt(l.g.height)) * 0.5);
    try l.snapshotPng("lookout-zoom.png");
    std.debug.print("wrote lookout-zoom.png (zoomed via MVP only, no re-tessellation)\n", .{});
    std.debug.print("MSAA: {s}\n", .{if (l.g.msaa_used) "4x" else "off (unsupported)"});
}
