//! NOAA's ENC product catalog, and what a region selection covers.
//!
//! NOAA publishes ENCProdCat.xml, listing every United States cell with its
//! edition, its issue date, the url of its own exchange-set zip, and the Coast
//! Guard district it is filed under. This module reads that document, prices a
//! selection, and reports which installed cells have been reissued.
//!
//! A region here is a Coast Guard district, the unit NOAA files a cell under.
//! A district is an administrative boundary and water is continuous across it.
//! NOAA files each cell under one district, so a cell on a district line
//! covers water in two of them and ships with only one. Selecting a district
//! and taking its tagged cells alone leaves a gap along that line.
//!
//! selectRegions therefore includes a cell when NOAA files it under a chosen
//! district, or when its coverage overlaps a cell that NOAA does. The result
//! is a superset of NOAA's own per-district bundle. Selecting too much is the
//! safe direction, because a cell reaching into the chosen water belongs on
//! the chart however NOAA files it.
//!
//! This module opens no socket. The catalog arrives as bytes the shell
//! fetched. See lookout_set_http_provider.

const std = @import("std");

/// One cell in the catalog. The slices point into the catalog's arena and
/// live exactly as long as it does.
pub const Cell = struct {
    /// The cell name. It is also the file stem: "US5MD1MC".
    name: []const u8,
    /// NOAA's long name: "Chesapeake Bay Entrance".
    title: []const u8,
    /// Compilation scale, 1:N. 0 when the catalog does not state one.
    scale: u32 = 0,
    /// Edition and update number. Together they say whether a cell already on
    /// this device is the one NOAA is publishing now.
    edition: u32 = 0,
    update: u32 = 0,
    /// Issue date as NOAA writes it, "20250903". Shown, never parsed.
    issued: []const u8 = "",
    /// This cell's own exchange-set zip.
    zip_url: []const u8 = "",
    zip_bytes: u64 = 0,
    /// The Coast Guard district NOAA files it under. 0 when absent.
    district: u8 = 0,
    /// Usage band, 1 overview to 6 berthing, from the third character of the
    /// cell name (US5MD1MC is band 5). 0 when the name does not carry one.
    band: u8 = 0,
    /// Coverage, from every vertex of every panel.
    box: Box = .{},

    /// True when these numbers match the cell.
    pub fn sameAs(self: Cell, edition: u32, update: u32) bool {
        return self.edition == edition and self.update == update;
    }
};

/// A cell's coverage as a longitude span and a latitude span.
///
/// Longitude is a start and a width rather than a west and an east, because a
/// west/east pair cannot describe a cell crossing the antimeridian. The min
/// and max of the raw longitudes of an Aleutian cell running 179E to 179W are
/// -179 and +179, which describe a box around the whole world. Alaska has
/// enough such cells to matter.
pub const Box = struct {
    /// Western edge, in [-180, 180).
    start: f64 = 0,
    /// Degrees of longitude eastward from `start`, in [0, 360].
    width: f64 = 0,
    south: f64 = 0,
    north: f64 = 0,
    /// False when the catalog listed no vertices for the cell.
    known: bool = false,

    /// Do these two boxes share any water?
    pub fn overlaps(a: Box, b: Box) bool {
        if (!a.known or !b.known) return false;
        if (a.north < b.south or b.north < a.south) return false;
        return overlapsLon(a, b);
    }

    /// Longitude overlap on the circle. Shifting b's start into the turn that
    /// begins at a's start reduces this to an interval test with one wrap.
    fn overlapsLon(a: Box, b: Box) bool {
        if (a.width >= 360 or b.width >= 360) return true;
        var d = @mod(b.start - a.start, 360.0);
        if (d < 0) d += 360;
        // b starts inside a, or b wraps past 360 back into a's opening.
        return d < a.width or d + b.width > 360;
    }
};

