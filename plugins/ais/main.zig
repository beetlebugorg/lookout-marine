//! AIS: draws the other traffic and alarms on a close approach.
//!
//! Up to three overlay objects per target, all deleted together:
//!
//!   t<mmsi>       the triangle, rotated to heading, else course over ground
//!   t<mmsi>/hdg   the heading line, solid
//!   t<mmsi>/vec   the speed vector, dashed, as long as `vector_min` says
//!
//! AIDS TO NAVIGATION share the store and nothing else. A buoy is not going
//! anywhere, so it gets one object — a diamond, broken open when the aid is
//! virtual — with no CPA, no vector and no heading line, and it ages on its own
//! slower clock. A physical aid that reports itself off station raises one
//! warning.
//!
//! SETTINGS, all applied hot, all in config.zig: the gate's two limits, the
//! alarm switch, the vector time, and the speed under which a vessel is not
//! drawn. A CONFIG_CHANGED redraws from the last snapshot, so a changed limit
//! shows on the chart in that same call rather than at the next report.
//!
//! The symbol carries a pick payload, which the shell shows on hover. The set
//! is rebuilt from the full snapshot the host delivers on every AIS_CHANGED,
//! so this plugin keeps no diff of what the chart is showing.
//!
//! THE ALARM. Every AIS_CHANGED, each target with a position is run against
//! own ship through cpa.zig. A target inside `cpa_alarm_m` and less than
//! `tcpa_alarm_s` ahead is drawn `target_danger` and raises one alarm. The
//! gate state is per MMSI, so the alarm re-arms only after that target leaves
//! the gate.
//!
//! WITHOUT OWN POSITION there is no relative motion to compute. Targets are
//! still drawn, nothing is flagged, and the status line says degraded.
//!
//! WHY A TIMER AS WELL. The 180-second age rule is time passing, not an event.
//! A 1 Hz sweep ages targets out and keeps the status line current.

const std = @import("std");
const lk = @import("lk");
const cpa = @import("cpa.zig");
const vec = @import("vector.zig");
const cfg = @import("config.zig");
const aton = @import("aton.zig");

comptime {
    lk.registerPlugin(@This());
}

// ---- the numbers, all in one place -----------------------------------------

/// A target not heard from for this long stops being drawn. The host evicts
/// at 600 s; between the two limits the target is in the store but not drawn.
const stale_target_ms: i64 = 180_000;

/// A target this old is dropped from the plugin's table too. It cannot come
/// back without a fresh AIS_CHANGED, which would build the entry again.
const forget_target_ms: i64 = 600_000;

/// An aid to navigation reports about every three minutes, so the vessel
/// limits would undraw one that is still on station. Undraw at ten minutes,
/// forget at thirty — the store evicts at thirty too.
const stale_aton_ms: i64 = 600_000;
const forget_aton_ms: i64 = 1_800_000;

/// Own ship values older than this are not usable for a CPA. Same window as
/// the vessel store's default and as the ownship plugin's.
const max_own_age_ms: i64 = 10_000;

/// Age sweep and status rate.
const sweep_ms: i64 = 1000;

/// Targets tracked at once. Beyond this the extras are not drawn; a prototype
/// running in a place with 256 targets in range has other problems.
const max_targets: usize = 256;

/// Overlay objects per call. A drawn target is up to three of them: the
/// symbol, its heading line and its speed vector. Bounds `ov_buf` whatever the
/// target count.
const objs_per_batch: usize = 24;

/// Metres per second to knots, for the pick payload.
const kn_per_mps: f64 = 3600.0 / vec.nautical_mile_m; // 1.94384

/// Longest name put in an alarm body or a pick title. The wire format allows
/// 20 for a vessel and 34 for an aid to navigation.
const max_name = 34;

// ---- state that outlives an event ------------------------------------------
// All container-level: lk's scratch allocator is reset the moment an event
// handler returns, so what survives lives here.

