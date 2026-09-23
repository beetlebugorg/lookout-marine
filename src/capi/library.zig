//! The chart-library half of the C ABI (see include/lookout-library.h): the
//! installed charts, the scan, the raster underlay, the charts reached by
//! link and the NOAA region table.

const std = @import("std");

const lk = @import("../root.zig");
const clinks = @import("../chartlinks.zig");
const noaa = @import("../noaa.zig");
const craster = @import("../ct/raster.zig");
const capi = @import("../capi.zig");

const lookout = capi.lookout;
const gpa = capi.gpa;
const cast = capi.cast;
const locked = capi.locked;
const capi_io = capi.capi_io;

// ---- the chart library ------------------------------------------------------

/// Add baked charts to the open library. See lookout.h.
export fn lookout_charts_add(h: ?*lookout, paths: [*]const [*:0]const u8, n: usize) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const list = gpa.alloc([:0]const u8, n) catch return -1;
    defer gpa.free(list);
    for (0..n) |i| list[i] = std.mem.span(paths[i]);
    return @intCast(l.chartsAdd(list));
}

/// How many charts the library holds. See lookout.h.
export fn lookout_charts_count(h: ?*lookout) u32 {
    const l = locked(h);
    defer l.apiUnlock();
    return @intCast(l.charts.items.len);
}

pub const lookout_scan = lk.library.Read;
pub const lookout_chart_file = lk.library.File;
pub const lookout_scan_summary = lk.library.Found;

fn count(out_n: ?*usize, n: usize) void {
    if (out_n) |p| p.* = n;
}

/// Walk a folder and report what is there, as structs. See lookout-library.h.
export fn lookout_scan_read(path: [*:0]const u8) ?*lookout_scan {
    var s = lk.scanCharts(gpa, capi_io, std.mem.span(path)) catch return null;
    defer s.deinit();
    return lk.library.toRead(gpa, &s) catch null;
}

/// lookout_scan_read for a chart set that arrives as one .zip.
export fn lookout_scan_zip_read(path: [*:0]const u8) ?*lookout_scan {
    var s = lk.scanZip(gpa, std.mem.span(path)) catch return null;
    defer s.deinit();
    return lk.library.toRead(gpa, &s) catch null;
}

export fn lookout_scan_free(s: ?*lookout_scan) void {
    if (s) |x| x.free();
}

/// The totals, and where the scan started. NULL for a read that is not there.
export fn lookout_scan_found(s: ?*const lookout_scan) ?*const lookout_scan_summary {
    const x = s orelse return null;
    return &x.found;
}

/// The baked archives and the source cells.
export fn lookout_scan_cells(s: ?*const lookout_scan, out_n: ?*usize) ?[*]const *const lookout_chart_file {
    const x = s orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.cells.len);
    return x.cells.ptr;
}

/// The picture charts. These belong in the raster chart list.
export fn lookout_scan_raster(s: ?*const lookout_scan, out_n: ?*usize) ?[*]const *const lookout_chart_file {
    const x = s orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.raster.len);
    return x.raster.ptr;
}

export fn lookout_alt_chart_style_active(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.altStyleActive()) 1 else 0;
}

// ---- charts by link --------------------------------------------------------
/// Adopt the shell's url fetcher. See lookout.h.
export fn lookout_set_http_provider(h: ?*lookout, get: ?lk.Lookout.HttpGetFn, cancel: ?lk.Lookout.HttpCancelFn, user: ?*anyopaque) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setHttpProvider(get, cancel, user);
}

/// Answer one GET, from any thread. See lookout.h.
///
/// Like lookout_tile_respond, this does NOT hold the api lock: the shell
/// answers from whatever thread its networking finished on, and that thread
/// must not queue behind a frame in flight. It enqueues and raises the
/// needs-redraw flag; the frame loop adopts it. That is also why a shell may
/// call this from inside its own http_get callback, which runs with the api
/// lock already held.
export fn lookout_http_respond(h: ?*lookout, req_id: u64, bytes: ?[*]const u8, len: usize, status: c_int) void {
    lookout_http_respond_chunk(h, req_id, bytes, len, status, 1);
}

/// Answer one GET a piece at a time. See lookout.h.
export fn lookout_http_respond_chunk(h: ?*lookout, req_id: u64, bytes: ?[*]const u8, len: usize, status: c_int, done: c_int) void {
    if (h == null) return;
    const slice: []const u8 = if (bytes != null and len != 0) bytes.?[0..len] else &.{};
    if (slice.len == 0 and done == 0) return;
    cast(h).links.respondChunk(req_id, slice, status, done != 0);
}

