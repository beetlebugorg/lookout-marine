//! Bakes the vendored GSHHG coastline into vendor/gshhg/basemap.pmtiles, the
//! archive the core embeds. `zig build basemap` is the only thing that runs
//! it, and the archive is committed: an app build cannot bake, because the
//! Apple targets hand zig a phone SDK as the sysroot and a host tool built
//! under that has no libc.
//!
//! The input is the vendored GeoJSON, gzipped or plain.
//!
//! One MVT layer per GSHHG level: `land` (level 1) and `lake` (level 2). A
//! lake is its own polygon in GSHHG, not a hole in the land polygon, so the
//! style paints lake over land rather than punching through it.
//!
//! `coast` carries the same rings again as LINES. Stroking the polygons
//! instead would render the tile's clip edges too, which reads as a grid of
//! straight lines across open water.
//!
//! Geometry below a display pixel is dropped rather than encoded, which is
//! what keeps the world at z0 to a few kilobytes.
//!
//! Every tile in the zoom range is written, including the ones with nothing in
//! them. A gap is not the same as an empty tile: charttable answers a missing
//! tile from its parent, so an ocean tile left out comes back as whatever the
//! parent had there, which is a continent's worth of fill over open water.
//! Empty tiles all hash alike and cost one blob between them.

const std = @import("std");
const tiles = @import("tiles");

const mvt = tiles.mvt;
const tmath = tiles.tile;
const pmtiles = tiles.pmtiles;

/// The deepest baked zoom. charttable overzooms past this, so the cost of one
/// more level is archive bytes against detail nobody navigates by.
const MAX_ZOOM: u8 = 5;

/// Rings smaller than this in tile units are dropped: an island under a
/// display pixel is a smudge, and at z0 that is most of them. PX is the tile
/// units in one display pixel, so this is four pixels of area.
const MIN_RING_AREA: i64 = 4 * @as(i64, tmath.PX) * @as(i64, tmath.PX);

/// One source polygon, projected to normalised web mercator once. Reprojecting
/// per tile from there is a multiply, not a transcendental.
const Poly = struct {
    level: u8,
    pts: [][2]f64,
    min: [2]f64,
    max: [2]f64,
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: basemap <coastline.geojson> <out.pmtiles>\n", .{});
        return error.Usage;
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(64 << 20));
    defer gpa.free(raw);
    const gzipped = raw.len > 2 and raw[0] == 0x1f and raw[1] == 0x8b;
    const text = if (gzipped) try tiles.gzip.decompress(gpa, raw) else raw;
    defer if (gzipped) gpa.free(text);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const polys = try readPolys(arena, text);

    var w = pmtiles.StreamWriter.init(gpa);
    defer w.deinit();

    // Quiet on success: a build step that writes to stderr is reported as a
    // failed command even when it exits 0.
    var z: u8 = 0;
    while (z <= MAX_ZOOM) : (z += 1) try bakeZoom(gpa, arena, &w, polys, z);

    const out = try w.finishBytes(.{
        .metadata_json =
        \\{"name":"basemap","description":"GSHHG coastline (LGPL), see vendor/gshhg/README.md"}
        ,
    });
    defer gpa.free(out);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out });
}