/// What this plugin remembers about one MMSI between events: enough to age it
/// out, to know whether it currently owns an overlay object, and to know
/// whether it has already raised its alarm.
const Tracked = struct {
    mmsi: u32 = 0,
    /// True while an overlay object exists for this target.
    drawn: bool = false,
    /// True while the target is inside the danger gate. The alarm fires on the
    /// false→true edge only.
    in_gate: bool = false,
    /// True for an aid to navigation, which ages on the slower clock.
    aton: bool = false,
    /// True once the off-position warning has gone out for this aid. Cleared
    /// when it reports itself back on station.
    warned: bool = false,
    /// Present in the snapshot being processed, and wanted on the chart by it.
    /// Both are scratch for one rebuild.
    seen: bool = false,
    want: bool = false,
    /// Monotonic time this target's last report reached us, and how old it
    /// already was, so its age can be recomputed later without a new event.
    recv_mono: i64 = 0,
    age_at_recv: i64 = 0,

    fn stamp(self: *Tracked, age_ms: i64, mono: i64) void {
        self.recv_mono = mono;
        self.age_at_recv = if (age_ms > 0) age_ms else 0;
    }

    fn ageMs(self: Tracked, mono: i64) i64 {
        return self.age_at_recv + (mono - self.recv_mono);
    }

    fn staleMs(self: Tracked) i64 {
        return if (self.aton) stale_aton_ms else stale_target_ms;
    }

    fn forgetMs(self: Tracked) i64 {
        return if (self.aton) forget_aton_ms else forget_target_ms;
    }
};

var tracked: [max_targets]Tracked = undefined;
var n_tracked: usize = 0;

/// Set once when the table has overflowed, so the warning is logged once
/// rather than twice a second forever.
var table_full_logged: bool = false;

/// When a store value reached us and how old it was then. Same shape and same
/// reasoning as the ownship plugin's: the host's `age_ms` is stale the instant
/// it lands, and the wall clock jumps when a GPS sets it.
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

    fn fresh(self: Stamp, mono: i64) bool {
        return self.have and self.age_at_recv + (mono - self.recv_mono) <= max_own_age_ms;
    }
};

const Scalar = struct {
    value: f64 = 0,
    stamp: Stamp = .{},

    fn set(self: *Scalar, v: f64, age_ms: i64, mono: i64) void {
        self.value = v;
        self.stamp.set(age_ms, mono);
    }

    fn get(self: Scalar, mono: i64) ?f64 {
        return if (self.stamp.fresh(mono)) self.value else null;
    }
};

var own_lat: f64 = 0;
var own_lon: f64 = 0;
var own_pos: Stamp = .{};
var own_sog: Scalar = .{};
var own_cog: Scalar = .{};

/// True once a target snapshot has arrived. Before that the plugin is starting
/// up, which is a different thing from having no traffic.
var had_snapshot: bool = false;

/// The overlay payload buffer. A global, not scratch: it is the same size
/// every call and the arena is for what the host hands in.
var ov_buf: [16 * 1024]u8 = undefined;

/// The mariner's settings, replaced whole on every CONFIG_CHANGED.
var settings: cfg.Settings = .{};

/// The last AIS snapshot, kept so a settings change can redraw at once instead
/// of waiting up to half a second for the next one. A snapshot too large for
/// the buffer is not kept: the change then lands on the next report, and the
/// line below says so once.
var snap_buf: [32 * 1024]u8 = undefined;
var snap_len: usize = 0;
var snap_dropped_logged: bool = false;

const State = enum { starting, running, degraded, stopped };

// ---- lifecycle ---------------------------------------------------------------

pub fn start(s: lk.Start) !void {
    settings = cfg.fromValue(s.config);
    if (lk.aisSubscribe() < 0) return error.AisSubscribeRefused;
    const n = lk.subscribePaths(&.{
        "navigation.position",
        "navigation.speedOverGround",
        "navigation.courseOverGroundTrue",
    });
    if (n < 0) return error.SubscribeRefused;

    _ = lk.timerSet(sweep_ms, true);
    setStatus(.starting, 0, 0);
}

