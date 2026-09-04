//! The AIS target store: MMSI-keyed, upserted, aged and evicted.
//!
//! A target arrives in pieces — a position report every few seconds, a static
//! report with the name every few minutes — so an update merges: fields the
//! caller leaves null keep the value they had. Each target carries the time it
//! was last updated: a triangle which stopped updating is the dangerous case,
//! so consumers get the age and present staleness before the target is
//! dropped.
//!
//! Provenance is per target, not per field: a target belongs to the source that
//! last updated it, and `clearSource` drops the targets that source owns. That
//! keeps disable-clears working with one MMSI reachable from two receivers.
//!
//! No wall clock is read here — `ts_ms` and `now_ms` come from the caller, so
//! the host, the replay harness and the tests agree.
//!
//! Locking: one mutex around the whole store, taken by the host's publish and
//! fanout threads. The render thread reads a snapshot, never the live map.

const std = @import("std");
const store = @import("store.zig");

pub const SourceId = store.SourceId;
const Lock = store.Lock;

/// The longest name the wire format carries: a vessel's static report has 20
/// characters, and an aid to navigation may add a 14-character extension.
pub const max_name = 34;

/// Distinct MMSIs held at once. The busiest harbours run a few thousand live
/// targets; without a cap a publisher inventing MMSIs grows the set forever,
/// and the memory budgets never see host-side growth.
pub const max_targets = 4096;

/// A target not heard from for this long is gone. 600 s is well past the
/// slowest class A static report, so it only fires when the target really has
/// left range or switched off.
pub const default_evict_ms: i64 = 600_000;

/// An aid to navigation transmits about every three minutes, so the vessel
/// limit would drop one that is still on station and still talking. Thirty
/// minutes is ten missed reports.
pub const default_aton_evict_ms: i64 = 1_800_000;

/// How much older than the stored target an update's KINEMATICS may be and
/// still apply. Within it reports merge, because stamps from different clocks
/// jitter by seconds. Past it the position, course and speed are outranked: a
/// minutes-old relay must not walk a live contact backward.
///
/// IT DOES NOT GATE IDENTITY. What a vessel is called is as true six minutes
/// late as it is now, and a class A ship broadcasts her name only every six
/// minutes — so an internet relay replaying her last static report, with its
/// own original time, is minutes behind her position stream every time.
/// Measured against a live feed of a busy approach, gating identity on this
/// threw away 88% of it and left a chart of anonymous triangles. Identity is
/// weighed against `Target.static_ts_ms` instead: the most recent thing the
/// vessel SAID ABOUT HERSELF wins.
pub const stale_drop_ms: i64 = 10_000;

/// One target. The name lives inline so a snapshot is a plain copy with no
/// pointers back into the store.
pub const Target = struct {
    mmsi: u32,
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Speed over ground, METRES PER SECOND. The AIS wire format reports
    /// knots; converting is the parsing plugin's job, so everything above this
    /// store — navigation.speedOverGround, the CPA math, the overlay — reads
    /// one unit and never has to ask which.
    sog: ?f64 = null,
    /// Course over ground, degrees true in [0,360).
    cog: ?f64 = null,
    /// True heading, degrees in [0,360).
    heading: ?f64 = null,
    name_buf: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,
    /// True once the target has reported as an aid to navigation. An AtoN ages
    /// on its own clock and gets no CPA: it is not going anywhere.
    aton: bool = false,
    /// The navaid type, 0..31, as type 21 carries it.
    aton_type: ?u8 = null,
    /// True for an aid with nothing in the water: a station broadcasts it.
    virtual_aton: bool = false,
    /// True when the aid reports itself off its charted position. Null when it
    /// has never said either way.
    off_position: ?bool = null,
    /// When this target was last updated, as the caller stamped it.
    ts_ms: i64 = 0,
    /// When the IDENTITY was last updated. Arbitrated on its own, because a
    /// vessel's name does not go stale the way her position does — see
    /// `stale_drop_ms`. Zero until one has been heard.
    static_ts_ms: i64 = 0,
    /// The source that last updated it.
    source: SourceId = 0,
    /// True when the last update came over the internet rather than from a
    /// receiver on the boat. Follows the writer like `source` does.
    net: bool = false,

    pub fn name(self: *const Target) ?[]const u8 {
        return if (self.name_len == 0) null else self.name_buf[0..self.name_len];
    }

    pub fn ageMs(self: Target, now_ms: i64) i64 {
        return now_ms - self.ts_ms;
    }

    /// True when the target has both halves of a position, which is what the
    /// overlay needs before it can draw anything.
    pub fn hasPosition(self: Target) bool {
        return self.lat != null and self.lon != null;
    }
};

