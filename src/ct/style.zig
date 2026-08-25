//! Builds the MapLibre style charttable draws the chart from.
//!
//! tile57 already generates the whole S-101 layer set — symbols, patterns,
//! complex linestyles, soundings, the mariner's depth shading and the danger
//! swaps. Nothing here reimplements portrayal. This file only:
//!
//!   1. asks tile57 for the TEMPLATE with our source name in it,
//!   2. patches the mariner's settings into it, and
//!   3. hands the bytes over.
//!
//! Step 2 is why a scheme change or a safety-contour nudge does not touch the
//! tiles: the tiles carry tokens and raw depths, the style decides what they
//! mean. Rebuild the style, set it, done.
//!
//! WHAT THE URLS ARE FOR. charttable fetches nothing by url: the host binds
//! the tile source by NAME and hands over the sprite and glyph sheets as
//! bytes. The template's sprite and glyphs urls still have to be non-null,
//! because their presence is what ENABLES the symbol, pattern and text layer
//! groups — pass null and the template comes back a fills-and-lines style.
//! So the values only have to exist.
//!
//! SCAMIN. The bucket mode: pass the library's distinct denominators and
//! tile57 splits each `_scamin` source-layer into one bucket layer per value,
//! each with a native fractional minzoom. A feature then appears at its exact
//! display scale for free, with no filter rewriting at gesture time. The
//! alternative (`scamin_filter_gate`) is exact too but pays a setFilter at
//! every denominator crossing, and in charttable a filter change is a
//! relayout of every resident tile.

const std = @import("std");
const cc = @import("../c.zig").c;
const basemap = @import("../basemap.zig");

/// The style source name the template writes, and the name the host binds its
/// tile provider to. Kept here so the template and the binding cannot drift.
pub const source_name = "chart";

/// The tile url in the template. charttable never fetches it — the source is
/// bound by name — but the template needs a template-shaped string.
pub const tiles_url = source_name ++ "/{z}/{x}/{y}";
pub const sprite_url = "lookout://sprite";
pub const glyphs_url = "lookout://glyphs/{fontstack}/{range}.pbf";

/// The style's sizes are ALREADY in drawn pixels, so this stays 1.0.
///
/// Checked by dumping a built style (LOOKOUT_STYLE_DUMP) rather than reasoned
/// about, because reasoning about it got the wrong answer twice:
///
///   icon-size   ["*", s, 1]                       -- 1 = sample the cell 1:1
///   line-width  ["*", s, ["get", "width_px"]]     -- the tile's own px
///   text-size   ["*", s, 10]                      -- px
///
/// `s` is this multiplier. The sheet states a real pixelRatio per cell (1 at a
/// 1x bake, 2 at 2x), so a cell already draws at its authored logical size and
/// nothing here has to correct for density. Anything other than 1.0 scales
/// symbols, labels AND line widths together, which is only ever right if the
/// whole chart is meant to be drawn larger — the mariner's own size control,
/// which rides charttable's uniform instead and costs no style rebuild.
pub const PHYSICAL_SIZE_SCALE: f64 = 1.0;

pub const Error = error{ TemplateFailed, BuildFailed, ColortablesFailed, SpliceFailed };

/// One raster underlay set the style must carry: a source and TWO raster
/// layers — "<name>-underlay" above the chart's area fills and below its
/// lines, and "<name>-overlay" above every chart layer. At most one is
/// visible: the underlay is the normal mode (the picture replaces the water
/// tint, the survey draws over it), the overlay is hide-ENC-over-raster (the
/// picture covers the chart exactly where its tiles exist, and the chart
/// stands wherever they do not).
pub const RasterSet = struct {
    source_name: [:0]const u8,
    minzoom: u8,
    maxzoom: u8,
    tile_size: u32,
    visible: bool,
    visible_over: bool,
};

/// Everything the style depends on. A change to any field means a rebuild.
pub const Inputs = struct {
    mariner: cc.tile57_mariner,
    /// The archive's stored tile encoding (tile57_tile_type). An MLT source
    /// must say so or charttable decodes it as MVT and draws nothing.
    tile_encoding: u8 = cc.TILE57_TILE_TYPE_MVT,
    minzoom: u32 = 0,
    maxzoom: u32 = 0,
    /// Distinct SCAMIN denominators in the open library, ascending.
    scamin: []const i32 = &.{},
    /// Representative latitude for the denominator conversion (the library
    /// centre). SCAMIN cutoffs are latitude-dependent.
    scamin_lat: f64 = 0,
    /// Band filter, or empty for all bands.
    bands: []const i32 = &.{},
    /// The raster underlay's sets, in set order.
    rasters: []const RasterSet = &.{},
};

