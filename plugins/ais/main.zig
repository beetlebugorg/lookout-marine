//! AIS: draws the other traffic and alarms on a close approach.
//!
//! Up to three overlay objects per target:
//!
//!   t<mmsi>       the triangle, rotated to heading, else course over ground
//!   t<mmsi>/hdg   the heading line, solid
//!   t<mmsi>/vec   the speed vector, dashed, as long as `vector_min` says
//!
//! `draw` describes every target it wants on the chart once a second, and the
//! library takes off what it did not describe. A target that stops reporting,
//! slows under the gate or drops its heading loses exactly what it stopped
//! earning, and this file keeps no memory of what is drawn.
//!
//! TWO PATHS. `onUpdate` decides and `draw` renders. Every report that arrives
//! is run through the gate at once, whatever rate the chart is being drawn at;
//! `draw` colours each target from the decision waiting for it in `gates`. A
//! decision taken in `draw` would run at whatever rate suits the picture, and
//! the picture is not what a collision alarm answers to.
//!
//! The targets dialog is on the deciding path too. A row is the ruling in
//! `gates` written out, so `evaluate` fills it and the mariner reads the same
//! set the chart is coloured from. The rows keep coming while the chart grant
//! is off, because a table is data and filling one is not something a plugin
//! asks permission for.
//!
//! AIDS TO NAVIGATION share the store and nothing else. A buoy is not going
//! anywhere, so it gets one object — a diamond, broken open when the aid is
//! virtual — with no CPA, no vector and no heading line, and it ages on its own
//! slower clock. A physical aid that reports itself off station raises one
//! warning.
//!
//! SETTINGS, all applied hot, all declared in config.zig: the gate's two
//! limits, the alarm switch, the vector time, and the speed under which a
//! vessel is not drawn. The library redraws on a change, so a new limit shows
//! in that same call rather than at the next report.
//!
//! THE ALARM. Every drawn vessel is run against own ship through cpa.zig. A
//! target inside `cpa_limit` and less than `tcpa_limit` ahead is drawn
//! `target_danger` and raises one alarm. The gate state is per MMSI, in
//! `gates` below: the alarm fires on the edge into the gate and re-arms only
//! after that target leaves it. The edge is what holds the alarm to one however
//! often the values arrive. The alert is keyed on the MMSI, so the host holds
//! one alert per vessel and a mariner who silences one has silenced that
//! vessel. The body names the vessel and nothing that moves; CPA and TCPA are
//! on the chart and in the dialog, live.
//!
//! WITHOUT OWN POSITION there is no relative motion to compute, which is why
//! own ship's three values are optional inputs: the traffic is still drawn,
//! nothing is flagged, and the status line says degraded.

const std = @import("std");
const lk = @import("lk2");
const cpa = @import("cpa.zig");
const vec = @import("vector.zig");
const cfg = @import("config.zig");
const aton = @import("aton.zig");
const vessel_names = @import("vessel.zig");
const targets = @import("targets.zig");

comptime {
    lk.plugin(@This());
}

pub const Settings = cfg.groups;

/// The targets dialog: the same set this file draws, in a sortable table, with
/// the alarmed vessels held at the top by their band. Declared in targets.zig;
/// named here because the library reads the plugin's root for what it declares.
/// `evaluate` fills it.
pub const Targets = targets.Targets;

// ---- the numbers, all in one place -----------------------------------------

/// A target not heard from for this long stops being drawn. The host evicts
/// at 600 s; between the two limits the target is in the store but not drawn.
const stale_target_ms: i64 = 180_000;

/// An aid to navigation reports about every three minutes, so the vessel limit
/// would undraw one that is still on station. Undraw at ten minutes; the store
/// evicts an aid at thirty.
const stale_aton_ms: i64 = 600_000;

/// Own ship values older than this are not usable for a CPA. Longer than the
/// library's 5 s window on purpose: a fix a few seconds old still gives a CPA
/// worth acting on, and v1 of this plugin used the same number.
const max_own_age_ms: i64 = 10_000;

/// Targets kept at once. Beyond this the extras are not drawn; a prototype
/// running in a place with 256 targets in range has other problems.
const max_targets: usize = 256;

/// The buffer that names a target with no reported name: "AtoN " or "MMSI "
/// and up to ten digits. A name the target did report is the library's, capped
/// at 32 bytes, and is used as it comes.
const max_name = 34;

/// The buffer an alert's dedup key is written into: a condition name and up to
/// ten digits of MMSI.
const max_key = 24;