/// One `ais_upsert` entry. Null fields are absent, not zero: they leave the
/// stored value alone.
pub const Update = struct {
    mmsi: u32,
    lat: ?f64 = null,
    lon: ?f64 = null,
    sog: ?f64 = null,
    cog: ?f64 = null,
    heading: ?f64 = null,
    name: ?[]const u8 = null,
    /// Set true by a type 21 report. Never set back to false: a target that
    /// has once identified as an aid to navigation stays one.
    aton: ?bool = null,
    aton_type: ?u8 = null,
    virtual_aton: ?bool = null,
    off_position: ?bool = null,
    /// Deliberately not optional: like `source`, provenance follows every
    /// FRESHEST write, so a receiver update clears the flag an internet
    /// update set.
    net: bool = false,
    ts_ms: i64,
};

pub const Error = error{
    /// MMSI 0 is the wire's "no identity"; it cannot key a target.
    InvalidMmsi,
    /// Half a position, an out-of-range one, or a non-finite number.
    InvalidPosition,
    InvalidNumber,
    /// max_targets distinct MMSIs are held; a NEW one is refused until one
    /// ages out. Known targets keep updating.
    TargetSetFull,
};

/// True when the update says something about WHAT the target is rather than
/// where it is or where it is going. These are the facts a vessel broadcasts
/// on her own slow schedule, and they are why an outranked report is still
/// worth reading.
fn carriesIdentity(u: Update) bool {
    return u.name != null or u.aton != null or u.aton_type != null or
        u.virtual_aton != null or u.off_position != null;
}

