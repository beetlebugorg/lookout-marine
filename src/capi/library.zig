//! The chart-library half of the C ABI (see include/lookout-library.h): the
//! installed charts, the scan, the raster underlay, the host-supplied style
//! the charts reached by link.

const std = @import("std");

const lk = @import("../root.zig");
const clinks = @import("../chartlinks.zig");
const noaa = @import("../noaa.zig");
const noaajob = @import("../noaajob.zig");
const craster = @import("../ct/raster.zig");
const capi = @import("../capi.zig");

const lookout = capi.lookout;
const gpa = capi.gpa;
const cast = capi.cast;
const locked = capi.locked;
const capi_io = capi.capi_io;

// ---- the chart library ------------------------------------------------------

/// The last scan's JSON. Held so the pointer the shell reads stays good until
/// the next scan.
var scan_json: ?[:0]u8 = null;

/// Add baked charts to the open library. See lookout.h.
export fn lookout_charts_add(h: ?*lookout, paths: [*]const [*:0]const u8, n: usize) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const list = gpa.alloc([:0]const u8, n) catch return -1;
    defer gpa.free(list);
    for (0..n) |i| list[i] = std.mem.span(paths[i]);
    return @intCast(l.chartsAdd(list));
}

/// True while the library's ownership partition is being built. See lookout.h.
export fn lookout_composing(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.loading or l.recomposing) 1 else 0;
}

/// How many charts the library holds. See lookout.h.
export fn lookout_charts_count(h: ?*lookout) u32 {
    const l = locked(h);
    defer l.apiUnlock();
    return @intCast(l.charts.items.len);
}

/// Look through `path` for charts. See lookout.h.
export fn lookout_scan_charts(path: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    if (scan_json) |old| gpa.free(old);
    scan_json = null;
    var s = lk.scanCharts(gpa, capi_io, std.mem.span(path)) catch return null;
    defer s.deinit();
    const json = lk.library.toJson(gpa, &s) catch return null;
    scan_json = json;
    if (out_len) |p| p.* = json.len;
    return json.ptr;
}

/// lookout_scan_charts for a chart set that arrives as one .zip. See lookout.h.
export fn lookout_scan_zip(path: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    if (scan_json) |old| gpa.free(old);
    scan_json = null;
    var s = lk.scanZip(gpa, std.mem.span(path)) catch return null;
    defer s.deinit();
    const json = lk.library.toJson(gpa, &s) catch return null;
    scan_json = json;
    if (out_len) |p| p.* = json.len;
    return json.ptr;
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

/// Draw a host-supplied style instead of lookout's portrayal. See lookout.h.
export fn lookout_alt_chart_style_json(h: ?*lookout, json: ?[*]const u8, len: usize) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const bytes: ?[]const u8 = if (json != null and len != 0) json.?[0..len] else null;
    l.setAltStyle(bytes) catch return 0;
    return 1;
}

export fn lookout_alt_chart_style_active(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.altStyleActive()) 1 else 0;
}

/// One sprite pack of the active alt style. See lookout.h.
export fn lookout_alt_sprite_pack(h: ?*lookout, prefix: ?[*:0]const u8, index_json: [*]const u8, json_len: usize, png: [*]const u8, png_len: usize) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    if (json_len == 0 or png_len == 0) return 0;
    const p: []const u8 = if (prefix) |pp| std.mem.span(pp) else "";
    return @intCast(l.altSpritePack(p, index_json[0..json_len], png[0..png_len]));
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
    if (h == null) return;
    const slice: []const u8 = if (bytes != null and len != 0) bytes.?[0..len] else &.{};
    // NOAA sets bit 63 on the ids it issues, so the two services share one
    // fetcher without sharing an id space.
    if (noaajob.ownsId(req_id)) {
        cast(h).noaa.respond(req_id, slice, status);
    } else {
        cast(h).links.respond(req_id, slice, status);
    }
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