pub const inputs = struct {
    /// The traffic. The library records each snapshot and ages it; an empty
    /// sea is not a missing instrument, so this never holds the draw back.
    ///
    /// The two windows are the ages at which `visible` stops drawing a target,
    /// so the library wakes this plugin the moment one crosses its own limit.
    /// A target that stops reporting leaves the chart and the dialog together
    /// whether or not any other target is still being heard.
    pub const traffic = lk.subscribeAis(.{
        .max = max_targets,
        .max_age_ms = stale_target_ms,
        .aton_max_age_ms = stale_aton_ms,
    });

    /// Own ship. All three are optional: the CPA needs them and the drawing
    /// does not, so a boat with no GPS still sees the traffic.
    pub const boat = lk.subscribePosition("navigation.position", .{
        .optional = true,
        .max_age_ms = max_own_age_ms,
    });
    pub const sog = lk.subscribeNumber("navigation.speedOverGround", .{
        .optional = true,
        .max_age_ms = max_own_age_ms,
    });
    pub const cog = lk.subscribeNumber("navigation.courseOverGroundTrue", .{
        .optional = true,
        .max_age_ms = max_own_age_ms,
    });
};

// ---- state that outlives one pass ------------------------------------------

/// What this plugin decided about one MMSI, and what it remembers between
/// decisions. Where the target is and how old its report is are the library's;
/// what is here is this plugin's own ruling on it, which `draw` renders.
const Gate = struct {
    mmsi: u32 = 0,
    /// True while the target is inside the danger gate. The alarm fires on the
    /// false→true edge only.
    in_gate: bool = false,
    /// True once the off-position warning has gone out for this aid. Cleared
    /// when it reports itself back on station.
    warned: bool = false,
    /// In the snapshot the last evaluation walked. Scratch for one pass.
    seen: bool = false,
    /// The approach the last evaluation solved, or null when own ship's fix
    /// would not allow one. The triangle's colour, the hover and the table row
    /// all read this, so none of the three can disagree with the alarm.
    sol: ?cpa.Solution = null,
};

var gates: [max_targets]Gate = @splat(.{});
var n_gates: usize = 0;

/// Set once when the table has overflowed, so the warning is logged once
/// rather than on every evaluation forever.
var table_full_logged: bool = false;

// ---- lifecycle ---------------------------------------------------------------

/// Every input is optional, so the library has nothing to name while it waits.
/// Say what this plugin is waiting for.
pub fn onStart(_: lk.raw.Start) !void {
    lk.say(.starting, "waiting for targets", .{});
}

/// A settings change is applied by the library, which then redraws. The gate
/// is re-run first, so the new limits rule that redraw rather than the next
/// report. The line is what a mariner's change looks like in the host log.
pub fn onSettings() void {
    const s = cfg.Tuned.now();
    lk.log(.info, "settings: cpa {d:.0} m, tcpa {d:.0} s, alarm {}, vector {d:.0} s, min sog {d:.2} m/s", .{
        s.cpa_limit_m,
        s.tcpa_limit_s,
        s.cpa_alarm,
        s.vector_seconds,
        s.min_sog_mps,
    });
    evaluate();
}

// ---- the decision ----------------------------------------------------------

/// New values have landed: own ship's position, or the whole AIS set.
pub fn onUpdate() void {
    evaluate();
}

/// Run every target against own ship and leave the ruling in its gate.
///
/// This is where the alarm is raised. The gate's edge is what holds one
/// approach to one alarm: the reports arrive faster than the chart is drawn,
/// and a target that stays inside the gate is already accounted for.
fn evaluate() void {
    const set = cfg.Tuned.now();
    const own = ownShip();

    for (gates[0..n_gates]) |*g| g.seen = false;
    for (inputs.traffic.targets()) |*t| {
        const g = gateFor(t.mmsi) orelse continue;
        g.seen = true;
        g.sol = null;

        // Off the chart, and out of the gate: a target that has stopped
        // reporting, slowed under the mariner's limit or lost its position may
        // alarm again when it comes back.
        if (!visible(t, set)) {
            g.in_gate = false;
            continue;
        }
        if (t.aton) {
            checkAid(t, g);
            if (Targets.isOpen()) targets.aid(t, t.at.?, own);
            continue;
        }
        const at = t.at.?;
        const sol = if (own) |o| cpa.solve(o, .{
            .lat = at.lat,
            .lon = at.lon,
            .sog_mps = t.sog_mps orelse 0,
            .cog_deg = t.cog_deg orelse t.heading_deg orelse 0,
        }) else null;
        g.sol = sol;

        // With the alarm switched off there is no danger colour either: the
        // mariner chose silence, and a red triangle nobody hears is worse than
        // no red triangle.
        const in_gate = set.cpa_alarm and if (sol) |s|
            s.dangerous(set.cpa_limit_m, set.tcpa_limit_s)
        else
            false;
        if (in_gate and !g.in_gate) alarm(t);
        g.in_gate = in_gate;

        // The row carries the solution the triangle is coloured by, so the
        // table and the chart cannot disagree about which vessel is dangerous.
        if (Targets.isOpen()) targets.vessel(t, at, own, sol, in_gate);
    }
    prune();
}

