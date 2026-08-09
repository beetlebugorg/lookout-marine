//! Ownship: draws the boat.
//!
//! Five objects, all off `navigation.position`:
//!
//!   ownship  the boat symbol, rotated to true heading (course over ground
//!            when there is no heading sensor)
//!   hdg      a short line along that same direction — where the bow points
//!   cog      a solid vector as long as the boat travels in the set time:
//!            where the boat will actually be, which is a different question
//!            in a tide
//!   cog_end  a ring on the end of that vector, held at one screen size
//!   track    where the boat has been, up to 600 kept positions
//!
//! A fix arriving is what adds a point to the track. `draw` reads the track
//! and renders it.
//!
//! The library holds `draw` until the fix is fresh, so every call has a
//! position for the symbol. Heading, course and speed are optional. A missing
//! one takes its own object off the chart. The rest of the scene stands.

const lk = @import("lk2");
const cfg = @import("config.zig");
const trk = @import("track.zig");

comptime {
    lk.plugin(@This());
}

pub const Settings = cfg.groups;

pub const inputs = struct {
    pub const fix = lk.subscribePosition("navigation.position", .{});
    pub const heading = lk.subscribeNumber("navigation.headingTrue", .{ .optional = true });
    pub const course = lk.subscribeNumber("navigation.courseOverGroundTrue", .{ .optional = true });
    pub const speed = lk.subscribeNumber("navigation.speedOverGround", .{ .optional = true });
};

/// Heading line length: 0.1 nm, the same as an AIS target's heading line, so
/// own ship and the traffic read on one scale. A 1 nm line crossed the harbour.
const heading_line_m = lk.nm(0.1);

/// The floor under the course vector. Below this the course over ground is
/// instrument noise: a boat at anchor would fly a vector that swings through
/// every point of the compass. 0.05 m/s is 0.1 kn, about what a GPS at rest
/// jitters at. Anything above it draws however short it comes out, so the
/// vector shrinks as the boat slows instead of going out at a step.
const cog_min_sog_mps: f64 = 0.05;

/// Radius of the ring at the far end of the course vector, screen points, and
/// the weight it is drawn at. It holds this size at every zoom, so it reads as
/// the end of the vector and never as a charted circle.
const cog_ring_pt: f64 = 4.0;
const cog_ring_width_pt: f64 = 1.5;

/// Track spacing gates. Distance is what thins the track. The time gate rejects
/// the same fix offered twice, which is what a cycle carrying only heading,
/// course or speed offers, and a clock that went backwards. It is half the
/// interval a GPS reports at: a full second there threw away any offer whose
/// fix was a few ms younger than the one before it.
const track_min_ms: i64 = 500;
const track_min_m: f64 = 2.0;

/// The heading line is the heavier of the two: it is the one that says which
/// way the boat is facing. Both ride own ship's display position, so they hold
/// their end on the hull between the 1 Hz fixes; the track is charted where the
/// fixes were.
const hdg_style = lk.Chart.Line{ .color = .ownship, .width_pt = 2.0, .anchor = .ownship };
const cog_style = lk.Chart.Line{ .color = .ownship, .width_pt = 1.5, .anchor = .ownship };
const track_style = lk.Chart.Line{ .color = .track, .width_pt = 1.5 };

var track: trk.Track = .{};

/// The track copied out for one call. A global, not a local: 600 points is
/// 9.6 KiB and the wasm stack is 64 KiB.
var pts: [trk.max_points]lk.Point = undefined;

pub fn onUpdate() void {
    // The freshness gate runs before `draw`, not before this, so a position
    // that stopped counting has to be refused here. A stale fix charted as a
    // leg would draw a line the boat never sailed.
    const boat = inputs.fix.fresh() orelse return;
    // The time the fix was taken, not now: the gates measure fix to fix, and a
    // GPS slower than the cycle has one fix offered several times.
    _ = track.consider(lk.monoMs() - (inputs.fix.ageMs() orelse 0), boat, track_min_ms, track_min_m);
}

pub fn draw(c: *lk.Chart) void {
    const set = cfg.Tuned.now();
    const boat = inputs.fix.get();

    // A compass says where the bow points and a GPS course says where the boat
    // is going. Only the first is what the symbol's rotation claims to show, so
    // the course is the fallback and the status line says which one is drawn.
    const compass = inputs.heading.fresh();
    const course = inputs.course.fresh();
    const rot = compass orelse course;
    const speed = inputs.speed.fresh() orelse 0;

    c.symbol("ownship", .ownship, boat, .{ .color = .ownship, .rot_deg = rot orelse 0, .anchor = .ownship });
    if (rot) |r| c.line("hdg", &.{ boat, boat.destination(r, heading_line_m) }, hdg_style);
    // The vector is as long as the boat travels in the set time, so it grows
    // and shrinks with the speed and says how far ahead the mariner is looking.
    if (course) |crs| {
        const reach_m = speed * set.vector_seconds;
        if (speed > cog_min_sog_mps and reach_m > 0) {
            const tip = boat.destination(crs, reach_m);
            c.line("cog", &.{ boat, tip }, cog_style);
            ring(c, tip);
        }
    }

    // A line wants two points, so a track of one draws nothing.
    const n = track.copy(&pts);
    if (n >= 2) c.line("track", pts[0..n], track_style);

    c.status("tracking, {s}", .{rotationSource(compass, course)});
}

/// The open ring on the end of the course vector. A canvas in point space
/// rather than a line: its size is screen points, so it marks the end of the
/// vector at every zoom instead of growing into a circle on the water. The
/// palette token is what carries night, so the ring dims with the line.
fn ring(c: *lk.Chart, at: lk.Point) void {
    var cv = c.canvas("cog_end", .{ .at = at, .space = .points });
    cv.strokeStyle(.{ .token = .ownship });
    cv.lineWidth(cog_ring_width_pt);
    cv.beginPath();
    cv.arc(0, 0, cog_ring_pt, 0, 360, false);
    cv.stroke();
    cv.done();
}

/// Where the symbol's rotation came from, which is the one thing about the
/// boat a mariner cannot read off the chart. The status dedupe compares the
/// whole text, so a figure that moves every second would be a host log line
/// every second. Nothing that changes at that rate belongs here.
fn rotationSource(compass: ?f64, course: ?f64) []const u8 {
    if (compass != null) return "heading from the compass";
    if (course != null) return "heading from GPS course";
    return "no heading";
}