/// The GeoJSON as projected polygons. Every GSHHG feature is a single closed
/// ring, so a feature is one polygon and no hole handling arises.
///
/// A ring that crosses the antimeridian arrives as one ring that steps from
/// +180 straight to -180. Taken literally that step is a segment across the
/// whole world, which floods a continent's worth of fill and leaves horizontal
/// lines behind it. So longitudes are unwrapped first, and a ring that then
/// reaches past the seam is emitted a second time, shifted a full turn, for
/// the tiles on the other side.
fn readPolys(arena: std.mem.Allocator, text: []const u8) ![]Poly {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, text, .{});
    defer parsed.deinit();

    const feats = parsed.value.object.get("features") orelse return error.NoFeatures;
    var out: std.ArrayList(Poly) = .empty;
    var lons: std.ArrayList(f64) = .empty;
    defer lons.deinit(arena);
    var lats: std.ArrayList(f64) = .empty;
    defer lats.deinit(arena);

    for (feats.array.items) |f| {
        const geom = f.object.get("geometry") orelse continue;
        const rings = geom.object.get("coordinates") orelse continue;
        if (rings.array.items.len == 0) continue;
        const ring = rings.array.items[0].array.items;
        if (ring.len < 4) continue;

        const level: u8 = lvl: {
            const props = f.object.get("properties") orelse break :lvl 1;
            const v = props.object.get("level") orelse break :lvl 1;
            break :lvl switch (v) {
                .integer => |i| @intCast(i),
                else => 1,
            };
        };
        if (level != 1 and level != 2) continue;

        lons.clearRetainingCapacity();
        lats.clearRetainingCapacity();
        var lo: f64 = 180;
        var hi: f64 = -180;
        for (ring) |p| {
            const c = p.array.items;
            var lon = num(c[0]);
            if (lons.items.len != 0) {
                const prev = lons.items[lons.items.len - 1];
                while (lon - prev > 180) lon -= 360;
                while (prev - lon > 180) lon += 360;
            }
            try lons.append(arena, lon);
            try lats.append(arena, num(c[1]));
            lo = @min(lo, lon);
            hi = @max(hi, lon);
        }

        try out.append(arena, try project(arena, level, lons.items, lats.items, 0));
        // The part that ran off one end of the world belongs at the other.
        if (hi > 180) try out.append(arena, try project(arena, level, lons.items, lats.items, -360));
        if (lo < -180) try out.append(arena, try project(arena, level, lons.items, lats.items, 360));
    }
    return out.toOwnedSlice(arena);
}

/// One ring in normalised web-mercator, `shift` degrees of longitude along.
fn project(arena: std.mem.Allocator, level: u8, lons: []const f64, lats: []const f64, shift: f64) !Poly {
    const pts = try arena.alloc([2]f64, lons.len);
    var min = [2]f64{ std.math.floatMax(f64), std.math.floatMax(f64) };
    var max = [2]f64{ -std.math.floatMax(f64), -std.math.floatMax(f64) };
    for (lons, lats, 0..) |lon, lat, i| {
        pts[i] = tmath.lonLatToWorld(lon + shift, lat);
        min[0] = @min(min[0], pts[i][0]);
        min[1] = @min(min[1], pts[i][1]);
        max[0] = @max(max[0], pts[i][0]);
        max[1] = @max(max[1], pts[i][1]);
    }
    return .{ .level = level, .pts = pts, .min = min, .max = max };
}