pub fn onEvent(e: lk.Event) !void {
    switch (e) {
        .ais_changed => |payload| {
            keepSnapshot(payload);
            rebuild(payload);
        },
        .config_changed => |payload| reconfigure(payload),
        .store_changed => |payload| ingest(payload),
        .timer => sweep(),
        // The host drops a plugin's overlay objects when it stops it, so
        // there is nothing to delete here.
        .shutdown => setStatus(.stopped, 0, 0),
        else => {},
    }
}

// ---- settings ----------------------------------------------------------------

/// Take the new settings and act on them now. The gate, the colours and the
/// vector lengths all come out of the last snapshot, so redrawing it is the
/// whole of "applied hot"; with no snapshot yet there is nothing on the chart
/// and the sweep keeps the status line honest.
fn reconfigure(payload: []const u8) void {
    settings = cfg.fromJson(lk.scratch(), payload);
    lk.logf(.info, "settings: cpa {d:.0} m, tcpa {d:.0} s, alarm {}, vector {d:.0} s, min sog {d:.2} m/s", .{
        settings.cpa_limit_m,
        settings.tcpa_limit_s,
        settings.cpa_alarm,
        settings.vector_seconds,
        settings.min_sog_mps,
    });
    if (snap_len > 0) rebuild(snap_buf[0..snap_len]) else sweep();
}

fn keepSnapshot(payload: []const u8) void {
    if (payload.len > snap_buf.len) {
        snap_len = 0;
        if (!snap_dropped_logged) {
            snap_dropped_logged = true;
            lk.logf(.warn, "snapshot of {d} bytes is not kept; a settings change lands on the next report", .{payload.len});
        }
        return;
    }
    @memcpy(snap_buf[0..payload.len], payload);
    snap_len = payload.len;
}

// ---- own ship ----------------------------------------------------------------

fn ingest(payload: []const u8) void {
    const mono = lk.monoMs();
    for (lk.readings(payload)) |r| {
        if (std.mem.eql(u8, r.path, "navigation.position")) {
            // A null value means the path lost its source, not that the boat
            // is at 0,0.
            if (r.removed()) {
                own_pos.clear();
                continue;
            }
            const p = r.position() orelse continue;
            own_lat = p[0];
            own_lon = p[1];
            own_pos.set(r.age_ms, mono);
        } else if (std.mem.eql(u8, r.path, "navigation.speedOverGround")) {
            scalar(&own_sog, r, mono);
        } else if (std.mem.eql(u8, r.path, "navigation.courseOverGroundTrue")) {
            scalar(&own_cog, r, mono);
        }
    }
}

fn scalar(dst: *Scalar, r: lk.Reading, mono: i64) void {
    if (r.removed()) {
        dst.stamp.clear();
        return;
    }
    dst.set(r.number() orelse return, r.age_ms, mono);
}

/// Own ship as cpa.zig wants it, or null when there is no usable fix.
///
/// A missing or stale speed reads as stopped rather than disabling the CPA:
/// the traffic's own motion is most of the closing rate, and a target bearing
/// down on a boat whose log has failed is still worth an alarm.
fn ownState(mono: i64) ?cpa.State {
    if (!own_pos.fresh(mono)) return null;
    return .{
        .lat = own_lat,
        .lon = own_lon,
        .sog_mps = own_sog.get(mono) orelse 0,
        .cog_deg = own_cog.get(mono) orelse 0,
    };
}

// ---- the target table ---------------------------------------------------------

fn find(mmsi: u32) ?*Tracked {
    for (tracked[0..n_tracked]) |*e| {
        if (e.mmsi == mmsi) return e;
    }
    return null;
}

fn findOrAdd(mmsi: u32) ?*Tracked {
    if (find(mmsi)) |e| return e;
    if (n_tracked == max_targets) {
        if (!table_full_logged) {
            table_full_logged = true;
            lk.logf(.warn, "target table full at {d}; further targets are not drawn", .{max_targets});
        }
        return null;
    }
    const e = &tracked[n_tracked];
    n_tracked += 1;
    e.* = .{ .mmsi = mmsi };
    return e;
}