/// Add a chart by link. See lookout.h.
export fn lookout_chart_link_add(h: ?*lookout, link: ?[*:0]const u8) void {
    const l = locked(h);
    defer l.apiUnlock();
    const s = link orelse return;
    l.links.add(std.mem.span(s));
}

/// Draw one of the carried charts, or NULL for lookout's own. See lookout.h.
export fn lookout_chart_link_select(h: ?*lookout, url: ?[*:0]const u8) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.links.select(if (url) |u| std.mem.span(u) else null);
}

export fn lookout_chart_link_remove(h: ?*lookout, url: ?[*:0]const u8) void {
    const l = locked(h);
    defer l.apiUnlock();
    const s = url orelse return;
    l.links.remove(std.mem.span(s));
}

/// One picture of a chart for a shell's chart list. See lookout-library.h.
export fn lookout_chart_link_picture(
    h: ?*lookout,
    url: ?[*:0]const u8,
    kind: c_int,
    lon: f64,
    lat: f64,
    zoom: f64,
    width: c_int,
    height: c_int,
    dst: ?[*]u8,
) c_int {
    const out = dst orelse return 0;
    if (width <= 0 or height <= 0) return 0;
    const k: lk.Lookout.PictureKind = switch (kind) {
        0 => .tile,
        1 => .render,
        else => return 0,
    };
    const w: u32 = @intCast(width);
    const ht: u32 = @intCast(height);
    const l = locked(h);
    defer l.apiUnlock();
    const u: []const u8 = if (url) |s| std.mem.span(s) else "";
    const len = @as(usize, w) * ht * 4;
    return @intFromEnum(l.chartLinkPicture(u, k, lon, lat, zoom, w, ht, out[0..len]));
}

/// Drop every picture still pending. See lookout-library.h.
export fn lookout_chart_link_pictures_cancel(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.chartLinkPicturesCancel();
}

export fn lookout_chart_link_refresh(h: ?*lookout, url: ?[*:0]const u8) void {
    const l = locked(h);
    defer l.apiUnlock();
    const s = url orelse return;
    l.links.refresh(std.mem.span(s));
}

/// Everything the UI renders, as one transfer-full document. See lookout.h.
export fn lookout_chart_links_json(h: ?*lookout) ?[*:0]u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.links.snapshotAlloc(gpa) orelse return null;
    return s.ptr;
}

pub const lookout_links = clinks.Read;
pub const lookout_chart_link = clinks.Link;
pub const lookout_link_state = clinks.State;

/// The same snapshot, as structs. See lookout-library.h.
export fn lookout_links_read(h: ?*lookout) ?*lookout_links {
    const l = locked(h);
    defer l.apiUnlock();
    return l.links.read(gpa) catch null;
}

export fn lookout_links_free(r: ?*lookout_links) void {
    if (r) |x| x.free();
}

/// The active link, the credit line, the last error and whether a resolve is
/// in flight. NULL for a read that is not there.
export fn lookout_links_state(r: ?*const lookout_links) ?*const lookout_link_state {
    const x = r orelse return null;
    return &x.state;
}

/// The links the mariner added, in the order they were added.
export fn lookout_links_all(r: ?*const lookout_links, out_n: ?*usize) ?[*]const *const lookout_chart_link {
    const x = r orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.links.len);
    return x.links.ptr;
}

/// Has the snapshot changed since the last poll? See lookout.h.
export fn lookout_chart_links_changed(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.links.takeChanged()) 1 else 0;
}

/// One-time migration from a shell's old store. See lookout.h.
export fn lookout_chart_links_import(h: ?*lookout, links_json: ?[*:0]const u8) void {
    const l = locked(h);
    defer l.apiUnlock();
    const s = links_json orelse return;
    l.links.import(std.mem.span(s));
}

/// Open a raster chart (satellite imagery or another picture chart the mariner
/// supplied) and add it beneath the vector chart. See lookout.h.
export fn lookout_raster_add(h: ?*lookout, path: ?[*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const p = path orelse return 0;
    return if (l.addRaster(std.mem.span(p))) 1 else 0;
}

/// Step to the next raster chart set, with "no picture" as one position. See lookout.h.
export fn lookout_raster_cycle(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.cycleRaster();
}

/// The active set's name, or "". Borrowed until the set list changes.
export fn lookout_raster_active_name(h: ?*lookout, out_len: ?*usize) [*:0]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    // The layer terminates its set names where it dupes them, so this borrows
    // with no copy. Valid until the set list changes.
    const n = l.rasterName();
    if (out_len) |o| o.* = n.len;
    return n.ptr;
}

