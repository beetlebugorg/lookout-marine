//! Builds the MapLibre style lookout hands to the map.
//!
//! tile57 already generates the whole S-101 layer set — 240 layers, symbols,
//! patterns, complex linestyles, soundings, the mariner's depth shading and
//! danger swaps. Nothing here reimplements portrayal. This file only:
//!
//!   1. asks for the TEMPLATE with our `lookout://` urls in it,
//!   2. patches the mariner's settings into it, and
//!   3. hands the bytes over.
//!
//! Step 2 is why a scheme change or a safety-contour nudge does not touch the
//! tiles: the tiles carry tokens and raw depths, the style decides what they
//! mean. Rebuild the style, set it, done.
//!
//! SCAMIN GATING
//!
//! tile57 has three SCAMIN modes and we want the third: `scamin_filter_gate`.
//! It emits ONE layer per render type carrying
//!
//!     [">=", ["coalesce", ["get","scamin"], 1e12], curDenom]
//!
//! which is fractional-exact, instead of one layer per distinct denominator
//! (107 across a full library, against a 240-layer style).
//!
//! It is selected on the MARINER struct, not as a style argument —
//! `tile57_mariner.scamin_filter_gate`, which `marinerFromC` maps straight
//! through. So it is reachable from the C ABI and no engine change is needed.
//!
//! The gate carries `curDenom = 0` out of the build, which means "show all".
//! Making it exact is the host's job: rewrite that literal with
//! `setLayerFilter` each time the view crosses one of the denominators the
//! library actually contains. That is `scaminDenom` plus the crossing driver in
//! host.zig, not a rebuild — see specs/maplibre/concerns.md C9.

const std = @import("std");
const cc = @import("cabi").c;
const t57 = @import("tile57");

/// The urls the resource provider answers. Kept here rather than in provider.zig
/// so the template and the parser cannot drift apart silently.
pub const tiles_url = "lookout://tile/{z}/{x}/{y}";
pub const sprite_url = "lookout://sprite";
pub const glyphs_url = "lookout://glyphs/{fontstack}/{range}.pbf";

pub const Error = error{ TemplateFailed, BuildFailed, AssetsFailed, OutOfMemory };

/// Everything the style depends on. A change to any field means a rebuild.
pub const Inputs = struct {
    scheme: cc.tile57_scheme = cc.TILE57_SCHEME_DAY,
    mariner: cc.tile57_mariner,
    /// The archive's stored tile encoding (tile57_tile_type). MLT archives must
    /// say so or MapLibre decodes them as MVT and draws nothing.
    tile_encoding: u8 = cc.TILE57_TILE_TYPE_MLT,
    minzoom: u32 = 0,
    maxzoom: u32 = 16,
    /// Distinct SCAMIN denominators in the open library, from
    /// tile57_chart_scamin, ascending. In filter-gate mode these are NOT passed
    /// to the style build (that argument selects bucket mode); they are the
    /// boundary list the host watches to know when to rewrite the gate.
    scamin: []const i32 = &.{},
    /// Representative latitude for the display-denominator conversion (the
    /// library centre). SCAMIN cutoffs are latitude-dependent.
    scamin_lat: f64 = 0,
    /// Band filter, or empty for all bands.
    bands: []const i32 = &.{},
};

/// The catalogue assets the style references. Baked once and reused: they do
/// not depend on the mariner, only on the catalogue.
pub const Assets = struct {
    raw: cc.tile57_assets,

    pub fn bake(catalog_dir: ?[:0]const u8) Error!Assets {
        var raw: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        const dir: [*c]const u8 = if (catalog_dir) |d| d.ptr else null;
        if (cc.tile57_bake_assets(dir, &raw, &err) != cc.TILE57_OK) return Error.AssetsFailed;
        return .{ .raw = raw };
    }

    pub fn deinit(self: *Assets) void {
        cc.tile57_assets_free(&self.raw);
    }

    pub fn colortables(self: *const Assets) []const u8 {
        if (self.raw.colortables == null) return "";
        return self.raw.colortables[0..self.raw.colortables_len];
    }
};

/// A built style. `json` is owned by tile57 and freed with `deinit`.
pub const Style = struct {
    json: []const u8,

    pub fn deinit(self: *Style) void {
        if (self.json.len != 0) cc.tile57_free(@constCast(self.json.ptr));
        self.json = "";
    }
};