/// One aid to navigation's own ruling: a warning the first time it says it has
/// drifted, re-armed when it reports itself back on station.
fn checkAid(t: *const lk.Target, g: *Gate) void {
    if (aton.wantsWarning(t.virtual_aton, t.off_position, g.warned)) {
        g.warned = true;
        offPositionWarning(t);
    } else if (aton.rearm(t.off_position)) g.warned = false;
}

/// True when a target belongs on the chart: it has a position, it has been
/// heard from recently enough, and it is not under the speed the mariner set.
/// Applied on both paths, so the picture and the ruling cover the same set.
fn visible(t: *const lk.Target, set: cfg.Tuned) bool {
    if (t.at == null) return false;
    if (t.age_ms > staleMs(t.aton)) return false;
    return !set.hidden(t.sog_mps, t.aton);
}

// ---- the scene ----------------------------------------------------------------

pub fn draw(c: *lk.Chart) void {
    const set = cfg.Tuned.now();
    const own = ownShip();

    var drawn: usize = 0;
    var danger: usize = 0;
    for (inputs.traffic.targets()) |*t| {
        // A target with no gate is one the table had no room for. It is not
        // drawn, exactly as it is not judged.
        const g = gateOf(t.mmsi) orelse continue;
        if (!visible(t, set)) continue;
        const at = t.at.?;

        if (t.aton) {
            drawAid(c, t, at);
        } else {
            drawVessel(c, t, at, g, set);
            if (g.in_gate) danger += 1;
        }
        drawn += 1;
    }

    // Silence a mariner chose has to look different from silence that is
    // broken, so the line says "alarms off" while the switch is off. No own
    // position outranks both: there is no CPA to be silent about.
    if (own == null)
        c.degraded("{d} targets, no own position: no CPA", .{drawn})
    else if (set.cpa_alarm)
        c.status("{d} targets, {d} in CPA alarm", .{ drawn, danger })
    else
        c.status("{d} targets, alarms off", .{drawn});
}

/// One vessel: the triangle, its heading line and its speed vector, coloured
/// by the ruling already in its gate.
fn drawVessel(
    c: *lk.Chart,
    t: *const lk.Target,
    at: lk.Point,
    g: *const Gate,
    set: cfg.Tuned,
) void {
    const sol = g.sol;
    const in_gate = g.in_gate;
    const color: lk.Color = if (in_gate) .target_danger else .target;
    var idb: [id_len]u8 = undefined;
    var pick: Pick = .{};
    pick.vessel(t, sol);
    c.symbol(objectId(&idb, t.mmsi, .symbol), .target, at, .{
        .color = color,
        // Heading is where the hull points and course over ground is where it
        // is going. The symbol claims the first, falls back to the second, and
        // to north when the target reports neither.
        .rot_deg = t.heading_deg orelse t.cog_deg orelse 0,
        .pick = .{ .title = pick.title(t), .rows = pick.rows() },
    });
    // The heading line takes the reported heading alone: a line the target did
    // not claim is a course, not a heading.
    if (vec.ray(at, t.heading_deg, vec.heading_line_m)) |line| {
        c.line(objectId(&idb, t.mmsi, .hdg), &line, .{
            .color = color,
            .width_pt = vec.line_width_pt,
        });
    }
    const reach = vec.vectorLengthFor(t.sog_mps orelse 0, set.vector_seconds);
    if (vec.ray(at, t.cog_deg, reach)) |line| {
        c.line(objectId(&idb, t.mmsi, .vec), &line, .{
            .color = color,
            .width_pt = vec.line_width_pt,
            .dash = true,
        });
    }
}

/// One aid to navigation: the diamond, broken open when the aid is virtual.
fn drawAid(c: *lk.Chart, t: *const lk.Target, at: lk.Point) void {
    var idb: [id_len]u8 = undefined;
    var pick: Pick = .{};
    pick.aid(t);
    c.symbol(
        objectId(&idb, t.mmsi, .symbol),
        if (t.virtual_aton) .aton_virtual else .aton,
        at,
        .{
            // An aid that has drifted off its charted position is a hazard in
            // the wrong place: it takes the warning colour.
            .color = if (t.off_position orelse false) .warning else .target,
            .pick = .{ .title = pick.title(t), .rows = pick.rows() },
        },
    );
}