pub const AisStore = struct {
    alloc: std.mem.Allocator,
    mu: Lock = .{},
    targets: std.AutoHashMapUnmanaged(u32, Target) = .empty,
    evict_after_ms: i64 = default_evict_ms,
    aton_evict_after_ms: i64 = default_aton_evict_ms,
    seq_no: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) AisStore {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *AisStore) void {
        self.targets.deinit(self.alloc);
        self.* = undefined;
    }

    /// Merge one update into the target set and stamp it with `source_id`. An
    /// update always refreshes the target's timestamp, including a static
    /// report that carries nothing but a name — hearing the target at all is
    /// what age measures. False when the update was outranked by a fresher
    /// report and did not land (see `stale_drop_ms`).
    pub fn upsert(self: *AisStore, u: Update, source_id: SourceId) !bool {
        if (u.mmsi == 0) return Error.InvalidMmsi;
        if ((u.lat == null) != (u.lon == null)) return Error.InvalidPosition;
        if (u.lat) |lat| {
            const lon = u.lon.?;
            if (!std.math.isFinite(lat) or !std.math.isFinite(lon)) return Error.InvalidPosition;
            if (@abs(lat) > 90 or @abs(lon) > 180) return Error.InvalidPosition;
        }
        inline for (.{ u.sog, u.cog, u.heading }) |maybe| {
            if (maybe) |v| if (!std.math.isFinite(v)) return Error.InvalidNumber;
        }

        self.mu.lock();
        defer self.mu.unlock();

        if (self.targets.count() >= max_targets and !self.targets.contains(u.mmsi))
            return Error.TargetSetFull;

        // Is this report materially older than the one stored? Its KINEMATICS
        // are refused if so; its identity is weighed separately below.
        var outranked = false;
        if (self.targets.get(u.mmsi)) |existing| {
            outranked = existing.ts_ms - u.ts_ms > stale_drop_ms;
        }
        // Nothing to say and outranked besides: leave no phantom target. Both
        // checks happen before the entry exists, which is what makes that true.
        if (outranked and !carriesIdentity(u)) return false;

        const gop = try self.targets.getOrPut(self.alloc, u.mmsi);
        if (!gop.found_existing) gop.value_ptr.* = .{ .mmsi = u.mmsi };
        const tgt = gop.value_ptr;

        // Whether this update changed anything at all, which is what the
        // return and the change counter both mean.
        var applied = false;

        // The freshest report wins the kinematics. Kinematics from the older
        // report would walk a live contact backward a few seconds every time
        // a relayed copy of it lands.
        const newer = !outranked and u.ts_ms >= tgt.ts_ms;
        if (newer) {
            if (u.lat) |v| tgt.lat = v;
            if (u.lon) |v| tgt.lon = v;
            if (u.sog) |v| tgt.sog = v;
            // Angles are canonical in [0,360) so consumers never rotate a
            // symbol by a negative or a wrapped bearing.
            if (u.cog) |v| tgt.cog = wrap360(v);
            if (u.heading) |v| tgt.heading = wrap360(v);
            tgt.source = source_id;
            tgt.net = u.net;
            applied = true;
        }

        // IDENTITY IS WEIGHED AGAINST IDENTITY. Not against the position
        // stream, which runs minutes ahead of every static report and would
        // refuse nearly all of them; and not unconditionally either, or an
        // ancient replay would overwrite a newer name. The most recent thing
        // the vessel said about herself is what the mariner reads.
        if (carriesIdentity(u) and u.ts_ms >= tgt.static_ts_ms) {
            if (u.name) |n| {
                const trimmed = std.mem.trim(u8, n, " ");
                const len = @min(trimmed.len, max_name);
                @memcpy(tgt.name_buf[0..len], trimmed[0..len]);
                tgt.name_len = @intCast(len);
            }
            // An aid to navigation reports its nature every time; a position
            // report from the same MMSI must not take it away again.
            if (u.aton) |v| {
                if (v) tgt.aton = true;
            }
            if (u.aton_type) |v| tgt.aton_type = v;
            if (u.virtual_aton) |v| tgt.virtual_aton = v;
            if (u.off_position) |v| tgt.off_position = v;
            tgt.static_ts_ms = u.ts_ms;
            applied = true;
        }

        // Neither a merging near-tie nor an outranked report may walk the age
        // backward: age measures when the target was last HEARD.
        tgt.ts_ms = @max(tgt.ts_ms, u.ts_ms);
        if (applied) self.seq_no +%= 1;
        return applied;
    }

    /// A copy of one target, or null when the MMSI is unknown.
    pub fn get(self: *AisStore, mmsi: u32) ?Target {
        self.mu.lock();
        defer self.mu.unlock();
        return self.targets.get(mmsi);
    }

    pub fn count(self: *AisStore) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.targets.count();
    }

    /// A change counter. The AIS_CHANGED fanout is capped at 2 Hz, so the host
    /// compares this against the value it last sent and skips the snapshot when
    /// nothing moved.
    pub fn seq(self: *AisStore) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.seq_no;
    }

    /// Every target, copied, sorted by MMSI. Sorted because a hash map iterates
    /// in an order that shifts with insertions, and both the AIS_CHANGED
    /// payload and the harness's golden output have to be reproducible. The
    /// caller frees the slice with the allocator it passed.
    pub fn snapshot(self: *AisStore, alloc: std.mem.Allocator) ![]Target {
        self.mu.lock();
        defer self.mu.unlock();

        const out = try alloc.alloc(Target, self.targets.count());
        errdefer alloc.free(out);
        var i: usize = 0;
        var it = self.targets.valueIterator();
        while (it.next()) |v| : (i += 1) out[i] = v.*;
        std.mem.sort(Target, out, {}, byMmsi);
        return out;
    }

    /// Drop targets older than the limit for their kind — `evict_after_ms` for
    /// a vessel, `aton_evict_after_ms` for an aid to navigation. Returns how
    /// many went. Age is measured strictly, so a target exactly at the limit
    /// survives one more tick. The host calls this on its fanout tick.
    pub fn evict(self: *AisStore, now_ms: i64) !usize {
        return self.removeWhere(.{ .older_than = now_ms });
    }

    /// Drop every target the source owns — the target set half of "disable
    /// clears". A target whose last update came from another source stays, so
    /// two receivers seeing the same MMSI do not blank each other out.
    pub fn clearSource(self: *AisStore, source_id: SourceId) !usize {
        return self.removeWhere(.{ .source = source_id });
    }

    const Predicate = union(enum) { older_than: i64, source: SourceId };

    /// Collect first, then remove: modifying a hash map while iterating it is
    /// not defined, and the target set is tens of entries, not thousands.
    fn removeWhere(self: *AisStore, pred: Predicate) !usize {
        self.mu.lock();
        defer self.mu.unlock();

        var doomed: std.ArrayList(u32) = .empty;
        defer doomed.deinit(self.alloc);
        var it = self.targets.iterator();
        while (it.next()) |e| {
            const hit = switch (pred) {
                .older_than => |now_ms| blk: {
                    // A stamp in the future means the wall clock stepped
                    // back; left alone the target could never be overwritten
                    // or evicted. Repaired here, in the pass that already
                    // walks every target each tick.
                    if (e.value_ptr.ts_ms > now_ms) e.value_ptr.ts_ms = now_ms;
                    // The identity stamp gates identity the same way, so a
                    // future one would freeze the name just as surely.
                    if (e.value_ptr.static_ts_ms > now_ms) e.value_ptr.static_ts_ms = now_ms;
                    break :blk e.value_ptr.ageMs(now_ms) >
                        if (e.value_ptr.aton) self.aton_evict_after_ms else self.evict_after_ms;
                },
                .source => |sid| e.value_ptr.source == sid,
            };
            if (hit) try doomed.append(self.alloc, e.key_ptr.*);
        }
        for (doomed.items) |mmsi| _ = self.targets.remove(mmsi);
        if (doomed.items.len > 0) self.seq_no +%= 1;
        return doomed.items.len;
    }
};

