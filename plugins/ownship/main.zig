//! Ownship: draws the boat.
//!
//! Four objects, all keyed off `navigation.position`:
//!
//!   ownship  the boat symbol, rotated to true heading (course over ground
//!            when there is no heading sensor)
//!   hdg      a 1 nm line along that same direction — where the bow points
//!   cog      a dashed vector 6 minutes long at the current speed — where the
//!            boat will actually be, which is a different question in a tide
//!   track    where the boat has been, up to 600 kept positions
//!
//! WHY A TIMER DRIVES THE DRAW. Store changes arrive at up to 10 Hz and each
//! one only updates a global here. The overlay is republished from a 1 Hz
//! timer, so a chatty GPS cannot make the plugin rebuild the chart's vertex
//! buffers ten times a second, and so the "the fix went stale" transition —
//! which is time passing, not an event — is noticed at all.
//!
//! WHY AGES ARE RECOMPUTED. The host stamps `age_ms` when it delivers a
//! reading. That number is stale the moment it lands, so every value carries
//! the monotonic time it arrived and its age is recomputed at draw time.
//! Nothing here trusts the wall clock: a GPS that sets the system clock mid-
//! passage must not make a good fix look ten minutes old.

const std = @import("std");
const lk = @import("lk");
const trk = @import("track.zig");

comptime {
    lk.registerPlugin(@This());
}

// ---- the numbers, all in one place -----------------------------------------

/// A fix older than this is not a fix. PROTOTYPE.md's rule, and the same
/// window the vessel store uses to call a navigation value stale.
const max_age_ms: i64 = 10_000;

/// Overlay republish rate.
const redraw_ms: i64 = 1000;

/// Track spacing gates. Both must pass before a position is kept.
const track_min_ms: i64 = 1000;
const track_min_m: f64 = 2.0;

/// Heading line length.
const heading_line_m: f64 = trk.nm_m;

/// The COG vector is where the boat gets to in six minutes at this speed.
const cog_vector_s: f64 = 6 * 60;

/// Below this the course over ground is noise — a boat "doing" 0.1 kn at
/// anchor would otherwise fly a vector that swings through every point of the
/// compass. 0.2 m/s is about 0.4 kn.
const cog_min_sog_mps: f64 = 0.2;

/// Line weights, in screen points. The heading line is the heavier of the two
/// because it is the one that says which way the boat is facing.
const hdg_width_pt: f64 = 2.0;
const cog_width_pt: f64 = 1.5;
const track_width_pt: f64 = 1.5;

// Overlay object ids. The host namespaces them per plugin, so these are short
// and mean what they say.
const id_ship = "ownship";
const id_hdg = "hdg";
const id_cog = "cog";
const id_track = "track";

// ---- state that outlives an event ------------------------------------------
// All of it container-level: lk's scratch allocator is reset when the event
// handler returns, so anything kept lives here or not at all.

/// When a store value reached us, and how old it already was. Enough to age
/// the value again later without another event.
const Stamp = struct {
    have: bool = false,
    recv_mono: i64 = 0,
    age_at_recv: i64 = 0,

    fn set(self: *Stamp, age_ms: i64, mono: i64) void {
        self.have = true;
        self.recv_mono = mono;
        self.age_at_recv = if (age_ms > 0) age_ms else 0;
    }

    fn clear(self: *Stamp) void {
        self.* = .{};
    }

    fn ageMs(self: Stamp, mono: i64) i64 {
        return self.age_at_recv + (mono - self.recv_mono);
    }

    fn fresh(self: Stamp, mono: i64) bool {
        return self.have and self.ageMs(mono) <= max_age_ms;
    }
};