/// The regions a mariner picks from, the Coast Guard districts NOAA
/// ships. NOAA disestablished 2, 3, 4, 6, 10, 12 and 16, and no cell lists
/// them.
pub const Region = struct {
    /// Stable id, used by the shells and written to the store. Null
    /// terminated, so the C API can hand the table out as it stands.
    id: [:0]const u8,
    district: u8,
    /// The name of the water. NOAA files cells under a Coast Guard district
    /// number, and a mariner picks the place instead.
    name: [:0]const u8,
    blurb: [:0]const u8,
    /// Where to draw this region on a picker's map, in degrees. A rough
    /// extent for display. What a region actually selects comes from the
    /// catalog, so these numbers never decide which cells download.
    west: f64,
    south: f64,
    east: f64,
    north: f64,
};

pub const regions = [_]Region{
    .{ .id = "d1", .district = 1, .name = "Northeast",
       .blurb = "Maine south to northern New Jersey",
       .west = -74.5, .south = 39.6, .east = -66.9, .north = 45.2 },
    .{ .id = "d5", .district = 5, .name = "Mid-Atlantic",
       .blurb = "New Jersey to North Carolina, and the Chesapeake and Delaware bays",
       .west = -78.5, .south = 33.8, .east = -73.4, .north = 40.6 },
    .{ .id = "d7", .district = 7, .name = "Southeast",
       .blurb = "South Carolina, Georgia and eastern Florida, with Puerto Rico and the Virgin Islands",
       .west = -83.4, .south = 24.2, .east = -75.0, .north = 33.9 },
    .{ .id = "d8", .district = 8, .name = "Gulf Coast",
       .blurb = "Western Florida to Texas, and the Western Rivers",
       .west = -97.4, .south = 25.8, .east = -81.0, .north = 31.4 },
    .{ .id = "d9", .district = 9, .name = "Great Lakes",
       .blurb = "All five lakes and the St Lawrence Seaway",
       .west = -92.4, .south = 41.2, .east = -76.0, .north = 49.0 },
    .{ .id = "d11", .district = 11, .name = "California",
       .blurb = "The California coast",
       .west = -125.0, .south = 32.5, .east = -117.1, .north = 42.0 },
    .{ .id = "d13", .district = 13, .name = "Pacific Northwest",
       .blurb = "Oregon and Washington",
       .west = -125.4, .south = 42.0, .east = -122.0, .north = 49.0 },
    .{ .id = "d14", .district = 14, .name = "Pacific Islands",
       .blurb = "Hawaii, Guam and American Samoa",
       .west = -160.6, .south = 18.6, .east = -154.6, .north = 22.4 },
    .{ .id = "d17", .district = 17, .name = "Alaska",
       .blurb = "All of Alaska",
       .west = -169.0, .south = 51.5, .east = -130.5, .north = 71.4 },
};

/// The region with this id, or null.
pub fn regionById(id: []const u8) ?Region {
    for (regions) |r| if (std.mem.eql(u8, r.id, id)) return r;
    return null;
}

/// Read a comma separated list of region ids into district numbers.
///
/// Returns the districts written into `buf`. An id no region answers to is
/// skipped, and a repeated id is written once.
pub fn districtsFromIds(buf: []u8, ids: []const u8) []u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, ids, ',');
    outer: while (it.next()) |raw| {
        const id = std.mem.trim(u8, raw, " \t\r\n");
        if (id.len == 0) continue;
        const r = regionById(id) orelse continue;
        for (buf[0..n]) |seen| {
            if (seen == r.district) continue :outer;
        }
        if (n == buf.len) break;
        buf[n] = r.district;
        n += 1;
    }
    return buf[0..n];
}

/// Where the catalog is published. The shell receives this url and returns
/// the bytes.
pub const catalog_url = "https://www.charts.noaa.gov/ENCs/ENCProdCat.xml";

/// A catalog is about 10 MB of XML for about 7,000 cells. Past this limit the
/// response is some other document.
pub const max_catalog_bytes: usize = 32 << 20;

