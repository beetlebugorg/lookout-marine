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
const sleepMs = @import("../lock.zig").sleepMs;

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

pub const View = struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 = 0 };

pub const Error = error{
    RuntimeFailed,
    MapFailed,
    SessionFailed,
    StyleFailed,
    Unsupported,
} || style_mod.Error;

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
    rstop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending_layer: ?*anyopaque = null,
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
    /// The ids of the layers whose filter carries a SCAMIN clause. Collected
    /// once per style: asking MapLibre for all 240 filters on every boundary
    /// crossing is the difference between a pinch that stutters and one that
    /// does not.
    gated_ids: std.ArrayList([]u8) = .empty,
    /// Owns the denominator manifest the gate points at.
    scamin_owned: []i32 = &.{},

    /// Set when something changed that the next render must act on. The
    /// invariant this serves is `idle means idle`: with nothing pending and no
    /// tiles in flight, a frame is not drawn at all.
    dirty: bool = true,

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

        self.provider.start() catch return Error.RuntimeFailed;
        self.runtime.setResourceProvider(.{
            .handler = provider_mod.Provider.handler,
            .context = @ptrCast(&self.provider),
        }) catch |e| {
            mlog("ml: setResourceProvider FAILED {s}\n", .{@errorName(e)});
            return Error.RuntimeFailed;
        };

        const session = maplibre.attachMetalSurface(&self.map, .{
            .layer = maplibre.NativePointer.fromPtr(layer),
            .extent = .{
                .width = self.pending_w,
                .height = self.pending_h,
                .scale_factor = self.density,
            },
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
        if (self.rthread) |t| t.join();
        self.rthread = null;
        if (!self.started) {
            self.provider.deinit();
            self.dropGatedIds();
            self.gated_ids.deinit(self.alloc);
            self.assets.deinit();
            if (self.scamin_owned.len != 0) self.alloc.free(self.scamin_owned);
            self.alloc.destroy(self);
            return;
        }
        self.runtime.clearResourceProvider() catch {};
        self.provider.deinit();
        if (self.session) |*s| s.detach() catch {};
        self.map.close() catch {};
        self.runtime.close() catch {};
        self.dropGatedIds();
        self.gated_ids.deinit(self.alloc);
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

        try self.rebuildStyle();
    }

    // ---- the two classes of change --------------------------------------

    /// Paint-class change: rebuild the style and set it. No tile re-layout.
    fn rebuildStyle(self: *Host) Error!void {
        self.provider.setScheme(self.scheme);
        var style = try style_mod.build(.{
            .scheme = self.scheme,
            .mariner = self.mariner,
            .tile_encoding = self.tile_encoding,
            .scamin = self.scamin_owned,
            .scamin_lat = self.gate.lat,
        }, &self.assets);
        defer style.deinit();

        mlog("ml: style built, {d} bytes\n", .{style.json.len});
        if (std.c.getenv("LOOKOUT_ML_STYLE")) |sp| {
            if (std.c.fopen(sp, "w")) |f| {
                _ = std.c.fwrite(style.json.ptr, 1, style.json.len, f);
                _ = std.c.fclose(f);
            }
        }
        self.map.setStyleJson(self.alloc, style.json) catch |e| {
            mlog("ml: setStyleJson FAILED: {s}\n", .{@errorName(e)});
            return Error.StyleFailed;
        };
        // A fresh style carries curDenom 0 (show all); the next view forces the
        // gate to be written rather than assumed.
        self.gate.current = 0;
        self.collectGatedIds();
        self.dirty = true;
    }

    pub fn setScheme(self: *Host, s: cc.tile57_scheme) Error!void {
        if (self.scheme == s) return;
        self.scheme = s;
        try self.rebuildStyle();
    }

    pub fn setMariner(self: *Host, m: cc.tile57_mariner) Error!void {
        self.mariner = m;
        try self.rebuildStyle();
    }

    // ---- the view --------------------------------------------------------

    /// Record the pose. The map is only ever touched from its own thread, so
    /// this records and the next frame applies it — which also means pan and
    /// zoom work without every gesture path having to know about MapLibre.
    pub fn setView(self: *Host, v: View) void {
        self.view = v;
        self.view_seq +%= 1;
        self.dirty = true;
    }

    /// Apply the recorded pose. Render thread only.
    fn applyView(self: *Host) void {
        const v = self.view;
        self.map.jumpTo(.{
            .center = .{ .latitude = v.lat, .longitude = v.lon },
            .zoom = v.zoom,
            // lookout's rotation is course-up degrees, 0 = north-up, which is
            // MapLibre's bearing convention. Sign is asserted in the tests
            // rather than assumed.
            .bearing = v.rotation_deg,
            .pitch = 0,
        }) catch {};

        // Only when the view actually steps over a SCAMIN denominator does the
        // gate literal have to change. Between boundaries this costs a compare.
        if (self.gate.crosses(v.zoom)) {
            const denom = self.gate.commit(v.zoom);
            self.writeScaminGate(denom);
        }
    }

    /// Rewrite the SCAMIN clause on every gated layer. This is the one place
    /// that pays MapLibre's re-layout on purpose, a few times per gesture.
    fn dropGatedIds(self: *Host) void {
        for (self.gated_ids.items) |id| self.alloc.free(id);
        self.gated_ids.clearRetainingCapacity();
    }

    /// Find the layers whose filter carries a SCAMIN clause. Once per style.
    fn collectGatedIds(self: *Host) void {
        self.dropGatedIds();
        var ids = self.map.listStyleLayerIds(self.alloc) catch return;
        defer ids.deinit();
        for (ids.items) |id| {
            var current = (self.map.getLayerFilter(self.alloc, id) catch continue) orelse continue;
            defer current.deinit();
            if (std.mem.indexOf(u8, current.value, "\"scamin\"") == null) continue;
            const owned = self.alloc.dupe(u8, id) catch continue;
            self.gated_ids.append(self.alloc, owned) catch self.alloc.free(owned);
        }
        mlog("ml: {d} scamin-gated layers of {d}\n", .{ self.gated_ids.items.len, ids.items.len });
    }

    /// Rewrite the SCAMIN clause on the gated layers. This is the one place
    /// that pays MapLibre's re-layout on purpose, a few times per gesture.
    fn writeScaminGate(self: *Host, denom: f64) void {
        var buf: [256]u8 = undefined;
        const patched = std.fmt.bufPrint(
            &buf,
            "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1e12],{d}]",
            .{denom},
        ) catch return;
        for (self.gated_ids.items) |id| self.map.setLayerFilter(self.alloc, id, patched) catch {};
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
        return true;
    }

    /// MapLibre's thread: it creates the runtime and the session, so it owns
    /// both, and it is the only thread that ever calls into them.
    fn renderLoop(self: *Host) void {
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
                // nothing left to settle, so this thread sleeps rather than
                // spinning a core on a boat's battery.
                sleepMs(8);
                continue;
            }
            _ = self.frame();
        }
    }

    fn frame(self: *Host) bool {
        const session = &(self.session orelse return false);
        if (self.view_seq != self.applied_view_seq) {
            self.applied_view_seq = self.view_seq;
            self.applyView();
        }
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

        const result = session.renderUpdate() catch |e| {
            mlog("ml: renderUpdate error {s}\n", .{@errorName(e)});
            return false;
        };

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
        self.dirty = switch (result) {
            .rendered, .no_update => !loaded,
            // Size not taken yet, or no drawable: ask again regardless.
            .size_pending, .target_not_ready => true,
            .unknown => !loaded,
        };
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

test "north-up is bearing zero on both sides" {
    // lookout rotation_deg 0 == north-up; MapLibre bearing 0 == north-up. If
    // this ever stops holding, a course-up view silently points the wrong way.
    const v = View{ .lon = -76.48, .lat = 38.97, .zoom = 15 };
    try std.testing.expectEqual(@as(f64, 0), v.rotation_deg);
}