/// A scalar from the store that is only usable while it is fresh.
const Scalar = struct {
    value: f64 = 0,
    stamp: Stamp = .{},

    fn set(self: *Scalar, v: f64, age_ms: i64, mono: i64) void {
        self.value = v;
        self.stamp.set(age_ms, mono);
    }

    fn clear(self: *Scalar) void {
        self.stamp.clear();
    }

    /// The value if it is fresh, else null. A heading from four minutes ago
    /// rotating the boat symbol is worse than no rotation at all.
    fn get(self: Scalar, mono: i64) ?f64 {
        return if (self.stamp.fresh(mono)) self.value else null;
    }
};

var pos_lat: f64 = 0;
var pos_lon: f64 = 0;
var pos: Stamp = .{};
/// True once a position has ever arrived — the difference between "no GPS
/// yet" and "the GPS we had is gone".
var had_fix: bool = false;

var hdg: Scalar = .{};
var cog: Scalar = .{};
var sog: Scalar = .{};

var track: trk.Track = .{};

/// Something changed that the next redraw should publish. False at start: a
/// fresh instance owns no overlay objects, so there is nothing to say until
/// data arrives.
var dirty: bool = false;

/// What the last published batch contained, so a tick with nothing new to say
/// stays silent. Freshness lapsing is a change even though no event carried
/// it, which is why the plan is recomputed every tick and compared.
const Plan = struct {
    ship: bool = false,
    line: bool = false,
    vector: bool = false,
    track_pts: usize = 0,

    fn eq(a: Plan, b: Plan) bool {
        return a.ship == b.ship and a.line == b.line and
            a.vector == b.vector and a.track_pts == b.track_pts;
    }
};
var drawn: Plan = .{};

const State = enum { starting, running, degraded, stopped };
var state: State = .starting;
var state_posted: bool = false;

var redraw_timer: i64 = -1;

/// The overlay batch buffer. A 600-point track is the biggest thing this
/// plugin says: ~45 bytes per point worst case, so 64 KiB has headroom of
/// more than two to one. A global, not a stack array — the wasm stack is not
/// the place for it, and not the lk arena, which resets under us.
var ov_buf: [64 * 1024]u8 = undefined;

/// Scratch for the track copy, same reasoning.
var pts_buf: [trk.max_points][2]f64 = undefined;

// ---- lifecycle --------------------------------------------------------------

pub fn start(s: lk.Start) !void {
    _ = s;

    if (lk.subscribePaths(&.{
        "navigation.position",
        "navigation.headingTrue",
        "navigation.courseOverGroundTrue",
        "navigation.speedOverGround",
    }) < 0) return error.SubscribeRefused;

    redraw_timer = lk.timerSet(redraw_ms, true);
    if (redraw_timer < 0) return error.TimerRefused;

    setState(.starting);
}

pub fn onEvent(e: lk.Event) !void {
    switch (e) {
        .store_changed => |payload| ingest(payload),
        .timer => |id| if (id == redraw_timer) tick(),
        // The host drops every overlay object this plugin owns when it stops,
        // so there is nothing to delete here — only a last word on the status
        // line.
        .shutdown => setState(.stopped),
        else => {},
    }
}

// ---- reading the store ------------------------------------------------------

/// Update globals. Nothing is drawn here; the timer owns that.
fn ingest(payload: []const u8) void {
    const mono = lk.monoMs();
    for (lk.readings(payload)) |r| {
        if (std.mem.eql(u8, r.path, "navigation.position")) {
            // A null value means the path has no source left, not that the
            // boat is at 0,0.
            if (r.removed()) {
                pos.clear();
                dirty = true;
                continue;
            }
            const p = r.position() orelse continue;
            pos_lat = p[0];
            pos_lon = p[1];
            pos.set(r.age_ms, mono);
            had_fix = true;
            dirty = true;
            // Only a fresh fix joins the track. A stale one re-elected by the
            // store would otherwise draw a leg the boat never sailed.
            if (pos.fresh(mono)) {
                const t_ms = mono - pos.ageMs(mono);
                if (track.consider(t_ms, p[0], p[1], track_min_ms, track_min_m)) dirty = true;
            }
        } else if (std.mem.eql(u8, r.path, "navigation.headingTrue")) {
            scalar(&hdg, r, mono);
        } else if (std.mem.eql(u8, r.path, "navigation.courseOverGroundTrue")) {
            scalar(&cog, r, mono);
        } else if (std.mem.eql(u8, r.path, "navigation.speedOverGround")) {
            scalar(&sog, r, mono);
        }
    }
}