fn byMmsi(_: void, a: Target, b: Target) bool {
    return a.mmsi < b.mmsi;
}

fn wrap360(deg: f64) f64 {
    const m = @mod(deg, 360.0);
    return if (m < 0) m + 360.0 else m;
}

// -- tests -------------------------------------------------------------------

const t = std.testing;

test "an upsert merges fields and leaves the rest alone" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();

    // A position report, then a static report with only the name.
    _ = try s.upsert(.{ .mmsi = 899000404, .lat = 38.98, .lon = -76.47, .sog = 5.1, .cog = 210, .ts_ms = 1_000 }, 1);
    _ = try s.upsert(.{ .mmsi = 899000404, .name = "TANGERINE OTTER", .ts_ms = 2_000 }, 1);

    const a = s.get(899000404).?;
    try t.expectEqualStrings("TANGERINE OTTER", a.name().?);
    try t.expectApproxEqAbs(@as(f64, 38.98), a.lat.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5.1), a.sog.?, 1e-9);
    try t.expectEqual(@as(i64, 2_000), a.ts_ms);
    try t.expect(a.heading == null);

    // A later position report keeps the name.
    _ = try s.upsert(.{ .mmsi = 899000404, .lat = 38.99, .lon = -76.46, .heading = 211, .ts_ms = 3_000 }, 1);
    const b = s.get(899000404).?;
    try t.expectEqualStrings("TANGERINE OTTER", b.name().?);
    try t.expectApproxEqAbs(@as(f64, 38.99), b.lat.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 211), b.heading.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 210), b.cog.?, 1e-9);
    try t.expectEqual(@as(usize, 1), s.count());
}

test "a name is trimmed and truncated, and angles come out canonical" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    _ = try s.upsert(.{ .mmsi = 1, .name = "  MARY ELLEN CARTER OF HALIFAX AND POINTS EAST  ", .cog = -30, .heading = 725, .ts_ms = 0 }, 1);
    const a = s.get(1).?;
    try t.expectEqualStrings("MARY ELLEN CARTER OF HALIFAX AND P", a.name().?);
    try t.expectApproxEqAbs(@as(f64, 330), a.cog.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5), a.heading.?, 1e-9);
}

test "an aid to navigation keeps its nature and gets the AtoN eviction clock" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    _ = try s.upsert(.{
        .mmsi = 998990002,
        .lat = 38.98,
        .lon = -76.47,
        .name = "VIRTUAL WRECK MARK",
        .aton = true,
        .aton_type = 28,
        .virtual_aton = true,
        .off_position = false,
        .ts_ms = 0,
    }, 1);
    // A vessel beside it, heard at the same instant.
    _ = try s.upsert(.{ .mmsi = 899000404, .lat = 38.98, .lon = -76.47, .ts_ms = 0 }, 1);

    const a = s.get(998990002).?;
    try t.expect(a.aton);
    try t.expect(a.virtual_aton);
    try t.expectEqual(@as(u8, 28), a.aton_type.?);
    try t.expect(!a.off_position.?);

    // The vessel goes at ten minutes; the aid stays until thirty.
    try t.expectEqual(@as(usize, 1), try s.evict(600_001));
    try t.expect(s.get(998990002) != null);
    try t.expectEqual(@as(usize, 0), try s.evict(1_800_000));
    try t.expectEqual(@as(usize, 1), try s.evict(1_800_001));
    try t.expect(s.get(998990002) == null);
}