/// Own ship as cpa.zig wants it, or null when there is no usable fix.
///
/// A missing or stale speed reads as stopped rather than disabling the CPA:
/// the traffic's own motion is most of the closing rate, and a target bearing
/// down on a boat whose log has failed is still worth an alarm.
fn ownShip() ?cpa.State {
    const at = inputs.boat.fresh() orelse return null;
    return .{
        .lat = at.lat,
        .lon = at.lon,
        .sog_mps = inputs.sog.fresh() orelse 0,
        .cog_deg = inputs.cog.fresh() orelse 0,
    };
}

fn staleMs(is_aton: bool) i64 {
    return if (is_aton) stale_aton_ms else stale_target_ms;
}

// ---- the gate table -------------------------------------------------------

/// The ruling on this MMSI, or null when no evaluation has reached it. `draw`
/// reads this and never creates: the gate table is the decision path's.
fn gateOf(mmsi: u32) ?*const Gate {
    for (gates[0..n_gates]) |*g| {
        if (g.mmsi == mmsi) return g;
    }
    return null;
}

fn gateFor(mmsi: u32) ?*Gate {
    for (gates[0..n_gates]) |*g| {
        if (g.mmsi == mmsi) return g;
    }
    if (n_gates == max_targets) {
        if (!table_full_logged) {
            table_full_logged = true;
            lk.log(.warn, "target table full at {d}; further targets are not drawn", .{max_targets});
        }
        return null;
    }
    const g = &gates[n_gates];
    n_gates += 1;
    g.* = .{ .mmsi = mmsi };
    return g;
}

/// Drop the targets this evaluation did not see. They have left the host's
/// snapshot, so nothing is latched for them any more; the last entry fills the
/// hole, because order carries no meaning here.
fn prune() void {
    var i: usize = 0;
    while (i < n_gates) {
        if (gates[i].seen) {
            i += 1;
        } else {
            n_gates -= 1;
            gates[i] = gates[n_gates];
        }
    }
}

// ---- what the mariner reads ------------------------------------------------

/// Overlay object ids: `t` and the MMSI for the symbol, plus `/hdg` and `/vec`
/// for the two lines. The host namespaces them per plugin. Longest is
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

/// What a hover over a target says. Fixed buffers, and it lives only as long as
/// the `c.symbol` call it is passed to: the library serializes the rows there
/// and then.
///
/// UNITS. These are display strings in knots, degrees, metres and minutes,
/// formatted here. That breaks the rule that units convert in the core. See
/// PROTOTYPE-CONCERNS.md.
const max_rows = 15;