fn scalar(dst: *Scalar, r: lk.Reading, mono: i64) void {
    if (r.removed()) {
        dst.clear();
        dirty = true;
        return;
    }
    const v = r.number() orelse return;
    dst.set(v, r.age_ms, mono);
    dirty = true;
}

// ---- drawing ----------------------------------------------------------------

fn tick() void {
    const mono = lk.monoMs();

    const fix = pos.fresh(mono);
    // Heading first, course over ground as the fallback: a compass says where
    // the bow points, a GPS course says where the boat is going, and only the
    // first is what the symbol's rotation claims to show.
    const rot = hdg.get(mono) orelse cog.get(mono);
    const course = cog.get(mono);
    const speed = sog.get(mono) orelse 0;

    const plan = Plan{
        .ship = fix,
        .line = fix and rot != null,
        .vector = fix and course != null and speed > cog_min_sog_mps,
        .track_pts = track.count(),
    };
    if (!plan.eq(drawn)) dirty = true;
    if (dirty) {
        draw(plan, rot, course, speed);
        drawn = plan;
        dirty = false;
    }

    setState(if (fix) .running else if (had_fix) .degraded else .starting);
}

fn draw(plan: Plan, rot: ?f64, course: ?f64, speed: f64) void {
    const n = track.copyLonLat(&pts_buf);

    var ov = lk.Overlay.init(&ov_buf);

    // Deletes first — lk.Overlay drops a del that follows a set. Deleting an
    // object that is not there is a no-op host side, so this needs no memory
    // of what was drawn last time. The track survives a lost fix: where the
    // boat has been is still true.
    if (!plan.ship) ov.del(id_ship);
    if (!plan.line) ov.del(id_hdg);
    if (!plan.vector) ov.del(id_cog);
    // The overlay wants at least two points for a line.
    if (n < 2) ov.del(id_track);

    if (plan.ship) ov.symbol(id_ship, .ownship, pos_lon, pos_lat, rot orelse 0, .ownship, 1.0);
    if (plan.line) ov.polyline(id_hdg, ray(rot.?, heading_line_m), hdg_width_pt, .ownship, false);
    if (plan.vector) ov.polyline(id_cog, ray(course.?, speed * cog_vector_s), cog_width_pt, .ownship, true);
    if (n >= 2) ov.polyline(id_track, pts_buf[0..n], track_width_pt, .track, false);

    _ = ov.send();
}

/// Two points, `[lon, lat]`: the boat, and `dist_m` away on `bearing_deg`.
/// The returned slice points at a static buffer, so a caller may only hold one
/// at a time — which is all `draw` does, one polyline at a time.
var ray_buf: [2][2]f64 = undefined;
fn ray(bearing_deg: f64, dist_m: f64) []const [2]f64 {
    const end = trk.destination(pos_lat, pos_lon, bearing_deg, dist_m);
    ray_buf[0] = .{ pos_lon, pos_lat };
    ray_buf[1] = .{ end[1], end[0] };
    return &ray_buf;
}

// ---- the status line --------------------------------------------------------

/// Post only on a transition. The host logs every status it is handed that
/// differs from the last, so a detail string carrying a live speed would
/// write a log line a second.
fn setState(s: State) void {
    if (state_posted and s == state) return;
    state = s;
    state_posted = true;
    switch (s) {
        .starting => lk.status("starting", "waiting for position", .{}),
        .running => lk.status("running", "tracking, {d} track points", .{track.count()}),
        .degraded => lk.status("degraded", "GPS lost", .{}),
        .stopped => lk.status("stopped", "shut down", .{}),
    }
}