/// A built style. `json` is owned by tile57 (freed with tile57_free) unless a
/// raster splice re-allocated it, in which case `alloc` says whose it is.
pub const Style = struct {
    json: []const u8 = "",
    alloc: ?std.mem.Allocator = null,

    pub fn deinit(self: *Style) void {
        if (self.json.len != 0) {
            if (self.alloc) |a| a.free(@constCast(self.json)) else cc.tile57_free(@constCast(self.json.ptr));
        }
        self.json = "";
        self.alloc = null;
    }
};

/// Build the concrete style for these inputs.
///
/// Two calls, as the engine intends: the template carries the layer set and
/// our source name, then the build patches the mariner in. The template is
/// not cached — it is cheap next to the tiles, and caching it invites the two
/// halves going out of step across a scheme change.
pub fn build(inputs: Inputs) Error!Style {
    var ct: [*c]u8 = null;
    var ct_len: usize = 0;
    var err: cc.tile57_error = undefined;
    if (cc.tile57_colortables_default(&ct, &ct_len, &err) != cc.TILE57_OK or ct == null)
        return Error.ColortablesFailed;
    defer cc.tile57_free(ct);

    var tmpl: [*c]u8 = null;
    var tmpl_len: usize = 0;
    if (cc.tile57_style_template(
        inputs.mariner.scheme,
        tiles_url,
        sprite_url,
        glyphs_url,
        inputs.minzoom,
        inputs.maxzoom,
        inputs.tile_encoding,
        &tmpl,
        &tmpl_len,
        &err,
    ) != cc.TILE57_OK) return Error.TemplateFailed;
    defer cc.tile57_free(tmpl);

    // The scheme is a MARINER field, not a style argument: the template
    // argument only stamps the template, while the build resolves every
    // colour token from `m.scheme`. A template built for night with a mariner
    // left on day yields a day chart.
    var m = inputs.mariner;
    // The catalogue-to-physical calibration (see PHYSICAL_SIZE_SCALE). The
    // mariner's OWN size multiplier does not belong here — it rides
    // charttable's uniform, where it costs no style rebuild — so this field
    // carries the calibration alone and is not the caller's to set.
    m.size_scale = PHYSICAL_SIZE_SCALE;

    var out: [*c]u8 = null;
    var out_len: usize = 0;
    if (cc.tile57_style_build(
        @ptrCast(tmpl),
        tmpl_len,
        &m,
        @ptrCast(ct),
        ct_len,
        if (inputs.bands.len == 0) null else inputs.bands.ptr,
        inputs.bands.len,
        if (inputs.scamin.len == 0) null else @constCast(inputs.scamin.ptr),
        inputs.scamin.len,
        inputs.scamin_lat,
        &out,
        &out_len,
        &err,
    ) != cc.TILE57_OK) return Error.BuildFailed;

    var style: Style = .{ .json = out[0..out_len] };

    // The raster underlay rides the same style: one source and one raster
    // layer per set, above the area fills, below every line, symbol and
    // label — the picture replaces the water tint, never the survey.
    if (inputs.rasters.len != 0) {
        const spliced = spliceRasters(std.heap.c_allocator, style.json, inputs.rasters) catch
            return Error.SpliceFailed;
        style.deinit();
        style = .{ .json = spliced, .alloc = std.heap.c_allocator };
    }

    // The world coastline, under every chart layer and above the style's own
    // background. It renders wherever the chart does not reach, which is the
    // whole window until a chart opens.
    {
        const spliced = spliceBasemap(std.heap.c_allocator, style.json, inputs.mariner.scheme) catch
            return Error.SpliceFailed;
        style.deinit();
        style = .{ .json = spliced, .alloc = std.heap.c_allocator };
    }

    // LOOKOUT_STYLE_DUMP=<path>: write the built style out. The sizes in it
    // (icon-size, line-width, text-size) are the only way to see what unit the
    // engine is speaking, and guessing at that is what made the symbols wrong
    // twice.
    if (std.c.getenv("LOOKOUT_STYLE_DUMP")) |p| {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = std.mem.span(p), .data = style.json }) catch {};
    }

    return style;
}

