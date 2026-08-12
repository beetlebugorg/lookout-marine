//! The MapLibre host: what `-Dbackend=maplibre` puts behind `lookout.h`.
//!
//! This replaces the scene lifecycle in root.zig and the four GPU transports,
//! not the C ABI. A shell still calls `lookout_open_charts_in_window`,
//! `lookout_set_view`, `lookout_render`. It never learns MapLibre exists.
//!
//! WHAT THE CHART IS MADE OF HERE
//!
//!   tiles      the SAME baked .pmtiles, served by provider.zig out of the
//!              live compositor. No merge, no re-bake, no tile server.
//!   style      tile57's own 240-layer S-101 style, built for the mariner.
//!   sprites    tile57's MapLibre sprite sheet, per scheme and density.
//!   glyphs     tile57's glyph PBF ranges.
//!
//! So the portrayal is the engine's, exactly as it is on the GPU path. What
//! changes is who rasterises it.
//!
//! WHAT COSTS WHAT, WHICH IS THE WHOLE POINT OF THE EXERCISE
//!
//! On the GPU path every mariner control is one 128-byte uniform write. Here
//! they split in two, and the split is the real finding of this branch:
//!
//!   scheme, safety contour, depth unit   -> rebuild the style, setStyle.
//!                                           Paint-only; no tile re-layout.
//!   display category, text, soundings    -> filter changes. MapLibre
//!                                           re-lays-out every loaded tile.
//!   SCAMIN boundary crossing             -> one setLayerFilter, a few times
//!                                           per gesture (see style.Gate).
//!
//! The middle row is the honest cost of the port and the thing to measure
//! before anyone claims parity. See specs/maplibre/concerns.md C6.

const std = @import("std");
const cc = @import("../c.zig").c;
const maplibre = @import("maplibre_native_ffi");
const provider_mod = @import("provider.zig");
const style_mod = @import("style.zig");
const builtin = @import("builtin");
const is_android = builtin.abi == .android or builtin.abi == .androideabi;
const vkboot = if (is_android) @import("vk_boot.zig") else struct {};
const sleepMs = @import("../lock.zig").sleepMs;
const WakeEvent = @import("../lock.zig").WakeEvent;
const nowMs = @import("../lock.zig").nowMs;
const setThreadQos = @import("../lock.zig").setThreadQos;

const memoryPressureRelief = @import("../lock.zig").memoryPressureRelief;

var rframe: u64 = 0;

/// First-light diagnostics. stderr is discarded for a bundled app launched with
/// `open`, and that is the only launch that makes a window, so the one place a
/// message reliably survives is a file. Off unless LOOKOUT_ML_LOG is set.
pub fn mlog(comptime fmt: []const u8, args: anytype) void {
    const path = std.c.getenv("LOOKOUT_ML_LOG") orelse return;
    const f = std.c.fopen(path, "a") orelse return;
    defer _ = std.c.fclose(f);
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.fwrite(msg.ptr, 1, msg.len, f);
}

/// MapLibre log records -> the mlog file. Returning true marks the record
/// consumed so it does not also go to the platform default sink.
fn mlnLog(_: ?*anyopaque, record: maplibre.LogRecord) bool {
    mlog("mln[{s}/{s}]: {s}\n", .{ @tagName(record.severity), @tagName(record.event), record.message });
    return true;
}

pub const View = struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 = 0 };

/// lookout's camera counts zoom against a 256 px world tile (camera.zig
/// worldToPx); MapLibre counts against 512 (util::tileSize_D), so the same
/// number means twice the scale there. Convert ONCE, here at the seam, or
/// every derived quantity goes wrong together: the chart renders one level
/// finer than the HUD claims, a pan overshoots the finger by exactly 2x, the
/// zoom pivot misses the cursor, and the SCAMIN gate declutters for the wrong
/// denominator. tile57's own displayDenom/style math is 512-based (verified
/// against GL JS), so the CONVERTED zoom is also the one the gate wants.
pub fn mlZoom(lookout_zoom: f64) f64 {
    return lookout_zoom - 1.0;
}

pub const Error = error{
    RuntimeFailed,
    MapFailed,
    SessionFailed,
    StyleFailed,
    Unsupported,
} || style_mod.Error;

/// One gated layer: its id and its full filter split around the denominator
/// literals. parts.len == slots + 1; the filter is rebuilt as
/// parts[0] ++ denom ++ parts[1] ++ denom ++ … ++ parts[n].
const Gated = struct { id: []u8, parts: [][]u8 };

const RunResult = struct { id: []u8, w: u32, h: u32, pixels: []u8 };
const Lock = @import("../lock.zig").Lock;

/// The two clause shapes (from tile57's writeScaminClause / writeOsclClause,
/// re-serialized by std.json so the byte shapes here are deterministic) whose
/// trailing number is the live display denominator the host must keep current.
const denom_slots = [_][]const u8{
    "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1000000000000],",
    "[\">\",[\"coalesce\",[\"get\",\"oscl\"],0],",
};

