//! Windline: one dashed line downwind from own ship.
//!
//! The whole plugin. The library subscribes, ages both readings against the
//! 5 s window, runs `draw` once a second, and takes the line off the chart and
//! says which instrument is missing when either one goes stale.

const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

pub const inputs = struct {
    pub const boat = lk.position("navigation.position", .{});
    pub const twd = lk.number("environment.wind.directionTrue", .{ .label = "wind" });
};

pub fn draw(c: *lk.Chart) void {
    const from = inputs.boat.get();
    // The wind direction is where the wind blows FROM, so downwind is the
    // reciprocal.
    const to = from.destination(inputs.twd.get() + 180, lk.nm(1));
    c.line("windline", &.{ from, to }, .{ .color = .warning, .dash = true });
}