/// Read every link's style for its tile template. See lookout-library.h.
export fn lookout_chart_links_preview(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.links.previewAll();
}

/// The tile url that pictures one chart. See lookout-library.h.
export fn lookout_chart_link_preview_url(
    h: ?*lookout,
    url: ?[*:0]const u8,
    lon: f64,
    lat: f64,
    zoom: i32,
    out: ?[*]u8,
    out_len: usize,
) c_int {
    const s = url orelse return 0;
    const dst = out orelse return 0;
    if (out_len == 0) return 0;
    const l = locked(h);
    defer l.apiUnlock();
    const built = l.links.previewUrl(std.mem.span(s), lon, lat, zoom, dst[0..out_len]) orelse return 0;
    return if (built.len == 0) 0 else 1;
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

/// The active set's name (borrowed, valid until the next raster call), or "".
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
};

pub const lookout_noaa_state = noaajob.State;

/// A cell already installed, for the update check. See lookout-library.h.
pub const lookout_noaa_installed = extern struct {
    name: [*:0]const u8,
    edition: u32,
    update: u32,
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
        };
    }
    break :blk out;
};

/// The regions and how many. See lookout-library.h.
/// One S-52 colour by token, for a shell drawing its own chart legend.
/// See lookout-library.h.
export fn lookout_s52_color(token: ?[*:0]const u8, scheme: u32, out: ?*[4]f32) c_int {
    const t = token orelse return 0;
    const dst = out orelse return 0;
    const rgba = lk.s52Color(std.mem.span(t), scheme) orelse return 0;
    dst.* = rgba;
    return 1;
}

export fn lookout_noaa_regions(out: ?*[*]const lookout_noaa_region) usize {
    if (out) |o| o.* = &noaa_regions;
    return noaa_regions.len;
}

/// One box of a region's coverage. See lookout-library.h.
pub const lookout_noaa_box = extern struct {
    west: f64,
    south: f64,
    east: f64,
    north: f64,
};

/// The coverage of one region's coarse cells. See lookout-library.h.
export fn lookout_noaa_region_coverage(h: ?*lookout, region_id: ?[*:0]const u8,
                                       out: ?[*]lookout_noaa_box, cap: usize) usize {
    if (h == null) return 0;
    const l = locked(h);
    defer l.apiUnlock();
    const cat = &(l.noaa.cat orelse return 0);
    const id = std.mem.span(region_id orelse return 0);
    const region = noaa.regionById(id) orelse return 0;
    // The finest of the coarse bands this district has. Band 3 is coastal and
    // hugs the shore; band 1 is an ocean basin and blots out the coastline it
    // is meant to describe. The Great Lakes have no band 3, so the choice is
    // made per district rather than fixed.
    var band: u8 = 0;
    for ([_]u8{ 3, 2, 1 }) |b| {
        for (cat.cells) |c| {
            if (c.district == region.district and c.band == b and c.box.known) {
                band = b;
                break;
            }
        }
        if (band != 0) break;
    }
    if (band == 0) return 0;

    var n: usize = 0;
    for (cat.cells) |c| {
        if (c.district != region.district or !c.box.known) continue;
        if (c.band != band) continue;
        if (out) |o| {
            if (n < cap) o[n] = .{
                .west = c.box.start,
                .south = c.box.south,
                .east = c.box.start + c.box.width,
                .north = c.box.north,
            };
        }
        n += 1;
    }
    return n;
}

/// Read NOAA's product catalog. See lookout-library.h.
export fn lookout_noaa_refresh(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.noaa.refresh();
    l.noaa.publish();
}

/// The catalog and download state. See lookout-library.h.
export fn lookout_noaa_poll(h: ?*lookout, out: ?*lookout_noaa_state) void {
    const o = out orelse return;
    if (h == null) {
        o.* = .{};
        return;
    }
    // No api lock. That lock is os_unfair_lock and the frame loop reclaims it
    // the moment it drops it. A download requests a frame for every answer, so
    // a poll on the main thread blocked for the whole transfer and the count
    // read 0 of 829 until it ended. The frame loop publishes this copy.
    o.* = cast(h).noaa.published();
}

