//! What sits behind lookout.h now that charttable draws the chart.
//!
//! This owns the renderer: the map, the surface, the style, the atlases and
//! the tile sources. root.zig keeps everything ABOVE the renderer — the chart
//! library, picks, the mariner's marks, the plugin layer — and drives this
//! for anything that reaches the screen.
//!
//! WHAT THE CHART IS MADE OF HERE
//!
//!   tiles     the same baked .pmtiles. One chart binds straight to the
//!             archive; a chart SET goes through tile57's compositor and
//!             ct/tiles.zig.
//!   style     tile57's own S-101 style, built for the mariner (ct/style.zig).
//!   sprites   tile57's MapLibre sprite sheet, per scheme and density.
//!   glyphs    tile57's SDF glyph sheet, which charttable takes directly.
//!
//! So the portrayal is still the engine's. What changed is who rasterises it.
//!
//! ZOOM CONVENTIONS. lookout.h counts zoom against a 256 px world tile;
//! charttable follows the style spec and counts against 512. The whole
//! difference is one level, and it is converted HERE, at the one boundary, so
//! nothing above this file and nothing below it has to think about it. See
//! specs/charttable/concerns.md C1.
//!
//! THREADING. Everything here runs under root.zig's api lock. The tile
//! workers in ct/tiles.zig are the exception, and they touch the compositor
//! (under the engine lock) and charttable's provider, never this struct.

const std = @import("std");
const cc = @import("../c.zig").c;
const ct = @import("charttable");
const cstyle = @import("style.zig");
const ctiles = @import("tiles.zig");
const Lock = @import("../lock.zig").Lock;

pub const Map = ct.map_object.Map;
pub const Camera = ct.camera.Camera;
pub const Uniforms = ct.gpu.Uniforms;
pub const NativeKind = ct.gpu.NativeKind;

/// lookout zoom (256 px world tile) -> charttable zoom (512 px, style spec).
/// One level, one place. Getting the sign wrong halves or doubles every
/// on-screen scale, which reads as "the chart drew, but at the wrong zoom".
pub const ZOOM_BIAS: f64 = 1.0;

pub fn toCt(lookout_zoom: f64) f64 {
    return lookout_zoom - ZOOM_BIAS;
}

pub fn fromCt(ct_zoom: f64) f64 {
    return ct_zoom + ZOOM_BIAS;
}