test "an AtoN that also sends a position report stays an AtoN" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    _ = try s.upsert(.{ .mmsi = 998990001, .lat = 38.98, .lon = -76.47, .aton = true, .aton_type = 25, .ts_ms = 0 }, 1);
    _ = try s.upsert(.{ .mmsi = 998990001, .lat = 38.99, .lon = -76.46, .ts_ms = 1_000 }, 1);
    const a = s.get(998990001).?;
    try t.expect(a.aton);
    try t.expectEqual(@as(u8, 25), a.aton_type.?);
    try t.expectApproxEqAbs(@as(f64, 38.99), a.lat.?, 1e-9);
}

test "a target that cannot be drawn is rejected, not stored" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    try t.expectError(Error.InvalidMmsi, s.upsert(.{ .mmsi = 0, .ts_ms = 0 }, 1));
    try t.expectError(Error.InvalidPosition, s.upsert(.{ .mmsi = 1, .lat = 38.9, .ts_ms = 0 }, 1));
    try t.expectError(Error.InvalidPosition, s.upsert(.{ .mmsi = 1, .lat = 91, .lon = 181, .ts_ms = 0 }, 1));
    try t.expectError(Error.InvalidNumber, s.upsert(.{ .mmsi = 1, .sog = std.math.nan(f64), .ts_ms = 0 }, 1));
    try t.expectEqual(@as(usize, 0), s.count());
}

test "age is what the caller's clock says" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    _ = try s.upsert(.{ .mmsi = 7, .lat = 38.9, .lon = -76.4, .ts_ms = 10_000 }, 1);
    try t.expectEqual(@as(i64, 5_000), s.get(7).?.ageMs(15_000));
    try t.expect(s.get(7).?.hasPosition());
}

test "a target is evicted after ten minutes, not before" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    _ = try s.upsert(.{ .mmsi = 2, .lat = 38.9, .lon = -76.4, .ts_ms = 300_000 }, 1);

    try t.expectEqual(@as(usize, 0), try s.evict(600_000)); // exactly 600 s stays
    try t.expectEqual(@as(usize, 1), try s.evict(600_001));
    try t.expect(s.get(1) == null);
    try t.expect(s.get(2) != null);

    // Hearing from a target resets its age.
    _ = try s.upsert(.{ .mmsi = 2, .lat = 38.91, .lon = -76.4, .ts_ms = 800_000 }, 1);
    try t.expectEqual(@as(usize, 0), try s.evict(1_000_000));
    try t.expectEqual(@as(usize, 1), s.count());
}