/// What downloading these regions costs. See lookout-library.h.
/// Name the NOAA cells this device already holds. See lookout-library.h.
export fn lookout_noaa_have(h: ?*lookout, names: ?[*]const ?[*:0]const u8, n: usize) void {
    const l = locked(h);
    defer l.apiUnlock();
    const src = names orelse {
        l.noaa.setHeld(&.{});
        return;
    };
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(std.heap.c_allocator);
    for (0..n) |i| {
        const p = src[i] orelse continue;
        list.append(std.heap.c_allocator, std.mem.span(p)) catch break;
    }
    l.noaa.setHeld(list.items);
}

export fn lookout_noaa_cost(h: ?*lookout, region_ids: ?[*:0]const u8,
                            out_cells: ?*u32, out_bytes: ?*u64,
                            out_held: ?*u32) c_int {
    if (out_cells) |c| c.* = 0;
    if (out_bytes) |b| b.* = 0;
    if (out_held) |x| x.* = 0;
    if (h == null) return 0;
    const l = locked(h);
    defer l.apiUnlock();
    if (!l.noaa.haveCatalog()) return 0;
    var buf: [noaa.regions.len]u8 = undefined;
    const ids = if (region_ids) |r| std.mem.span(r) else "";
    const c = l.noaa.costOf(noaa.districtsFromIds(&buf, ids));
    if (out_cells) |o| o.* = c.cells;
    if (out_bytes) |o| o.* = c.bytes;
    if (out_held) |o| o.* = c.held;
    return 1;
}

/// Download every cell covering these regions. See lookout-library.h.
export fn lookout_noaa_download(h: ?*lookout, region_ids: ?[*:0]const u8,
                                dest_dir: ?[*:0]const u8) void {
    const l = locked(h);
    defer l.apiUnlock();
    const dest = dest_dir orelse return;
    var buf: [noaa.regions.len]u8 = undefined;
    const ids = if (region_ids) |r| std.mem.span(r) else "";
    l.noaa.start(noaa.districtsFromIds(&buf, ids), std.mem.span(dest));
    l.noaa.publish();
}

/// How many of these cells NOAA has reissued. See lookout-library.h.
export fn lookout_noaa_outdated(h: ?*lookout, have: ?[*]const lookout_noaa_installed,
                                n: usize) u32 {
    if (h == null or have == null or n == 0) return 0;
    const l = locked(h);
    defer l.apiUnlock();
    const list = gpa.alloc(noaa.Installed, n) catch return 0;
    defer gpa.free(list);
    for (have.?[0..n], 0..) |c, i| {
        list[i] = .{
            .name = std.mem.span(c.name),
            .edition = c.edition,
            .update = c.update,
        };
    }
    const cat = &(l.noaa.cat orelse return 0);
    const stale = noaa.outdated(gpa, cat, list) catch return 0;
    defer gpa.free(stale);
    return @intCast(stale.len);
}

/// Download the reissued editions of these cells. See lookout-library.h.
export fn lookout_noaa_update(h: ?*lookout, have: ?[*]const lookout_noaa_installed,
                              n: usize, dest_dir: ?[*:0]const u8) void {
    const l = locked(h);
    defer l.apiUnlock();
    const dest = dest_dir orelse return;
    if (have == null or n == 0) return;
    const list = gpa.alloc(noaa.Installed, n) catch return;
    defer gpa.free(list);
    for (have.?[0..n], 0..) |c, i| {
        list[i] = .{
            .name = std.mem.span(c.name),
            .edition = c.edition,
            .update = c.update,
        };
    }
    l.noaa.startUpdate(list, std.mem.span(dest));
    l.noaa.publish();
}

/// Stop the download that is running. See lookout-library.h.
export fn lookout_noaa_cancel(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.noaa.cancelAll();
    l.noaa.publish();
}
