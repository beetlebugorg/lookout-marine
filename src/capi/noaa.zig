//! The NOAA service's C ABI (see include/lookout-library.h).
//!
//! lookout_noaa_open makes a service with no chart handle, so a download runs
//! while the shell closes and reopens its charts. Every call on it is
//! lookout_noaa_svc_*. The lookout_noaa_* calls that take a chart handle run
//! the same functions over the service that handle holds.

const std = @import("std");

const noaa = @import("../noaa.zig");
const noaajob = @import("../noaajob.zig");
const clinks = @import("../chartlinks.zig");
const capi = @import("../capi.zig");

const gpa = capi.gpa;

pub const lookout_noaa = noaajob.Handle;
pub const lookout_noaa_state = noaajob.State;
pub const lookout_noaa_box = noaajob.Box;

/// A cell already installed, for the update check. See lookout-library.h.
pub const lookout_noaa_installed = extern struct {
    name: [*:0]const u8,
    edition: u32,
    update: u32,
};

// ---- the calls both ABIs share ----------------------------------------------

fn span(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "";
}

pub fn have(n: *noaajob.Handle, names: ?[*]const ?[*:0]const u8, count: usize) void {
    const src = names orelse return n.have(&.{});
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    for (0..count) |i| {
        const p = src[i] orelse continue;
        list.append(gpa, std.mem.span(p)) catch break;
    }
    n.have(list.items);
}

pub fn cost(n: *noaajob.Handle, region_ids: ?[*:0]const u8, out_cells: ?*u32, out_bytes: ?*u64, out_held: ?*u32, out_held_bytes: ?*u64) c_int {
    if (out_cells) |c| c.* = 0;
    if (out_bytes) |b| b.* = 0;
    if (out_held) |x| x.* = 0;
    if (out_held_bytes) |x| x.* = 0;
    var buf: [noaa.regions.len]u8 = undefined;
    const c = n.cost(noaa.districtsFromIds(&buf, span(region_ids))) orelse return 0;
    if (out_cells) |o| o.* = c.cells;
    if (out_bytes) |o| o.* = c.bytes;
    if (out_held) |o| o.* = c.held;
    if (out_held_bytes) |o| o.* = c.held_bytes;
    return 1;
}

pub fn regionCells(n: *noaajob.Handle, region_ids: ?[*:0]const u8, out: ?[*][*:0]const u8, cap: usize) usize {
    var buf: [noaa.regions.len]u8 = undefined;
    return n.regionCells(noaa.districtsFromIds(&buf, span(region_ids)), out, cap);
}

pub fn regionCoverage(n: *noaajob.Handle, region_id: ?[*:0]const u8, out: ?[*]lookout_noaa_box, cap: usize) usize {
    const id = region_id orelse return 0;
    return n.regionCoverage(std.mem.span(id), out, cap);
}

pub fn download(n: *noaajob.Handle, region_ids: ?[*:0]const u8, dest_dir: ?[*:0]const u8, again: c_int) void {
    const dest = dest_dir orelse return;
    var buf: [noaa.regions.len]u8 = undefined;
    n.download(noaa.districtsFromIds(&buf, span(region_ids)), std.mem.span(dest), again != 0);
}

/// The installed cells as the core reads them, or null. Owned by gpa.
fn installedList(have_: ?[*]const lookout_noaa_installed, count: usize) ?[]noaa.Installed {
    const src = have_ orelse return null;
    if (count == 0) return null;
    const list = gpa.alloc(noaa.Installed, count) catch return null;
    for (src[0..count], 0..) |c, i| {
        list[i] = .{ .name = std.mem.span(c.name), .edition = c.edition, .update = c.update };
    }
    return list;
}

pub fn outdated(n: *noaajob.Handle, have_: ?[*]const lookout_noaa_installed, count: usize) u32 {
    const list = installedList(have_, count) orelse return 0;
    defer gpa.free(list);
    return n.outdated(list);
}

pub fn update(n: *noaajob.Handle, have_: ?[*]const lookout_noaa_installed, count: usize, dest_dir: ?[*:0]const u8) void {
    const dest = dest_dir orelse return;
    const list = installedList(have_, count) orelse return;
    defer gpa.free(list);
    n.update(list, std.mem.span(dest));
}