test "clearing a source drops the targets it owns and keeps the others" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    _ = try s.upsert(.{ .mmsi = 2, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 2);
    // A second receiver hears target 3 last, so target 3 becomes its target.
    _ = try s.upsert(.{ .mmsi = 3, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    _ = try s.upsert(.{ .mmsi = 3, .lat = 38.91, .lon = -76.4, .ts_ms = 1_000 }, 2);

    try t.expectEqual(@as(usize, 1), try s.clearSource(1));
    try t.expect(s.get(1) == null);
    try t.expect(s.get(2) != null);
    try t.expect(s.get(3) != null);
    try t.expectEqual(@as(SourceId, 2), s.get(3).?.source);

    try t.expectEqual(@as(usize, 2), try s.clearSource(2));
    try t.expectEqual(@as(usize, 0), s.count());
}

test "a snapshot is sorted, self-contained and detached from the store" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    _ = try s.upsert(.{ .mmsi = 300, .lat = 1, .lon = 1, .name = "C", .ts_ms = 0 }, 1);
    _ = try s.upsert(.{ .mmsi = 100, .lat = 1, .lon = 1, .name = "A", .ts_ms = 0 }, 1);
    _ = try s.upsert(.{ .mmsi = 200, .lat = 1, .lon = 1, .name = "B", .ts_ms = 0 }, 1);

    const snap = try s.snapshot(t.allocator);
    defer t.allocator.free(snap);
    try t.expectEqual(@as(usize, 3), snap.len);
    try t.expectEqual(@as(u32, 100), snap[0].mmsi);
    try t.expectEqual(@as(u32, 200), snap[1].mmsi);
    try t.expectEqual(@as(u32, 300), snap[2].mmsi);
    try t.expectEqualStrings("A", snap[0].name().?);
    try t.expectEqual(@as(i64, 4_000), snap[0].ageMs(4_000));

    // Later store changes do not reach a snapshot already taken.
    _ = try s.clearSource(1);
    try t.expectEqual(@as(usize, 0), s.count());
    try t.expectEqualStrings("A", snap[0].name().?);
}

test "the freshest report wins, and only a near-tie merges" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    const base: i64 = 100_000;

    // A live receiver contact: a materially older relayed report loses its
    // KINEMATICS whole — the position, the provenance and the source all stay
    // the live contact's. What it says about the vessel's identity is not
    // stale in the same way and lands, which is what it landed for.
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.98, .lon = -76.47, .ts_ms = base }, 1);
    try t.expect(try s.upsert(.{ .mmsi = 1, .lat = 40.0, .lon = -70.0, .name = "GHOST", .net = true, .ts_ms = base - stale_drop_ms - 1 }, 2));
    const a = s.get(1).?;
    try t.expectApproxEqAbs(@as(f64, 38.98), a.lat.?, 1e-9);
    try t.expectEqualStrings("GHOST", a.name().?);
    try t.expect(!a.net);
    try t.expectEqual(@as(SourceId, 1), a.source);
    // And the age still measures the live contact, not the old replay.
    try t.expectEqual(@as(i64, base), a.ts_ms);

    // Carrying nothing but outranked kinematics, it lands nothing and says so.
    try t.expect(!try s.upsert(.{ .mmsi = 1, .lat = 41.0, .lon = -71.0, .ts_ms = base - stale_drop_ms - 1 }, 2));
    try t.expectApproxEqAbs(@as(f64, 38.98), s.get(1).?.lat.?, 1e-9);

    // A near-tie merges its STATIC facts: a static report seconds behind the
    // position race still lands its name — but the age never walks backward,
    // the kinematics stay the fresher report's, and so does the provenance.
    try t.expect(try s.upsert(.{ .mmsi = 1, .lat = 40.0, .lon = -70.0, .name = "TIN WHISTLE", .net = true, .ts_ms = base - 1_000 }, 2));
    const b = s.get(1).?;
    try t.expectEqualStrings("TIN WHISTLE", b.name().?);
    try t.expectEqual(@as(i64, base), b.ts_ms);
    try t.expectApproxEqAbs(@as(f64, 38.98), b.lat.?, 1e-9);
    try t.expect(!b.net);
    try t.expectEqual(@as(SourceId, 1), b.source);

    // A newer receiver report reclaims it, and the flag follows the writer.
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.99, .lon = -76.46, .ts_ms = base + 2_000 }, 1);
    const c = s.get(1).?;
    try t.expect(!c.net);
    try t.expectApproxEqAbs(@as(f64, 38.99), c.lat.?, 1e-9);

    // The rule is symmetric: a stale receiver replay loses to a fresher
    // internet report already stored.
    _ = try s.upsert(.{ .mmsi = 2, .lat = 40.0, .lon = -70.0, .net = true, .ts_ms = base }, 2);
    try t.expect(!try s.upsert(.{ .mmsi = 2, .lat = 38.9, .lon = -76.4, .ts_ms = base - stale_drop_ms - 1 }, 1));
    try t.expect(s.get(2).?.net);
    try t.expectApproxEqAbs(@as(f64, 40.0), s.get(2).?.lat.?, 1e-9);
}

