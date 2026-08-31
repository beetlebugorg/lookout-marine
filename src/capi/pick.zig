//! The cursor pick's half of the C ABI (see include/lookout.h): the composed
//! page and the source fold, as structs.
//!
//! `lookout_pick_ranked` replays the same features through the engine's own
//! callback and stays. This is the same pick without a JSON parse at the other
//! end.

const std = @import("std");

const capi = @import("../capi.zig");
const pick = @import("../pick.zig");

const lookout = capi.lookout;
const gpa = capi.gpa;
const locked = capi.locked;

pub const lookout_picks = pick.Read;
pub const lookout_pick_feature = pick.Report;
pub const lookout_pick_row = pick.ReportRow;
pub const lookout_pick_empty = pick.Empty;

fn count(out_n: ?*usize, n: usize) void {
    if (out_n) |p| p.* = n;
}

/// Read what is under a point. Never NULL unless the read cannot be allocated.
export fn lookout_picks_read(h: ?*lookout, lon: f64, lat: f64) ?*lookout_picks {
    const l = locked(h);
    defer l.apiUnlock();
    return l.pickRead(lon, lat) catch null;
}

export fn lookout_picks_free(p: ?*lookout_picks) void {
    if (p) |x| x.free();
}

/// The features under the point, best first.
export fn lookout_picks_all(p: ?*const lookout_picks, out_n: ?*usize) ?[*]const *const lookout_pick_feature {
    const x = p orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.rows.len);
    return x.rows.ptr;
}

/// What the cell wrote for a mariner to read.
export fn lookout_pick_notes(f: ?*const lookout_pick_feature, out_n: ?*usize) ?[*]const [*:0]const u8 {
    const rec = pick.recOf(f orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.notes_len);
    return rec.notes;
}

/// The page's detail rows, in reading order.
export fn lookout_pick_rows(f: ?*const lookout_pick_feature, out_n: ?*usize) ?[*]const *const lookout_pick_row {
    const rec = pick.recOf(f orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.rows_len);
    return rec.rows;
}

/// The payload as the cell states it, flattened depth first with object keys
/// in alphabetical order.
export fn lookout_pick_source(f: ?*const lookout_pick_feature, out_n: ?*usize) ?[*]const *const lookout_pick_row {
    const rec = pick.recOf(f orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.source_len);
    return rec.source;
}