/// Drop entry `i`, filling the hole with the last one. Order carries no
/// meaning here, so this is the cheap removal.
fn removeAt(i: usize) void {
    n_tracked -= 1;
    tracked[i] = tracked[n_tracked];
}

// ---- the rebuild --------------------------------------------------------------

/// What one target in the snapshot resolves to. Computed in a first pass so
/// the overlay batch can emit every delete before any set, which is what the
/// builder requires.
///
/// `e` points into the table, which no pass moves an entry in until the prune
/// at the end of the rebuild.
const Plan = struct {
    e: ?*Tracked = null,
    draw: bool = false,
    danger: bool = false,
    /// The shape this target draws as. An aid to navigation is a diamond, and
    /// a virtual one a broken diamond.
    sym: lk.Sym = .target,
    rot_deg: f64 = 0,
    /// The reported heading, if the target sent one. The heading line uses
    /// this alone. The symbol's rotation may fall back to course over ground;
    /// the heading line may not.
    hdg_deg: ?f64 = null,
    cog_deg: ?f64 = null,
    sog_mps: ?f64 = null,
    /// The closest-approach solution, when own ship's fix allowed one.
    sol: ?cpa.Solution = null,
    /// The two lines, resolved here because the delete pass must know which
    /// are absent, and every delete goes out before the first set.
    hdg_line: ?[2][2]f64 = null,
    vec_line: ?[2][2]f64 = null,
};

/// Shortest payload that could carry a target. A parse failure and an empty
/// snapshot both come back as no targets, and the two must not be treated
/// alike: an empty snapshot means the water is clear, a parse failure means we
/// do not know. Anything longer than this that yielded nothing is the second.
const min_nonempty_payload = 64;