pub const Options = struct {
    width: u32 = 1024,
    height: u32 = 768,
    want_window: bool = false,
    want_msaa: bool = false,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

pub const Error = error{ SurfaceFailed, StyleFailed, SourceFailed, OutOfMemory };

pub const Host = struct {
    alloc: std.mem.Allocator,
    m: Map,
    g: ?ct.gpu.Gpu = null,
    uploaded: Map.Uploaded = .{},

    /// Composed chart sets. Idle (no workers, no queue) until a set binds.
    tiles: ctiles.Tiles,
    /// The single-chart path: charttable reads the archive itself.
    archive: ?*Archive = null,
    bound: bool = false,

    style: cstyle.Style = .{},
    sprite: ?ct.sprite.Sprite = null,
    glyph_atlas: ?ct.glyphs.GlyphAtlas = null,
    sprite_uploaded: u32 = 0,
    glyphs_dirty: bool = false,
    /// Missing-image names already answered, so a name is rendered once and
    /// not once per frame.
    reported: std.StringHashMapUnmanaged(void) = .empty,
    /// The density and scheme the symbol runs are rendered at, so a runtime
    /// symbol matches the sheet it lands beside.
    asset_ratio: f32 = 1.0,
    asset_scheme: cc.tile57_scheme = cc.TILE57_SCHEME_DAY,

    const Archive = struct {
        reader: ct.pmtiles.Reader,
        src: ct.cache.PmtilesSource,
    };

    pub fn init(alloc: std.mem.Allocator, engine_mu: *Lock, opts: Options) Error!Host {
        var h = Host{
            .alloc = alloc,
            .m = Map.init(alloc, .{}),
            .tiles = ctiles.Tiles.init(alloc, engine_mu),
        };
        errdefer h.deinit();
        // Always: a device with no layer still renders, offscreen, which is
        // what every snapshot and the replay harness use. Only presenting
        // needs a layer.
        try h.attachSurface(opts);
        return h;
    }

    pub fn deinit(self: *Host) void {
        self.tiles.deinit();
        if (self.g) |*g| g.deinit();
        self.g = null;
        self.m.deinit();
        self.style.deinit();
        if (self.sprite) |*s| s.deinit();
        if (self.glyph_atlas) |*a| a.deinit();
        var it = self.reported.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.reported.deinit(self.alloc);
        self.closeArchive();
    }

    fn closeArchive(self: *Host) void {
        if (self.archive) |a| {
            a.reader.deinit();
            self.alloc.destroy(a);
            self.archive = null;
        }
    }

    // ---- surface ------------------------------------------------------------

    pub fn attachSurface(self: *Host, opts: Options) Error!void {
        if (self.g) |*g| {
            g.deinit();
            self.g = null;
        }
        self.g = ct.gpu.Gpu.init(.{
            .width = opts.width,
            .height = opts.height,
            .want_msaa = opts.want_msaa,
            .native_handle = opts.native_handle,
            .native_kind = opts.native_kind,
        }) catch return Error.SurfaceFailed;
        // A fresh device holds none of the old one's buffers or textures.
        self.uploaded = .{};
        self.sprite_uploaded = 0;
        self.glyphs_dirty = self.glyph_atlas != null;
        self.m.setViewport(@floatFromInt(opts.width), @floatFromInt(opts.height));
    }

    pub fn detachSurface(self: *Host) void {
        if (self.g) |*g| g.deinit();
        self.g = null;
        self.uploaded = .{};
        self.sprite_uploaded = 0;
    }

    pub fn hasSurface(self: *const Host) bool {
        return self.g != null;
    }

    pub fn resize(self: *Host, width_pt: u32, height_pt: u32) void {
        const g = if (self.g) |*g| g else return;
        g.resize(width_pt, height_pt);
        self.m.setViewport(@floatFromInt(g.width), @floatFromInt(g.height));
    }

    pub fn setPixelDensity(self: *Host, d: f32) void {
        const g = if (self.g) |*g| g else return;
        g.setPixelDensity(d);
        self.m.setViewport(@floatFromInt(g.width), @floatFromInt(g.height));
    }

    pub fn pixelDensity(self: *const Host) f32 {
        return if (self.g) |g| g.pixel_density else 1.0;
    }

    /// The physical size multiplier for symbols, text and line widths: S-52
    /// specifies them in millimetres, and the sprite is baked at the
    /// catalogue's own px-per-mm.
    pub fn setSizeScale(self: *Host, scale: f32) void {
        self.m.setSizeScale(scale);
    }

    // ---- style and sources ---------------------------------------------------

    /// Build the style for these inputs and hand it over. Every mariner change
    /// comes through here: the tiles carry tokens and raw depths, the style
    /// decides what they mean.
    pub fn setStyle(self: *Host, inputs: cstyle.Inputs) Error!void {
        var built = cstyle.build(inputs) catch return Error.StyleFailed;
        errdefer built.deinit();
        self.m.setStyleJson(built.json) catch return Error.StyleFailed;
        self.style.deinit();
        self.style = built;
        self.reportDiagnostics();
        // A new style re-lays-out everything, so nothing the GPU holds is
        // current.
        self.uploaded = .{};
    }

    /// Every degradation the style parse recorded. Silence is the goal: this
    /// style is generated by tile57, so a diagnostic is a disagreement
    /// between the two halves of our own stack, not a foreign style's quirk.
    fn reportDiagnostics(self: *Host) void {
        const diags = self.m.styleDiagnostics();
        if (diags.len == 0) return;
        std.debug.print("style: {d} diagnostic(s) from charttable\n", .{diags.len});
        for (diags, 0..) |d, i| {
            if (i >= 10) {
                std.debug.print("  ... and {d} more\n", .{diags.len - 10});
                break;
            }
            std.debug.print("  {s}: {s}\n", .{ d.layer, d.message });
        }
    }

    /// Bind ONE baked chart: charttable reads the archive itself, so no
    /// compositor and no worker pool are involved.
    pub fn bindChart(self: *Host, path: [:0]const u8) Error!void {
        self.closeArchive();
        const a = self.alloc.create(Archive) catch return Error.OutOfMemory;
        errdefer self.alloc.destroy(a);
        const io = std.Io.Threaded.global_single_threaded.io();
        a.reader = ct.pmtiles.Reader.open(self.alloc, io, path) catch return Error.SourceFailed;
        a.src = .{ .reader = &a.reader };
        _ = self.m.bindPmtiles(cstyle.source_name, &a.src) catch return Error.SourceFailed;
        self.archive = a;
        self.bound = true;
    }

    /// Bind a chart SET: the tiles come from tile57's compositor, through the
    /// host-provider door.
    pub fn bindComposed(self: *Host, compose: *cc.tile57_compose, encoding: ct.cache.Encoding) Error!void {
        self.tiles.setCompose(compose);
        if (!self.bound) {
            var meta: cc.tile57_compose_meta = std.mem.zeroes(cc.tile57_compose_meta);
            cc.tile57_compose_get_meta(compose, &meta);
            self.tiles.provider.encoding = encoding;
            self.tiles.provider.minzoom = meta.min_zoom;
            // The source has to declare where its data stops, or the map asks
            // for tiles that can only ever be answered "no tile there".
            self.tiles.provider.maxzoom = meta.max_zoom;
            _ = self.m.bindProvider(cstyle.source_name, &self.tiles.provider) catch
                return Error.SourceFailed;
            self.bound = true;
        }
        self.tiles.start();
    }

    /// Show or hide every chart layer at once, leaving the tiles and the style
    /// where they are. A visibility diff, not a restyle: turning the chart back
    /// on costs a relayout and no refetch.
    pub fn setChartVisible(self: *Host, on: bool) void {
        const st = self.m.style orelse return;
        for (st.layers) |layer| {
            self.m.setLayerVisibility(layer.id, on) catch {};
        }
    }

    /// The zoom band the camera may move in, in LOOKOUT zoom.
    pub fn setZoomRange(self: *Host, min_zoom: f64, max_zoom: f64) void {
        self.m.setZoomRange(toCt(min_zoom), toCt(max_zoom));
    }

    // ---- assets --------------------------------------------------------------

    /// The style's sprite sheet: tile57's MapLibre sprite index + its PNG.
    /// charttable decodes the PNG itself, so the host hands over bytes and
    /// keeps no atlas of its own.
    pub fn setSprite(self: *Host, index_json: []const u8, png_bytes: []const u8, ratio: f32, scheme: cc.tile57_scheme) bool {
        self.m.waitForBuild(); // a build in flight is reading the atlases
        var loaded = ct.sprite.Sprite.load(self.alloc, index_json, png_bytes) catch return false;
        if (self.sprite) |*s| s.deinit();
        self.sprite = loaded;
        errdefer loaded.deinit();
        self.applyAssets();
        self.asset_ratio = ratio;
        self.asset_scheme = scheme;
        // A new sheet is new pixels AND new cells: both streams are stale.
        self.uploaded = .{};
        self.sprite_uploaded = 0;
        // Symbol runs answered for the old sheet were rendered in the old
        // palette at the old density.
        self.forgetReported();
        return true;
    }

    /// tile57's SDF glyph sheet, which is exactly the shape charttable's
    /// addSdfSheet takes — so no fontnik PBFs are needed anywhere.
    pub fn setGlyphSheet(self: *Host, index_json: []const u8, rgba: []const u8, w: u32, h: u32) bool {
        self.m.waitForBuild();
        if (self.glyph_atlas == null) {
            self.glyph_atlas = ct.glyphs.GlyphAtlas.init(self.alloc, ct.glyphs.default_width) catch return false;
        }
        const added = self.glyph_atlas.?.addSdfSheet(index_json, rgba, w, h) catch return false;
        if (added == 0) return false;
        self.glyphs_dirty = true;
        self.applyAssets();
        return true;
    }

    fn applyAssets(self: *Host) void {
        self.m.setAssets(.{
            .sprite = if (self.sprite) |*s| s else null,
            .glyph_atlas = if (self.glyph_atlas) |*a| a else null,
        });
    }

    fn forgetReported(self: *Host) void {
        var it = self.reported.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.reported.clearRetainingCapacity();
    }

    /// Answer the images the scene could not resolve. A chart library carries
    /// more distinct symbol runs than any prebaked sheet can enumerate (every
    /// sounding is its own run), so tile57 renders exactly the ones the
    /// display asks for, once each.
    fn serveMissingImages(self: *Host) void {
        const b = self.m.scene() orelse return;
        if (b.missing_images.len == 0) return;
        for (b.missing_images) |name| {
            if (self.reported.contains(name)) continue;
            const owned = self.alloc.dupe(u8, name) catch continue;
            self.reported.put(self.alloc, owned, {}) catch {
                self.alloc.free(owned);
                continue;
            };
            self.renderSymbolRun(name);
        }
    }

    fn renderSymbolRun(self: *Host, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const run = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return;
        var rgba: [*c]u8 = null;
        var w: u32 = 0;
        var h: u32 = 0;
        var err: cc.tile57_error = undefined;
        if (cc.tile57_render_symbol_run(
            null,
            run.ptr,
            @floatCast(self.asset_ratio),
            @intCast(self.asset_scheme),
            &rgba,
            &w,
            &h,
            &err,
        ) != cc.TILE57_OK or rgba == null or w == 0 or h == 0) return;
        defer cc.tile57_free(rgba);
        if (self.sprite == null) {
            self.sprite = ct.sprite.Sprite.initEmpty(self.alloc, 512) catch return;
        }
        const n = @as(usize, w) * h * 4;
        self.sprite.?.addImage(name, rgba[0..n], w, h, self.asset_ratio) catch return;
        self.applyAssets();
        self.uploaded = .{};
        self.sprite_uploaded = 0;
    }

    fn syncAtlases(self: *Host) void {
        const g = if (self.g) |*gg| gg else return;
        if (self.sprite) |*sp| {
            if (self.sprite_uploaded != sp.generation) {
                g.uploadSpriteAtlas(sp.rgba, sp.width, sp.height) catch return;
                self.sprite_uploaded = sp.generation;
            }
        }
        if (self.glyph_atlas) |*ga| {
            if (self.glyphs_dirty) {
                const rgba = ga.toRgba(self.alloc) catch return;
                defer self.alloc.free(rgba);
                g.uploadGlyphAtlas(rgba, ga.width, ga.height) catch return;
                self.glyphs_dirty = false;
            }
        }
    }

    // ---- camera ---------------------------------------------------------------

    pub fn camera(self: *Host) *Camera {
        return self.m.camera();
    }

    /// Set the view in LOOKOUT zoom, with course-up rotation in degrees.
    pub fn setView(self: *Host, lon: f64, lat: f64, zoom: f64, rotation_deg: f64) void {
        self.m.setView(lon, lat, toCt(zoom));
        self.m.camera().rotation = rotation_deg * std.math.pi / 180.0;
    }

    pub fn view(self: *Host) struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 } {
        const cam = self.m.camera();
        const ll = ct.camera.worldToLonLat(cam.center);
        return .{
            .lon = ll.x,
            .lat = ll.y,
            .zoom = fromCt(cam.zoom),
            .rotation_deg = cam.rotation * 180.0 / std.math.pi,
        };
    }

    pub fn pan(self: *Host, dx_pt: f32, dy_pt: f32) void {
        self.m.pan(dx_pt, dy_pt);
    }

    pub fn zoomAt(self: *Host, dz: f64, x_pt: f32, y_pt: f32) void {
        self.m.zoomAt(dz, x_pt, y_pt);
    }

    pub fn zoomToward(self: *Host, dz: f64, x_pt: f32, y_pt: f32) void {
        self.m.zoomToward(dz, x_pt, y_pt);
    }

    pub fn fling(self: *Host, vx: f64, vy: f64) void {
        self.m.fling(vx, vy);
    }

    pub fn advance(self: *Host, dt_ms: f64) void {
        self.m.advance(dt_ms);
    }

    pub fn screenToGeo(self: *Host, x_pt: f32, y_pt: f32) [2]f64 {
        const w = self.m.camera().screenToWorld(x_pt, y_pt);
        const ll = ct.camera.worldToLonLat(w);
        return .{ ll.x, ll.y };
    }

    pub fn geoToScreen(self: *Host, lon: f64, lat: f64) [2]f32 {
        const w = ct.camera.lonLatToWorld(lon, lat);
        const s = self.m.camera().worldToScreen(w);
        return .{ @floatCast(s.x), @floatCast(s.y) };
    }

    // ---- the mariner's own geometry -------------------------------------------

    /// Hand the renderer this frame's overlay: the plugin layer's retained
    /// scene and the mariner's marks, already tessellated into world space by
    /// overlay.zig. charttable draws it after the chart in the same encoder,
    /// so the two can never tear apart across a gesture.
    ///
    /// The upload is skipped while the generation is unchanged, so calling
    /// this every frame costs one compare.
    pub fn setOverlay(self: *Host, verts: []const ct.scene.OverlayVertex, generation: u64, u: Uniforms) !void {
        const g = if (self.g) |*g| g else return;
        try g.setOverlay(verts, generation, u);
    }

    pub fn clearOverlay(self: *Host) void {
        if (self.g) |*g| g.clearOverlay();
    }

    // ---- the frame ------------------------------------------------------------

    /// One frame of map work: hand the workers their asks, take whatever
    /// landed, rebuild if the view left the built coverage.
    pub fn update(self: *Host) void {
        _ = self.m.update() catch {};
        self.tiles.pump();
        self.serveMissingImages();
    }

    pub fn needsRedraw(self: *Host) bool {
        return self.m.needsRedraw();
    }

    pub fn idle(self: *Host) bool {
        return self.m.idle() and !self.tiles.busy();
    }

    pub fn pendingTiles(self: *const Host) usize {
        return self.m.pendingWanted();
    }

    /// Draw into the attached surface. Answers whether a frame reached it.
    pub fn render(self: *Host) bool {
        const g = if (self.g) |*g| g else return false;
        self.update();
        self.syncAtlases();
        _ = self.m.uploadIfChanged(g, &self.uploaded) catch return false;
        const drew = g.renderWindow(self.m.uniforms());
        if (drew) self.m.markDrawn();
        return drew;
    }

    /// Render offscreen. The caller owns the returned pixels.
    pub fn snapshotRgba(self: *Host) ![]u8 {
        const g = if (self.g) |*g| g else return Error.SurfaceFailed;
        self.update();
        self.syncAtlases();
        _ = try self.m.uploadIfChanged(g, &self.uploaded);
        return g.renderOffscreen(self.alloc, self.m.uniforms());
    }

    pub fn width(self: *const Host) u32 {
        return if (self.g) |g| g.width else 0;
    }

    pub fn height(self: *const Host) u32 {
        return if (self.g) |g| g.height else 0;
    }
};

// ---- tests -------------------------------------------------------------------

test "zoom converts one level, both ways" {
    // A 256 px world tile at lookout zoom 15 is the same ground as a 512 px
    // tile at charttable zoom 14.
    try std.testing.expectEqual(@as(f64, 14.0), toCt(15.0));
    try std.testing.expectEqual(@as(f64, 15.0), fromCt(14.0));
    try std.testing.expectEqual(@as(f64, 12.5), fromCt(toCt(12.5)));
}