/// The parsed catalog. Owns one arena holding every string the cells point
/// at, so the whole thing frees in one call.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    cells: []Cell = &.{},
    /// NOAA's own validity date for this snapshot, "20250903".
    date: []const u8 = "",

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    /// The cell of this name, or null. A linear scan, because callers read the
    /// catalog in bulk far more often than by name.
    pub fn find(self: *const Catalog, name: []const u8) ?*const Cell {
        for (self.cells) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

/// What a selection costs. `bytes` sums the cells' own zips, so it measures
/// the download rather than the prepared chart on disk.
pub const Cost = struct {
    cells: u32 = 0,
    bytes: u64 = 0,
};

/// A cell already on this device.
pub const Installed = struct {
    name: []const u8,
    edition: u32,
    update: u32,
};

// ---- parsing --------------------------------------------------------------
//
// The catalog is flat and regular, a run of <cell> blocks holding leaf tags,
// so this scans for tags rather than building a tree. A DOM of 7,000 cells
// costs more than the document.

/// The text between <name> and </name> in `s`, first occurrence, trimmed.
fn tag(s: []const u8, comptime name: []const u8) ?[]const u8 {
    const open = "<" ++ name ++ ">";
    const close = "</" ++ name ++ ">";
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const after = s[i + open.len ..];
    const j = std.mem.indexOf(u8, after, close) orelse return null;
    return std.mem.trim(u8, after[0..j], " \t\r\n");
}

/// A tag's value as a number, or 0 when it is absent or not all digits.
fn tagInt(s: []const u8, comptime name: []const u8, comptime T: type) T {
    const v = tag(s, name) orelse return 0;
    if (v.len == 0) return 0;
    return std.fmt.parseInt(T, v, 10) catch 0;
}

/// The usage band a cell name states. S-57 puts it in the third character.
fn bandOf(name: []const u8) u8 {
    if (name.len < 3) return 0;
    const c = name[2];
    return if (c >= '1' and c <= '6') c - '0' else 0;
}

/// A cell's coverage, from every vertex of every panel.
///
/// This gathers the vertices first and decides the span afterward. One vertex
/// does not show whether the cell crosses the antimeridian.
fn coverage(alloc: std.mem.Allocator, block: []const u8) !Box {
    var lons: std.ArrayList(f64) = .empty;
    defer lons.deinit(alloc);
    var south: f64 = std.math.floatMax(f64);
    var north: f64 = -std.math.floatMax(f64);

    var rest = block;
    while (std.mem.indexOf(u8, rest, "<vertex>")) |vi| {
        rest = rest[vi + "<vertex>".len ..];
        const lat_s = tag(rest, "lat") orelse continue;
        const lon_s = tag(rest, "long") orelse continue;
        const lat = std.fmt.parseFloat(f64, lat_s) catch continue;
        const lon = std.fmt.parseFloat(f64, lon_s) catch continue;
        south = @min(south, lat);
        north = @max(north, lat);
        try lons.append(alloc, lon);
    }
    if (lons.items.len == 0) return .{};

    const span = lonSpan(lons.items);
    return .{
        .start = span.start,
        .width = span.width,
        .south = south,
        .north = north,
        .known = true,
    };
}

/// The narrowest longitude span containing every one of these points.
///
/// Sort the points and find the widest gap between neighbors. The span is the
/// rest of the circle. This holds whether or not the points straddle the
/// antimeridian, where a plain min and max fails.
fn lonSpan(lons: []f64) struct { start: f64, width: f64 } {
    if (lons.len == 1) return .{ .start = lons[0], .width = 0 };
    std.mem.sort(f64, lons, {}, std.sort.asc(f64));

    var gap: f64 = -1;
    var after: usize = 0;
    for (lons, 0..) |lo, i| {
        const next = if (i + 1 < lons.len) lons[i + 1] else lons[0] + 360;
        const d = next - lo;
        if (d > gap) {
            gap = d;
            after = i;
        }
    }
    // The span begins at the point just past the widest gap and runs to the
    // point the gap started from, the long way round if that is what is left.
    const start = lons[(after + 1) % lons.len];
    const width = 360 - gap;
    return .{ .start = start, .width = @max(width, 0) };
}

/// Parse a NOAA ENCProdCat.xml. The returned catalog owns every string in it,
/// so the caller may free `xml` at once.
pub fn parse(gpa: std.mem.Allocator, xml: []const u8) !Catalog {
    var cat = Catalog{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer cat.arena.deinit();
    const a = cat.arena.allocator();

    cat.date = try a.dupe(u8, tag(xml, "date_valid") orelse "");

    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(a);

    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<cell>")) |i| {
        const after = rest[i + "<cell>".len ..];
        const end = std.mem.indexOf(u8, after, "</cell>") orelse break;
        const block = after[0..end];
        rest = after[end + "</cell>".len ..];

        const name = tag(block, "name") orelse continue;
        if (name.len == 0) continue;

        try cells.append(a, .{
            .name = try a.dupe(u8, name),
            .title = try a.dupe(u8, tag(block, "lname") orelse ""),
            .scale = tagInt(block, "cscale", u32),
            .edition = tagInt(block, "edtn", u32),
            .update = tagInt(block, "updn", u32),
            .issued = try a.dupe(u8, tag(block, "isdt") orelse ""),
            .zip_url = try a.dupe(u8, tag(block, "zipfile_location") orelse ""),
            .zip_bytes = tagInt(block, "zipfile_size", u64),
            .district = tagInt(block, "coast_guard_district", u8),
            .band = bandOf(name),
            .box = try coverage(a, block),
        });
    }

    cat.cells = try cells.toOwnedSlice(a);
    return cat;
}

// ---- selection ------------------------------------------------------------

/// Every cell that covers any part of the chosen regions, by index into
/// `cat.cells`, ascending.
///
/// Two passes. The first collects the cells NOAA files under a chosen
/// district. The second adds every cell whose coverage overlaps one of those,
/// turning the district's own cells into the charts that cover its water. See
/// the note at the top of this file.
///
/// The caller owns the returned slice.
pub fn selectRegions(
    alloc: std.mem.Allocator,
    cat: *const Catalog,
    districts: []const u8,
) ![]u32 {
    const in = try alloc.alloc(bool, cat.cells.len);
    defer alloc.free(in);
    @memset(in, false);

    // Pass one: NOAA's own filing.
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(alloc);
    for (cat.cells, 0..) |c, i| {
        if (c.district == 0) continue;
        for (districts) |d| {
            if (c.district == d) {
                in[i] = true;
                try members.append(alloc, @intCast(i));
                break;
            }
        }
    }

    // Pass two: everything that reaches into the same water at the same
    // scale. A cell already in needs no test, and a member is never tested
    // against itself.
    //
    // The bands must match. A band 1 cell covers an entire ocean basin, so
    // testing every band against every other selects a third of the country
    // for one district: measured against NOAA's own catalog, district 5 went
    // from 910 cells to 3,005. The gap this pass closes is a cell that
    // straddles a district line, and such a cell is the same scale as the
    // neighbor it abuts.
    for (cat.cells, 0..) |c, i| {
        if (in[i] or !c.box.known or c.band == 0) continue;
        for (members.items) |mi| {
            const m = cat.cells[mi];
            if (m.band != c.band) continue;
            if (c.box.overlaps(m.box)) {
                in[i] = true;
                break;
            }
        }
    }

    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(alloc);
    for (in, 0..) |hit, i| {
        if (hit) try out.append(alloc, @intCast(i));
    }
    return out.toOwnedSlice(alloc);
}

/// What a set of selected indices costs to download.
pub fn cost(cat: *const Catalog, picked: []const u32) Cost {
    var c = Cost{};
    for (picked) |i| {
        if (i >= cat.cells.len) continue;
        c.cells += 1;
        c.bytes += cat.cells[i].zip_bytes;
    }
    return c;
}

// ---- updates --------------------------------------------------------------

/// Which of the cells on this device NOAA has reissued, by index into
/// `installed`.
///
/// A cell is out of date when the catalog holds a higher edition, or the same
/// edition with a higher update number. A lower edition in the catalog is
/// ignored. It means the catalog download was bad, and acting on it re-fetches
/// a mariner's whole library over one failed request.
///
/// A cell the catalog no longer lists is current. NOAA withdraws cells, and
/// the chart on the device is then the last edition published.
///
/// The caller owns the returned slice.
pub fn outdated(
    alloc: std.mem.Allocator,
    cat: *const Catalog,
    installed: []const Installed,
) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(alloc);
    for (installed, 0..) |have, i| {
        const c = cat.find(have.name) orelse continue;
        const newer = c.edition > have.edition or
            (c.edition == have.edition and c.update > have.update);
        if (newer) try out.append(alloc, @intCast(i));
    }
    return out.toOwnedSlice(alloc);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

/// A catalog of three cells: two in district 5, one in district 1 that
/// reaches down over the district line into the same water.
const sample =
    \\<ENC_Product_Catalog><date_valid>20250903</date_valid>
    \\<cell><name>US5MD1MC</name><lname>Chesapeake Bay Entrance</lname>
    \\<cscale>20000</cscale><edtn>27</edtn><updn>3</updn><isdt>20250801</isdt>
    \\<zipfile_location>https://charts.noaa.gov/ENCs/US5MD1MC.zip</zipfile_location>
    \\<zipfile_size>1048576</zipfile_size><coast_guard_district>5</coast_guard_district>
    \\<panel><vertex><lat>36.0</lat><long>-76.5</long></vertex>
    \\<vertex><lat>37.0</lat><long>-75.5</long></vertex></panel></cell>
    \\<cell><name>US5MD2MC</name><lname>Chesapeake Bay North</lname>
    \\<cscale>20000</cscale><edtn>12</edtn><updn>0</updn><isdt>20250801</isdt>
    \\<zipfile_location>https://charts.noaa.gov/ENCs/US5MD2MC.zip</zipfile_location>
    \\<zipfile_size>2097152</zipfile_size><coast_guard_district>5</coast_guard_district>
    \\<panel><vertex><lat>38.0</lat><long>-76.5</long></vertex>
    \\<vertex><lat>39.0</lat><long>-75.5</long></vertex></panel></cell>
    \\<cell><name>US5NJ1MC</name><lname>Southern New Jersey</lname>
    \\<cscale>20000</cscale><edtn>4</edtn><updn>1</updn><isdt>20250801</isdt>
    \\<zipfile_location>https://charts.noaa.gov/ENCs/US5NJ1MC.zip</zipfile_location>
    \\<zipfile_size>4194304</zipfile_size><coast_guard_district>1</coast_guard_district>
    \\<panel><vertex><lat>38.5</lat><long>-75.8</long></vertex>
    \\<vertex><lat>40.0</lat><long>-74.0</long></vertex></panel></cell>
    \\</ENC_Product_Catalog>
;

test "parse reads every field the picker shows" {
    var cat = try parse(testing.allocator, sample);
    defer cat.deinit();

    try testing.expectEqualStrings("20250903", cat.date);
    try testing.expectEqual(@as(usize, 3), cat.cells.len);

    const c = cat.cells[0];
    try testing.expectEqualStrings("US5MD1MC", c.name);
    try testing.expectEqualStrings("Chesapeake Bay Entrance", c.title);
    try testing.expectEqual(@as(u32, 20000), c.scale);
    try testing.expectEqual(@as(u32, 27), c.edition);
    try testing.expectEqual(@as(u32, 3), c.update);
    try testing.expectEqualStrings("20250801", c.issued);
    try testing.expectEqualStrings("https://charts.noaa.gov/ENCs/US5MD1MC.zip", c.zip_url);
    try testing.expectEqual(@as(u64, 1048576), c.zip_bytes);
    try testing.expectEqual(@as(u8, 5), c.district);
    try testing.expect(c.box.known);
}

test "a region selects every cell covering its water" {
    var cat = try parse(testing.allocator, sample);
    defer cat.deinit();

    const picked = try selectRegions(testing.allocator, &cat, &.{5});
    defer testing.allocator.free(picked);

    // Both district-5 cells, plus the district-1 cell reaching over the line
    // into the same water. NOAA's filing alone leaves a gap across southern
    // New Jersey.
    try testing.expectEqual(@as(usize, 3), picked.len);

    const c = cost(&cat, picked);
    try testing.expectEqual(@as(u32, 3), c.cells);
    try testing.expectEqual(@as(u64, 1048576 + 2097152 + 4194304), c.bytes);
}

test "an overview cell does not drag in the harbors beneath it" {
    // US1EEZ5M covers the whole eastern seaboard. Without the band match it
    // overlaps every harbor cell on the coast, and picking district 5 selected
    // a third of NOAA's catalog.
    const xml =
        \\<x><cell><name>US1EEZ5M</name><coast_guard_district>5</coast_guard_district>
        \\<panel><vertex><lat>24</lat><long>-82</long></vertex>
        \\<vertex><lat>45</lat><long>-65</long></vertex></panel></cell>
        \\<cell><name>US5MA1MC</name><coast_guard_district>1</coast_guard_district>
        \\<panel><vertex><lat>42.2</lat><long>-71.1</long></vertex>
        \\<vertex><lat>42.4</lat><long>-70.9</long></vertex></panel></cell>
        \\<cell><name>US1EEZ1M</name><coast_guard_district>1</coast_guard_district>
        \\<panel><vertex><lat>40</lat><long>-74</long></vertex>
        \\<vertex><lat>45</lat><long>-66</long></vertex></panel></cell></x>
    ;
    var cat = try parse(testing.allocator, xml);
    defer cat.deinit();
    try testing.expectEqual(@as(u8, 1), cat.cells[0].band);
    try testing.expectEqual(@as(u8, 5), cat.cells[1].band);

    const picked = try selectRegions(testing.allocator, &cat, &.{5});
    defer testing.allocator.free(picked);

    // The district-5 overview cell, and the district-1 overview cell that
    // overlaps it at the same scale. The Boston harbor cell stays out.
    try testing.expectEqual(@as(usize, 2), picked.len);
    try testing.expectEqual(@as(u32, 0), picked[0]);
    try testing.expectEqual(@as(u32, 2), picked[1]);
}

test "a cell name states its usage band" {
    try testing.expectEqual(@as(u8, 5), bandOf("US5MD1MC"));
    try testing.expectEqual(@as(u8, 1), bandOf("US1EEZ1M"));
    try testing.expectEqual(@as(u8, 0), bandOf("US"));
    try testing.expectEqual(@as(u8, 0), bandOf("USXMD1MC"));
    try testing.expectEqual(@as(u8, 0), bandOf("US9MD1MC"));
}

test "selection is symmetric across a district line" {
    var cat = try parse(testing.allocator, sample);
    defer cat.deinit();

    // District 1's cell overlaps a district-5 cell, so selecting district 1
    // pulls that neighbor in.
    const picked = try selectRegions(testing.allocator, &cat, &.{1});
    defer testing.allocator.free(picked);
    try testing.expectEqual(@as(usize, 2), picked.len);
}

test "an empty selection is free" {
    var cat = try parse(testing.allocator, sample);
    defer cat.deinit();
    const picked = try selectRegions(testing.allocator, &cat, &.{});
    defer testing.allocator.free(picked);
    try testing.expectEqual(@as(usize, 0), picked.len);
    try testing.expectEqual(@as(u32, 0), cost(&cat, picked).cells);
}

test "a cell across the antimeridian keeps a narrow span" {
    // An Aleutian cell from 179E to 179W is 2 degrees wide.
    var lons = [_]f64{ 179.0, 179.5, -179.5, -179.0 };
    const span = lonSpan(&lons);
    try testing.expectApproxEqAbs(@as(f64, 179.0), span.start, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), span.width, 1e-9);
}

