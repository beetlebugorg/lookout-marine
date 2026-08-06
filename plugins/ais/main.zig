//! AIS: draws the other traffic and shouts when one of them is going to hit
//! you.
//!
//! One overlay object per target — a `target` symbol at its last reported
//! position, rotated to true heading where the target sends one and to course
//! over ground where it does not. The set is rebuilt from the full snapshot
//! the host delivers on every AIS_CHANGED, so a target that stops reporting,
//! or that the host evicts, loses its symbol without this plugin keeping a
//! diff of what the chart is showing.
//!
//! THE ALARM. Every AIS_CHANGED, each target with a position is run against
//! own ship through cpa.zig. A target whose closest approach is inside
//! `cpa_alarm_m` and still ahead of us by less than `tcpa_alarm_s` is drawn
//! `target_danger` and raises one alarm — ONE. The gate state is kept per
//! MMSI, so the alarm re-arms only after that target leaves the gate. Without
//! that, a target closing for ten minutes would raise twelve hundred alarms
//! and the twelve-hundredth would mean nothing.
//!
//! WITHOUT OWN POSITION there is no relative motion to compute, so targets are
//! still drawn — where the traffic is remains worth knowing — but nothing is
//! flagged and the status line says degraded. A CPA computed against a
//! position an hour old is not a conservative estimate, it is a wrong one.
//!
//! WHY A TIMER AS WELL. The 180-second age rule is time passing, not an event.
//! A harbour where every target goes quiet at once produces no AIS_CHANGED,
//! and the symbols would sit on the chart until one of them spoke again. A
//! 1 Hz sweep ages them out and keeps the status line honest.

const std = @import("std");
const lk = @import("lk");
const cpa = @import("cpa.zig");

comptime {
    lk.registerPlugin(@This());
}

// ---- the numbers, all in one place -----------------------------------------

/// A target not heard from for this long stops being drawn. PROTOTYPE.md's
/// rule. The host's own eviction is 600 s, so between the two the target is
/// still in the store — it just is not on the chart claiming to be somewhere.
const stale_target_ms: i64 = 180_000;

/// A target this old is dropped from the plugin's table too. It cannot come
/// back without a fresh AIS_CHANGED, which would build the entry again.
const forget_target_ms: i64 = 600_000;

/// Own ship values older than this are not usable for a CPA. Same window as
/// the vessel store's default and as the ownship plugin's.
const max_own_age_ms: i64 = 10_000;

/// The danger gate: half a nautical mile, ten minutes.
const cpa_alarm_m: f64 = 926.0;
const tcpa_alarm_s: f64 = 600.0;

/// Age sweep and status rate.
const sweep_ms: i64 = 1000;

/// Targets tracked at once. Beyond this the extras are not drawn; a prototype
/// running in a place with 256 targets in range has other problems.
const max_targets: usize = 256;

/// Symbols per overlay call. Deletes all go in the first batch, so this bounds
/// `ov_buf` whatever the target count.
const sets_per_batch: usize = 40;

/// Longest vessel name put in an alarm body. The AIS wire format allows 20.
const max_name = 32;

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

const State = enum { starting, running, degraded, stopped };

// ---- lifecycle ---------------------------------------------------------------

pub fn start(s: lk.Start) !void {
    _ = s;
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
        .ais_changed => |payload| rebuild(payload),
        .store_changed => |payload| ingest(payload),
        .timer => sweep(),
        // The host drops a plugin's overlay objects when it stops it, so
        // there is nothing to delete here.
        .shutdown => setStatus(.stopped, 0, 0),
        else => {},
    }
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
    rot_deg: f64 = 0,
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
        e.stamp(t.age_ms, mono);

        if (!t.hasPosition() or t.age_ms > stale_target_ms) {
            // Off the chart, and out of the gate: a target that has stopped
            // reporting may alarm again when it comes back.
            e.in_gate = false;
            continue;
        }
        plan.draw = true;
        e.want = true;
        // Heading is where the hull points and course over ground is where it
        // is going. The symbol claims the first, and falls back to the second,
        // and to north when the target reports neither.
        plan.rot_deg = t.heading orelse t.cog orelse 0;

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
        plan.danger = sol.dangerous(cpa_alarm_m, tcpa_alarm_s);
        if (plan.danger) danger_count += 1;
        if (plan.danger and !e.in_gate) alarm(t, sol);
        e.in_gate = plan.danger;
    }

    // Deletes first: the builder drops a del that follows a set, and the host
    // applies deletes before sets in any case.
    var b = Batch.begin();
    for (tracked[0..n_tracked]) |*e| {
        if (!e.drawn or e.want) continue;
        var idb: [id_len]u8 = undefined;
        b.del(objectId(&idb, e.mmsi));
        e.drawn = false;
    }

    var drawn_count: usize = 0;
    for (list, plans) |t, plan| {
        if (!plan.draw) continue;
        var idb: [id_len]u8 = undefined;
        b.symbol(
            objectId(&idb, t.mmsi),
            t.lon.?,
            t.lat.?,
            plan.rot_deg,
            if (plan.danger) .target_danger else .target,
        );
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
        if (age > stale_target_ms) {
            if (e.drawn) {
                var idb: [id_len]u8 = undefined;
                b.del(objectId(&idb, e.mmsi));
                e.drawn = false;
            }
            e.in_gate = false;
            if (age > forget_target_ms) {
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

/// Overlay object ids: `t` and the MMSI. The host namespaces them per plugin,
/// so nothing else can collide with them.
const id_len = 12;

fn objectId(buf: *[id_len]u8, mmsi: u32) []const u8 {
    return std.fmt.bufPrint(buf, "t{d}", .{mmsi}) catch buf[0..0];
}

/// An overlay batch that starts a new call rather than overflowing its buffer.
/// Deletes must all be emitted before the first symbol; after that the batch
/// may split anywhere, because two calls carrying different ids mean the same
/// thing as one call carrying both.
const Batch = struct {
    ov: lk.Overlay,
    sets: usize = 0,

    fn begin() Batch {
        return .{ .ov = lk.Overlay.init(&ov_buf) };
    }

    fn del(self: *Batch, id: []const u8) void {
        self.ov.del(id);
    }

    fn symbol(self: *Batch, id: []const u8, lon: f64, lat: f64, rot_deg: f64, color: lk.Color) void {
        if (self.sets == sets_per_batch) {
            _ = self.ov.send();
            self.ov = lk.Overlay.init(&ov_buf);
            self.sets = 0;
        }
        self.ov.symbol(id, .target, lon, lat, rot_deg, color, 1.0);
        self.sets += 1;
    }

    /// Sending an empty batch is a no-op in the builder, so this is safe to
    /// call whether or not anything was added.
    fn flush(self: *Batch) void {
        _ = self.ov.send();
    }
};

/// One alarm, on the edge into the gate.
fn alarm(t: lk.Target, sol: cpa.Solution) void {
    var who_buf: [max_name]u8 = undefined;
    const who = blk: {
        if (t.name) |n| {
            if (n.len > 0) break :blk n[0..@min(n.len, max_name)];
        }
        break :blk std.fmt.bufPrint(&who_buf, "{d}", .{t.mmsi}) catch "unknown";
    };

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
        .running => lk.status("running", "{d} targets, {d} in CPA alarm", .{ drawn, danger }),
        .degraded => lk.status("degraded", "{d} targets, no own position: no CPA", .{drawn}),
        .stopped => lk.status("stopped", "shut down", .{}),
    }
}