fn rebuild(payload: []const u8) void {
    const mono = lk.monoMs();
    const list = lk.targets(payload);
    if (list.len == 0 and payload.len > min_nonempty_payload) {
        lk.logf(.warn, "unreadable ais snapshot of {d} bytes; keeping what is drawn", .{payload.len});
        return;
    }
    const own = ownState(mono);

    const plans = lk.scratch().alloc(Plan, list.len) catch {
        lk.logf(.warn, "ais snapshot of {d} targets did not fit", .{list.len});
        return;
    };

    for (tracked[0..n_tracked]) |*e| {
        e.seen = false;
        e.want = false;
    }

    var danger_count: usize = 0;
    for (list, plans) |t, *plan| {
        plan.* = .{};
        const e = findOrAdd(t.mmsi) orelse continue;
        plan.e = e;
        e.seen = true;
        e.aton = t.aton;
        e.stamp(t.age_ms, mono);

        if (!t.hasPosition() or t.age_ms > e.staleMs() or settings.hidden(t.sog, t.aton)) {
            // Off the chart, and out of the gate: a target that has stopped
            // reporting may alarm again when it comes back.
            e.in_gate = false;
            continue;
        }
        plan.draw = true;
        e.want = true;

        if (t.aton) {
            // An aid to navigation has no heading, no course and nowhere to
            // go: one symbol, and a warning if it says it has drifted.
            plan.sym = if (t.virtual_aton) .aton_virtual else .aton;
            if (aton.wantsWarning(t.virtual_aton, t.off_position, e.warned)) {
                e.warned = true;
                offPositionWarning(t);
            } else if (aton.rearm(t.off_position)) e.warned = false;
            continue;
        }

        // Heading is where the hull points and course over ground is where it
        // is going. The symbol claims the first, and falls back to the second,
        // and to north when the target reports neither.
        plan.rot_deg = t.heading orelse t.cog orelse 0;
        plan.hdg_deg = t.heading;
        plan.cog_deg = t.cog;
        plan.sog_mps = t.sog;

        const at = vec.Point{ .lat = t.lat.?, .lon = t.lon.? };
        plan.hdg_line = vec.ray(at, t.heading, vec.heading_line_m);
        plan.vec_line = vec.ray(at, t.cog, vec.vectorLengthFor(t.sog orelse 0, settings.vector_seconds));

        const o = own orelse {
            e.in_gate = false;
            continue;
        };
        const sol = cpa.solve(o, .{
            .lat = t.lat.?,
            .lon = t.lon.?,
            .sog_mps = t.sog orelse 0,
            .cog_deg = t.cog orelse t.heading orelse 0,
        });
        plan.sol = sol;
        // With the alarm switched off there is no danger colour either: the
        // mariner chose silence, and a red triangle nobody hears is worse than
        // no red triangle.
        plan.danger = settings.cpa_alarm and sol.dangerous(settings.cpa_limit_m, settings.tcpa_limit_s);
        if (plan.danger) danger_count += 1;
        if (plan.danger and !e.in_gate) alarm(t, sol);
        e.in_gate = plan.danger;
    }

    // Deletes first: the builder drops a del that follows a set, and the host
    // applies deletes before sets in any case. A target owns three objects and
    // loses all three together.
    var b = Batch.begin();
    for (tracked[0..n_tracked]) |*e| {
        if (!e.drawn or e.want) continue;
        b.delTarget(e.mmsi);
        e.drawn = false;
    }
    // A drawn target that stopped reporting a heading, or slowed below the
    // vector gate, loses that one line. Deleting a line that is not there is a
    // no-op host side, so this needs no memory of the last pass.
    for (list, plans) |t, plan| {
        // An aid to navigation never had either line to lose.
        if (!plan.draw or plan.sym != .target) continue;
        if (plan.hdg_line == null) b.del(t.mmsi, .hdg);
        if (plan.vec_line == null) b.del(t.mmsi, .vec);
    }

    var drawn_count: usize = 0;
    for (list, plans) |t, plan| {
        if (!plan.draw) continue;
        b.drawTarget(t, plan, mono);
        drawn_count += 1;
        if (plan.e) |e| e.drawn = true;
    }
    b.flush();

    // Targets gone from the snapshot are gone from the table; their symbols
    // were deleted above.
    var i: usize = 0;
    while (i < n_tracked) {
        if (tracked[i].seen) i += 1 else removeAt(i);
    }

    had_snapshot = true;
    setStatus(if (own == null) .degraded else .running, drawn_count, danger_count);
}

/// Age targets out between snapshots and keep the status line current.
fn sweep() void {
    const mono = lk.monoMs();
    var b = Batch.begin();
    var drawn_count: usize = 0;
    var danger_count: usize = 0;

    var i: usize = 0;
    while (i < n_tracked) {
        const e = &tracked[i];
        const age = e.ageMs(mono);
        if (age > e.staleMs()) {
            if (e.drawn) {
                b.delTarget(e.mmsi);
                e.drawn = false;
            }
            e.in_gate = false;
            if (age > e.forgetMs()) {
                removeAt(i);
                continue;
            }
        }
        if (e.drawn) drawn_count += 1;
        if (e.in_gate) danger_count += 1;
        i += 1;
    }
    b.flush();

    const s: State =
        if (!had_snapshot) .starting else if (own_pos.fresh(mono)) .running else .degraded;
    setStatus(s, drawn_count, danger_count);
}

// ---- output -------------------------------------------------------------------

/// Overlay object ids: `t` and the MMSI for the symbol, plus `/hdg` and
/// `/vec` for the two lines. The host namespaces them per plugin. Longest is
/// "t" + 10 digits + "/hdg" = 15.
const id_len = 16;

const Id = enum {
    symbol,
    hdg,
    vec,

    fn suffix(self: Id) []const u8 {
        return switch (self) {
            .symbol => "",
            .hdg => "/hdg",
            .vec => "/vec",
        };
    }
};

