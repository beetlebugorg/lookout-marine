//! Setup's C ABI (see include/lookout-library.h): the state machine in
//! firstrun.zig behind a handle.

const std = @import("std");

const capi = @import("../capi.zig");
const firstrun = @import("../firstrun.zig");

const gpa = capi.gpa;

pub const lookout_setup = firstrun.Setup;
pub const lookout_setup_facts = firstrun.Facts;
pub const lookout_setup_state = firstrun.State;

/// Make a setup handle, down, with no facts noted. NULL when it cannot be
/// allocated.
export fn lookout_setup_new() ?*lookout_setup {
    const s = gpa.create(lookout_setup) catch return null;
    s.* = .{};
    return s;
}

export fn lookout_setup_free(s: ?*lookout_setup) void {
    if (s) |x| gpa.destroy(x);
}

/// Replace the facts setup reads. See lookout-library.h.
export fn lookout_setup_note(s: ?*lookout_setup, facts: ?*const lookout_setup_facts) void {
    const x = s orelse return;
    const f = facts orelse return;
    x.note(f.*);
}

/// Apply a LOOKOUT_SETUP_* action. Returns the LOOKOUT_SETUP_FROM_* source
/// the shell acts on, or -1.
export fn lookout_setup_act(s: ?*lookout_setup, action: c_int, arg: c_int) c_int {
    const x = s orelse return -1;
    const a = std.enums.fromInt(firstrun.Action, action) orelse return -1;
    const src = x.act(a, arg) orelse return -1;
    return @intFromEnum(src);
}

export fn lookout_setup_read(s: ?*lookout_setup, out: ?*lookout_setup_state) void {
    const o = out orelse return;
    const x = s orelse {
        o.* = .{};
        return;
    };
    o.* = x.state();
}