/// 1 while the chart is drawing WITHOUT its opaque water and land fills because
/// a picture is beneath THIS view. See lookout.h.
export fn lookout_raster_over_chart(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterOverChart()) 1 else 0;
}

/// The name of set `i`. Borrowed; valid until the set list changes. See lookout.h.
export fn lookout_raster_set_name(h: ?*lookout, i: u32, out_len: ?*usize) [*:0]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const n = l.rasterSetName(i);
    if (out_len) |o| o.* = n.len;
    return n.ptr;
}

/// 1 when set `i` has enabled charts in view. See lookout.h.
export fn lookout_raster_set_in_view(h: ?*lookout, i: u32) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterSetInView(i)) 1 else 0;
}

/// The drawn set's index, or -1 when none is drawn. See lookout.h.
export fn lookout_raster_active_index(h: ?*lookout) i32 {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterActiveIndex()) |i| @intCast(i) else -1;
}

/// Draw set `i`, or nothing when `i` is negative. See lookout.h.
export fn lookout_raster_select(h: ?*lookout, i: i32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.rasterSelect(if (i < 0) null else @intCast(i));
}

/// Read and write one set's drawn state by index, no camera. See lookout.h.
export fn lookout_raster_shown(h: ?*lookout, i: u32) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterShown(i)) 1 else 0;
}

export fn lookout_raster_set_shown(h: ?*lookout, i: u32, shown: c_int) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.rasterSetShown(i, shown != 0);
}

/// Turn one raster chart on or off without removing it. See lookout.h.
export fn lookout_raster_set_enabled(h: ?*lookout, path: ?[*:0]const u8, enabled: c_int) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const p = path orelse return 0;
    return if (l.setRasterEnabled(std.mem.span(p), enabled != 0)) 1 else 0;
}

export fn lookout_raster_enabled(h: ?*lookout, path: ?[*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const p = path orelse return 0;
    return if (l.rasterEnabled(std.mem.span(p))) 1 else 0;
}

/// The set that covers this view, DRAWN OR NOT. See lookout.h.
export fn lookout_raster_available_name(h: ?*lookout, out_len: ?*usize) [*:0]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const n = l.rasterAvailableName();
    if (out_len) |o| o.* = n.len;
    return n.ptr;
}

/// What to call the set a raster file belongs to. See lookout-library.h.
export fn lookout_raster_set_name_for(path: ?[*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    const p = path orelse {
        if (out_len) |n| n.* = 0;
        return null;
    };
    const name = craster.setNameFor(std.mem.span(p));
    if (out_len) |n| n.* = name.len;
    return name.ptr;
}

/// Show or hide the vector chart; the picture beneath it stays. See lookout.h.
export fn lookout_set_chart_hidden(h: ?*lookout, hidden: c_int) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setChartHidden(hidden != 0);
}

export fn lookout_toggle_chart(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.toggleChart();
}

export fn lookout_chart_hidden(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.chartHidden()) 1 else 0;
}

/// How many raster chart sets are installed. The cycle has this many positions plus
/// one for "no picture". See lookout.h.
export fn lookout_raster_set_count(h: ?*lookout) u32 {
    const l = locked(h);
    defer l.apiUnlock();
    return @intCast(l.rasterSetCount());
}

// ---- NOAA charts -----------------------------------------------------------

/// One region a mariner picks. See lookout-library.h.
pub const lookout_noaa_region = extern struct {
    id: [*:0]const u8,
    name: [*:0]const u8,
    blurb: [*:0]const u8,
    district: c_int,
    west: f64,
    south: f64,
    east: f64,
    north: f64,
    panel: c_int,
};

/// The region table, built once from src/noaa.zig.
const noaa_regions = blk: {
    var out: [noaa.regions.len]lookout_noaa_region = undefined;
    for (noaa.regions, 0..) |r, i| {
        out[i] = .{
            .id = r.id.ptr,
            .name = r.name.ptr,
            .blurb = r.blurb.ptr,
            .district = r.district,
            .west = r.west,
            .south = r.south,
            .east = r.east,
            .north = r.north,
            .panel = @intFromEnum(r.panel),
        };
    }
    break :blk out;
};

/// The regions and how many. See lookout-library.h.
export fn lookout_noaa_regions(out: ?*[*]const lookout_noaa_region) usize {
    if (out) |o| o.* = &noaa_regions;
    return noaa_regions.len;
}