/// Splice the basemap's source and layers into a built style. Same scanner
/// approach as the raster splice below, at a different insertion point: the
/// layers go in front of the first layer that is not a `background`, so the
/// coastline covers the style's own backdrop and every chart layer covers the
/// coastline.
fn spliceBasemap(alloc: std.mem.Allocator, json: []const u8, scheme: cc.tile57_scheme) ![]u8 {
    const src = try basemap.sourceJson(alloc);
    defer alloc.free(src);
    const lyrs = try basemap.layersJson(alloc, scheme);
    defer alloc.free(lyrs);

    const src_tag = "\"sources\":{";
    const src_at = (std.mem.indexOf(u8, json, src_tag) orelse return error.NoSources) + src_tag.len;
    const lyr_tag = "\"layers\":[";
    const lyr_start = (std.mem.indexOf(u8, json, lyr_tag) orelse return error.NoLayers) + lyr_tag.len;
    const lyr_at = layerInsertAfterBackground(json, lyr_start);
    if (lyr_at < src_at) return error.NoLayers; // generator order: sources first

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, json[0..src_at]);
    try out.appendSlice(alloc, src);
    try out.appendSlice(alloc, json[src_at..lyr_at]);
    try out.appendSlice(alloc, lyrs);
    try out.appendSlice(alloc, json[lyr_at..]);
    return out.toOwnedSlice(alloc);
}