test "an ordinary cell spans west to east" {
    var lons = [_]f64{ -76.5, -75.5, -76.0 };
    const span = lonSpan(&lons);
    try testing.expectApproxEqAbs(@as(f64, -76.5), span.start, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), span.width, 1e-9);
}

test "boxes across the antimeridian meet each other and miss the far side" {
    const a = Box{ .start = 179.0, .width = 2.0, .south = 51, .north = 53, .known = true };
    const b = Box{ .start = -179.5, .width = 1.0, .south = 51, .north = 53, .known = true };
    const far = Box{ .start = -76.5, .width = 1.0, .south = 36, .north = 37, .known = true };

    try testing.expect(a.overlaps(b));
    try testing.expect(b.overlaps(a));
    try testing.expect(!a.overlaps(far));
    // A box with no vertices never claims to cover anything.
    try testing.expect(!a.overlaps(.{}));
}

test "latitude separates boxes that share a longitude span" {
    const north = Box{ .start = -76.5, .width = 1.0, .south = 44, .north = 45, .known = true };
    const south = Box{ .start = -76.5, .width = 1.0, .south = 36, .north = 37, .known = true };
    try testing.expect(!north.overlaps(south));
}

test "outdated names only what NOAA has actually reissued" {
    var cat = try parse(testing.allocator, sample);
    defer cat.deinit();

    const have = [_]Installed{
        .{ .name = "US5MD1MC", .edition = 27, .update = 3 },  // current
        .{ .name = "US5MD2MC", .edition = 11, .update = 9 },  // older edition
        .{ .name = "US5NJ1MC", .edition = 4, .update = 0 },   // same edition, older update
        .{ .name = "US5XX9MC", .edition = 1, .update = 0 },   // withdrawn: not listed
    };
    const stale = try outdated(testing.allocator, &cat, &have);
    defer testing.allocator.free(stale);

    try testing.expectEqual(@as(usize, 2), stale.len);
    try testing.expectEqual(@as(u32, 1), stale[0]);
    try testing.expectEqual(@as(u32, 2), stale[1]);
}

