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
//! relayout of every resident tile. See specs/charttable/concerns.md C2.

const std = @import("std");
const cc = @import("../c.zig").c;

/// The style source name the template writes, and the name the host binds its
/// tile provider to. Kept here so the template and the binding cannot drift.
pub const source_name = "chart";

/// The tile url in the template. charttable never fetches it — the source is
/// bound by name — but the template needs a template-shaped string.
pub const tiles_url = source_name ++ "/{z}/{x}/{y}";
pub const sprite_url = "lookout://sprite";
pub const glyphs_url = "lookout://glyphs/{fontstack}/{range}.pbf";

pub const Error = error{ TemplateFailed, BuildFailed, ColortablesFailed };

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
};

/// A built style. `json` is owned by tile57 and freed with `deinit`.
pub const Style = struct {
    json: []const u8 = "",

    pub fn deinit(self: *Style) void {
        if (self.json.len != 0) cc.tile57_free(@constCast(self.json.ptr));
        self.json = "";
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

    return .{ .json = out[0..out_len] };
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

test "the template names the source the host binds" {
    // The two must agree, or every tile request goes to a source charttable
    // has never heard of and the chart stays empty.
    try std.testing.expect(std.mem.startsWith(u8, tiles_url, source_name ++ "/"));
}