const Pick = struct {
    /// Room for every row `vessel` and `aid` can add. A row a target has not
    /// reported is not added at all, so most picks are far shorter than this:
    /// a dash against a label the vessel never sent tells the mariner nothing.
    buf: [max_rows][40]u8 = undefined,
    store: [max_rows][2][]const u8 = undefined,
    n: usize = 0,
    name_buf: [max_name]u8 = undefined,

    fn add(self: *Pick, key: []const u8, comptime fmt: []const u8, args: anytype) void {
        // A row past the end would go missing from the popup with nothing
        // said, which reads exactly like a vessel that never reported it.
        // Say so instead: `max_rows` needs raising.
        if (self.n == self.buf.len) {
            lk.log(.warn, "pick: more than {d} rows; \"{s}\" dropped", .{ max_rows, key });
            return;
        }
        const v = std.fmt.bufPrint(&self.buf[self.n], fmt, args) catch return;
        self.store[self.n] = .{ key, v };
        self.n += 1;
    }

    /// What she is, then what she is doing, then where she is bound, then how
    /// long ago she said so. Identity first because the mariner is matching
    /// the symbol to something out of the window; the approach in the middle
    /// because that is what the hover was for.
    fn vessel(self: *Pick, t: *const lk.Target, sol: ?cpa.Solution) void {
        self.add("MMSI", "{d}", .{t.mmsi});
        if (t.callsign().len > 0) self.add("Call sign", "{s}", .{t.callsign()});
        if (t.imo) |v| self.add("IMO", "{d}", .{v});
        var type_buf: [32]u8 = undefined;
        if (vessel_names.typeName(t.ship_type, &type_buf)) |name| self.add("Type", "{s}", .{name});
        if (vessel_names.statusName(t.nav_status)) |name| self.add("Status", "{s}", .{name});
        if (t.sog_mps) |s| self.add("SOG", "{d:.1} kn", .{lk.knots(s)});
        if (t.cog_deg) |c| self.add("COG", "{d:.0}\u{00b0}", .{c});
        if (t.heading_deg) |h| self.add("HDG", "{d:.0}\u{00b0}", .{h});
        // CPA and TCPA only when own ship's fix allowed the solve, and only
        // while the target is still closing.
        if (sol) |s| {
            if (s.tcpa_s) |tc| {
                if (tc >= 0) {
                    self.add("CPA", "{d:.0} m", .{s.cpa_m});
                    self.add("TCPA", "{d:.1} min", .{tc / 60.0});
                }
            }
        }
        if (t.destination().len > 0) self.add("Bound for", "{s}", .{t.destination()});
        // Length and beam are one fact about how much water she needs beside
        // you, so they read as one row. Either alone is still worth saying.
        if (t.length_m) |l| {
            if (t.beam_m) |b| {
                self.add("Size", "{d} \u{00d7} {d} m", .{ l, b });
            } else {
                self.add("Length", "{d} m", .{l});
            }
        } else if (t.beam_m) |b| {
            self.add("Beam", "{d} m", .{b});
        }
        if (t.draught_m) |d| self.add("Draught", "{d:.1} m", .{d});
        if (vessel_names.className(t.class_b)) |c| self.add("Class", "{s}", .{c});
        self.add("Age", "{d} s", .{@divTrunc(t.age_ms, 1000)});
    }

    fn aid(self: *Pick, t: *const lk.Target) void {
        self.add("MMSI", "{d}", .{t.mmsi});
        self.add("Type", "{s}", .{aton.navaidName(t.aton_type)});
        self.add("Virtual", "{s}", .{if (t.virtual_aton) "yes" else "no"});
        if (t.off_position) |off| self.add("Off position", "{s}", .{if (off) "YES" else "no"});
        self.add("Age", "{d} s", .{@divTrunc(t.age_ms, 1000)});
    }

    /// The name the target reports, or its MMSI.
    fn title(self: *Pick, t: *const lk.Target) []const u8 {
        if (t.name().len > 0) return t.name();
        if (t.aton) return std.fmt.bufPrint(&self.name_buf, "AtoN {d}", .{t.mmsi}) catch "Aid to navigation";
        return std.fmt.bufPrint(&self.name_buf, "MMSI {d}", .{t.mmsi}) catch "AIS target";
    }

    fn rows(self: *Pick) []const [2][]const u8 {
        return self.store[0..self.n];
    }
};

/// The name to put in an alert, or the MMSI when the target has not sent one.
fn whoIs(buf: *[max_name]u8, t: *const lk.Target) []const u8 {
    if (t.name().len > 0) return t.name();
    return std.fmt.bufPrint(buf, "{d}", .{t.mmsi}) catch "unknown";
}

/// The key the host holds one alert under: the condition, then the MMSI. The
/// prefix keeps the two conditions in key spaces of their own, so an aid's
/// warning and a vessel's alarm can never be read as one alert.
fn alertKey(buf: *[max_key]u8, comptime what: []const u8, mmsi: u32) []const u8 {
    return std.fmt.bufPrint(buf, what ++ ":{d}", .{mmsi}) catch buf[0..0];
}

/// One warning for an aid to navigation that says it has left its charted
/// position. A warning, not an alarm: the buoy is in the wrong place, which is
/// a reason to distrust it, not a collision in the next ten minutes.
fn offPositionWarning(t: *const lk.Target) void {
    var who_buf: [max_name]u8 = undefined;
    var key_buf: [max_key]u8 = undefined;
    var body: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{s} ({s}) reports itself off position", .{
        whoIs(&who_buf, t),
        aton.navaidName(t.aton_type),
    }) catch return;
    _ = lk.alertKeyed(alertKey(&key_buf, "aton", t.mmsi), .warning, "AtoN off position", text);
}

/// One alarm, on the edge into the gate.
///
/// The key is the vessel, so the same approach said again is the same alarm
/// and the mariner's acknowledgement holds. NO CPA OR TCPA IN THE BODY: both
/// move every second, and an alert whose words move is one the mariner cannot
/// silence. They are on the chart and in the targets dialog, which is where a
/// figure that moves belongs.
fn alarm(t: *const lk.Target) void {
    var who_buf: [max_name]u8 = undefined;
    var key_buf: [max_key]u8 = undefined;
    var body: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{s} is closing inside your CPA limit", .{
        whoIs(&who_buf, t),
    }) catch return;
    _ = lk.alertKeyed(alertKey(&key_buf, "cpa", t.mmsi), .alarm, "AIS CPA alarm", text);
}
