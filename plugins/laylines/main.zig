//! Laylines: the tracks out of own ship's position for the beat and for the
//! run, one on each tack, drawn 1 nm long from the true wind direction.
//!
//! Wind or position that is missing, cleared, or older than the 5 s window
//! takes all four lines off the chart and puts the plugin in `degraded`, because
//! a layline from a wind value half a minute old is a confident drawing of a
//! guess. The library owns that gate, the 1 Hz redraw and the status line;
//! this file owns the four bearings and what the lines look like.

const lk = @import("lk2");
const cfg = @import("config.zig");
const geo = @import("geo.zig");

comptime {
    lk.plugin(@This());
}

pub const Settings = cfg.groups;

pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
};

/// Dashed, and light: a layline is where the boat could go, not anything
/// charted or measured, and it must not read as either. The tack owns the
/// colour, so a tack's beat and its run are the same line twice, pointing
/// opposite ways.
const port_style = lk.Chart.Line{ .color = .layline_port, .width_pt = 1.5, .dash = true };
const stbd_style = lk.Chart.Line{ .color = .layline_stbd, .width_pt = 1.5, .dash = true };

/// How far the true wind must shift before the status line says a new number.
/// Only stops a 1 Hz status from filling the host log.
const status_step_deg: f64 = 5.0;

pub fn draw(c: *lk.Chart) void {
    const set = lk.settings(cfg.Angles);
    const from = inputs.boat.get();
    const twd = geo.normalizeDeg(inputs.twd.get());

    const up_port = geo.portBearingDeg(twd, set.upwind_deg);
    const up_stbd = geo.stbdBearingDeg(twd, set.upwind_deg);
    const down_port = geo.portBearingDeg(twd, set.downwind_deg);
    const down_stbd = geo.stbdBearingDeg(twd, set.downwind_deg);

    leg(c, "layline_port", from, up_port, port_style);
    leg(c, "layline_stbd", from, up_stbd, stbd_style);
    leg(c, "layline_port_down", from, down_port, port_style);
    leg(c, "layline_stbd_down", from, down_stbd, stbd_style);

    c.status("TWD {d:.0} deg, upwind {d:.0}/{d:.0}, downwind {d:.0}/{d:.0}", .{
        @round(twd / status_step_deg) * status_step_deg,
        up_port,
        up_stbd,
        down_port,
        down_stbd,
    });
}

/// One line, from the boat along `bearing_deg`.
fn leg(c: *lk.Chart, id: []const u8, from: lk.Point, bearing_deg: f64, style: lk.Chart.Line) void {
    c.line(id, &.{ from, from.destination(bearing_deg, geo.layline_length_m) }, style);
}
