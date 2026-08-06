//! Laylines: the two close-hauled tracks out of own ship's position, one for
//! each tack, drawn 1 nm long from the true wind direction.
//!
//! The plugin holds the last position and the last true wind in globals and
//! redraws from them on a 1 Hz timer, rather than on every store change: the
//! store fans out at up to 10 Hz and a layline that twitches ten times a second
//! is harder to read than one that steps once a second.
//!
//! Wind that is missing, cleared, or older than 30 s takes both lines off the
//! chart and puts the plugin in `degraded`, because a layline from a wind
//! reading half a minute old is a confident drawing of a guess. Position is
//! held to the same window. Either recovers on the next good reading.

const std = @import("std");
const lk = @import("lk");
const geo = @import("geo.zig");

comptime {
    lk.registerPlugin(@This());
}

/// Overlay object ids. The host namespaces them per plugin.
const id_port = "layline_port";
const id_stbd = "layline_stbd";

/// One 5 s window rules all vessel data; the vessel store and the other
/// plugins use the same number.
const wind_max_age_ms: i64 = 5_000;
const position_max_age_ms: i64 = 5_000;

const redraw_interval_ms: i64 = 1000;

/// Line width in screen points, and dashed: a layline is where the boat could
/// go, not anything charted or measured, and it must not read as either.
const width_pt: f64 = 1.5;
const dashed = true;

/// How far the true wind must shift before the status line is reposted, in
/// degrees. Only stops a 1 Hz status from filling the host log.
const status_twd_step: f64 = 5.0;

// ---- state that outlives one event ----------------------------------------
// The scratch arena resets at the end of every event, so everything the timer
// draws from lives here.

/// The last value seen for a path, and enough to age it between events: the
/// host stamps `age_ms` at delivery, and the monotonic clock carries it on.
const Sample = struct {
    valid: bool = false,
    mono_at_ms: i64 = 0,
    age_at_ms: i64 = 0,

    fn stamp(self: *Sample, age_ms: i64, mono_ms: i64) void {
        self.valid = true;
        self.mono_at_ms = mono_ms;
        self.age_at_ms = age_ms;
    }

    fn ageMs(self: Sample, mono_ms: i64) i64 {
        return self.age_at_ms + (mono_ms - self.mono_at_ms);
    }

    fn fresh(self: Sample, mono_ms: i64, limit_ms: i64) bool {
        return self.valid and self.ageMs(mono_ms) <= limit_ms;
    }
};

var pos: Sample = .{};
var pos_lat: f64 = 0;
var pos_lon: f64 = 0;

var wind: Sample = .{};
var twd_deg: f64 = 0;

var timer_id: i64 = -1;
var drawn = false;

const State = enum {
    starting,
    running,
    no_wind,
    no_position,
    no_wind_no_position,
    stopped,

    /// What the chrome says while degraded. Every missing input is named: a
    /// line that says "no wind" while the GPS is also out sends the mariner
    /// after the wrong instrument.
    fn detail(self: State) []const u8 {
        return switch (self) {
            .no_wind => "no wind",
            .no_position => "no position",
            .no_wind_no_position => "no wind, no position",
            else => "",
        };
    }
};

fn degradedState(wind_ok: bool, pos_ok: bool) State {
    if (!wind_ok and !pos_ok) return .no_wind_no_position;
    return if (wind_ok) .no_position else .no_wind;
}

var state: State = .starting;
var status_twd_bucket: f64 = 0;

pub fn start(s: lk.Start) !void {
    _ = s;
    if (lk.subscribePaths(&.{ "navigation.position", "environment.wind.directionTrue" }) < 0)
        return error.SubscribeRefused;
    timer_id = lk.timerSet(redraw_interval_ms, true);
    if (timer_id < 0) return error.TimerRefused;
    lk.status("starting", "waiting for wind and position", .{});
}

pub fn onEvent(e: lk.Event) !void {
    switch (e) {
        .store_changed => |payload| take(payload),
        .timer => |id| if (id == timer_id) redraw(),
        .shutdown => {
            if (timer_id >= 0) lk.timerCancel(timer_id);
            timer_id = -1;
            clearLines();
            state = .stopped;
            lk.status("stopped", "shut down", .{});
        },
        else => {},
    }
}

/// Record what the store sent. Nothing is drawn here — the timer does that.
fn take(payload: []const u8) void {
    const mono = lk.monoMs();
    for (lk.readings(payload)) |r| {
        if (std.mem.eql(u8, r.path, "navigation.position")) {
            if (r.removed()) {
                pos.valid = false;
                continue;
            }
            const p = r.position() orelse continue;
            if (!geo.validPosition(p[0], p[1])) continue;
            pos_lat = p[0];
            pos_lon = p[1];
            pos.stamp(r.age_ms, mono);
        } else if (std.mem.eql(u8, r.path, "environment.wind.directionTrue")) {
            if (r.removed()) {
                wind.valid = false;
                continue;
            }
            const v = r.number() orelse continue;
            if (!geo.validDirection(v)) continue;
            twd_deg = geo.normalizeDeg(v);
            wind.stamp(r.age_ms, mono);
        }
    }
}

fn redraw() void {
    const mono = lk.monoMs();
    const pos_ok = pos.fresh(mono, position_max_age_ms);
    const wind_ok = wind.fresh(mono, wind_max_age_ms);
    if (!pos_ok or !wind_ok) {
        clearLines();
        degrade(degradedState(wind_ok, pos_ok));
        return;
    }

    const from = geo.Point{ .lat = pos_lat, .lon = pos_lon };
    const ends = geo.endpoints(from, twd_deg, geo.layline_length_m);
    const port_leg = [2][2]f64{ .{ from.lon, from.lat }, .{ ends.port.lon, ends.port.lat } };
    const stbd_leg = [2][2]f64{ .{ from.lon, from.lat }, .{ ends.stbd.lon, ends.stbd.lat } };

    var buf: [768]u8 = undefined;
    var ov = lk.Overlay.init(&buf);
    ov.polyline(id_port, &port_leg, width_pt, .layline_port, dashed);
    ov.polyline(id_stbd, &stbd_leg, width_pt, .layline_stbd, dashed);
    if (ov.send() < 0) return;
    drawn = true;
    runningStatus();
}

/// Take both lines off the chart. Idempotent: nothing is sent once they are
/// already gone.
fn clearLines() void {
    if (!drawn) return;
    var buf: [128]u8 = undefined;
    var ov = lk.Overlay.init(&buf);
    ov.del(id_port);
    ov.del(id_stbd);
    _ = ov.send();
    drawn = false;
}

/// Post `degraded` once per transition. The host logs a status it has not seen
/// before, so a 1 Hz repeat of the same line would be a 1 Hz log line.
fn degrade(next: State) void {
    if (state == next) return;
    state = next;
    lk.status("degraded", "{s}", .{next.detail()});
}

/// Repost the running status when the state changed or the wind shifted a
/// bucket; the host logs every status it has not seen before.
fn runningStatus() void {
    const bucket = @round(twd_deg / status_twd_step);
    if (state == .running and bucket == status_twd_bucket) return;
    state = .running;
    status_twd_bucket = bucket;
    lk.status("running", "TWD {d:.0} deg, laylines {d:.0}/{d:.0}", .{
        twd_deg,
        geo.portBearingDeg(twd_deg),
        geo.stbdBearingDeg(twd_deg),
    });
}
