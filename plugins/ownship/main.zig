//! Ownship: draws the boat.
//!
//! Four objects, all off `navigation.position`:
//!
//!   ownship  the boat symbol, rotated to true heading (course over ground
//!            when there is no heading sensor)
//!   hdg      a short line along that same direction — where the bow points
//!   cog      a dashed vector 6 minutes long at the current speed — where the
//!            boat will actually be, which is a different question in a tide
//!   track    where the boat has been, up to 600 kept positions
//!
//! The library holds `draw` until the fix is fresh, so every call has a
//! position for the symbol and the track. Heading, course and speed are
//! optional: a missing one takes its own object off the chart and nothing else.

const lk = @import("lk2");
const trk = @import("track.zig");

comptime {
    lk.plugin(@This());
}

pub const inputs = struct {
    pub const fix = lk.position("navigation.position", .{});
    pub const heading = lk.number("navigation.headingTrue", .{ .optional = true });
    pub const course = lk.number("navigation.courseOverGroundTrue", .{ .optional = true });
    pub const speed = lk.number("navigation.speedOverGround", .{ .optional = true });
};

/// Heading line length: 0.1 nm, the same as an AIS target's heading line, so
/// own ship and the traffic read on one scale. A 1 nm line crossed the harbour.
const heading_line_m = lk.nm(0.1);

/// The COG vector reaches where the boat gets to in six minutes at this speed.
const cog_vector_s: f64 = 6 * 60;

/// Below this the course over ground is noise — a boat "doing" 0.1 kn at
/// anchor would fly a vector that swings through every point of the compass.
/// 0.2 m/s is about 0.4 kn.
const cog_min_sog_mps: f64 = 0.2;

/// Track spacing gates. The draw timer offers one fix a second, so distance is
/// what thins the track; the time gate is half the timer's period and rejects a
/// fix offered twice and a clock that went backwards. A full second there threw
/// away any offer whose fix was a few ms younger than the tick before it.
const track_min_ms: i64 = 500;
const track_min_m: f64 = 2.0;

/// The heading line is the heavier of the two: it is the one that says which
/// way the boat is facing. Both ride own ship's display position, so they hold
/// their end on the hull between the 1 Hz fixes; the track is charted where the
/// fixes were.
const hdg_style = lk.Chart.Line{ .color = .ownship, .width_pt = 2.0, .anchor = .ownship };
const cog_style = lk.Chart.Line{ .color = .ownship, .width_pt = 1.5, .dash = true, .anchor = .ownship };
const track_style = lk.Chart.Line{ .color = .track, .width_pt = 1.5 };

var track: trk.Track = .{};

/// The track copied out for one call. A global, not a local: 600 points is
/// 9.6 KiB and the wasm stack is 64 KiB.
var pts: [trk.max_points]lk.Point = undefined;

pub fn draw(c: *lk.Chart) void {
    const boat = inputs.fix.get();
    // The time the fix was taken, not now: the gates measure fix to fix, and a
    // GPS slower than the draw timer has one fix offered several times.
    _ = track.consider(lk.monoMs() - (inputs.fix.ageMs() orelse 0), boat, track_min_ms, track_min_m);

    // A compass says where the bow points and a GPS course says where the boat
    // is going. Only the first is what the symbol's rotation claims to show, so
    // the course is the fallback and the status line says which one is drawn.
    const compass = inputs.heading.fresh();
    const course = inputs.course.fresh();
    const rot = compass orelse course;
    const speed = inputs.speed.fresh() orelse 0;

    c.symbol("ownship", .ownship, boat, .{ .color = .ownship, .rot_deg = rot orelse 0, .anchor = .ownship });
    if (rot) |r| c.line("hdg", &.{ boat, boat.destination(r, heading_line_m) }, hdg_style);
    if (course != null and speed > cog_min_sog_mps)
        c.line("cog", &.{ boat, boat.destination(course.?, speed * cog_vector_s) }, cog_style);

    // A line wants two points, so a track of one draws nothing.
    const n = track.copy(&pts);
    if (n >= 2) c.line("track", pts[0..n], track_style);

    c.status("tracking, {s}", .{rotationSource(compass, course)});
}

/// Where the symbol's rotation came from — the one thing about the boat a
/// mariner cannot read off the chart. v1 printed the track's point count here;
/// the status dedupe compares the whole text, so a number that moves every
/// second would be a host log line every second.
fn rotationSource(compass: ?f64, course: ?f64) []const u8 {
    if (compass != null) return "heading from the compass";
    if (course != null) return "heading from GPS course";
    return "no heading";
}
