//! The installed sets' C ABI (see include/lookout-library.h).
//!
//! No chart handle: the sets exist before anything is open, and the first-run
//! page is drawn from them.

const std = @import("std");

const capi = @import("../capi.zig");
const sets = @import("../chartsets.zig");
const settings = @import("../settings.zig");

const gpa = capi.gpa;
const capi_io = capi.capi_io;

pub const lookout_chart_sets = sets.Sets;
pub const lookout_chart_set = sets.Set;

fn count(out_n: ?*usize, n: usize) void {
    if (out_n) |p| p.* = n;
}

fn span(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "";
}

/// Load the saved list and start the background scans. See
/// lookout-library.h.
export fn lookout_chart_sets_open(store: ?*settings.Store) ?*lookout_chart_sets {
    const s = store orelse return null;
    return sets.Sets.open(gpa, capi_io, s) catch null;
}

export fn lookout_chart_sets_close(s: ?*lookout_chart_sets) void {
    if (s) |x| x.close();
}

/// 1 since the last poll, then clears. A background scan landing raises it.
export fn lookout_chart_sets_changed(s: ?*lookout_chart_sets) c_int {
    const x = s orelse return 0;
    return @intFromBool(x.takeChanged());
}

/// The list, in the order added. Borrowed until the next call that changes it.
export fn lookout_chart_sets_all(s: ?*lookout_chart_sets, out_n: ?*usize) ?[*]const *const lookout_chart_set {
    const x = s orelse {
        count(out_n, 0);
        return null;
    };
    const rows = x.all();
    count(out_n, rows.len);
    if (rows.len == 0) return null;
    return rows.ptr;
}

export fn lookout_chart_sets_add(s: ?*lookout_chart_sets, path: ?[*:0]const u8) c_int {
    const x = s orelse return 0;
    return @intFromBool(x.add(span(path)));
}

export fn lookout_chart_sets_remove(s: ?*lookout_chart_sets, path: ?[*:0]const u8) c_int {
    const x = s orelse return 0;
    return @intFromBool(x.remove(span(path)));
}

export fn lookout_chart_sets_set_on(s: ?*lookout_chart_sets, path: ?[*:0]const u8, on: c_int) c_int {
    const x = s orelse return 0;
    return @intFromBool(x.setOn(span(path), on != 0));
}

export fn lookout_chart_sets_is_on(s: ?*lookout_chart_sets, path: ?[*:0]const u8) c_int {
    const x = s orelse return 0;
    return @intFromBool(x.isOn(span(path)));
}

/// The charts to open. Borrowed until the next call that changes the list.
export fn lookout_chart_sets_compose(s: ?*lookout_chart_sets, out_n: ?*usize) ?[*]const [*:0]const u8 {
    const x = s orelse {
        count(out_n, 0);
        return null;
    };
    const paths = x.compose();
    count(out_n, paths.len);
    if (paths.len == 0) return null;
    return paths.ptr;
}
