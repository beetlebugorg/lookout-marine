//! The AIS target store: MMSI-keyed, upserted, aged and evicted.
//!
//! A target arrives in pieces — a position report every few seconds, a static
//! report with the name every few minutes — so an update merges: fields the
//! caller leaves null keep the value they had. Each target carries the time it
//! was last updated, because specs/plugins/data-model.md is explicit that a
//! triangle which stopped updating is the dangerous case: consumers get the age
//! and present staleness before the target is dropped.
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

/// ITU-R M.1371 static data carries a 20 character vessel name.
pub const max_name = 20;

/// A target not heard from for this long is gone. 600 s is well past the
/// slowest class A static report, so it only fires when the target really has
/// left range or switched off.
pub const default_evict_ms: i64 = 600_000;

/// One target. The name lives inline so a snapshot is a plain copy with no
/// pointers back into the store.
pub const Target = struct {
    mmsi: u32,
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Speed over ground, knots as AIS reports it.
    sog: ?f64 = null,
    /// Course over ground, degrees true in [0,360).
    cog: ?f64 = null,
    /// True heading, degrees in [0,360).
    heading: ?f64 = null,
    name_buf: [max_name]u8 = [_]u8{0} ** max_name,
    name_len: u8 = 0,
    /// When this target was last updated, as the caller stamped it.
    ts_ms: i64 = 0,
    /// The source that last updated it.
    source: SourceId = 0,

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
    ts_ms: i64,
};

pub const Error = error{
    /// MMSI 0 is the wire's "no identity"; it cannot key a target.
    InvalidMmsi,
    /// Half a position, an out-of-range one, or a non-finite number.
    InvalidPosition,
    InvalidNumber,
};

pub const AisStore = struct {
    alloc: std.mem.Allocator,
    mu: Lock = .{},
    targets: std.AutoHashMapUnmanaged(u32, Target) = .empty,
    evict_after_ms: i64 = default_evict_ms,
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
    /// what age measures.
    pub fn upsert(self: *AisStore, u: Update, source_id: SourceId) !void {
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

        const gop = try self.targets.getOrPut(self.alloc, u.mmsi);
        if (!gop.found_existing) gop.value_ptr.* = .{ .mmsi = u.mmsi };
        const tgt = gop.value_ptr;

        if (u.lat) |v| tgt.lat = v;
        if (u.lon) |v| tgt.lon = v;
        if (u.sog) |v| tgt.sog = v;
        // Angles are canonical in [0,360) so consumers never rotate a symbol by
        // a negative or a wrapped bearing.
        if (u.cog) |v| tgt.cog = wrap360(v);
        if (u.heading) |v| tgt.heading = wrap360(v);
        if (u.name) |n| {
            const trimmed = std.mem.trim(u8, n, " ");
            const len = @min(trimmed.len, max_name);
            @memcpy(tgt.name_buf[0..len], trimmed[0..len]);
            tgt.name_len = @intCast(len);
        }
        tgt.ts_ms = u.ts_ms;
        tgt.source = source_id;
        self.seq_no +%= 1;
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

    /// Drop targets older than `evict_after_ms`; returns how many went. Age is
    /// measured strictly, so a target exactly at the limit survives one more
    /// tick. The host calls this on its fanout tick.
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
                .older_than => |now_ms| e.value_ptr.ageMs(now_ms) > self.evict_after_ms,
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
    try s.upsert(.{ .mmsi = 366123456, .lat = 38.98, .lon = -76.47, .sog = 5.1, .cog = 210, .ts_ms = 1_000 }, 1);
    try s.upsert(.{ .mmsi = 366123456, .name = "EVER GIVEN", .ts_ms = 2_000 }, 1);

    const a = s.get(366123456).?;
    try t.expectEqualStrings("EVER GIVEN", a.name().?);
    try t.expectApproxEqAbs(@as(f64, 38.98), a.lat.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5.1), a.sog.?, 1e-9);
    try t.expectEqual(@as(i64, 2_000), a.ts_ms);
    try t.expect(a.heading == null);

    // A later position report keeps the name.
    try s.upsert(.{ .mmsi = 366123456, .lat = 38.99, .lon = -76.46, .heading = 211, .ts_ms = 3_000 }, 1);
    const b = s.get(366123456).?;
    try t.expectEqualStrings("EVER GIVEN", b.name().?);
    try t.expectApproxEqAbs(@as(f64, 38.99), b.lat.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 211), b.heading.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 210), b.cog.?, 1e-9);
    try t.expectEqual(@as(usize, 1), s.count());
}

test "a name is trimmed and truncated, and angles come out canonical" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    try s.upsert(.{ .mmsi = 1, .name = "  MARY ELLEN CARTER LONG NAME  ", .cog = -30, .heading = 725, .ts_ms = 0 }, 1);
    const a = s.get(1).?;
    try t.expectEqualStrings("MARY ELLEN CARTER LO", a.name().?);
    try t.expectApproxEqAbs(@as(f64, 330), a.cog.?, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 5), a.heading.?, 1e-9);
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
    try s.upsert(.{ .mmsi = 7, .lat = 38.9, .lon = -76.4, .ts_ms = 10_000 }, 1);
    try t.expectEqual(@as(i64, 5_000), s.get(7).?.ageMs(15_000));
    try t.expect(s.get(7).?.hasPosition());
}

test "a target is evicted after ten minutes, not before" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    try s.upsert(.{ .mmsi = 2, .lat = 38.9, .lon = -76.4, .ts_ms = 300_000 }, 1);

    try t.expectEqual(@as(usize, 0), try s.evict(600_000)); // exactly 600 s stays
    try t.expectEqual(@as(usize, 1), try s.evict(600_001));
    try t.expect(s.get(1) == null);
    try t.expect(s.get(2) != null);

    // Hearing from a target resets its age.
    try s.upsert(.{ .mmsi = 2, .lat = 38.91, .lon = -76.4, .ts_ms = 800_000 }, 1);
    try t.expectEqual(@as(usize, 0), try s.evict(1_000_000));
    try t.expectEqual(@as(usize, 1), s.count());
}

test "clearing a source drops the targets it owns and keeps the others" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    try s.upsert(.{ .mmsi = 2, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 2);
    // A second receiver hears target 3 last, so target 3 becomes its target.
    try s.upsert(.{ .mmsi = 3, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    try s.upsert(.{ .mmsi = 3, .lat = 38.91, .lon = -76.4, .ts_ms = 1_000 }, 2);

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
    try s.upsert(.{ .mmsi = 300, .lat = 1, .lon = 1, .name = "C", .ts_ms = 0 }, 1);
    try s.upsert(.{ .mmsi = 100, .lat = 1, .lon = 1, .name = "A", .ts_ms = 0 }, 1);
    try s.upsert(.{ .mmsi = 200, .lat = 1, .lon = 1, .name = "B", .ts_ms = 0 }, 1);

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

test "the change counter moves only when the target set does" {
    var s = AisStore.init(t.allocator);
    defer s.deinit();
    const start = s.seq();
    try s.upsert(.{ .mmsi = 1, .lat = 38.9, .lon = -76.4, .ts_ms = 0 }, 1);
    try t.expect(s.seq() != start);

    const after_upsert = s.seq();
    try t.expectEqual(@as(usize, 0), try s.evict(1_000)); // nothing old enough
    try t.expectEqual(after_upsert, s.seq());
    try t.expectEqual(@as(usize, 1), try s.evict(700_000));
    try t.expect(s.seq() != after_upsert);
}
