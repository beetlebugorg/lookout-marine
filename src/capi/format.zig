//! The shell kit's C ABI (see include/lookout-shell.h): the format kit and the
//! license manifest. None of it needs a handle.

const std = @import("std");

const capi = @import("../capi.zig");
const format = @import("../shell/format.zig");
const depth = @import("../shell/depth.zig");
const lic = @import("../licenses.zig");
const coast = @import("../shell/coastline.zig");

const gpa = capi.gpa;

// The buffer sizes lookout-shell.h states, checked against what the kit writes.
comptime {
    std.debug.assert(format.coord_max + 1 <= 32);
    std.debug.assert(format.position_max + 1 <= 72);
    std.debug.assert(format.scale_max + 1 <= 32);
    std.debug.assert(format.scale_compact_max + 1 <= 32);
    std.debug.assert(format.count_max <= 32);
    std.debug.assert(format.bytes_max <= 32);
    std.debug.assert(format.duration_max <= 48);
    std.debug.assert(format.depth_max <= 32);
}

/// Copy `s` and its NUL into the caller's buffer. Returns the length, or 0 when
/// the buffer is absent or too small.
fn copyOut(out: ?[*]u8, cap: usize, s: []const u8) usize {
    const dst = out orelse return 0;
    if (cap == 0) return 0;
    if (s.len + 1 > cap) {
        dst[0] = 0;
        return 0;
    }
    @memcpy(dst[0..s.len], s);
    dst[s.len] = 0;
    return s.len;
}

/// Degrees and decimal minutes with a hemisphere. See lookout-shell.h.
export fn lookout_fmt_coord_dm(value: f64, is_lat: c_int, out: ?[*]u8, cap: usize) usize {
    var buf: [format.coord_max]u8 = undefined;
    return copyOut(out, cap, format.fmtCoordDM(&buf, value, is_lat != 0));
}

/// A full position, latitude first. See lookout-shell.h.
export fn lookout_fmt_position(lat: f64, lon: f64, out: ?[*]u8, cap: usize) usize {
    var buf: [format.position_max]u8 = undefined;
    return copyOut(out, cap, format.fmtPosition(&buf, lat, lon));
}

/// The 1:N scale with group separators. See lookout-shell.h.
export fn lookout_fmt_scale(denominator: f64, out: ?[*]u8, cap: usize) usize {
    var buf: [format.scale_max]u8 = undefined;
    return copyOut(out, cap, format.fmtScale(&buf, denominator));
}

/// The scale in millions from 1,000,000 up. See lookout-shell.h.
export fn lookout_fmt_scale_compact(denominator: f64, out: ?[*]u8, cap: usize) usize {
    var buf: [format.scale_compact_max]u8 = undefined;
    return copyOut(out, cap, format.fmtScaleCompact(&buf, denominator));
}

/// A position at two decimals of minutes. See lookout-shell.h.
export fn lookout_fmt_position_compact(lat: f64, lon: f64, out: ?[*]u8, cap: usize) usize {
    var buf: [format.position_max]u8 = undefined;
    return copyOut(out, cap, format.fmtPositionCompact(&buf, lat, lon));
}

/// A count grouped in threes. See lookout-shell.h.
export fn lookout_fmt_count(n: u64, out: ?[*]u8, cap: usize) usize {
    var buf: [format.count_max]u8 = undefined;
    return copyOut(out, cap, format.fmtCount(&buf, n));
}

/// A size in megabytes or gigabytes. See lookout-shell.h.
export fn lookout_fmt_bytes(bytes: u64, out: ?[*]u8, cap: usize) usize {
    var buf: [format.bytes_max]u8 = undefined;
    return copyOut(out, cap, format.fmtBytes(&buf, bytes));
}

/// About how long a time is. See lookout-shell.h.
export fn lookout_fmt_duration(seconds: f64, style: c_int, out: ?[*]u8, cap: usize) usize {
    var buf: [format.duration_max]u8 = undefined;
    const s: format.DurationStyle = if (style == @intFromEnum(format.DurationStyle.about)) .about else .left;
    return copyOut(out, cap, format.fmtDuration(&buf, seconds, s));
}

/// A depth in the unit on screen. See lookout-shell.h.
export fn lookout_fmt_depth(v_m: f64, unit: c_int, out: ?[*]u8, cap: usize) usize {
    var buf: [format.depth_max]u8 = undefined;
    return copyOut(out, cap, format.fmtDepth(&buf, v_m, unit & 1 != 0, unit & 2 != 0));
}

/// The name of an S-57 usage band. See lookout-shell.h.
export fn lookout_usage_band_name(band: c_int) [*:0]const u8 {
    const b: u8 = if (band >= 1 and band <= 6) @intCast(band) else 0;
    return format.bandName(b).ptr;
}

/// The S-52 navigational purpose band for a display scale. See lookout-shell.h.
export fn lookout_band_name(denominator: f64) [*:0]const u8 {
    return format.bandForDenominator(denominator).ptr;
}