/// Build the concrete style for these inputs.
///
/// Two calls, as the engine intends: the template carries the layer set and our
/// urls, then the build patches the mariner in. We do not cache the template
/// because it is cheap next to the tiles and caching it invites the two halves
/// going out of step across a scheme change.
pub fn build(inputs: Inputs, assets: *const Assets) Error!Style {
    var tmpl: [*c]u8 = null;
    var tmpl_len: usize = 0;
    var err: cc.tile57_error = undefined;

    if (cc.tile57_style_template(
        inputs.scheme,
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

    const ct = assets.colortables();
    var out: [*c]u8 = null;
    var out_len: usize = 0;

    // Two things that look like style arguments but are actually mariner
    // fields. Both were caught by tests rather than by reading the signature.
    //
    // `scheme`: tile57_style_template takes one, but it only stamps the
    // template. The BUILD resolves every colour token from `m.scheme`, so a
    // template built for night and a mariner left on day yields a day chart.
    //
    // `scamin_filter_gate`: selects the one-layer-per-type exact gate over the
    // per-value buckets. Passing a SCAMIN manifest as well would select buckets
    // and silently undo it, so the manifest goes in as null.
    var m = inputs.mariner;
    m.scheme = inputs.scheme;
    m.scamin_filter_gate = true;

    if (cc.tile57_style_build(
        @ptrCast(tmpl),
        tmpl_len,
        &m,
        @ptrCast(ct.ptr),
        ct.len,
        if (inputs.bands.len == 0) null else inputs.bands.ptr,
        inputs.bands.len,
        null,
        0,
        inputs.scamin_lat,
        &out,
        &out_len,
        &err,
    ) != cc.TILE57_OK) return Error.BuildFailed;

    return .{ .json = out[0..out_len] };
}

// ---- the SCAMIN crossing driver -------------------------------------------

/// The 1:N denominator the display is showing at this zoom and latitude. The
/// engine's own function, so the gate we write agrees with the gate the style
/// was generated against.
pub fn displayDenom(zoom: f64, lat: f64) f64 {
    return t57.style.displayDenom(zoom, lat);
}

/// Watches the view and answers one question: has it crossed a SCAMIN boundary,
/// so the gate literal has to be rewritten?
///
/// WHY THIS IS NOT PER FRAME. The gate only has to change when the display
/// denominator crosses a value some feature actually carries. A library holds
/// about a hundred distinct denominators over the whole zoom range, and a real
/// pinch crosses a handful. So this is a compare per frame and a `setLayerFilter`
/// a few times per gesture — not a rebuild, and not per frame.
pub const Gate = struct {
    /// Distinct denominators present in the library, ascending.
    denoms: []const i32,
    lat: f64,
    /// The value currently written into the style's gate clause. 0 = show all,
    /// which is what a freshly built style carries.
    current: f64 = 0,

    /// The denominator the gate should hold for this zoom: the display
    /// denominator itself. Features whose `scamin >= curDenom` show.
    pub fn wanted(self: *const Gate, zoom: f64) f64 {
        return displayDenom(zoom, self.lat);
    }

    /// True when moving to `zoom` steps over at least one denominator in the
    /// manifest, i.e. when some feature's visibility actually changes. Between
    /// boundaries the gate is already correct and must not be rewritten.
    pub fn crosses(self: *const Gate, zoom: f64) bool {
        const next = self.wanted(zoom);
        const lo = @min(self.current, next);
        const hi = @max(self.current, next);
        if (lo == hi) return false;
        for (self.denoms) |d| {
            const v: f64 = @floatFromInt(d);
            if (v > lo and v <= hi) return true;
        }
        // Leaving the initial show-all state always counts: the style ships
        // with curDenom 0 and nothing is gated until we write a real value.
        return self.current == 0;
    }

    pub fn commit(self: *Gate, zoom: f64) f64 {
        self.current = self.wanted(zoom);
        return self.current;
    }
};

// ---- tests ---------------------------------------------------------------

test "displayDenom falls as you zoom in" {
    const a = displayDenom(9.0, 38.9);
    const b = displayDenom(14.0, 38.9);
    try std.testing.expect(b < a);
    try std.testing.expect(a > 0);
}

test "Gate: the first move off show-all always rewrites" {
    var g = Gate{ .denoms = &.{ 12000, 45000 }, .lat = 38.9 };
    try std.testing.expect(g.crosses(12.0));
    _ = g.commit(12.0);
    try std.testing.expect(g.current > 0);
}

test "Gate: a move inside one band does not rewrite" {
    // Between two denominators nothing changes visibility, so a pinch that
    // stays inside a band must not call setLayerFilter at all.
    var g = Gate{ .denoms = &.{ 1000, 10_000_000 }, .lat = 38.9 };
    _ = g.commit(14.0);
    try std.testing.expect(!g.crosses(14.05));
    try std.testing.expect(!g.crosses(13.95));
}

test "Gate: crossing a denominator rewrites, in either direction" {
    var g = Gate{ .denoms = &.{}, .lat = 38.9 };
    _ = g.commit(14.0);
    const mid = (displayDenom(14.0, 38.9) + displayDenom(13.0, 38.9)) / 2.0;
    const one = [_]i32{@intFromFloat(mid)};
    g.denoms = &one;

    try std.testing.expect(g.crosses(13.0)); // zooming out crosses it
    _ = g.commit(13.0);
    try std.testing.expect(g.crosses(14.0)); // and back in crosses it again
}

test "Gate: a fractional zoom is honoured, not rounded to a step" {
    // The whole reason for this mode is that MapLibre filters snap to integer
    // zooms. If the driver rounded too, the port would be no better off.
    var g = Gate{ .denoms = &.{}, .lat = 38.9 };
    const at_14 = displayDenom(14.0, 38.9);
    const at_14_5 = displayDenom(14.5, 38.9);
    try std.testing.expect(at_14_5 < at_14);
    _ = g.commit(14.5);
    try std.testing.expectApproxEqRel(at_14_5, g.current, 1e-12);
}

test "the template urls match what the provider parses" {
    // These two files are the only place the scheme is spelled out. If either
    // side is edited alone the map silently fetches nothing, so assert the
    // shapes here rather than discovering it as a blank chart.
    const provider = @import("provider.zig");
    try std.testing.expect(std.mem.startsWith(u8, tiles_url, provider.scheme));
    try std.testing.expect(std.mem.startsWith(u8, sprite_url, provider.scheme));
    try std.testing.expect(std.mem.startsWith(u8, glyphs_url, provider.scheme));

    // The provider must accept a url of the shape the template emits once
    // MapLibre has substituted its placeholders.
    try std.testing.expect(std.mem.endsWith(u8, tiles_url, "{z}/{x}/{y}"));
    try std.testing.expect(std.mem.endsWith(u8, glyphs_url, "{fontstack}/{range}.pbf"));
}

test "assets bake from the embedded catalogue and carry colortables" {
    var assets = try Assets.bake(null);
    defer assets.deinit();
    const ct = assets.colortables();
    try std.testing.expect(ct.len > 0);
    // The three S-52 palettes are the contract the style resolves tokens against.
    try std.testing.expect(std.mem.indexOf(u8, ct, "day") != null);
    try std.testing.expect(std.mem.indexOf(u8, ct, "dusk") != null);
    try std.testing.expect(std.mem.indexOf(u8, ct, "night") != null);
}

test "build produces a style naming our source urls" {
    var assets = try Assets.bake(null);
    defer assets.deinit();

    var m: cc.tile57_mariner = undefined;
    cc.tile57_mariner_defaults(&m);

    var style = try build(.{ .mariner = m }, &assets);
    defer style.deinit();

    try std.testing.expect(style.json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, style.json, "lookout://tile/") != null);
    try std.testing.expect(std.mem.indexOf(u8, style.json, "lookout://sprite") != null);
    try std.testing.expect(std.mem.indexOf(u8, style.json, "lookout://glyphs/") != null);
}

test "a scheme change changes the style, not the tiles" {
    var assets = try Assets.bake(null);
    defer assets.deinit();

    var m: cc.tile57_mariner = undefined;
    cc.tile57_mariner_defaults(&m);

    var day = try build(.{ .scheme = cc.TILE57_SCHEME_DAY, .mariner = m }, &assets);
    defer day.deinit();
    var night = try build(.{ .scheme = cc.TILE57_SCHEME_NIGHT, .mariner = m }, &assets);
    defer night.deinit();

    // Same layer set, different resolved colours: this is the whole reason the
    // tiles carry tokens instead of RGB.
    try std.testing.expect(!std.mem.eql(u8, day.json, night.json));
    try std.testing.expect(std.mem.indexOf(u8, day.json, "lookout://tile/") != null);
    try std.testing.expect(std.mem.indexOf(u8, night.json, "lookout://tile/") != null);
}
