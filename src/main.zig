//! lookout demo: open a baked tile57 chart and render it on SDL_GPU.
//!   lookout <chart.pmtiles> [--window] [--png OUT] [--lon L --lat L --zoom Z]
//! Headless default: render day + night PNGs (night proves palette swap needs
//! no re-tessellation) and exit. --window: interactive pan/zoom + live toggles.
const std = @import("std");
const cc = @import("c.zig").c;
const lk = @import("root.zig");

const DEFAULT_CHART = "/home/claude/.cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles";

const USAGE =
    \\lookout — render a baked tile57 chart on SDL_GPU
    \\
    \\usage: lookout <chart.pmtiles> [options]
    \\
    \\  <chart.pmtiles>   a baked tile57 PMTiles archive (required)
    \\  --window          open an interactive window (needs a display; HiDPI-aware)
    \\  --width W --height H   render size in pixels (default 1600x1200)
    \\  --frames N        window mode: exit after N frames (testing)
    \\  --png OUT         headless day PNG output path (default lookout.png)
    \\  --lon L --lat L --zoom Z   explicit view center + zoom (else fit the cell)
    \\  -h, --help        this help
    \\
    \\Headless (no --window) writes lookout.png (day), lookout-night.png
    \\(palette swap, no re-tessellation) and lookout-zoom.png (MVP zoom, no
    \\re-tessellation), then exits.
    \\
    \\Window controls: drag=pan, wheel=zoom, n=day/night, t=text, s=soundings,
    \\d=OTHER category, [/]=safety contour (rebuilds), -/=+ size, Esc=quit.
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
    var want_window = false;
    var png_out: []const u8 = "lookout.png";
    var lon: ?f64 = null;
    var lat: ?f64 = null;
    var zoom: ?f64 = null;
    var max_frames: ?u64 = null; // window mode: exit after N frames (for testing)
    var width: u32 = 1600;
    var height: u32 = 1200;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{USAGE});
            return;
        } else if (std.mem.eql(u8, a, "--window")) {
            want_window = true;
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
        } else if (std.mem.eql(u8, a, "--frames") and i + 1 < args.len) {
            i += 1;
            max_frames = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--width") and i + 1 < args.len) {
            i += 1;
            width = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--height") and i + 1 < args.len) {
            i += 1;
            height = try std.fmt.parseInt(u32, args[i], 10);
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

    // headless default: force SDL's offscreen video driver. --window keeps the
    // platform driver (Lookout.open falls back to offscreen if it can't open one).
    if (!want_window) {
        _ = cc.SDL_SetHint(cc.SDL_HINT_VIDEO_DRIVER, "offscreen");
    }

    const l = openTarget(alloc, chart, .{ .want_window = want_window, .width = width, .height = height }) catch {
        std.debug.print("error: could not open chart(s) '{s}'.\n", .{chart});
        return error.ChartOpenFailed;
    };
    defer l.close();

    const v = if (lon != null and lat != null and zoom != null)
        lk.View{ .lon = lon.?, .lat = lat.?, .zoom = zoom.? }
    else
        l.fitChart();
    std.debug.print("view: lon={d:.5} lat={d:.5} zoom={d:.2}\n", .{ v.lon, v.lat, v.zoom });
    l.setView(v);

    if (!want_window) {
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
        return;
    }

    // interactive
    try runWindow(l, max_frames);
}

/// Tracks a smoothed drag velocity (logical px/sec) so releasing the mouse can
/// hand the camera a fling.
const PanTracker = struct {
    last_ns: u64 = 0,
    vx: f64 = 0,
    vy: f64 = 0,
    fn reset(self: *PanTracker) void {
        self.* = .{};
    }
    fn sample(self: *PanTracker, dx: f32, dy: f32, ts_ns: u64) void {
        if (self.last_ns != 0 and ts_ns > self.last_ns) {
            const dt = @as(f64, @floatFromInt(ts_ns - self.last_ns)) / 1e9;
            if (dt > 0.0005) {
                self.vx = self.vx * 0.5 + (@as(f64, dx) / dt) * 0.5;
                self.vy = self.vy * 0.5 + (@as(f64, dy) / dt) * 0.5;
            }
        }
        self.last_ns = ts_ns;
    }
};

fn handleEvent(l: *lk.Lookout, ev: *cc.SDL_Event, dragging: *bool, running: *bool, pan: *PanTracker) void {
    switch (ev.type) {
        cc.SDL_EVENT_QUIT => running.* = false,
        cc.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            dragging.* = true;
            l.flingStart(0, 0); // grabbing the map stops any coast
            pan.reset();
        },
        cc.SDL_EVENT_MOUSE_BUTTON_UP => {
            dragging.* = false;
            l.flingStart(pan.vx, pan.vy); // throw it
        },
        cc.SDL_EVENT_MOUSE_MOTION => {
            if (dragging.*) {
                l.panLogical(ev.motion.xrel, ev.motion.yrel);
                pan.sample(ev.motion.xrel, ev.motion.yrel, ev.motion.timestamp);
            }
        },
        cc.SDL_EVENT_MOUSE_WHEEL => l.zoomAtLogical(@as(f64, ev.wheel.y) * 0.25, ev.wheel.mouse_x, ev.wheel.mouse_y),
        cc.SDL_EVENT_WINDOW_RESIZED => l.resize(@intCast(ev.window.data1), @intCast(ev.window.data2)) catch {},
        cc.SDL_EVENT_KEY_DOWN => switch (ev.key.key) {
            cc.SDLK_N => l.cycleScheme(),
            cc.SDLK_T => l.toggleText(),
            cc.SDLK_D => l.toggleOtherCategory(),
            cc.SDLK_S => l.toggleSoundings(),
            cc.SDLK_LEFTBRACKET => l.nudgeSafetyContour(-2),
            cc.SDLK_RIGHTBRACKET => l.nudgeSafetyContour(2),
            cc.SDLK_EQUALS => l.adjustSize(1.1),
            cc.SDLK_MINUS => l.adjustSize(1.0 / 1.1),
            cc.SDLK_ESCAPE => running.* = false,
            else => {},
        },
        else => {},
    }
}

fn runWindow(l: *lk.Lookout, max_frames: ?u64) !void {
    var dragging = false;
    var running = true;
    var frame: u64 = 0;
    var pan = PanTracker{};
    const test_mode = max_frames != null; // render every iteration for --frames
    var last_ns = cc.SDL_GetTicksNS();
    while (running) {
        if (max_frames) |mf| {
            if (frame >= mf) break;
        }
        var ev: cc.SDL_Event = undefined;
        // On-demand: block on events when static (0% CPU idle). While a zoom ease
        // or fling is running, never block — spin so it animates every frame. A
        // short timeout keeps a background build filling in progressively.
        if (!test_mode and !l.animating() and !l.needsRedraw()) {
            const timeout: i32 = if (l.isBuilding()) 16 else 250;
            if (cc.SDL_WaitEventTimeout(&ev, timeout)) handleEvent(l, &ev, &dragging, &running, &pan);
        }
        while (cc.SDL_PollEvent(&ev)) handleEvent(l, &ev, &dragging, &running, &pan);
        const now_ns = cc.SDL_GetTicksNS();
        var dt = @as(f64, @floatFromInt(now_ns -% last_ns)) / 1e9;
        last_ns = now_ns;
        if (dt > 0.05) dt = 0.05; // cap the step after an idle block
        if (l.animating()) l.tickAnim(dt);
        if (test_mode or l.needsRedraw()) {
            _ = try l.render();
            frame += 1;
        }
    }
}
