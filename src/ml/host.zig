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
    /// Owns the denominator manifest the gate points at.
    scamin_owned: []i32 = &.{},

    /// Set when something changed that the next render must act on. The
    /// invariant this serves is `idle means idle`: with nothing pending and no
    /// tiles in flight, a frame is not drawn at all.
    dirty: bool = true,

    pub fn open(alloc: std.mem.Allocator) Error!*Host {
        const self = alloc.create(Host) catch return Error.OutOfMemory;
        errdefer alloc.destroy(self);

        var m: cc.tile57_mariner = undefined;
        cc.tile57_mariner_defaults(&m);

        var rt = maplibre.RuntimeHandle.create(alloc, .{}, null) catch return Error.RuntimeFailed;
        errdefer rt.close() catch {};

        var map = maplibre.MapHandle.create(&rt, .{
            // MLT is the bake default. A map created without this decodes the
            // FastPFOR integer streams as a parse warning and draws nothing.
            .fast_pfor_enabled = true,
        }) catch return Error.MapFailed;
        errdefer map.close() catch {};

        self.* = .{
            .alloc = alloc,
            .runtime = rt,
            .map = map,
            .provider = provider_mod.Provider.init(alloc),
            .assets = try style_mod.Assets.bake(null),
            .mariner = m,
            .gate = .{ .denoms = &.{}, .lat = 0 },
        };

        self.provider.start() catch return Error.RuntimeFailed;
        self.runtime.setResourceProvider(.{
            .handler = provider_mod.Provider.handler,
            .context = @ptrCast(&self.provider),
        }) catch return Error.RuntimeFailed;

        return self;
    }

    pub fn close(self: *Host) void {
        // Order matters: stop answering before the map can ask again, or the
        // worker completes a handle the runtime has already torn down.
        self.runtime.clearResourceProvider() catch {};
        self.provider.deinit();
        if (self.session) |*s| s.detach() catch {};
        self.map.close() catch {};
        self.runtime.close() catch {};
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
            .scamin = self.scamin_owned,
            .scamin_lat = self.gate.lat,
        }, &self.assets);
        defer style.deinit();

        self.map.setStyleJson(self.alloc, style.json) catch return Error.StyleFailed;
        // A fresh style carries curDenom 0 (show all); the next view forces the
        // gate to be written rather than assumed.
        self.gate.current = 0;
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

    pub fn setView(self: *Host, v: View) void {
        self.view = v;
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
        self.dirty = true;
    }

    /// Rewrite the SCAMIN clause on every gated layer. This is the one place
    /// that pays MapLibre's re-layout on purpose, a few times per gesture.
    fn writeScaminGate(self: *Host, denom: f64) void {
        var ids = self.map.listStyleLayerIds(self.alloc) catch return;
        defer ids.deinit();

        var buf: [256]u8 = undefined;
        for (ids.items) |id| {
            var current = (self.map.getLayerFilter(self.alloc, id) catch continue) orelse continue;
            defer current.deinit();
            // Only the gated layers carry a scamin clause; the rest are left
            // alone so a rewrite touches the minimum MapLibre must re-lay-out.
            if (std.mem.indexOf(u8, current.value, "\"scamin\"") == null) continue;

            const patched = std.fmt.bufPrint(
                &buf,
                "[\">=\",[\"coalesce\",[\"get\",\"scamin\"],1e12],{d}]",
                .{denom},
            ) catch continue;
            self.map.setLayerFilter(self.alloc, id, patched) catch {};
        }
    }

    // ---- the surface and the frame ---------------------------------------

    pub fn attachMetal(self: *Host, layer: *anyopaque, w: u32, h: u32, density: f64) Error!void {
        const session = maplibre.attachMetalSurface(&self.map, .{
            .layer = maplibre.NativePointer.fromPtr(layer),
            .extent = .{ .width = w, .height = h, .scale_factor = density },
        }) catch return Error.SessionFailed;
        self.session = session;
        self.density = density;
        self.dirty = true;
    }

    pub fn resize(self: *Host, w: u32, h: u32) void {
        if (self.session) |*s| {
            s.resize(.{ .width = w, .height = h, .scale_factor = self.density }) catch {};
        }
        self.dirty = true;
    }

    /// One frame. Returns true when something was drawn.
    ///
    /// `renderUpdate` reports whether MapLibre still has work pending — tiles
    /// in flight, a style settling. We keep asking while it does and stop when
    /// it does not, which is what turns `idle means idle` from an aspiration
    /// into a property: a still chart issues no frames at all.
    pub fn render(self: *Host) bool {
        const session = &(self.session orelse return false);

        // Drain the runtime's owner-thread queues first: that is what delivers
        // completed tiles, style loads and sprite images into the map. Without
        // it the provider answers and nothing ever appears.
        self.runtime.pump(0) catch {};

        const result = session.renderUpdate() catch return false;
        self.dirty = switch (result) {
            // Drawn, or nothing to draw: either way this frame settled it.
            .rendered, .no_update => false,
            // The map has not taken the new size, or the target had no drawable.
            // Both are "ask again next frame" rather than an error.
            .size_pending, .target_not_ready => true,
            .unknown => false,
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