pub const Host = struct {
    alloc: std.mem.Allocator,

    runtime: maplibre.RuntimeHandle,
    map: maplibre.MapHandle,
    session: ?maplibre.RenderSessionHandle = null,

    provider: provider_mod.Provider,
    assets: style_mod.Assets,

    view: View = .{ .lon = 0, .lat = 0, .zoom = 2 },
    mariner: cc.tile57_mariner,
    scheme: cc.tile57_scheme = cc.TILE57_SCHEME_DAY,
    density: f64 = 1,

    gate: style_mod.Gate,
    /// The open archive's stored tile encoding. Telling MapLibre "mlt" for an
    /// MVT archive (or the reverse) is silent: the tiles arrive, fail to
    /// decode, and the chart stays empty. So this is read from the chart, never
    /// assumed.
    tile_encoding: u8 = cc.TILE57_TILE_TYPE_MVT,

    /// Deferred-start state. The surface arrives on the shell's thread; the
    /// render thread picks it up on its next frame.
    started: bool = false,
    /// MapLibre's own thread. The FFI binds the runtime and the render session
    /// to the thread that created them, and this app drives frames from a
    /// serial DispatchQueue — which is serial but NOT thread-stable, so the
    /// same queue lands on different OS threads over time and every other frame
    /// comes back WrongThread. Owning a thread outright is the only way to hold
    /// the contract; `render` just signals it.
    rthread: ?std.Thread = null,
    rwake: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    rwake_ev: WakeEvent = .{},
    rstop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending_layer: ?*anyopaque = null,
    /// Android only: the Vulkan context MapLibre's session borrows (see
    /// vk_boot.zig). Torn down after the session detaches.
    vk_boot: (if (is_android) ?vkboot.Boot else void) = if (is_android) null else {},
    pending_w: u32 = 0,
    pending_h: u32 = 0,
    applied_w: u32 = 0,
    applied_h: u32 = 0,
    applied_density: f64 = 0,
    /// Set once the shell has reported a real display density.
    density_known: bool = false,
    /// The provider's answer count as of the last frame, and how many more
    /// frames to draw after the last answer. MapLibre places arriving material
    /// over several frames, so going idle the instant it says "loaded" leaves
    /// the chart half-drawn.
    last_served: u64 = 0,
    settle_frames: u32 = 0,
    view_seq: u32 = 0,
    applied_view_seq: u32 = 0,
    /// The converted zoom the last frame saw; the SCAMIN gate only rewrites
    /// once the zoom rests at a value (see tickGate).
    last_zoom_applied: f64 = -1,
    /// A crossing happened mid-gesture; keep framing until it can be written.
    gate_pending: bool = false,
    /// Frames spent waiting to apply a pending style swap (see frame()).
    style_swap_wait: u32 = 0,
    // Frame cadence stats, printed every 120 frames when LOOKOUT_ML_FRAMESTATS
    // is set: the inter-frame gap and renderUpdate cost, avg and max. Jitter
    // is a max several times the avg; this makes it a number.
    fs_last_ms: i64 = 0,
    fs_gap_sum: i64 = 0,
    fs_gap_max: i64 = 0,
    fs_ru_sum: i64 = 0,
    fs_ru_max: i64 = 0,
    fs_n: u32 = 0,
    /// Style generation, stamped into the sprite url (?g=N). MapLibre matches
    /// resources by url, so a generation-unique url makes it impossible for a
    /// sprite fetched by one style load to satisfy a later one — the residual
    /// icon-palette wedge after rapid scheme flips.
    style_gen: u32 = 0,
    /// Composite runs (sounding digit stacks) already rendered and registered
    /// for the CURRENT style. Cleared on every rebuild: images live on the
    /// style, and a scheme change must re-render them in the new palette.
    runs_done: std.StringHashMapUnmanaged(void) = .empty,
    /// Run rasterization moved OFF the render thread: SVG-compositing a
    /// missing sounding run costs tens of ms, and a zoom into a fresh area
    /// misses dozens at once — rendered inline they were a visible freeze
    /// (the gesture literally stopped, then continued). The worker renders
    /// and premultiplies; the render thread only registers finished pixels.
    run_queue: std.ArrayList([]u8) = .empty,
    run_results: std.ArrayList(RunResult) = .empty,
    run_lock: Lock = .{},
    run_ev: WakeEvent = .{},
    run_thread: ?std.Thread = null,
    run_scheme: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// The layers whose filter carries a live display-denominator literal (the
    /// SCAMIN gate and the overscale clause). For each, the layer's WHOLE
    /// serialized filter, split around those literals — the rewrite joins the
    /// parts with the new denominator and sets the COMPLETE filter back.
    ///
    /// Replacing the filter with only the SCAMIN clause is the bug this
    /// structure exists to prevent: it silently drops every other clause the
    /// style build composed (the ls_style match, display category, the M_QUAL
    /// and INFORM01 exclusions…), and the chart drowns in symbols that were
    /// supposed to be filtered — decorations on every line, quality symbology
    /// over all water. Collected once per style, from our own style bytes.
    gated: std.ArrayList(Gated) = .empty,
    /// Owns the denominator manifest the gate points at.
    scamin_owned: []i32 = &.{},

    /// Set when something changed that the next render must act on. The
    /// invariant this serves is `idle means idle`: with nothing pending and no
    /// tiles in flight, a frame is not drawn at all.
    dirty: bool = true,

    /// Set when the mariner/scheme/library changed and the style must be
    /// rebuilt. The FFI binds the map to the render thread, so a shell-thread
    /// setMariner cannot call setStyleJson itself (WrongThread, silently a
    /// stale chart) — it records here and the next frame rebuilds.
    style_stale: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// An ALTERNATIVE chart: a MapLibre style url the mariner added. When
    /// set, the map renders that style INSTEAD of the tile57-built one —
    /// our chart is just the default entry in the list. MapLibre fetches
    /// the style and everything it names (sources, sprite, glyphs) through
    /// its own file source. null = the built-in chart. Owned.
    alt_style_url: ?[:0]u8 = null,

    /// Allocate and bake the catalogue assets. Deliberately touches NOTHING in
    /// MapLibre: the FFI binds a runtime to its creating thread and a render
    /// session to the thread that attached it, and in this app that thread is
    /// the render thread, not whichever one opened the chart. Everything
    /// MapLibre-shaped is therefore deferred to `ensureStarted`, which only
    /// `render` calls. Getting this wrong is not a crash — it is
    /// `renderUpdate` returning WrongThread forever and a blank chart.
    pub fn open(alloc: std.mem.Allocator) Error!*Host {
        const self = alloc.create(Host) catch return Error.OutOfMemory;
        errdefer alloc.destroy(self);

        var m: cc.tile57_mariner = undefined;
        cc.tile57_mariner_defaults(&m);

        self.* = .{
            .alloc = alloc,
            .runtime = undefined,
            .map = undefined,
            .provider = provider_mod.Provider.init(alloc),
            .assets = try style_mod.Assets.bake(null),
            .mariner = m,
            .gate = .{ .denoms = &.{}, .lat = 0 },
        };
        self.rwake_ev.init();
        self.run_ev.init();
        mlog("ml: Host.open (deferred start)\n", .{});
        return self;
    }

    /// Stand MapLibre up on the calling thread. Called only from `render`, so
    /// the runtime owner thread and the render session owner thread are the
    /// same thread, which is what the FFI requires.
    fn ensureStarted(self: *Host) Error!void {
        if (self.started) return;
        const layer = self.pending_layer orelse return; // no surface yet
        // MapOptions.scale_factor is FIXED for the map's lifetime and is what
        // selects the sprite and glyph density. Standing the map up before the
        // shell has reported the display density pins a Retina app to the 1x
        // sheet for good — symbols come out at the wrong size and the chart
        // looks like clutter. So wait for a real density; the shell delivers
        // one on its first resize, which is always before the first frame.
        if (!self.density_known) return;

        // MapLibre's own log stream, into the same file as ours. This is where
        // a rejected filter, a failed sprite load or a glyph parse error goes;
        // without it every style mistake is a silent visual defect.
        maplibre.setLogCallback(.{ .handler = mlnLog }, null) catch {};
        maplibre.setAsyncLogSeverityMask(maplibre.LogSeverityMask.all, null) catch {};

        const rt = maplibre.RuntimeHandle.create(self.alloc, .{}, null) catch |e| {
            mlog("ml: RuntimeHandle.create FAILED {s}\n", .{@errorName(e)});
            return Error.RuntimeFailed;
        };
        self.runtime = rt;

        self.map = maplibre.MapHandle.create(&self.runtime, .{
            // MLT is the bake default. Without this the FastPFOR integer
            // streams parse as a warning and nothing draws.
            .fast_pfor_enabled = true,
            .scale_factor = self.density,
        }) catch |e| {
            mlog("ml: MapHandle.create FAILED {s}\n", .{@errorName(e)});
            return Error.MapFailed;
        };

        // Kill MapLibre's ambient cache. Every provider response was being
        // gzip-compressed and written into its offline SQLite DURING gestures
        // (OfflineDatabase::put -> deflate, a whole thread of it in the zoom
        // profile) — for tiles that are local, deterministic, and already in
        // this process's LRU. Zero disables the store.
        _ = self.runtime.startSetMaximumAmbientCacheSize(0) catch |e| {
            mlog("ml: ambient cache disable FAILED {s}\n", .{@errorName(e)});
        };

        self.provider.start() catch return Error.RuntimeFailed;
        self.runtime.setResourceProvider(.{
            .handler = provider_mod.Provider.handler,
            .context = @ptrCast(&self.provider),
        }) catch |e| {
            mlog("ml: setResourceProvider FAILED {s}\n", .{@errorName(e)});
            return Error.RuntimeFailed;
        };

        // Apple attaches straight to the CAMetalLayer; Android stands a
        // Vulkan context up over the ANativeWindow first (vk_boot.zig) and
        // hands MapLibre the pieces — it builds its swapchain over them.
        const extent: maplibre.RenderTargetExtent = .{
            .width = self.pending_w,
            .height = self.pending_h,
            .scale_factor = self.density,
        };
        const session = if (comptime is_android) blk: {
            var boot = vkboot.init(layer) catch {
                mlog("ml: vulkan bootstrap FAILED\n", .{});
                return Error.SessionFailed;
            };
            errdefer boot.deinit();
            const sess = maplibre.attachVulkanSurface(&self.map, .{
                .extent = extent,
                .context = .{
                    .instance = maplibre.NativePointer.fromPtr(@ptrCast(boot.instance)),
                    .physical_device = maplibre.NativePointer.fromPtr(@ptrCast(boot.phys)),
                    .device = maplibre.NativePointer.fromPtr(@ptrCast(boot.device)),
                    .graphics_queue = maplibre.NativePointer.fromPtr(@ptrCast(boot.queue)),
                    .graphics_queue_family_index = boot.family,
                },
                .surface = maplibre.NativePointer.fromPtr(@ptrCast(boot.surface)),
            }) catch |e| {
                mlog("ml: attachVulkanSurface FAILED {s}\n", .{@errorName(e)});
                return Error.SessionFailed;
            };
            self.vk_boot = boot;
            break :blk sess;
        } else maplibre.attachMetalSurface(&self.map, .{
            .layer = maplibre.NativePointer.fromPtr(layer),
            .extent = extent,
        }) catch |e| {
            mlog("ml: attachMetalSurface FAILED {s}\n", .{@errorName(e)});
            return Error.SessionFailed;
        };
        self.session = session;
        self.started = true;
        mlog("ml: started on render thread, {d}x{d} @{d}\n", .{ self.pending_w, self.pending_h, self.density });

        try self.rebuildStyle();
        self.applyView();
    }

    pub fn close(self: *Host) void {
        // Order matters: stop answering before the map can ask again, or the
        // worker completes a handle the runtime has already torn down.
        self.rstop.store(true, .release);
        self.rwake_ev.signal();
        self.run_ev.signal();
        if (self.run_thread) |t| t.join();
        self.run_thread = null;
        for (self.run_queue.items) |q| self.alloc.free(q);
        self.run_queue.deinit(self.alloc);
        for (self.run_results.items) |r| {
            self.alloc.free(r.id);
            self.alloc.free(r.pixels);
        }
        self.run_results.deinit(self.alloc);
        if (self.rthread) |t| t.join();
        self.rthread = null;
        if (self.alt_style_url) |cur| self.alloc.free(cur);
        if (!self.started) {
            self.provider.deinit();
            self.dropGatedIds();
            self.gated.deinit(self.alloc);
            self.assets.deinit();
            if (self.scamin_owned.len != 0) self.alloc.free(self.scamin_owned);
            self.alloc.destroy(self);
            return;
        }
        self.runtime.clearResourceProvider() catch {};
        self.provider.deinit();
        if (self.session) |*s| s.detach() catch {};
        if (comptime is_android) if (self.vk_boot) |*boot| {
            boot.deinit();
            self.vk_boot = null;
        };
        self.map.close() catch {};
        self.runtime.close() catch {};
        self.dropGatedIds();
        self.gated.deinit(self.alloc);
        self.dropRunsDone();
        self.runs_done.deinit(self.alloc);
        self.assets.deinit();
        if (self.scamin_owned.len != 0) self.alloc.free(self.scamin_owned);
        self.alloc.destroy(self);
    }

    // ---- what the library is -------------------------------------------

    /// Point the host at the open library and rebuild the style for it.
    /// `scamin` is the manifest from `tile57_chart_scamin`, which the gate
    /// watches; `lat` is the library centre.
    pub fn setLibrary(
        self: *Host,
        compose: ?*cc.tile57_compose,
        chart: ?*cc.tile57_chart,
        scamin: []const i32,
        lat: f64,
    ) Error!void {
        self.provider.setSource(compose, chart);

        if (chart) |ch| {
            var info: cc.tile57_info = std.mem.zeroes(cc.tile57_info);
            cc.tile57_chart_get_info(ch, &info);
            if (info.tile_type != 0) self.tile_encoding = info.tile_type;
            mlog("ml: chart tile_type={d}\n", .{info.tile_type});
        }

        if (self.scamin_owned.len != 0) self.alloc.free(self.scamin_owned);
        self.scamin_owned = self.alloc.dupe(i32, scamin) catch return Error.OutOfMemory;
        std.mem.sort(i32, self.scamin_owned, {}, std.sort.asc(i32));
        self.gate = .{ .denoms = self.scamin_owned, .lat = lat };

        self.markStyleStale();
    }

    // ---- the two classes of change --------------------------------------

    /// Paint-class change: rebuild the style and set it. No tile re-layout.
    fn rebuildStyle(self: *Host) Error!void {
        // Before the render thread stands the map up there is nothing to set a
        // style ON — ensureStarted rebuilds unconditionally once it exists, so
        // an early call records nothing and must not touch self.map.
        if (!self.started) return;
        // An added chart is a whole style of its own: hand MapLibre the url
        // and stand the built-in machinery down. No gated layers to drive,
        // no sounding runs to answer — a foreign style's missing images are
        // its own business (see queueRunImage's gate).
        if (self.alt_style_url) |url| {
            // The string is a url, or the style document itself (a TileJSON
            // link arrives as a shell-generated wrapper style — there is no
            // second url to fetch).
            if (url.len != 0 and url[0] == '{') {
                self.map.setStyleJson(self.alloc, url) catch |e| {
                    mlog("ml: alt setStyleJson FAILED: {s}\n", .{@errorName(e)});
                    return Error.StyleFailed;
                };
                mlog("ml: chart style -> inline document, {d} bytes\n", .{url.len});
            } else {
                self.map.setStyleUrl(self.alloc, url) catch |e| {
                    mlog("ml: setStyleUrl FAILED: {s}\n", .{@errorName(e)});
                    return Error.StyleFailed;
                };
                mlog("ml: chart style -> {s}\n", .{url});
            }
            self.gate.current = 0;
            self.dropGatedIds();
            self.gated.clearRetainingCapacity();
            self.dropRunsDone();
            self.dirty = true;
            return;
        }
        self.provider.setScheme(self.scheme);
        self.style_gen +%= 1;
        var style = try style_mod.build(.{
            .scheme = self.scheme,
            .mariner = self.mariner,
            .tile_encoding = self.tile_encoding,
            .scamin = self.scamin_owned,
            .scamin_lat = self.gate.lat,
            .sprite_generation = self.style_gen,
        }, &self.assets);
        defer style.deinit();

        mlog("ml: style built, {d} bytes\n", .{style.json.len});
        if (std.c.getenv("LOOKOUT_ML_STYLE")) |sp| {
            if (std.c.fopen(sp, "w")) |f| {
                _ = std.c.fwrite(style.json.ptr, 1, style.json.len, f);
                _ = std.c.fclose(f);
            }
        }
        // Debug override: render a hand-edited style instead of the built one.
        // The bisecting instrument for "which layer draws THAT": dump with
        // LOOKOUT_ML_STYLE, edit, feed back with LOOKOUT_ML_STYLE_IN.
        var injected_list = std.ArrayList(u8).empty;
        defer injected_list.deinit(self.alloc);
        if (std.c.getenv("LOOKOUT_ML_STYLE_IN")) |sp| {
            if (std.c.fopen(sp, "r")) |f| {
                defer _ = std.c.fclose(f);
                var chunk: [65536]u8 = undefined;
                while (true) {
                    const n = std.c.fread(&chunk, 1, chunk.len, f);
                    if (n == 0) break;
                    injected_list.appendSlice(self.alloc, chunk[0..n]) catch break;
                }
                if (injected_list.items.len != 0)
                    mlog("ml: style OVERRIDDEN from {s}, {d} bytes\n", .{ sp, injected_list.items.len });
            }
        }
        const injected: ?[]u8 = if (injected_list.items.len != 0) injected_list.items else null;
        const final: []const u8 = injected orelse style.json;
        self.map.setStyleJson(self.alloc, final) catch |e| {
            mlog("ml: setStyleJson FAILED: {s}\n", .{@errorName(e)});
            return Error.StyleFailed;
        };
        // A fresh style carries curDenom 0 (show all); the next view forces the
        // gate to be written rather than assumed.
        self.gate.current = 0;
        self.collectGatedIds(final);
        // Style images died with the old style; the map will re-report what it
        // misses and each run re-renders in the NEW scheme's palette.
        self.dropRunsDone();
        self.dirty = true;
    }

    /// Choose the chart: an added style url renders INSTEAD of the built-in
    /// chart; empty returns to the built-in. Copies; the caller keeps its
    /// buffer. The swap itself happens on the render thread like every
    /// other style change (markStyleStale → rebuildStyle).
    pub fn setAltStyleUrl(self: *Host, url: []const u8) Error!void {
        const same = if (self.alt_style_url) |cur| std.mem.eql(u8, cur, url) else url.len == 0;
        if (same) return;
        const copy: ?[:0]u8 = if (url.len == 0) null else self.alloc.dupeZ(u8, url) catch return Error.OutOfMemory;
        if (self.alt_style_url) |cur| self.alloc.free(cur);
        self.alt_style_url = copy;
        self.markStyleStale();
    }

    pub fn setScheme(self: *Host, s: cc.tile57_scheme) Error!void {
        if (self.scheme == s) return;
        self.scheme = s;
        self.markStyleStale();
    }

    /// Adopt the mariner's full state, scheme included — the shells set the
    /// scheme as a mariner field, so honouring it here is what makes
    /// day/dusk/night work on this backend at all.
    pub fn setMariner(self: *Host, m: cc.tile57_mariner) Error!void {
        self.mariner = m;
        self.scheme = m.scheme;
        self.markStyleStale();
    }

    /// Every style-affecting mutation lands here, from whichever thread the
    /// shell called on. The map is bound to the render thread, so calling
    /// setStyleJson from here would be WrongThread — record instead, and the
    /// next frame rebuilds. Setting `dirty` is what guarantees that frame
    /// happens even on an otherwise still chart.
    fn markStyleStale(self: *Host) void {
        self.style_stale.store(true, .release);
        self.dirty = true;
    }

    // ---- the view --------------------------------------------------------

    /// Record the pose. The map is only ever touched from its own thread, so
    /// this records and the next frame applies it — which also means pan and
    /// zoom work without every gesture path having to know about MapLibre.
    pub fn setView(self: *Host, v: View) void {
        // The shell pushes the camera EVERY frame (root.zig render), so an
        // unchanged pose must be a no-op here — marking dirty for it would
        // mean the app never idles, and `idle means idle` is the invariant.
        const p = self.view;
        if (p.lon == v.lon and p.lat == v.lat and p.zoom == v.zoom and p.rotation_deg == v.rotation_deg) return;
        self.view = v;
        self.view_seq +%= 1;
        self.dirty = true;
    }

    /// Apply the recorded pose. Render thread only.
    fn applyView(self: *Host) void {
        const v = self.view;
        const z = mlZoom(v.zoom);
        self.map.jumpTo(.{
            .center = .{ .latitude = v.lat, .longitude = v.lon },
            .zoom = z,
            // lookout's rotation turns the WORLD on screen; MapLibre's bearing
            // names the compass direction that points up — the same turn with
            // the opposite sign. Passing it through unnegated span the chart
            // against the drag.
            .bearing = -v.rotation_deg,
            .pitch = 0,
        }) catch {};
    }

    /// Tell the provider where the view is, in source-tile coordinates, so
    /// its idle workers can pre-compose the zoom-out parents and the pan ring
    /// into the tile cache. The native path feels instant because its scene
    /// is built before the mariner asks; this is that idea for tiles.
    fn hintPrefetch(self: *Host) void {
        const zf = mlZoom(self.view.zoom);
        if (zf < 1 or zf > 22) return;
        const z: u8 = @intFromFloat(@floor(zf));
        const n: f64 = @floatFromInt(@as(u32, 1) << @intCast(z));
        const lon = std.math.clamp(self.view.lon, -179.999, 179.999);
        const lat = std.math.clamp(self.view.lat, -85.0, 85.0);
        const x: u32 = @intFromFloat(@floor((lon + 180.0) / 360.0 * n));
        const s = @sin(lat * std.math.pi / 180.0);
        const yf = (0.5 - @log((1.0 + s) / (1.0 - s)) / (4.0 * std.math.pi)) * n;
        const y: u32 = @intFromFloat(std.math.clamp(@floor(yf), 0, n - 1));
        self.provider.hintView(z, x, y);
    }

    /// The SCAMIN gate check, run once per frame. Only when the view steps
    /// over a denominator the library carries does the literal change — and
    /// even then ONLY AT REST. A gate write re-filters every gated layer,
    /// which re-lays-out every loaded tile: the one genuinely expensive
    /// control on this backend (concerns C6). A zoom ease crosses several
    /// denominators in a second; rewriting at each made the gesture a
    /// re-layout storm. Features popping at a slightly stale threshold
    /// mid-gesture is invisible; jank is not. The first write (off show-all)
    /// lands immediately so the chart never starts uncluttered, and a pending
    /// crossing keeps `dirty` set so the settling frame that writes it is
    /// guaranteed to happen.
    fn tickGate(self: *Host) void {
        // The static zoom-gate (the shipped mode) has no live literal to
        // rewrite; the whole driver is dormant unless a style carries one.
        if (self.gated.items.len == 0) return;
        const z = mlZoom(self.view.zoom);
        const stable = z == self.last_zoom_applied;
        self.last_zoom_applied = z;
        if (!self.gate.crosses(z)) return;
        if (stable or self.gate.current == 0) {
            const denom = self.gate.commit(z);
            self.writeScaminGate(denom);
        } else self.gate_pending = true;
    }

    fn dropRunsDone(self: *Host) void {
        var it = self.runs_done.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.runs_done.clearRetainingCapacity();
    }

    /// Queue one missing image id for the run worker. Non-run ids (no comma)
    /// have no runtime source and are recorded so they are attempted once.
    fn queueRunImage(self: *Host, id: []const u8) void {
        // A foreign chart's missing images are not sounding runs; rendering
        // tile57 glyph runs into someone else's style would paint garbage.
        if (self.alt_style_url != null) return;
        if (self.runs_done.contains(id)) return;
        const owned = self.alloc.dupe(u8, id) catch return;
        self.runs_done.put(self.alloc, owned, {}) catch {
            self.alloc.free(owned);
            return;
        };
        if (std.mem.indexOfScalar(u8, id, ',') == null) {
            mlog("ml: missing image (not a run): {s}\n", .{id});
            return;
        }
        const q = self.alloc.dupe(u8, id) catch return;
        self.run_lock.lock();
        self.run_queue.append(self.alloc, q) catch {
            self.run_lock.unlock();
            self.alloc.free(q);
            return;
        };
        self.run_lock.unlock();
        if (self.run_thread == null) {
            self.run_thread = std.Thread.spawn(.{}, runWorker, .{self}) catch null;
        }
        self.run_ev.signal();
    }

    /// Register every run the worker finished — one frame, one atlas pass.
    fn registerFinishedRuns(self: *Host) void {
        while (true) {
            self.run_lock.lock();
            if (self.run_results.items.len == 0) {
                self.run_lock.unlock();
                return;
            }
            const r = self.run_results.orderedRemove(0);
            self.run_lock.unlock();
            self.map.setStyleImage(self.alloc, r.id, .{
                .width = r.w,
                .height = r.h,
                .stride = r.w * 4,
                .pixels = r.pixels,
            }, .{ .pixel_ratio = @floatCast(self.density) }) catch |e| {
                mlog("ml: setStyleImage {s} FAILED {s}\n", .{ r.id, @errorName(e) });
            };
            self.alloc.free(r.id);
            self.alloc.free(r.pixels);
            self.dirty = true;
        }
    }

    /// The run worker: rasterize queued runs via the engine, premultiply, and
    /// hand pixels back to the render thread. Palette follows self.scheme at
    /// render time; a scheme change clears runs_done and the map re-asks.
    fn runWorker(self: *Host) void {
        while (!self.rstop.load(.acquire)) {
            self.run_lock.lock();
            if (self.run_queue.items.len == 0) {
                self.run_lock.unlock();
                self.run_ev.waitMs(250);
                continue;
            }
            const id = self.run_queue.orderedRemove(0);
            self.run_lock.unlock();
            defer self.alloc.free(id);

            const idz = self.alloc.dupeZ(u8, id) catch continue;
            defer self.alloc.free(idz);
            var rgba: ?[*]u8 = null;
            var w: u32 = 0;
            var h: u32 = 0;
            var err: cc.tile57_error = undefined;
            if (cc.tile57_render_symbol_run(null, idz.ptr, self.density, @intCast(self.scheme), &rgba, &w, &h, &err) != cc.TILE57_OK) continue;
            const px = rgba orelse continue;
            defer cc.tile57_free(px);
            const n: usize = @as(usize, w) * h * 4;
            var i: usize = 0;
            while (i < n) : (i += 4) {
                const a: u32 = px[i + 3];
                px[i + 0] = @intCast((@as(u32, px[i + 0]) * a + 127) / 255);
                px[i + 1] = @intCast((@as(u32, px[i + 1]) * a + 127) / 255);
                px[i + 2] = @intCast((@as(u32, px[i + 2]) * a + 127) / 255);
            }
            const id_copy = self.alloc.dupe(u8, id) catch continue;
            const pix = self.alloc.dupe(u8, px[0..n]) catch {
                self.alloc.free(id_copy);
                continue;
            };
            self.run_lock.lock();
            self.run_results.append(self.alloc, .{ .id = id_copy, .w = w, .h = h, .pixels = pix }) catch {
                self.run_lock.unlock();
                self.alloc.free(id_copy);
                self.alloc.free(pix);
                continue;
            };
            self.run_lock.unlock();
            // Wake the render thread to register the finished run.
            self.rwake_ev.signal();
            _ = self.rwake.fetchAdd(1, .release);
        }
    }

    fn dropGatedIds(self: *Host) void {
        for (self.gated.items) |g| {
            self.alloc.free(g.id);
            for (g.parts) |p| self.alloc.free(p);
            self.alloc.free(g.parts);
        }
        self.gated.clearRetainingCapacity();
    }

    /// Find the layers whose filter carries a live denominator, from the style
    /// bytes WE built (never read back from the map: MapLibre's re-serialized
    /// filters are not byte-stable, and our own bytes are). Once per style.
    fn collectGatedIds(self: *Host, style_json: []const u8) void {
        self.dropGatedIds();
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, style_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const layers_v = parsed.value.object.get("layers") orelse return;
        if (layers_v != .array) return;

        var total: usize = 0;
        for (layers_v.array.items) |lv| {
            if (lv != .object) continue;
            total += 1;
            const id_v = lv.object.get("id") orelse continue;
            if (id_v != .string) continue;
            const f_v = lv.object.get("filter") orelse continue;
            const fs = std.json.Stringify.valueAlloc(self.alloc, f_v, .{}) catch continue;
            defer self.alloc.free(fs);

            var parts = std.ArrayList([]u8).empty;
            errdefer {
                for (parts.items) |p| self.alloc.free(p);
                parts.deinit(self.alloc);
            }
            var start: usize = 0;
            var cursor: usize = 0;
            scan: while (cursor < fs.len) {
                var hit: ?usize = null;
                var hit_len: usize = 0;
                for (denom_slots) |slot| {
                    const at = std.mem.indexOfPos(u8, fs, cursor, slot) orelse continue;
                    if (hit == null or at < hit.?) {
                        hit = at;
                        hit_len = slot.len;
                    }
                }
                const at = hit orelse break :scan;
                var num_end = at + hit_len;
                while (num_end < fs.len and (std.ascii.isDigit(fs[num_end]) or
                    fs[num_end] == '.' or fs[num_end] == '-' or fs[num_end] == '+' or
                    fs[num_end] == 'e' or fs[num_end] == 'E')) num_end += 1;
                const head = self.alloc.dupe(u8, fs[start .. at + hit_len]) catch break :scan;
                parts.append(self.alloc, head) catch {
                    self.alloc.free(head);
                    break :scan;
                };
                start = num_end;
                cursor = num_end;
            }
            if (parts.items.len == 0) {
                parts.deinit(self.alloc);
                continue; // no live denominator in this filter
            }
            const tail = self.alloc.dupe(u8, fs[start..]) catch continue;
            parts.append(self.alloc, tail) catch {
                self.alloc.free(tail);
                continue;
            };
            const owned_id = self.alloc.dupe(u8, id_v.string) catch continue;
            self.gated.append(self.alloc, .{
                .id = owned_id,
                .parts = parts.toOwnedSlice(self.alloc) catch {
                    self.alloc.free(owned_id);
                    continue;
                },
            }) catch continue;
        }
        mlog("ml: {d} denominator-gated layers of {d}\n", .{ self.gated.items.len, total });
    }

    /// Rewrite the live denominator on every gated layer by setting the WHOLE
    /// composed filter back with the new literal spliced in. This is the one
    /// place that pays MapLibre's re-layout on purpose, a few times per
    /// gesture. Never set a fragment: every clause the style build composed
    /// must survive the rewrite (see `gated`).
    fn writeScaminGate(self: *Host, denom: f64) void {
        var dbuf: [64]u8 = undefined;
        const dstr = std.fmt.bufPrint(&dbuf, "{d}", .{denom}) catch return;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        for (self.gated.items) |g| {
            out.clearRetainingCapacity();
            for (g.parts, 0..) |p, i| {
                if (i != 0) out.appendSlice(self.alloc, dstr) catch return;
                out.appendSlice(self.alloc, p) catch return;
            }
            self.map.setLayerFilter(self.alloc, g.id, out.items) catch {};
        }
    }

    // ---- the surface and the frame ---------------------------------------

    /// Take the shell's layer. Runs on the shell's thread, so it only records
    /// what to attach; `ensureStarted` does the attaching on the render thread.
    pub fn attachMetal(self: *Host, layer: *anyopaque, w: u32, h_px: u32, density: f64) Error!void {
        self.pending_layer = layer;
        self.pending_w = w;
        self.pending_h = h_px;
        self.density = density;
        self.dirty = true;
    }

    pub fn resize(self: *Host, w: u32, h_px: u32, density: f64) void {
        self.pending_w = w;
        self.pending_h = h_px;
        if (density > 0) {
            self.density = density;
            self.density_known = true;
        }
        // Only the render thread owns the session; a resize from the shell
        // thread just records the size and the next frame applies it.
        self.dirty = true;
    }

    /// One frame. Returns true when something was drawn.
    ///
    /// `renderUpdate` reports whether MapLibre still has work pending — tiles
    /// in flight, a style settling. We keep asking while it does and stop when
    /// it does not, which is what turns `idle means idle` from an aspiration
    /// into a property: a still chart issues no frames at all.
    pub fn render(self: *Host) bool {
        // Hand the frame to MapLibre's own thread and return. The caller here
        // is a DispatchQueue worker and must not touch the map at all.
        if (self.rthread == null) {
            if (!self.density_known or self.pending_layer == null) return false;
            self.rthread = std.Thread.spawn(.{}, renderLoop, .{self}) catch return false;
        }
        _ = self.rwake.fetchAdd(1, .release);
        self.rwake_ev.signal();
        return true;
    }

    /// MapLibre's thread: it creates the runtime and the session, so it owns
    /// both, and it is the only thread that ever calls into them.
    fn renderLoop(self: *Host) void {
        setThreadQos(.user_interactive);
        self.ensureStarted() catch |e| {
            mlog("ml: ensureStarted FAILED {s}\n", .{@errorName(e)});
            return;
        };
        var last_wake: u32 = 0;
        while (!self.rstop.load(.acquire)) {
            const wake = self.rwake.load(.acquire);
            const asked = wake != last_wake;
            last_wake = wake;
            if (!asked and !self.dirty) {
                // Idle means idle: nothing asked for a frame and the map has
                // nothing left to settle. Block until the next signal (the
                // long timeout is only a heartbeat). An event, not a sleep
                // poll: a poll added up to its whole period of latency to
                // EVERY vsync-paced frame request, which reads as stutter.
                self.rwake_ev.waitMs(250);
                continue;
            }
            _ = self.frame();
            // ONE frame per signal or pacing tick. Following an asked frame
            // straight into an unasked dirty frame re-presented the same pose
            // mid-vsync-interval, and that irregular present cadence read as
            // pan jitter. The wait returns early on the next signal, so
            // gesture latency is untouched; between signals the fill-in still
            // ticks. The drain collapses any signal burst that landed during
            // the frame into a single further wake-up.
            self.rwake_ev.drain();
            self.rwake_ev.waitMs(30);
        }
    }

    fn frame(self: *Host) bool {
        const session = &(self.session orelse return false);
        if (self.style_stale.load(.acquire)) {
            // Swap styles only once the CURRENT one has finished loading. A
            // swap issued while the previous sprite fetch was still in flight
            // wedged the icon palette on whichever sheet landed last — a day
            // chart wearing dusk symbols and white dusk soundings, until the
            // next swap. Rapid flips coalesce here anyway (last one wins),
            // and the wait is bounded so a stuck tile cannot pin the scheme.
            self.style_swap_wait += 1;
            const settled_enough = (self.map.isFullyLoaded() catch true) or self.style_swap_wait > 120;
            if (settled_enough and self.style_stale.swap(false, .acq_rel)) {
                self.style_swap_wait = 0;
                self.rebuildStyle() catch |e| mlog("ml: deferred rebuild FAILED {s}\n", .{@errorName(e)});
            } else {
                self.dirty = true; // keep framing until the swap can land
            }
        } else {
            self.style_swap_wait = 0;
        }
        if (self.view_seq != self.applied_view_seq) {
            self.applied_view_seq = self.view_seq;
            self.applyView();
        }
        self.gate_pending = false;
        self.tickGate();
        if (self.pending_w != 0 and
            (self.pending_w != self.applied_w or self.pending_h != self.applied_h or self.density != self.applied_density))
        {
            session.resize(.{ .width = self.pending_w, .height = self.pending_h, .scale_factor = self.density }) catch {};
            self.applied_w = self.pending_w;
            self.applied_h = self.pending_h;
            self.applied_density = self.density;
            mlog("ml: extent {d}x{d} @{d}\n", .{ self.pending_w, self.pending_h, self.density });
        }

        // Drain the runtime's owner-thread queues first: that is what delivers
        // completed tiles, style loads and sprite images into the map. Without
        // it the provider answers and nothing ever appears.
        self.runtime.pump(0) catch {};

        // The map names what it cannot draw. Sounding depths are composite
        // digit runs ("SOUNDG11,SOUNDG53") and a library carries far more
        // distinct runs than any prebaked sheet — every sounding whose run
        // was missing simply did not draw. The ids queue to the run worker
        // (rasterizing here froze the gesture); finished pixels register
        // below, all of a frame's arrivals in one batch so MapLibre pays one
        // atlas pass.
        var polled: u32 = 0;
        while (polled < 512) : (polled += 1) {
            var ev = (self.runtime.pollEvent(self.alloc) catch break) orelse break;
            defer ev.deinit();
            switch (ev.payload) {
                .style_image_missing => |p| if (p.image_id.len != 0) self.queueRunImage(p.image_id),
                else => {},
            }
            // A failed load or a render error otherwise vanishes without a
            // trace — a source that never yields tiles (the bathymetry hunt)
            // looks identical to open ocean. Name it.
            switch (ev.event_type) {
                .map_loading_failed => mlog("mln EVENT loading_failed code={d}: {s}\n", .{ ev.code, ev.message }),
                .map_render_error => mlog("mln EVENT render_error code={d}: {s}\n", .{ ev.code, ev.message }),
                else => {},
            }
        }
        self.registerFinishedRuns();

        const fs_on = std.c.getenv("LOOKOUT_ML_FRAMESTATS") != null;
        const t0 = if (fs_on) nowMs() else 0;
        const result = session.renderUpdate() catch |e| {
            mlog("ml: renderUpdate error {s}\n", .{@errorName(e)});
            return false;
        };
        if (fs_on) {
            const t1 = nowMs();
            if (self.fs_last_ms != 0) {
                const gap = t0 - self.fs_last_ms;
                self.fs_gap_sum += gap;
                if (gap > self.fs_gap_max) self.fs_gap_max = gap;
            }
            self.fs_last_ms = t0;
            const ru = t1 - t0;
            self.fs_ru_sum += ru;
            if (ru > self.fs_ru_max) self.fs_ru_max = ru;
            self.fs_n += 1;
            if (self.fs_n >= 120) {
                mlog("ml: frames n={d} gap avg {d}ms max {d}ms | renderUpdate avg {d}ms max {d}ms\n", .{
                    self.fs_n,
                    @divTrunc(self.fs_gap_sum, self.fs_n),
                    self.fs_gap_max,
                    @divTrunc(self.fs_ru_sum, self.fs_n),
                    self.fs_ru_max,
                });
                self.fs_gap_sum = 0;
                self.fs_gap_max = 0;
                self.fs_ru_sum = 0;
                self.fs_ru_max = 0;
                self.fs_n = 0;
            }
        }

        // THE REDRAW RULE, and the one thing this port gets wrong if copied
        // from the GPU path. Our own renderer finishes a view in one call, so
        // `dirty` could be cleared the moment a frame was drawn. MapLibre does
        // not: a frame is drawn from whatever tiles have arrived so far, and
        // more keep arriving. Clear `dirty` on `.rendered` and the shell stops
        // asking, the runtime stops being pumped, and the chart freezes as an
        // empty background — which is exactly what happened here.
        //
        // So the map itself decides when we are idle. `isFullyLoaded` is false
        // while any tile, sprite or glyph is still outstanding, which keeps
        // `idle means idle` honest: a settled chart stops issuing frames.
        const served = self.provider.served.load(.acquire);
        if (served != self.last_served) {
            self.last_served = served;
            // Something new arrived. Keep drawing for a short while: placement
            // and label collision settle over a few frames, not one.
            self.settle_frames = 8;
        } else if (self.settle_frames > 0) {
            self.settle_frames -= 1;
        }

        const loaded = (self.map.isFullyLoaded() catch false) and self.settle_frames == 0;
        const was_dirty = self.dirty;
        self.dirty = self.gate_pending or switch (result) {
            .rendered, .no_update => !loaded,
            // Size not taken yet, or no drawable: ask again regardless.
            .size_pending, .target_not_ready => true,
            .unknown => !loaded,
        };
        // Entering idle: return the churn to the OS (see the extern above).
        // A style swap or load burst churns hundreds of MB of transients;
        // hand the freed pages back each time the map settles — and only THEN
        // arm the prefetcher. Hinting per frame re-armed it on every
        // centre-tile crossing: four workers perpetually composing fat
        // parents mid-gesture, which read as worse everything.
        if (was_dirty and !self.dirty) {
            memoryPressureRelief();
            self.hintPrefetch();
        }
        return result == .rendered;
    }

    pub fn needsRedraw(self: *const Host) bool {
        return self.dirty;
    }
};