test "a relay's static report still names a vessel its position stream outran" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    // Epoch milliseconds, because the ages in play here are tens of minutes.
    const now: i64 = 1_754_400_000_000;

    // THE SHAPE THE INTERNET RELAY ACTUALLY SENDS, and the reason this rule
    // is split. A class A ship broadcasts her identity every six minutes and
    // her position every few seconds, so the relay's snapshot replays a type 5
    // that is minutes behind the position stream — measured against a live
    // feed of a busy approach, a median of twenty-odd minutes behind. Gated on
    // the position, 88% of it was refused and the mariner read a chart of
    // anonymous triangles.
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.98, .lon = -76.47, .sog = 6.0, .ts_ms = now }, 1);
    try t.expect(try s.upsert(.{
        .mmsi = 1,
        // The relay hangs the last known position on every event, including
        // this one. It is the old one, and it must not win.
        .lat = 20.0,
        .lon = -30.0,
        .name = "TANGERINE OTTER",
        .ts_ms = now - 22 * 60 * 1000,
    }, 1));

    const a = s.get(1).?;
    try t.expectEqualStrings("TANGERINE OTTER", a.name().?);
    // The live contact keeps where she is, how fast, and how long ago.
    try t.expectApproxEqAbs(@as(f64, 38.98), a.lat.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 6.0), a.sog.?, 1e-9);
    try t.expectEqual(@as(i64, now), a.ts_ms);

    // Identity is weighed against identity: an older static report than the
    // one already applied cannot overwrite the name with a staler one...
    try t.expect(!try s.upsert(.{ .mmsi = 1, .name = "WRONG", .ts_ms = now - 30 * 60 * 1000 }, 1));
    try t.expectEqualStrings("TANGERINE OTTER", s.get(1).?.name().?);

    // ...and a newer one renames her, which is what a vessel correcting her
    // static report looks like.
    try t.expect(try s.upsert(.{ .mmsi = 1, .name = "TIN WHISTLE", .ts_ms = now - 60_000 }, 1));
    try t.expectEqualStrings("TIN WHISTLE", s.get(1).?.name().?);
}

test "an outranked update leaves no phantom target behind" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    // The MMSI is unknown, so however ancient the stamp, the first report
    // creates the target...
    _ = try s.upsert(.{ .mmsi = 9, .lat = 1, .lon = 1, .ts_ms = 50_000 }, 1);
    const seq_before = s.seq();
    // ...but one outranked against it must not create or touch anything.
    try t.expect(!try s.upsert(.{ .mmsi = 9, .lat = 2, .lon = 2, .ts_ms = 10_000 }, 2));
    try t.expectEqual(seq_before, s.seq());
    try t.expectEqual(@as(usize, 1), s.count());
}

test "a wall clock that stepped back is repaired on the eviction tick" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    // Stamped before the clock stepped back: the store now holds the future.
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 700_000 }, 1);
    // A live report on the corrected clock would be outranked...
    try t.expect(!try s.upsert(.{ .mmsi = 1, .lat = 38.91, .lon = -76.4, .ts_ms = 100_000 }, 1));
    // ...until the tick clamps the stored stamp to now, and life goes on.
    try t.expectEqual(@as(usize, 0), try s.evict(100_000));
    try t.expect(try s.upsert(.{ .mmsi = 1, .lat = 38.91, .lon = -76.4, .ts_ms = 100_001 }, 1));
    try t.expectApproxEqAbs(@as(f64, 38.91), s.get(1).?.lat.?, 1e-9);
}

test "the change counter moves only when the target set does" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    const start = s.seq();
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    try t.expect(s.seq() != start);

    const after_upsert = s.seq();
    try t.expectEqual(@as(usize, 0), try s.evict(1_000)); // nothing old enough
    try t.expectEqual(after_upsert, s.seq());
    try t.expectEqual(@as(usize, 1), try s.evict(700_000));
    try t.expect(s.seq() != after_upsert);
}

test "a full target set refuses a new MMSI and keeps updating known ones" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    var mmsi: u32 = 1;
    while (mmsi <= max_targets) : (mmsi += 1) {
        _ = try s.upsert(.{ .mmsi = mmsi, .ts_ms = 0 }, 1);
    }
    try t.expectError(Error.TargetSetFull, s.upsert(.{ .mmsi = max_targets + 1, .ts_ms = 0 }, 1));
    _ = try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 5 }, 1);
    try t.expectEqual(@as(i64, 5), s.get(1).?.ts_ms);
    // Eviction makes room again.
    try t.expectEqual(@as(usize, max_targets), try s.evict(700_000));
    _ = try s.upsert(.{ .mmsi = max_targets + 1, .ts_ms = 700_001 }, 1);
}
