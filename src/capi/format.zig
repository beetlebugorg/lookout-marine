//! The shell kit's C ABI (see include/lookout-shell.h): the format kit and the
//! license manifest. None of it takes a handle.

const std = @import("std");

const capi = @import("../capi.zig");
const format = @import("../shell/format.zig");
const lic = @import("../licenses.zig");

const gpa = capi.gpa;

// The buffer sizes lookout-shell.h states, checked against what the kit writes.
comptime {
    std.debug.assert(format.coord_max + 1 <= 32);
    std.debug.assert(format.position_max + 1 <= 72);
    std.debug.assert(format.scale_max + 1 <= 32);
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

// ---- licenses ----------------------------------------------------------------

/// The license manifest baked into this build. See lookout-shell.h. Static, so
/// it takes no handle and outlives every call.
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

/// Read the components `shell` carries. See lookout-shell.h.
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