/// Parse what the mariner typed into the search field. See lookout-shell.h.
export fn lookout_parse_position(text: ?[*:0]const u8, out_lat: ?*f64, out_lon: ?*f64) c_int {
    const raw = text orelse return 0;
    const p = format.parsePosition(std.mem.span(raw)) orelse return 0;
    if (out_lat) |q| q.* = p.lat;
    if (out_lon) |q| q.* = p.lon;
    return 1;
}

/// Parse what the mariner typed into the scale entry. See lookout-shell.h.
export fn lookout_parse_scale(text: ?[*:0]const u8, out_denominator: ?*f64) c_int {
    const raw = text orelse return 0;
    const denominator = format.parseScale(std.mem.span(raw)) orelse return 0;
    if (out_denominator) |q| q.* = denominator;
    return 1;
}

/// A wanted scale as a zoom delta. See lookout-shell.h.
export fn lookout_zoom_delta_for_scale(current_denominator: f64, wanted_denominator: f64) f64 {
    return format.zoomDeltaForScale(current_denominator, wanted_denominator);
}

// ---- the depth plan ----------------------------------------------------------

// lookout_depth_plan in lookout-shell.h: seventeen doubles, in this order.
comptime {
    std.debug.assert(@sizeOf(depth.Plan) == 17 * @sizeOf(f64));
    std.debug.assert(@offsetOf(depth.Plan, "clearances") == 12 * @sizeOf(f64));
}

/// The four depth settings for a boat. See lookout-shell.h.
export fn lookout_depth_plan(draft_m: f64, clearance_m: f64, feet: c_int, out: ?*depth.Plan) void {
    const dst = out orelse return;
    dst.* = depth.plan(draft_m, clearance_m, feet != 0);
}

/// The contour ladder in the unit on screen. See lookout-shell.h.
export fn lookout_depth_ladder(feet: c_int, out: ?[*]f64, cap: usize) usize {
    const l = depth.ladder(feet != 0);
    if (out) |dst| {
        const n = @min(cap, l.len);
        @memcpy(dst[0..n], l[0..n]);
    }
    return l.len;
}

// ---- the coverage coastline --------------------------------------------------

/// Width over height of a Mercator window. See lookout-shell.h.
export fn lookout_map_aspect(w: f64, e: f64, s: f64, n: f64) f64 {
    return coast.aspect(w, e, s, n);
}

/// Lon/lat pairs projected into a window's rectangle. See lookout-shell.h.
export fn lookout_map_project(w: f64, e: f64, s: f64, n: f64, px_w: f64, px_h: f64, lonlat: ?[*]const f64, xy: ?[*]f32, points: usize) void {
    const src = lonlat orelse return;
    const dst = xy orelse return;
    const win = coast.Window{ .west = w, .east = e, .south = s, .north = n, .px_w = px_w, .px_h = px_h };
    for (0..points) |i| {
        const p = win.point(src[i * 2], src[i * 2 + 1]);
        dst[i * 2] = @floatCast(p[0]);
        dst[i * 2 + 1] = @floatCast(p[1]);
    }
}

/// The coastline's rings of one level, projected to pixels. See lookout-shell.h.
export fn lookout_coastline_rings(level: c_int, w: f64, e: f64, s: f64, n: f64, px_w: f64, px_h: f64, xy: ?[*]f32, cap: usize, ends: ?[*]u32, ends_cap: usize) usize {
    if (level < 0 or level > 255) return 0;
    const win = coast.Window{ .west = w, .east = e, .south = s, .north = n, .px_w = px_w, .px_h = px_h };
    const pts: []f32 = if (xy) |p| p[0 .. cap * 2] else &.{};
    const ring_ends: []u32 = if (ends) |p| p[0..ends_cap] else &.{};
    return coast.rings(@intCast(level), win, pts, ring_ends);
}

// ---- licenses ----------------------------------------------------------------

/// The license manifest baked into this build. See lookout-shell.h. Static, so
/// it needs no handle and outlives every call.
export fn lookout_licenses_json(out_len: ?*usize) [*]const u8 {
    const json = lic.json;
    if (out_len) |p| p.* = json.len;
    return json.ptr;
}

pub const lookout_licenses = lic.Read;
pub const lookout_license = lic.Entry;

fn count(out_n: ?*usize, n: usize) void {
    if (out_n) |p| p.* = n;
}

/// Read the components `shell` ships with. See lookout-shell.h.
export fn lookout_licenses_read(shell: ?[*:0]const u8) ?*lookout_licenses {
    const id = if (shell) |s| std.mem.span(s) else "";
    return lic.read(gpa, id) catch null;
}

export fn lookout_licenses_free(l: ?*lookout_licenses) void {
    if (l) |x| x.free();
}

/// The components, in the order the manifest lists them.
export fn lookout_licenses_all(l: ?*const lookout_licenses, out_n: ?*usize) ?[*]const *const lookout_license {
    const x = l orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.rows().len);
    return x.rows().ptr;
}

/// This app's own terms. Not a component, and not in the count above.
export fn lookout_licenses_app(l: ?*const lookout_licenses) ?*const lookout_license {
    const x = l orelse return null;
    return x.app;
}
