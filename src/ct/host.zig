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
//! nothing above this file and nothing below it has to think about it.
//!
//! THREADING. Everything here runs under root.zig's api lock. The tile
//! workers in ct/tiles.zig are the exception, and they touch the compositor
//! (under the engine lock) and charttable's provider, never this struct.

const std = @import("std");
const cc = @import("../c.zig").c;
const ct = @import("charttable");
const cstyle = @import("style.zig");
const ctiles = @import("tiles.zig");
const cprovided = @import("provided.zig");
const Lock = @import("../lock.zig").Lock;
const RwLock = @import("../lock.zig").RwLock;
const clock = @import("../clock.zig");

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

/// One raster underlay set: the style source name and the provider that
/// answers its tiles (ct/raster.zig).
pub const RasterBinding = struct {
    name: [:0]const u8,
    provider: *ct.provider.Provider,
};

pub const Host = struct {
    alloc: std.mem.Allocator,
    m: Map,
    g: ?ct.gpu.Gpu = null,
    uploaded: Map.Uploaded = .{},

    /// Composed chart sets. Idle (no workers, no queue) until a set binds.
    tiles: ctiles.Tiles,
    /// The sources an alt style names, served by the host. Empty until one is
    /// set — lookout's own chart never goes through here.
    provided: cprovided.Provided,
    /// The single-chart path: charttable reads the archive itself.
    archive: ?*Archive = null,

    /// The raster underlay's providers, re-bound by name after every setStyle
    /// (a new style is a new parse, and bindings do not survive it). The
    /// caller owns the slice and the providers, which outlive the map
    /// (ct/raster.zig's lifetime rule).
    raster_bindings: []const RasterBinding = &.{},
    /// Called once per update on the map-driving thread: the raster
    /// underlay's drain (ct/raster.zig pump), owned by the caller.
    raster_pump: ?*const fn (ctx: *anyopaque) void = null,
    raster_pump_ctx: ?*anyopaque = null,

    /// The last frame's three spans, µs — see `renderPrepare` / `renderPresent`.
    /// Always kept.
    prof_update_us: i64 = 0,
    prof_upload_us: i64 = 0,
    prof_present_us: i64 = 0,
    /// What the last `update` tick spent its time on, from the map itself.
    tick: ct.map_object.Tick = .{},
    /// The rest of the update span, µs: the tile/provider pumps, the
    /// missing-symbol batch, and the atlas sync (whole-sheet uploads live
    /// there). What the map's own tick cannot see.
    prof_pump_us: i64 = 0,
    prof_serve_us: i64 = 0,
    prof_atlas_us: i64 = 0,
    /// Guards the GPU surface against the one true concurrency the ABI
    /// allows: the render thread presenting WITHOUT the api lock (see
    /// renderPresent) while the input thread resizes, re-attaches or detaches
    /// the surface. Everything else that touches `g` runs on the render
    /// thread, already sequenced against its own present. Leaf lock: nothing
    /// is acquired while it is held.
    gpu_mu: Lock = .{},
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

    pub fn init(alloc: std.mem.Allocator, engine_mu: *RwLock, opts: Options) Error!Host {
        var h = Host{
            .alloc = alloc,
            .m = Map.init(alloc, .{}),
            .tiles = ctiles.Tiles.init(alloc, engine_mu),
            .provided = cprovided.Provided.init(alloc),
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
        // Before the device goes: joins any build whose worker is staging
        // GPU buffers on it, and frees the staged scene.
        self.m.setStagingGpu(null);
        // Under gpu_mu: a present that slipped past the host's own teardown
        // barrier is still holding the surface, and destroying it out from
        // under the encoder is a crash the lock is cheaper than.
        self.gpu_mu.lock();
        if (self.g) |*g| g.deinit();
        self.g = null;
        self.gpu_mu.unlock();
        self.m.deinit();
        // AFTER the map: its cache workers call fetch on these providers from
        // their own threads, and m.deinit is what stops them.
        self.provided.deinit();
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
        // Before gpu_mu (leaf lock) and before the old device goes: the
        // build worker may be inside makeScene on it. The NEW device is
        // registered lazily by update(); init calls this on a Host the
        // caller then MOVES, so a pointer taken here would dangle.
        self.m.setStagingGpu(null);
        self.gpu_mu.lock();
        defer self.gpu_mu.unlock();
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
        self.m.setStagingGpu(null);
        self.gpu_mu.lock();
        defer self.gpu_mu.unlock();
        if (self.g) |*g| g.deinit();
        self.g = null;
        self.uploaded = .{};
        self.sprite_uploaded = 0;
    }

    pub fn hasSurface(self: *const Host) bool {
        return self.g != null;
    }

    /// The renderer-owned IDXGISwapChain* to compose, for a surface attached
    /// with NativeKind.d3d12_panel. Null on every other kind and backend. The
    /// renderer keeps ownership; detachSurface releases it.
    pub fn swapchainPtr(self: *Host) ?*anyopaque {
        self.gpu_mu.lock();
        defer self.gpu_mu.unlock();
        const g = if (self.g) |*x| x else return null;
        return g.swapchainPtr();
    }

    /// Resize in LOGICAL POINTS, which is also the camera's unit: density
    /// lives in the projection and is applied once, there. Handing the camera
    /// the pixel size instead would scale the whole world by the density.
    pub fn resize(self: *Host, width_pt: u32, height_pt: u32) void {
        {
            self.gpu_mu.lock();
            defer self.gpu_mu.unlock();
            const g = if (self.g) |*g| g else return;
            g.resize(width_pt, height_pt);
        }
        self.m.setViewport(@floatFromInt(width_pt), @floatFromInt(height_pt));
    }

    /// The viewport in points does not move when the density does — only the
    /// framebuffer behind it does.
    pub fn setPixelDensity(self: *Host, d: f32) void {
        self.gpu_mu.lock();
        defer self.gpu_mu.unlock();
        const g = if (self.g) |*g| g else return;
        g.setPixelDensity(d);
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
        // The raster underlay's sources, re-bound on every style: the parse
        // read each source's declaration (zoom band, tileSize), and a source
        // left unbound asks tiles of nobody, forever.
        for (self.raster_bindings) |b| {
            _ = self.m.bindProvider(b.name, b.provider) catch {
                std.debug.print("raster: bind '{s}' failed\n", .{b.name});
            };
        }
        // A new style re-lays-out everything, so nothing the GPU holds is
        // current.
        self.uploaded = .{};
    }

    /// Set a style the host supplies instead of the engine's. The bytes are
    /// borrowed for the call.
    pub fn setStyleJson(self: *Host, json: []const u8) Error!void {
        self.m.setStyleJson(json) catch return Error.StyleFailed;
        self.style.deinit();
        self.reportDiagnostics();
        try self.bindProvidedSources();
        self.uploaded = .{};
    }

    /// Give every source the current style names somewhere to come from: the
    /// host, through ct/provided.zig.
    ///
    /// AFTER the parse, always. bindProvider reads the source's own
    /// declaration out of the style — its encoding, its zoom band, and for a
    /// raster source its tile size — and a provider that has not been told
    /// where the data stops sends the map asking for tiles that can only ever
    /// be answered "no tile there", forever.
    fn bindProvidedSources(self: *Host) Error!void {
        const st = self.m.style orelse return;
        for (st.sources.keys()) |name| {
            if (!hostServes(name)) continue;
            const s = self.provided.source(name) catch return Error.OutOfMemory;
            _ = self.m.bindProvider(name, &s.provider) catch return Error.SourceFailed;
        }
    }

    /// Whether a style source name is the HOST's to serve. The mariner's chart
    /// is not: it is already bound to the archive or the compositor, and that
    /// binding is the one that draws the survey. A publisher's style that
    /// happens to name a source "chart" means its own, but ours is the one
    /// that must win.
    fn hostServes(name: []const u8) bool {
        return !std.mem.eql(u8, name, cstyle.source_name);
    }

    /// Where a provided source's tiles are asked for. Null stops the asking:
    /// every outstanding tile is then failed rather than parked, because a
    /// tile nobody will answer is a hole in the chart that never fills.
    pub fn setTileProvider(self: *Host, cb: ?cprovided.RequestFn, user: ?*anyopaque) void {
        self.provided.setCallback(cb, user);
    }

    /// Serve a provided source's tiles from the CORE instead of the shell: the
    /// shell gave a generic url fetcher, so src/chartlinks.zig does the
    /// templating. See provided.zig.
    pub fn setCoreTileSink(self: *Host, cb: ?cprovided.CoreFn, ctx: ?*anyopaque) void {
        self.provided.setCoreSink(cb, ctx);
    }

    /// The host's answer to one ask. Safe from any thread — see provided.zig.
    pub fn respondTile(self: *Host, req_id: u64, bytes: []const u8, status: cprovided.Status) void {
        self.provided.respond(req_id, bytes, status);
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
            // The raster underlay's layers are not the chart's.
            if (std.mem.endsWith(u8, layer.id, "-underlay") or
                std.mem.endsWith(u8, layer.id, "-overlay")) continue;
            self.m.setLayerVisibility(layer.id, on) catch {};
        }
    }

    /// Show or hide one raster set layer without a style rebuild — a
    /// visibility diff. `suffix` picks which of the set's two layers
    /// ("-underlay" below the survey, "-overlay" above everything).
    pub fn setRasterLayerVisible(self: *Host, source_name: []const u8, suffix: []const u8, on: bool) void {
        var buf: [64]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "{s}{s}", .{ source_name, suffix }) catch return;
        self.m.setLayerVisibility(id, on) catch {};
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
        // The sheet's index states the real pixelRatio per cell — tile57 writes
        // the bake scale into it (1 at a 1x bake, 2 at 2x) — so charttable
        // already draws each cell at its authored logical size. Do NOT correct
        // for the density here as well; that halves every symbol on a Retina
        // display.
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

    /// Fold one MapLibre sprite PACK — an alt style's, fetched by the shell —
    /// into the resident atlas: every cell re-packed under its array-form
    /// name (`<prefix>:<name>`, bare when the pack id is "default"). Cells
    /// marked `sdf` are SKIPPED: the sprite pipeline draws texels verbatim,
    /// and a distance field drawn verbatim is a smear where an icon should
    /// be. Answers how many cells landed.
    ///
    /// Adding to the resident sheet (not swapping it) is the point: the
    /// S-52 symbols, the baked sounding runs and the alt style's seamarks
    /// share one atlas, one texture, and the banded-row upload that already
    /// exists for the missing-symbol path.
    pub fn addSpritePack(self: *Host, prefix: []const u8, index_json: []const u8, png_bytes: []const u8) usize {
        self.m.waitForBuild(); // the build worker reads the sprite
        var tmp = std.heap.ArenaAllocator.init(self.alloc);
        defer tmp.deinit();
        const ta = tmp.allocator();

        const img = ct.png.read(ta, png_bytes) catch return 0;
        const doc = std.json.parseFromSliceLeaky(std.json.Value, ta, index_json, .{}) catch return 0;
        if (doc != .object) return 0;

        if (self.sprite == null) {
            self.sprite = ct.sprite.Sprite.initEmpty(self.alloc, img.w) catch return 0;
        }
        const sp = &self.sprite.?;

        var added: usize = 0;
        var skipped_sdf: usize = 0;
        var it = doc.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .object) continue;
            const o = e.value_ptr.object;
            const x = packUint(o, "x") orelse continue;
            const y = packUint(o, "y") orelse continue;
            const w = packUint(o, "width") orelse continue;
            const h = packUint(o, "height") orelse continue;
            if (w == 0 or h == 0 or x > img.w or w > img.w - x or y > img.h or h > img.h - y)
                continue;
            if (o.get("sdf")) |s| {
                if (s == .bool and s.bool) {
                    skipped_sdf += 1;
                    continue;
                }
            }
            var ratio: f32 = 1;
            if (o.get("pixelRatio")) |r| switch (r) {
                .integer => |i| ratio = @floatFromInt(i),
                .float => |f| ratio = @floatCast(f),
                else => {},
            };
            if (!(ratio > 0)) ratio = 1;

            // A tight copy of the cell, row by row.
            const cell = ta.alloc(u8, @as(usize, w) * h * 4) catch continue;
            for (0..h) |r| {
                const src = ((@as(usize, y) + r) * img.w + x) * 4;
                @memcpy(cell[r * w * 4 ..][0 .. w * 4], img.rgba[src..][0 .. w * 4]);
            }
            const name = if (prefix.len == 0)
                e.key_ptr.*
            else
                std.fmt.allocPrint(ta, "{s}:{s}", .{ prefix, e.key_ptr.* }) catch continue;
            sp.addImage(name, cell, w, h, ratio) catch continue;
            added += 1;
        }
        if (added > 0) {
            // One swap for the whole pack, and the missing-image ledger
            // starts over: names that could not resolve before this pack
            // landed can now.
            self.applyAssets();
            self.forgetReported();
        }
        std.debug.print("sprite pack '{s}': {d} cells added, {d} sdf skipped\n", .{ prefix, added, skipped_sdf });
        return added;
    }

    /// The deepest zoom among the sources the active style names, used for
    /// the camera band while an alt style is up. Bindings outlive a style
    /// swap: the ENC's own source and the raster underlays stay bound while
    /// a link is drawn, and a deeper one of those must not extend the zoom
    /// band of a shallower publisher's map or hide its overscale badge.
    /// Returns 22 when no source qualifies, so a chart that has not declared
    /// its depth is not clamped.
    pub fn deepestSourceZoom(self: *Host) f64 {
        var maxz: f64 = 0;
        for (self.m.cache.sources.items, 0..) |s, si| {
            if (!self.sourceNamedByStyle(si)) continue;
            maxz = @max(maxz, @as(f64, @floatFromInt(s.maxzoom)));
        }
        return if (maxz > 0) maxz else 22;
    }

    /// True when the map's current style names this source. This is the
    /// same test the renderer applies to its own tile requests
    /// (map_object.zig, sourceInStyle).
    fn sourceNamedByStyle(self: *Host, si: usize) bool {
        const style = if (self.m.style) |*s| s else return true;
        for (self.m.bound.items) |b| {
            if (b.index == si) return style.sources.get(b.name) != null;
        }
        // Bound without a name to check against: count it.
        return true;
    }

    fn packUint(o: std.json.ObjectMap, key: []const u8) ?u32 {
        const v = o.get(key) orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
            .float => |f| if (f >= 0 and f <= std.math.maxInt(u32) and f == @floor(f)) @intFromFloat(f) else null,
            else => null,
        };
    }

    fn forgetReported(self: *Host) void {
        var it = self.reported.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.reported.clearRetainingCapacity();
    }

    /// How long one frame may spend rasterizing missing symbol runs. The rest
    /// of the list waits for the next frame — those symbols are not on screen
    /// either way, and a burst served whole was a felt hitch (a new harbor
    /// brings dozens of sounding runs at once).
    const SYMBOL_BUDGET_US: i64 = 4000;

    /// Answer the images the scene could not resolve. A chart library carries
    /// more distinct symbol runs than any prebaked sheet can enumerate (every
    /// sounding is its own run), so tile57 renders exactly the ones the
    /// display asks for, once each.
    ///
    /// Never while a build is in flight, and one asset swap per frame, not
    /// per image. The build worker reads the sprite, so adding a cell
    /// mid-build is a race — and setAssets guards it with waitForBuild, which
    /// JOINS the build on this thread. Serving a burst image-by-image
    /// therefore pulled the whole "off-thread" build back into the frame,
    /// once per symbol: measured 15-30 ms frames at every new harbor of the
    /// tour, none of it in the map's own tick.
    fn serveMissingImages(self: *Host) void {
        const b = self.m.scene() orelse return;
        if (b.missing_images.len == 0) return;
        if (self.m.buildInFlight()) return;
        const t0 = clock.ticksUs();
        var added = false;
        for (b.missing_images) |name| {
            if (self.reported.contains(name)) continue;
            const owned = self.alloc.dupe(u8, name) catch continue;
            self.reported.put(self.alloc, owned, {}) catch {
                self.alloc.free(owned);
                continue;
            };
            const before = if (self.sprite) |*s| s.count() else 0;
            const after = self.renderSymbolRun(name);
            if (after > before) added = true;
            if (std.c.getenv("LOOKOUT_SYMBOL_PROBE") != null) {
                std.debug.print("symbol: {s} — {s}\n", .{ name, if (after > before) "rendered" else "NOT AVAILABLE" });
            }
            if (clock.ticksUs() - t0 > SYMBOL_BUDGET_US) break;
        }
        // One swap for the whole batch: setAssets invalidates every cached
        // bucket (an icon that was missing may now resolve), so doing it per
        // image re-tessellated the resident set once per symbol.
        if (added) self.applyAssets();
    }

    /// Rasterize one symbol run into the sprite. Answers the sprite's cell
    /// count so the caller can tell whether anything landed. The caller owns
    /// the asset swap: no build may be in flight (the sheet is mutated in
    /// place, and the build worker reads it), and applyAssets runs once per
    /// batch, after this. The GPU scene is deliberately NOT invalidated here:
    /// the swap dirties the map, the rebuild bumps the scene generation, and
    /// the upload follows from that — resetting `uploaded` as well re-sent
    /// the entire unchanged scene to the GPU for every new symbol (a 19 ms
    /// frame doing nothing).
    fn renderSymbolRun(self: *Host, name: []const u8) usize {
        const have = if (self.sprite) |*s| s.count() else 0;
        var buf: [256]u8 = undefined;
        const run = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return have;
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
        ) != cc.TILE57_OK or rgba == null or w == 0 or h == 0) return have;
        defer cc.tile57_free(rgba);
        if (self.sprite == null) {
            self.sprite = ct.sprite.Sprite.initEmpty(self.alloc, 512) catch return have;
        }
        const n = @as(usize, w) * h * 4;
        self.sprite.?.addImage(name, rgba[0..n], w, h, self.asset_ratio) catch return have;
        self.sprite_uploaded = 0;
        return self.sprite.?.count();
    }

    fn syncAtlases(self: *Host) void {
        const g = if (self.g) |*gg| gg else return;
        if (self.sprite) |*sp| {
            if (self.sprite_uploaded != sp.generation) {
                // Only the rows the batch touched, when the resident texture
                // still has the sheet's shape. The full sheet at library
                // scale measured 20-64 ms a send, once per missing-symbol
                // batch of the tour; the band is a few dozen rows.
                const banded = if (sp.dirtyRows()) |band|
                    g.updateSpriteAtlasRows(sp.rgba, sp.width, sp.height, band[0], band[1] - band[0])
                else
                    false;
                if (!banded) g.uploadSpriteAtlas(sp.rgba, sp.width, sp.height) catch return;
                sp.clearDirty();
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
        // Registered here, not at attach: init builds the Host in a local the
        // caller moves, so the surface's address is only stable once calls
        // arrive through the moved-in copy. One pointer compare when nothing
        // changed. With this set, the build worker copies each scene into GPU
        // buffers off-thread and the landing in renderPrepare is a pointer
        // swap instead of a buffer upload.
        self.m.setStagingGpu(if (self.g) |*g| g else null);
        self.tick = self.m.update() catch .{};
        const t0 = clock.ticksUs();
        self.tiles.pump();
        self.provided.pump();
        if (self.raster_pump) |f| f(self.raster_pump_ctx.?);
        const t1 = clock.ticksUs();
        self.serveMissingImages();
        self.prof_pump_us = t1 - t0;
        self.prof_serve_us = clock.ticksUs() - t1;
    }

    pub fn needsRedraw(self: *Host) bool {
        return self.m.needsRedraw();
    }

    pub fn idle(self: *Host) bool {
        return self.m.idle() and !self.tiles.busy();
    }

    /// Whether the drawn scene is still being CONSTRUCTED, ignoring tiles in
    /// flight (Map.buildingScene). For an alt style whose tiles stream from
    /// the host, the ENC compositor may still be busy in the background
    /// (a link-first startup loads the library behind the link) — that is not
    /// what the mariner is looking at, so it does not count here.
    pub fn buildingScene(self: *Host) bool {
        return self.m.buildingScene();
    }

    pub fn pendingTiles(self: *const Host) usize {
        return self.m.pendingWanted();
    }

    /// The frame, in two halves, so the caller can drop its api lock for the
    /// half that blocks.
    ///
    /// `renderPrepare` is everything that reads or writes MAP state — adopting
    /// builds, tile pumps, atlas and scene uploads, the uniforms — and runs
    /// under the api lock like any other entry. `renderPresent` only encodes
    /// and presents what was prepared, and the api lock is deliberately NOT
    /// held across it: the present blocks on the swapchain's drawable
    /// (measured 0.2 ms typical, ~400 ms worst on a wedged GPU), and any
    /// gesture or per-tick query queued behind the lock would freeze the
    /// host's input thread for exactly that long. See root.zig render().
    ///
    /// The spans are timed unconditionally (a clock read is tens of
    /// nanoseconds against a frame of milliseconds), because which of them the
    /// caller holds a lock across is the whole question.
    pub fn renderPrepare(self: *Host) ?Uniforms {
        if (self.g == null) return null;
        const t0 = clock.ticksUs();
        self.update();
        const ta = clock.ticksUs();
        self.syncAtlases();
        const t1 = clock.ticksUs();
        self.prof_atlas_us = t1 - ta;
        _ = self.m.uploadIfChanged(&self.g.?, &self.uploaded) catch return null;
        const t2 = clock.ticksUs();
        self.prof_update_us = t1 - t0;
        self.prof_upload_us = t2 - t1;
        return self.m.uniforms();
    }

    /// Present the prepared frame. Safe without the api lock: it touches only
    /// the surface, under gpu_mu, so a resize or detach landing mid-present
    /// waits for the drawable instead of racing it. The map is not touched —
    /// the caller re-takes its lock and marks the captured view drawn.
    pub fn renderPresent(self: *Host, u: Uniforms) bool {
        self.gpu_mu.lock();
        defer self.gpu_mu.unlock();
        const g = if (self.g) |*g| g else return false;
        const t0 = clock.ticksUs();
        const drew = g.renderWindow(u);
        self.prof_present_us = clock.ticksUs() - t0;
        return drew;
    }

    /// Render offscreen. The caller owns the returned pixels.
    ///
    /// Under gpu_mu from the atlas sync on: this can arrive on the input
    /// thread while the render thread is presenting without the api lock, and
    /// uploadIfChanged frees the scene buffers that present is encoding.
    pub fn snapshotRgba(self: *Host) ![]u8 {
        self.update();
        self.gpu_mu.lock();
        defer self.gpu_mu.unlock();
        const g = if (self.g) |*g| g else return Error.SurfaceFailed;
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

test "an alt style's sources go to the host, and the mariner's chart does not" {
    // Against a real parse, because the whole binding rests on what the style
    // module calls a source and in what order.
    const json =
        \\{"version":8,
        \\ "sources":{
        \\   "chart":{"type":"vector","tiles":["lookout://chart/{z}/{x}/{y}"]},
        \\   "basemap":{"type":"vector","tiles":["https://x/{z}/{x}/{y}.pbf"],"maxzoom":14},
        \\   "satellite":{"type":"raster","tiles":["https://y/{z}/{x}/{y}.jpg"],"tileSize":256}
        \\ },
        \\ "layers":[]}
    ;
    var st = try ct.style.parse(std.testing.allocator, json);
    defer st.deinit();

    var served: std.ArrayListUnmanaged([]const u8) = .empty;
    defer served.deinit(std.testing.allocator);
    for (st.sources.keys()) |name| {
        if (!Host.hostServes(name)) continue;
        try served.append(std.testing.allocator, name);
    }

    try std.testing.expectEqual(@as(usize, 2), served.items.len);
    try std.testing.expectEqualStrings("basemap", served.items[0]);
    try std.testing.expectEqualStrings("satellite", served.items[1]);
}