// ---- lookout_noaa ------------------------------------------------------------

/// Open the NOAA service. See lookout-library.h.
export fn lookout_noaa_open(store: ?*anyopaque, sets: ?*anyopaque) ?*lookout_noaa {
    const n = gpa.create(lookout_noaa) catch return null;
    n.* = noaajob.Handle.init(gpa);
    n.store = store;
    n.sets = sets;
    return n;
}

/// Stop the download and free the service. See lookout-library.h.
export fn lookout_noaa_close(n: ?*lookout_noaa) void {
    const x = n orelse return;
    x.deinit();
    gpa.destroy(x);
}

export fn lookout_noaa_svc_set_http_provider(n: ?*lookout_noaa, get: ?clinks.HttpGetFn, cancel: ?clinks.HttpCancelFn, wake: ?noaajob.WakeFn, user: ?*anyopaque) void {
    const x = n orelse return;
    x.setProvider(get, cancel, wake, user);
}

/// Answer one GET a piece at a time, from any thread. See lookout-library.h.
export fn lookout_noaa_svc_http_respond_chunk(n: ?*lookout_noaa, req_id: u64, bytes: ?[*]const u8, len: usize, status: c_int, done: c_int) void {
    const x = n orelse return;
    const slice: []const u8 = if (bytes != null and len != 0) bytes.?[0..len] else &.{};
    if (slice.len == 0 and done == 0) return;
    x.respondChunk(req_id, slice, status, done != 0);
}

export fn lookout_noaa_svc_poll(n: ?*lookout_noaa, out: ?*lookout_noaa_state) void {
    const o = out orelse return;
    const x = n orelse {
        o.* = .{};
        return;
    };
    x.adopt();
    o.* = x.poll();
}

export fn lookout_noaa_svc_refresh(n: ?*lookout_noaa) void {
    if (n) |x| x.refresh();
}

export fn lookout_noaa_svc_have(n: ?*lookout_noaa, names: ?[*]const ?[*:0]const u8, count: usize) void {
    if (n) |x| have(x, names, count);
}

export fn lookout_noaa_svc_cost(n: ?*lookout_noaa, region_ids: ?[*:0]const u8, out_cells: ?*u32, out_bytes: ?*u64, out_held: ?*u32, out_held_bytes: ?*u64) c_int {
    const x = n orelse {
        // cost() zeroes the outputs; with no handle there is none to call.
        if (out_cells) |c| c.* = 0;
        if (out_bytes) |b| b.* = 0;
        if (out_held) |c| c.* = 0;
        if (out_held_bytes) |b| b.* = 0;
        return 0;
    };
    return cost(x, region_ids, out_cells, out_bytes, out_held, out_held_bytes);
}

export fn lookout_noaa_svc_region_cells(n: ?*lookout_noaa, region_ids: ?[*:0]const u8, out: ?[*][*:0]const u8, cap: usize) usize {
    const x = n orelse return 0;
    return regionCells(x, region_ids, out, cap);
}

export fn lookout_noaa_svc_region_coverage(n: ?*lookout_noaa, region_id: ?[*:0]const u8, out: ?[*]lookout_noaa_box, cap: usize) usize {
    const x = n orelse return 0;
    return regionCoverage(x, region_id, out, cap);
}

export fn lookout_noaa_svc_download(n: ?*lookout_noaa, region_ids: ?[*:0]const u8, dest_dir: ?[*:0]const u8, again: c_int) void {
    if (n) |x| download(x, region_ids, dest_dir, again);
}

export fn lookout_noaa_svc_outdated(n: ?*lookout_noaa, have_: ?[*]const lookout_noaa_installed, count: usize) u32 {
    const x = n orelse return 0;
    return outdated(x, have_, count);
}

export fn lookout_noaa_svc_update(n: ?*lookout_noaa, have_: ?[*]const lookout_noaa_installed, count: usize, dest_dir: ?[*:0]const u8) void {
    if (n) |x| update(x, have_, count, dest_dir);
}

export fn lookout_noaa_svc_cancel(n: ?*lookout_noaa) void {
    if (n) |x| x.cancel();
}