fn objectId(buf: *[id_len]u8, mmsi: u32, which: Id) []const u8 {
    return std.fmt.bufPrint(buf, "t{d}{s}", .{ mmsi, which.suffix() }) catch buf[0..0];
}

/// An overlay batch that starts a new call rather than overflowing its buffer.
/// Deletes go before sets within one call, and the split keeps every delete
/// ahead of every set across the whole rebuild. The host applies calls in
/// order, and nothing here deletes an id it has already set this pass.
const Batch = struct {
    ov: lk.Overlay,
    objs: usize = 0,

    fn begin() Batch {
        return .{ .ov = lk.Overlay.init(&ov_buf) };
    }

    /// Send what is buffered and start a fresh call.
    fn restart(self: *Batch) void {
        _ = self.ov.send();
        self.ov = lk.Overlay.init(&ov_buf);
        self.objs = 0;
    }

    fn room(self: *Batch) void {
        if (self.objs == objs_per_batch) self.restart();
        self.objs += 1;
    }

    fn del(self: *Batch, mmsi: u32, which: Id) void {
        self.room();
        var idb: [id_len]u8 = undefined;
        self.ov.del(objectId(&idb, mmsi, which));
    }

    /// Drop everything one target owns. Deleting an object that is not there
    /// is a no-op host side.
    fn delTarget(self: *Batch, mmsi: u32) void {
        for ([_]Id{ .symbol, .hdg, .vec }) |which| self.del(mmsi, which);
    }

    /// One target: the triangle, the heading line and the speed vector. An aid
    /// to navigation is the symbol alone.
    fn drawTarget(self: *Batch, t: lk.Target, plan: Plan, mono: i64) void {
        const color: lk.Color = if (plan.danger)
            .target_danger
            // An aid that has drifted off its charted position is a hazard in
            // the wrong place: it takes the warning colour.
        else if (t.aton and (t.off_position orelse false))
            .warning
        else
            .target;
        var idb: [id_len]u8 = undefined;

        self.room();
        var pick: PickRows = .{};
        pick.fill(t, plan, mono);
        self.ov.symbolPick(
            objectId(&idb, t.mmsi, .symbol),
            plan.sym,
            t.lon.?,
            t.lat.?,
            plan.rot_deg,
            color,
            1.0,
            pick.title(t),
            pick.rows(),
        );

        if (plan.hdg_line) |line| {
            self.room();
            self.ov.polyline(objectId(&idb, t.mmsi, .hdg), &line, vec.line_width_pt, color, false);
        }
        if (plan.vec_line) |line| {
            self.room();
            self.ov.polyline(objectId(&idb, t.mmsi, .vec), &line, vec.line_width_pt, color, true);
        }
    }

    /// Sending an empty batch is a no-op in the builder, so this is safe to
    /// call whether or not anything was added.
    fn flush(self: *Batch) void {
        _ = self.ov.send();
    }
};