test "a catalog older than the device reissues no cell" {
    var cat = try parse(testing.allocator, sample);
    defer cat.deinit();

    // Every cell on the device is ahead of the catalog, which means the
    // catalog download was bad.
    const have = [_]Installed{
        .{ .name = "US5MD1MC", .edition = 28, .update = 0 },
        .{ .name = "US5MD2MC", .edition = 12, .update = 1 },
    };
    const stale = try outdated(testing.allocator, &cat, &have);
    defer testing.allocator.free(stale);
    try testing.expectEqual(@as(usize, 0), stale.len);
}

test "every shipped region has a distinct id and a real district" {
    for (regions, 0..) |r, i| {
        try testing.expect(r.district > 0);
        try testing.expect(r.id.len > 0);
        try testing.expect(r.name.len > 0);
        for (regions[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, r.id, other.id));
            try testing.expect(r.district != other.district);
        }
        try testing.expectEqual(r.district, regionById(r.id).?.district);
    }
    try testing.expect(regionById("d3") == null);
}

test "a cell with no vertices parses and matches no coverage" {
    const xml =
        \\<x><cell><name>US1BOGUS</name><coast_guard_district>9</coast_guard_district></cell>
        \\<cell><name>US2ELSE</name>
        \\<panel><vertex><lat>1</lat><long>1</long></vertex>
        \\<vertex><lat>2</lat><long>2</long></vertex></panel></cell></x>
    ;
    var cat = try parse(testing.allocator, xml);
    defer cat.deinit();
    try testing.expectEqual(@as(usize, 2), cat.cells.len);
    try testing.expect(!cat.cells[0].box.known);

    // The boxless cell is selected by its district tag. The other stays out,
    // because there is no coverage to overlap.
    const picked = try selectRegions(testing.allocator, &cat, &.{9});
    defer testing.allocator.free(picked);
    try testing.expectEqual(@as(usize, 1), picked.len);
    try testing.expectEqual(@as(u32, 0), picked[0]);
}

test "region ids read into districts, skipping unknowns and repeats" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 5, 8 }, districtsFromIds(&buf, "d5,d8"));
    try testing.expectEqualSlices(u8, &.{5}, districtsFromIds(&buf, "d5, d5 , d3"));
    try testing.expectEqualSlices(u8, &.{}, districtsFromIds(&buf, ""));
    try testing.expectEqualSlices(u8, &.{}, districtsFromIds(&buf, "nonsense"));
    try testing.expectEqualSlices(u8, &.{ 1, 17 }, districtsFromIds(&buf, " d1 ,d17"));
}

test "a district buffer smaller than the request fills and stops" {
    var buf: [2]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 1, 5 }, districtsFromIds(&buf, "d1,d5,d7,d8"));
}