/// Scanning from just past `"layers":[`: the offset of the first layer object
/// whose "type" is not "background", or the array's closing bracket when they
/// all are.
fn layerInsertAfterBackground(json: []const u8, start: usize) usize {
    var i = start;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var obj_start: usize = start;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (ch == '\\') {
                esc = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_str = true,
            '{' => {
                if (depth == 0) obj_start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0 and std.mem.indexOf(u8, json[obj_start .. i + 1], "\"type\":\"background\"") == null)
                    return obj_start;
            },
            ']' => {
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return json.len;
}

/// Splice the raster underlay's sources and layers into a built style.
///
/// The JSON is our own generator's output, so this is a scanner, not a
/// parser: sources go right after `"sources":{`, and the layers go in front
/// of the first layer whose type is neither `background` nor `fill` — above
/// every area fill, below every line, symbol and label.
fn spliceRasters(alloc: std.mem.Allocator, json: []const u8, sets: []const RasterSet) ![]u8 {
    var srcs: std.ArrayList(u8) = .empty;
    defer srcs.deinit(alloc);
    var lyrs: std.ArrayList(u8) = .empty;
    defer lyrs.deinit(alloc);
    var overs: std.ArrayList(u8) = .empty;
    defer overs.deinit(alloc);
    for (sets) |s| {
        try srcs.print(alloc, "\"{s}\":{{\"type\":\"raster\",\"tiles\":[\"{s}/{{z}}/{{x}}/{{y}}\"]," ++
            "\"tileSize\":{d},\"minzoom\":{d},\"maxzoom\":{d}}},", .{ s.source_name, s.source_name, s.tile_size, s.minzoom, s.maxzoom });
        try lyrs.print(alloc, "{{\"id\":\"{s}-underlay\",\"type\":\"raster\",\"source\":\"{s}\"," ++
            "\"layout\":{{\"visibility\":\"{s}\"}}}},", .{ s.source_name, s.source_name, if (s.visible) "visible" else "none" });
        // Leading comma: this rides after the last chart layer.
        try overs.print(alloc, ",{{\"id\":\"{s}-overlay\",\"type\":\"raster\",\"source\":\"{s}\"," ++
            "\"layout\":{{\"visibility\":\"{s}\"}}}}", .{ s.source_name, s.source_name, if (s.visible_over) "visible" else "none" });
    }

    const src_tag = "\"sources\":{";
    const src_at = (std.mem.indexOf(u8, json, src_tag) orelse return error.NoSources) + src_tag.len;
    const lyr_tag = "\"layers\":[";
    const lyr_start = (std.mem.indexOf(u8, json, lyr_tag) orelse return error.NoLayers) + lyr_tag.len;
    const lyr_at = layerInsertAt(json, lyr_start, false);
    const lyr_end = layerInsertAt(json, lyr_start, true);

    var outb: std.ArrayList(u8) = .empty;
    errdefer outb.deinit(alloc);
    if (lyr_at < src_at or lyr_end < lyr_at) return error.NoLayers; // generator order: sources first
    try outb.appendSlice(alloc, json[0..src_at]);
    try outb.appendSlice(alloc, srcs.items);
    try outb.appendSlice(alloc, json[src_at..lyr_at]);
    try outb.appendSlice(alloc, lyrs.items);
    try outb.appendSlice(alloc, json[lyr_at..lyr_end]);
    try outb.appendSlice(alloc, overs.items);
    try outb.appendSlice(alloc, json[lyr_end..]);
    return outb.toOwnedSlice(alloc);
}

/// Scanning from just past `"layers":[`: with `to_end` false, the offset of
/// the first layer object whose "type" is neither "background" nor "fill"
/// (falling back to the array's closing bracket when every layer is a fill);
/// with `to_end` true, the offset of the closing bracket itself.
fn layerInsertAt(json: []const u8, start: usize, to_end: bool) usize {
    var i = start;
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var obj_start: usize = start;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (ch == '\\') {
                esc = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_str = true,
            '{' => {
                if (depth == 0) obj_start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0 and !to_end) {
                    const obj = json[obj_start .. i + 1];
                    const is_under = std.mem.indexOf(u8, obj, "\"type\":\"fill\"") != null or
                        std.mem.indexOf(u8, obj, "\"type\":\"background\"") != null;
                    if (!is_under) return obj_start;
                }
            },
            ']' => {
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return json.len;
}

/// The distinct SCAMIN denominators across a set of open charts, ascending.
/// Caller owns the returned slice.
pub fn collectScamin(alloc: std.mem.Allocator, charts: []const *cc.tile57_chart) []i32 {
    var seen: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer seen.deinit(alloc);
    for (charts) |c| {
        var out: [*c]i32 = null;
        var n: usize = 0;
        var err: cc.tile57_error = undefined;
        if (cc.tile57_chart_scamin(c, &out, &n, &err) != cc.TILE57_OK or out == null) continue;
        defer cc.tile57_free(out);
        for (out[0..n]) |v| if (v > 0) seen.put(alloc, v, {}) catch {};
    }
    const vals = alloc.alloc(i32, seen.count()) catch return &.{};
    var i: usize = 0;
    var it = seen.keyIterator();
    while (it.next()) |k| : (i += 1) vals[i] = k.*;
    std.mem.sort(i32, vals, {}, std.sort.asc(i32));
    return vals;
}

// ---- tests -----------------------------------------------------------------

test "collectScamin: no charts is an empty manifest" {
    const vals = collectScamin(std.testing.allocator, &.{});
    defer std.testing.allocator.free(vals);
    try std.testing.expectEqual(@as(usize, 0), vals.len);
}

// Every mariner switch has to reach the built style, because that is the only
// channel it has: the tiles carry tokens and raw depths, the style decides
// what they mean. A switch the emitter ignores is a setting the mariner can
// turn off and still see, which is what "data quality shows when disabled"
// was. This asks the emitter directly, one bool at a time, and names the ones
// that make no difference at all.
test "every mariner toggle changes the built style" {
    var base: cc.tile57_mariner = undefined;
    cc.tile57_mariner_defaults(&base);

    const Toggle = struct { name: []const u8, off: *const fn (*cc.tile57_mariner) void, on: *const fn (*cc.tile57_mariner) void };
    const T = struct {
        fn dqOff(m: *cc.tile57_mariner) void {
            m.data_quality = false;
        }
        fn dqOn(m: *cc.tile57_mariner) void {
            m.data_quality = true;
        }
        fn icOff(m: *cc.tile57_mariner) void {
            m.show_inform_callouts = false;
        }
        fn icOn(m: *cc.tile57_mariner) void {
            m.show_inform_callouts = true;
        }
        fn mbOff(m: *cc.tile57_mariner) void {
            m.show_meta_bounds = false;
        }
        fn mbOn(m: *cc.tile57_mariner) void {
            m.show_meta_bounds = true;
        }
        fn osOff(m: *cc.tile57_mariner) void {
            m.show_overscale = false;
        }
        fn osOn(m: *cc.tile57_mariner) void {
            m.show_overscale = true;
        }
        fn idOff(m: *cc.tile57_mariner) void {
            m.show_isolated_dangers_shallow = false;
        }
        fn idOn(m: *cc.tile57_mariner) void {
            m.show_isolated_dangers_shallow = true;
        }
        fn tnOff(m: *cc.tile57_mariner) void {
            m.text_names = false;
        }
        fn tnOn(m: *cc.tile57_mariner) void {
            m.text_names = true;
        }
        fn ldOff(m: *cc.tile57_mariner) void {
            m.show_light_descriptions = false;
        }
        fn ldOn(m: *cc.tile57_mariner) void {
            m.show_light_descriptions = true;
        }
        fn toOff(m: *cc.tile57_mariner) void {
            m.text_other = false;
        }
        fn toOn(m: *cc.tile57_mariner) void {
            m.text_other = true;
        }
        fn spOff(m: *cc.tile57_mariner) void {
            m.simplified_points = false;
        }
        fn spOn(m: *cc.tile57_mariner) void {
            m.simplified_points = true;
        }
        fn fsOff(m: *cc.tile57_mariner) void {
            m.show_full_sector_lines = false;
        }
        fn fsOn(m: *cc.tile57_mariner) void {
            m.show_full_sector_lines = true;
        }
        fn doOff(m: *cc.tile57_mariner) void {
            m.display_other = false;
        }
        fn doOn(m: *cc.tile57_mariner) void {
            m.display_other = true;
        }
        fn fwOff(m: *cc.tile57_mariner) void {
            m.four_shade_water = false;
        }
        fn fwOn(m: *cc.tile57_mariner) void {
            m.four_shade_water = true;
        }
    };
    const toggles = [_]Toggle{
        .{ .name = "data_quality", .off = T.dqOff, .on = T.dqOn },
        .{ .name = "show_inform_callouts", .off = T.icOff, .on = T.icOn },
        .{ .name = "show_meta_bounds", .off = T.mbOff, .on = T.mbOn },
        .{ .name = "show_overscale", .off = T.osOff, .on = T.osOn },
        .{ .name = "show_isolated_dangers_shallow", .off = T.idOff, .on = T.idOn },
        .{ .name = "text_names", .off = T.tnOff, .on = T.tnOn },
        .{ .name = "show_light_descriptions", .off = T.ldOff, .on = T.ldOn },
        .{ .name = "text_other", .off = T.toOff, .on = T.toOn },
        .{ .name = "simplified_points", .off = T.spOff, .on = T.spOn },
        .{ .name = "show_full_sector_lines", .off = T.fsOff, .on = T.fsOn },
        .{ .name = "display_other", .off = T.doOff, .on = T.doOn },
        .{ .name = "four_shade_water", .off = T.fwOff, .on = T.fwOn },
    };

    var inert: usize = 0;
    for (toggles) |t| {
        var m_off = base;
        t.off(&m_off);
        var s_off = build(.{ .mariner = m_off }) catch |e| {
            std.debug.print("  {s}: build failed {t}\n", .{ t.name, e });
            return e;
        };
        defer s_off.deinit();
        var m_on = base;
        t.on(&m_on);
        var s_on = build(.{ .mariner = m_on }) catch |e| {
            std.debug.print("  {s}: build failed {t}\n", .{ t.name, e });
            return e;
        };
        defer s_on.deinit();
        const same = std.mem.eql(u8, s_off.json, s_on.json);
        if (same) inert += 1;
        std.debug.print("  {s:<32} off={d:>7} on={d:>7} bytes  {s}\n", .{
            t.name, s_off.json.len, s_on.json.len,
            if (same) "NO EFFECT ON THE STYLE" else "ok",
        });
        // Exact equality: any toggle going inert fails, by name, above.
        try std.testing.expectEqual(false, same);
    }
    std.debug.print("mariner toggles with no effect on the built style: {d}/{d}\n", .{ inert, toggles.len });
}

test "the template names the source the host binds" {
    // The two must agree, or every tile request goes to a source charttable
    // has never heard of and the chart stays empty.
    try std.testing.expect(std.mem.startsWith(u8, tiles_url, source_name ++ "/"));
}

test "the basemap splices above the background and below the chart" {
    // The order is the whole point: the coastline must cover the style's own
    // backdrop and be covered by every chart layer.
    const json =
        \\{"version":8,
        \\ "sources":{"chart":{"type":"vector","tiles":["chart/{z}/{x}/{y}"]}},
        \\ "layers":[{"id":"bg","type":"background"},
        \\           {"id":"depare","type":"fill","source":"chart"},
        \\           {"id":"coalne","type":"line","source":"chart"}]}
    ;
    const out = try spliceBasemap(std.testing.allocator, json, cc.TILE57_SCHEME_DAY);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"basemap\":{\"type\":\"vector\"") != null);
    const bg = std.mem.indexOf(u8, out, "\"id\":\"bg\"").?;
    const land = std.mem.indexOf(u8, out, "\"id\":\"basemap-land\"").?;
    const coast = std.mem.indexOf(u8, out, "\"id\":\"basemap-coast\"").?;
    const depare = std.mem.indexOf(u8, out, "\"id\":\"depare\"").?;
    try std.testing.expect(bg < land);
    try std.testing.expect(land < coast);
    try std.testing.expect(coast < depare);
}

test "the basemap dims with the colour scheme" {
    // A night chart with daylight-grey land in it costs the dark adaptation
    // the palette exists to protect.
    const day = try basemap.layersJson(std.testing.allocator, cc.TILE57_SCHEME_DAY);
    defer std.testing.allocator.free(day);
    const night = try basemap.layersJson(std.testing.allocator, cc.TILE57_SCHEME_NIGHT);
    defer std.testing.allocator.free(night);
    try std.testing.expect(!std.mem.eql(u8, day, night));
}