/// What a hover over a target says. Fixed buffers: the lk arena resets when
/// the event handler returns.
///
/// UNITS. These are display strings in knots, degrees, metres and minutes,
/// formatted here. That breaks the rule that units convert in the core. See
/// PROTOTYPE-CONCERNS.md.
const PickRows = struct {
    /// Room for every row `fill` can add: MMSI, SOG, COG, HDG, CPA, TCPA, Age.
    buf: [7][40]u8 = undefined,
    store: [7][2][]const u8 = undefined,
    n: usize = 0,
    name_buf: [max_name]u8 = undefined,

    fn add(self: *PickRows, key: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (self.n == self.buf.len) return;
        const v = std.fmt.bufPrint(&self.buf[self.n], fmt, args) catch return;
        self.store[self.n] = .{ key, v };
        self.n += 1;
    }

    fn fill(self: *PickRows, t: lk.Target, plan: Plan, mono: i64) void {
        self.add("MMSI", "{d}", .{t.mmsi});
        if (t.aton) {
            self.add("Type", "{s}", .{aton.navaidName(t.aton_type)});
            self.add("Virtual", "{s}", .{if (t.virtual_aton) "yes" else "no"});
            if (t.off_position) |off| self.add("Off position", "{s}", .{if (off) "YES" else "no"});
            if (plan.e) |e| self.add("Age", "{d} s", .{@divTrunc(e.ageMs(mono), 1000)});
            return;
        }
        if (plan.sog_mps) |s| self.add("SOG", "{d:.1} kn", .{s * kn_per_mps});
        if (plan.cog_deg) |c| self.add("COG", "{d:.0}\u{00b0}", .{c});
        if (plan.hdg_deg) |hh| self.add("HDG", "{d:.0}\u{00b0}", .{hh});
        // CPA and TCPA only when own ship's fix allowed the solve, and only
        // while the target is still closing.
        if (plan.sol) |sol| {
            if (sol.tcpa_s) |tc| {
                if (tc >= 0) {
                    self.add("CPA", "{d:.0} m", .{sol.cpa_m});
                    self.add("TCPA", "{d:.1} min", .{tc / 60.0});
                }
            }
        }
        if (plan.e) |e| self.add("Age", "{d} s", .{@divTrunc(e.ageMs(mono), 1000)});
    }

    /// The name the target reports, or its MMSI.
    fn title(self: *PickRows, t: lk.Target) []const u8 {
        if (t.name) |n| {
            if (n.len > 0) return n[0..@min(n.len, max_name)];
        }
        if (t.aton) return std.fmt.bufPrint(&self.name_buf, "AtoN {d}", .{t.mmsi}) catch "Aid to navigation";
        return std.fmt.bufPrint(&self.name_buf, "MMSI {d}", .{t.mmsi}) catch "AIS target";
    }

    fn rows(self: *PickRows) []const [2][]const u8 {
        return self.store[0..self.n];
    }
};

/// The name to put in an alert, or the MMSI when the target has not sent one.
fn whoIs(buf: *[max_name]u8, t: lk.Target) []const u8 {
    if (t.name) |n| {
        if (n.len > 0) return n[0..@min(n.len, max_name)];
    }
    return std.fmt.bufPrint(buf, "{d}", .{t.mmsi}) catch "unknown";
}

/// One warning for an aid to navigation that says it has left its charted
/// position. A warning, not an alarm: the buoy is in the wrong place, which is
/// a reason to distrust it, not a collision in the next ten minutes.
fn offPositionWarning(t: lk.Target) void {
    var who_buf: [max_name]u8 = undefined;
    var body: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{s} ({s}) reports itself off position", .{
        whoIs(&who_buf, t),
        aton.navaidName(t.aton_type),
    }) catch return;
    _ = lk.raiseAlert(.warning, "AtoN off position", text);
}

/// One alarm, on the edge into the gate.
fn alarm(t: lk.Target, sol: cpa.Solution) void {
    var who_buf: [max_name]u8 = undefined;
    const who = whoIs(&who_buf, t);

    var body: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{s}: CPA {d:.0} m in {d:.0} s", .{
        who,
        sol.cpa_m,
        sol.tcpa_s orelse 0,
    }) catch return;
    _ = lk.raiseAlert(.alarm, "AIS CPA alarm", text);
}

/// The host keeps the last status per plugin and only logs a change, so
/// posting one on every snapshot and every sweep costs nothing when nothing
/// moved.
fn setStatus(s: State, drawn: usize, danger: usize) void {
    switch (s) {
        .starting => lk.status("starting", "waiting for targets", .{}),
        // Silence a mariner chose has to look different from silence that is
        // broken, so the line says so for as long as the alarm is off.
        .running => if (settings.cpa_alarm)
            lk.status("running", "{d} targets, {d} in CPA alarm", .{ drawn, danger })
        else
            lk.status("running", "{d} targets, alarms off", .{drawn}),
        .degraded => lk.status("degraded", "{d} targets, no own position: no CPA", .{drawn}),
        .stopped => lk.status("stopped", "shut down", .{}),
    }
}
