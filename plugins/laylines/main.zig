//! Laylines: the two close-hauled tracks out of own ship's position, one for
//! each tack, drawn 1 nm long from the true wind direction.
//!
//! Wind or position that is missing, cleared, or older than the 5 s window
//! takes both lines off the chart and puts the plugin in `degraded`, because a
//! layline from a wind reading half a minute old is a confident drawing of a
//! guess. The library owns that gate, the 1 Hz redraw and the status line;
//! this file owns the two bearings and what the lines look like.

const lk = @import("lk2");
const geo = @import("geo.zig");

comptime {
    lk.plugin(@This());
}

pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
};

/// Dashed, and light: a layline is where the boat could go, not anything
/// charted or measured, and it must not read as either.
const style = lk.Chart.Line{ .color = .layline_port, .width_pt = 1.5, .dash = true };

/// How far the true wind must shift before the status line says a new number.
/// Only stops a 1 Hz status from filling the host log.
const status_step_deg: f64 = 5.0;

pub fn draw(c: *lk.Chart) void {
    const from = inputs.boat.get();
    const twd = geo.normalizeDeg(inputs.twd.get());
    const port = geo.portBearingDeg(twd);
    const stbd = geo.stbdBearingDeg(twd);

    c.line("layline_port", &.{ from, from.destination(port, geo.layline_length_m) }, style);
    c.line("layline_stbd", &.{ from, from.destination(stbd, geo.layline_length_m) }, .{
        .color = .layline_stbd,
        .width_pt = style.width_pt,
        .dash = style.dash,
    });

    c.status("TWD {d:.0} deg, laylines {d:.0}/{d:.0}", .{
        @round(twd / status_step_deg) * status_step_deg,
        port,
        stbd,
    });
}