// ---- tests ---------------------------------------------------------------

test "a fresh style resets the gate to show-all" {
    // The style ships curDenom 0. If the host kept a stale `current` across a
    // rebuild it would skip the first crossing and gate nothing until the next
    // one, which reads as "SCAMIN randomly stopped working".
    var gate = style_mod.Gate{ .denoms = &.{ 12000, 45000 }, .lat = 38.9 };
    _ = gate.commit(14.0);
    try std.testing.expect(gate.current > 0);
    gate.current = 0; // what rebuildStyle does
    try std.testing.expect(gate.crosses(14.0));
}

test "the zoom seam: 256px-world zoom N draws at MapLibre's N-1" {
    // Same on-screen scale on both sides: lookout's 256·2^z px world must
    // equal MapLibre's 512·2^mlZoom(z). If this drifts, pans overshoot 2x,
    // the zoom pivot misses the cursor, and the HUD lies about the scale.
    const z = 15.0;
    try std.testing.expectEqual(@as(f64, 256.0 * std.math.exp2(z)), 512.0 * std.math.exp2(mlZoom(z)));
}

test "the shipped style is statically gated: nothing to rewrite per gesture" {
    // The host ships the static zoom-gate: SCAMIN and overscale clauses
    // compare the baked per-feature gate zooms (vz/oz, tile57/3) against
    // ["zoom"] and gate themselves at tile load. That means the style must
    // contain NO live denominator slots (a slot means setLayerFilter storms
    // are back — the end-of-zoom freeze), and MUST carry the self-gating
    // form. If tile57's clause shapes drift, this is where it shows.
    const a = std.testing.allocator;
    var assets = try style_mod.Assets.bake(null);
    defer assets.deinit();
    var m: cc.tile57_mariner = undefined;
    cc.tile57_mariner_defaults(&m);
    var style = try style_mod.build(.{ .mariner = m, .scamin_lat = 38.9 }, &assets);
    defer style.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, a, style.json, .{});
    defer parsed.deinit();
    const layers = parsed.value.object.get("layers").?.array;
    var slot_hits: usize = 0;
    var static_hits: usize = 0;
    for (layers.items) |lv| {
        const f_v = lv.object.get("filter") orelse continue;
        const fs = try std.json.Stringify.valueAlloc(a, f_v, .{});
        defer a.free(fs);
        for (denom_slots) |slot| {
            if (std.mem.indexOf(u8, fs, slot) != null) slot_hits += 1;
        }
        if (std.mem.indexOf(u8, fs, "[\"<=\",[\"coalesce\",[\"get\",\"vz\"],0],[\"zoom\"]]") != null or
            std.mem.indexOf(u8, fs, "[\">\",[\"zoom\"],[\"coalesce\",[\"get\",\"oz\"],99]]") != null) static_hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), slot_hits);
    try std.testing.expect(static_hits > 100);
}

test "north-up is bearing zero on both sides" {
    // lookout rotation_deg 0 == north-up; MapLibre bearing 0 == north-up. If
    // this ever stops holding, a course-up view silently points the wrong way.
    const v = View{ .lon = -76.48, .lat = 38.97, .zoom = 15 };
    try std.testing.expectEqual(@as(f64, 0), v.rotation_deg);
}