fn num(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

/// Write every non-empty tile of one zoom.
fn bakeZoom(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    w: *pmtiles.StreamWriter,
    polys: []const Poly,
    z: u8,
) !void {
    const side: u32 = @as(u32, 1) << @intCast(z);
    const sidef: f64 = @floatFromInt(side);
    // The clip box reaches one buffer past the tile, so a polygon whose bounds
    // stop just short of a tile can still cross into it.
    const pad: f64 = @as(f64, @floatFromInt(tmath.BUFFER)) / @as(f64, @floatFromInt(tmath.EXTENT)) / sidef;
    const box = tmath.Box.default(tmath.EXTENT, tmath.BUFFER);

    // Which polygons touch which tile. Bucketing beats testing every polygon
    // against every tile once the zoom has more than a few hundred tiles.
    var buckets = std.AutoHashMap(u64, std.ArrayList(u32)).init(gpa);
    defer {
        var it = buckets.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        buckets.deinit();
    }
    for (polys, 0..) |p, pi| {
        const x0 = tileIndex(p.min[0] - pad, side);
        const x1 = tileIndex(p.max[0] + pad, side);
        const y0 = tileIndex(p.min[1] - pad, side);
        const y1 = tileIndex(p.max[1] + pad, side);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const key = (@as(u64, y) << 32) | x;
                const slot = try buckets.getOrPut(key);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(gpa, @intCast(pi));
            }
        }
    }

    // The tiles that got geometry, so the gaps can be filled below.
    var written = std.AutoHashMap(u64, void).init(gpa);
    defer written.deinit();

    var it = buckets.iterator();
    while (it.next()) |e| {
        const tx: u32 = @truncate(e.key_ptr.*);
        const ty: u32 = @truncate(e.key_ptr.* >> 32);

        var tile_arena = std.heap.ArenaAllocator.init(gpa);
        defer tile_arena.deinit();
        const ta = tile_arena.allocator();

        var land: std.ArrayList(mvt.Feature) = .empty;
        var lake: std.ArrayList(mvt.Feature) = .empty;
        var coast: std.ArrayList(mvt.Feature) = .empty;
        for (e.value_ptr.items) |pi| {
            const p = polys[pi];
            const proj = try projectRing(ta, p, z, tx, ty);
            if (proj.len < 4) continue;

            const ring = try clipRing(ta, proj, box);
            if (ring.len != 0) {
                const parts = try ta.alloc([]const mvt.Point, 1);
                parts[0] = ring;
                const feat: mvt.Feature = .{ .geom_type = .polygon, .parts = parts };
                if (p.level == 1) try land.append(ta, feat) else try lake.append(ta, feat);
            }

            // The shoreline itself: the ring cut as a line, so a cut leaves a
            // gap at the tile edge rather than a segment along it.
            const runs = try tmath.clipLine(ta, proj, box);
            for (runs) |run| {
                if (run.len < 2) continue;
                const parts = try ta.alloc([]const mvt.Point, 1);
                parts[0] = run;
                try coast.append(ta, .{ .geom_type = .linestring, .parts = parts });
            }
        }
        if (land.items.len == 0 and lake.items.len == 0 and coast.items.len == 0) continue;

        var layers: std.ArrayList(mvt.Layer) = .empty;
        if (land.items.len != 0) try layers.append(ta, .{ .name = "land", .features = land.items });
        if (lake.items.len != 0) try layers.append(ta, .{ .name = "lake", .features = lake.items });
        if (coast.items.len != 0) try layers.append(ta, .{ .name = "coast", .features = coast.items });

        const bytes = try mvt.encode(gpa, .{ .layers = layers.items });
        defer gpa.free(bytes);
        try w.add(z, tx, ty, bytes);
        try written.put(e.key_ptr.*, {});
    }

    // One layer, no features: a tile that says "nothing here" rather than one
    // the map has to guess at.
    const empty = try mvt.encode(gpa, .{ .layers = &.{.{ .name = "land", .features = &.{} }} });
    defer gpa.free(empty);
    var y: u32 = 0;
    while (y < side) : (y += 1) {
        var x: u32 = 0;
        while (x < side) : (x += 1) {
            if (written.contains((@as(u64, y) << 32) | x)) continue;
            try w.add(z, x, y, empty);
        }
    }
    _ = arena;
}

/// One polygon in this tile's coordinates, with the points the quantisation
/// collapsed dropped. Short of 4 points there is no ring left to render.
fn projectRing(ta: std.mem.Allocator, p: Poly, z: u8, tx: u32, ty: u32) ![]const mvt.Point {
    const proj = try ta.alloc(mvt.Point, p.pts.len);
    var n: usize = 0;
    for (p.pts) |wpt| {
        const q = tmath.worldToTile(wpt, z, tx, ty, tmath.EXTENT);
        // The projection quantises to tile units, so a coastline that is
        // finely surveyed collapses to repeated points at low zoom.
        if (n != 0 and proj[n - 1].x == q.x and proj[n - 1].y == q.y) continue;
        proj[n] = q;
        n += 1;
    }
    return proj[0..n];
}

/// The ring clipped to the tile and wound the way the MVT spec asks (exterior
/// ring clockwise in tile space, which is y down). Empty when nothing of it
/// survives, or when what survives is smaller than a few pixels.
fn clipRing(ta: std.mem.Allocator, proj: []const mvt.Point, box: tmath.Box) ![]const mvt.Point {
    const clipped = try tmath.clipPolygon(ta, proj, box);
    if (clipped.len < 4) return &.{};

    const area = signedArea(clipped);
    if (@abs(area) < MIN_RING_AREA) return &.{};
    if (area < 0) std.mem.reverse(mvt.Point, clipped);
    return clipped;
}

/// Twice the signed area, positive when the ring runs clockwise in tile space.
fn signedArea(ring: []const mvt.Point) i64 {
    var sum: i64 = 0;
    var prev = ring[ring.len - 1];
    for (ring) |cur| {
        sum += @as(i64, prev.x) * @as(i64, cur.y) - @as(i64, cur.x) * @as(i64, prev.y);
        prev = cur;
    }
    return sum;
}

fn tileIndex(w: f64, side: u32) u32 {
    const sidef: f64 = @floatFromInt(side);
    const v = @floor(w * sidef);
    if (v < 0) return 0;
    if (v > sidef - 1) return side - 1;
    return @intFromFloat(v);
}
