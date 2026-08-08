//! The vessel path store: Signal K paths, one slot per source per path, an
//! election between sources, staleness by path family, and a coalescing dirty
//! set that drives the host's subscriber fanout.
//!
//! The rules this file carries:
//!
//!   1. Provenance is mandatory — a value is always stored under the source
//!      that published it, never merged into one anonymous cell.
//!   2. Disable clears — `clearSource` drops every slot a source wrote, so a
//!      revoked plugin cannot leave a frozen phantom position behind.
//!   3. Staleness is data — every read carries age and a stale flag, so the
//!      presentation can say "GPS lost" instead of drawing an old fix.
//!   4. Arbitration is host policy — priority is source registration order:
//!      the first-registered source wins while its value is fresh, and a stale
//!      elected value falls back to the next fresh source.
//!
//! No wall clock is read here. The caller injects `ts_ms` on write and
//! `now_ms` on read, so the host, the replay harness and the tests all see the
//! same behavior.
//!
//! Locking: one mutex around the whole store. Publishes and the fanout tick
//! run on host threads; the render thread never touches this.

const std = @import("std");
const builtin = @import("builtin");

/// The same kernel-blocking lock as src/lock.zig, copied rather than imported:
/// `zig test src/plugin/store.zig` roots the module at src/plugin/, so a parent
/// path is not importable. Zig 0.16 has no std.Thread.Mutex — it moved behind
/// an Io that this layer does not take. Method names match src/lock.zig so the
/// two are interchangeable.
pub const Lock = if (builtin.os.tag.isDarwin())
    struct {
        const Handle = extern struct { v: u32 = 0 };
        extern "c" fn os_unfair_lock_lock(l: *Handle) void;
        extern "c" fn os_unfair_lock_unlock(l: *Handle) void;
        h: Handle = .{},
        pub fn lock(self: *@This()) void {
            os_unfair_lock_lock(&self.h);
        }
        pub fn unlock(self: *@This()) void {
            os_unfair_lock_unlock(&self.h);
        }
    }
else if (builtin.os.tag == .windows)
    struct {
        extern "kernel32" fn AcquireSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
        extern "kernel32" fn ReleaseSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
        m: ?*anyopaque = null, // SRWLOCK; null == SRWLOCK_INIT
        pub fn lock(self: *@This()) void {
            AcquireSRWLockExclusive(&self.m);
        }
        pub fn unlock(self: *@This()) void {
            ReleaseSRWLockExclusive(&self.m);
        }
    }
else
    struct {
        // A zeroed pthread_mutex_t is PTHREAD_MUTEX_INITIALIZER on Linux/bionic.
        extern "c" fn pthread_mutex_lock(m: *std.c.pthread_mutex_t) c_int;
        extern "c" fn pthread_mutex_unlock(m: *std.c.pthread_mutex_t) c_int;
        m: std.c.pthread_mutex_t = std.mem.zeroes(std.c.pthread_mutex_t),
        pub fn lock(self: *@This()) void {
            _ = pthread_mutex_lock(&self.m);
        }
        pub fn unlock(self: *@This()) void {
            _ = pthread_mutex_unlock(&self.m);
        }
    };

/// A source is a plugin instance (or a host service) as the host numbers them.
pub const SourceId = u32;

/// A subscription handle. Ids are never reused, so a stale handle is inert.
pub const SubId = u32;

pub const Position = struct { lat: f64, lon: f64 };

/// The value types the prototype carries. Every frozen path in PROTOTYPE.md is
/// a number or a position; `none` is a published null, which reads as "the
/// source has this path but currently has no value".
pub const Value = union(enum) {
    none,
    number: f64,
    position: Position,

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .none => b == .none,
            .number => |x| b == .number and b.number == x,
            .position => |p| b == .position and b.position.lat == p.lat and b.position.lon == p.lon,
        };
    }

    /// Write the value as the JSON the STORE_CHANGED payload carries. Returns
    /// the used part of `buf`; 64 bytes is always enough.
    pub fn toJson(self: Value, buf: []u8) ![]const u8 {
        return switch (self) {
            .none => std.fmt.bufPrint(buf, "null", .{}),
            .number => |n| std.fmt.bufPrint(buf, "{d}", .{n}),
            .position => |p| std.fmt.bufPrint(buf, "{{\"lat\":{d},\"lon\":{d}}}", .{ p.lat, p.lon }),
        };
    }
};

/// What a consumer reads: the elected value plus everything needed to judge it.
pub const Reading = struct {
    value: Value,
    ts_ms: i64,
    age_ms: i64,
    source: SourceId,
    /// True when no source held a value inside its family's staleness window
    /// and this is the most recent stale one.
    stale: bool,
};

/// One coalesced change for a subscriber. `reading` is null when the path has
/// no value at all any more, which is what a subscriber sees after the source
/// that owned the path was cleared.
pub const Change = struct {
    path: []const u8,
    reading: ?Reading,
};

/// Values older than this are stale. One window rules every path: on the
/// water, five seconds without an instrument is the fact a mariner needs to
/// see. Per-family overrides stay possible through setFamilyStaleness.
pub const default_staleness_ms: i64 = 5_000;

const default_families = [_]Family{};

const Family = struct { prefix: []const u8, ms: i64 };

/// A cap on the JSON text of a single value. Plugin input is untrusted and a
/// scalar or a lat/lon pair is tens of bytes.
pub const max_value_json = 512;

const Slot = struct {
    source: SourceId,
    value: Value,
    ts_ms: i64,
};

/// Entries are append-only for the store's lifetime: an index handed to a
/// subscriber or held in a dirty set stays valid, and `clearSource` empties an
/// entry's slots rather than removing it.
const Entry = struct {
    path: []u8,
    staleness_ms: i64,
    slots: std.ArrayList(Slot) = .empty,
    subs: std.ArrayList(SubId) = .empty,
    /// The election result at the last write or refresh, for change detection.
    last: ?Reading = null,
};

const Subscriber = struct {
    owner: SourceId,
    entries: std.ArrayList(u32) = .empty,
    /// Entry indices changed since the last collect. A list rather than a hash
    /// set: a subscriber watches a handful of paths, and the flush order stays
    /// deterministic for tests and for the replay harness.
    dirty: std.ArrayList(u32) = .empty,
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    mu: Lock = .{},
    entries: std.ArrayList(Entry) = .empty,
    /// path → index into `entries`. Keys are the entries' own path bytes.
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// Registration order is priority order: index 0 outranks index 1.
    sources: std.ArrayList(SourceId) = .empty,
    /// Tombstoned so a SubId is never reused.
    subs: std.ArrayList(?Subscriber) = .empty,
    families: std.ArrayList(Family) = .empty,

    pub fn init(alloc: std.mem.Allocator) !Store {
        var s = Store{ .alloc = alloc };
        try s.families.appendSlice(alloc, &default_families);
        return s;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*e| {
            self.alloc.free(e.path);
            e.slots.deinit(self.alloc);
            e.subs.deinit(self.alloc);
        }
        self.entries.deinit(self.alloc);
        self.index.deinit(self.alloc);
        self.sources.deinit(self.alloc);
        for (self.subs.items) |*maybe| {
            if (maybe.*) |*sub| {
                sub.entries.deinit(self.alloc);
                sub.dirty.deinit(self.alloc);
            }
        }
        self.subs.deinit(self.alloc);
        self.families.deinit(self.alloc);
        self.* = undefined;
    }

    // -- sources -------------------------------------------------------------

    /// Put a source in the priority order. Call in the order the mariner's
    /// settings list them, before those sources publish; `set` appends an
    /// unknown source at the end (lowest priority) so a publish is never lost.
    pub fn registerSource(self: *Store, source_id: SourceId) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.ensureSourceLocked(source_id);
    }

    fn ensureSourceLocked(self: *Store, source_id: SourceId) !void {
        for (self.sources.items) |s| if (s == source_id) return;
        try self.sources.append(self.alloc, source_id);
    }

    /// Set the staleness window for every path under `prefix`. The prefix is
    /// borrowed, so it must outlive the store (a literal, in practice).
    pub fn setFamilyStaleness(self: *Store, prefix: []const u8, ms: i64) !void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.families.items) |*f| {
            if (std.mem.eql(u8, f.prefix, prefix)) {
                f.ms = ms;
                break;
            }
        } else try self.families.append(self.alloc, .{ .prefix = prefix, .ms = ms });
        // Entries resolve their window once, at creation, so fix up the ones
        // that already exist.
        for (self.entries.items) |*e| e.staleness_ms = self.stalenessForLocked(e.path);
    }

    fn stalenessForLocked(self: *const Store, path: []const u8) i64 {
        var best: i64 = default_staleness_ms;
        var best_len: usize = 0;
        for (self.families.items) |f| {
            if (std.mem.startsWith(u8, path, f.prefix) and f.prefix.len >= best_len) {
                best = f.ms;
                best_len = f.prefix.len;
            }
        }
        return best;
    }

    // -- writing -------------------------------------------------------------

    /// Publish one path from one source. `value_json` is the raw JSON text of
    /// the `value` field of a publish update: a number, `{"lat":..,"lon":..}`
    /// or `null`. The newest write from a source replaces that source's slot.
    pub fn set(self: *Store, path: []const u8, value_json: []const u8, ts_ms: i64, source_id: SourceId) !void {
        const value = try parseValue(self.alloc, value_json);
        self.mu.lock();
        defer self.mu.unlock();

        try self.ensureSourceLocked(source_id);
        const idx = try self.entryIndexLocked(path);
        const e = &self.entries.items[idx];

        for (e.slots.items) |*slot| {
            if (slot.source == source_id) {
                slot.value = value;
                slot.ts_ms = ts_ms;
                break;
            }
        } else try e.slots.append(self.alloc, .{ .source = source_id, .value = value, .ts_ms = ts_ms });

        // Elect against the write's own timestamp: it is the freshest time the
        // store knows about.
        _ = self.reelectLocked(idx, ts_ms);
    }

    /// Drop everything `source_id` wrote and every subscription it holds. The
    /// paths it owned stay as entries so subscriber indices remain valid; they
    /// simply have no value until something publishes again. The source keeps
    /// its place in the priority order, so re-enabling a plugin restores its
    /// rank rather than demoting it to last.
    pub fn clearSource(self: *Store, source_id: SourceId, now_ms: i64) void {
        self.mu.lock();
        defer self.mu.unlock();

        for (self.entries.items, 0..) |*e, i| {
            var removed = false;
            var k: usize = 0;
            while (k < e.slots.items.len) {
                if (e.slots.items[k].source == source_id) {
                    _ = e.slots.orderedRemove(k);
                    removed = true;
                } else k += 1;
            }
            if (removed) _ = self.reelectLocked(@intCast(i), now_ms);
        }

        for (self.subs.items) |*maybe| {
            const sub = &(maybe.* orelse continue);
            if (sub.owner != source_id) continue;
            sub.entries.deinit(self.alloc);
            sub.dirty.deinit(self.alloc);
            maybe.* = null;
        }
        // Entry->subscriber back-references to the dropped subscribers.
        for (self.entries.items) |*e| {
            var k: usize = 0;
            while (k < e.subs.items.len) {
                const id = e.subs.items[k];
                if (id < self.subs.items.len and self.subs.items[id] != null) {
                    k += 1;
                } else _ = e.subs.orderedRemove(k);
            }
        }
    }

    /// Re-run every election against `now_ms` and dirty the paths whose elected
    /// value changed because time passed — a fix going stale and handing over
    /// to the next source produces no write, so the fanout tick calls this.
    /// Returns the number of paths that changed.
    pub fn refresh(self: *Store, now_ms: i64) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var n: usize = 0;
        for (0..self.entries.items.len) |i| {
            if (self.reelectLocked(@intCast(i), now_ms)) n += 1;
        }
        return n;
    }

    // -- reading -------------------------------------------------------------

    /// The elected value for a path, or null when no source holds one.
    pub fn readElected(self: *Store, path: []const u8, now_ms: i64) ?Reading {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.index.get(path) orelse return null;
        return self.electLocked(&self.entries.items[idx], now_ms);
    }

    // -- subscriptions -------------------------------------------------------

    /// Register a subscriber's path list. Unknown paths are accepted: they get
    /// an empty entry and report as soon as something publishes. Every path is
    /// dirty at once, so the first collect delivers the current state.
    pub fn subscribe(self: *Store, owner: SourceId, paths: []const []const u8) !SubId {
        self.mu.lock();
        defer self.mu.unlock();

        const id: SubId = @intCast(self.subs.items.len);
        var sub = Subscriber{ .owner = owner };
        errdefer {
            sub.entries.deinit(self.alloc);
            sub.dirty.deinit(self.alloc);
        }
        for (paths) |p| {
            const idx = try self.entryIndexLocked(p);
            if (indexOfU32(sub.entries.items, idx) != null) continue;
            try sub.entries.append(self.alloc, idx);
            try sub.dirty.append(self.alloc, idx);
            try self.entries.items[idx].subs.append(self.alloc, id);
        }
        try self.subs.append(self.alloc, sub);
        return id;
    }

    pub fn unsubscribe(self: *Store, sub_id: SubId) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (sub_id >= self.subs.items.len) return;
        const sub = &(self.subs.items[sub_id] orelse return);
        for (sub.entries.items) |idx| {
            const e = &self.entries.items[idx];
            if (indexOfU32(e.subs.items, sub_id)) |at| _ = e.subs.orderedRemove(at);
        }
        sub.entries.deinit(self.alloc);
        sub.dirty.deinit(self.alloc);
        self.subs.items[sub_id] = null;
    }

    /// Append the subscribed paths that changed since the last call and clear
    /// the dirty set. Repeated writes between two calls coalesce into one
    /// change per path, which is what holds the fanout to 10 Hz. The `path`
    /// slices are owned by the store and stay valid until `deinit`. `out` grows
    /// with the store's allocator, so free it with that same allocator.
    pub fn collectChanged(self: *Store, sub_id: SubId, now_ms: i64, out: *std.ArrayList(Change)) !void {
        self.mu.lock();
        defer self.mu.unlock();
        if (sub_id >= self.subs.items.len) return;
        const sub = &(self.subs.items[sub_id] orelse return);
        for (sub.dirty.items) |idx| {
            const e = &self.entries.items[idx];
            try out.append(self.alloc, .{ .path = e.path, .reading = self.electLocked(e, now_ms) });
        }
        sub.dirty.clearRetainingCapacity();
    }

    /// True when the subscriber has anything to collect, so the fanout can skip
    /// the allocation entirely.
    pub fn hasChanges(self: *Store, sub_id: SubId) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (sub_id >= self.subs.items.len) return false;
        const sub = &(self.subs.items[sub_id] orelse return false);
        return sub.dirty.items.len > 0;
    }

    // -- internals -----------------------------------------------------------

    fn entryIndexLocked(self: *Store, path: []const u8) !u32 {
        if (self.index.get(path)) |i| return i;
        const owned = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(owned);
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.alloc, .{
            .path = owned,
            .staleness_ms = self.stalenessForLocked(owned),
        });
        errdefer _ = self.entries.pop();
        try self.index.put(self.alloc, owned, idx);
        return idx;
    }

    /// Priority order with the fresh-first rule. Sources are tried in
    /// registration order; the first one holding a value inside the path's
    /// staleness window wins. If none is fresh, the most recent stale value is
    /// returned flagged stale — a mariner is told the fix is old, not left with
    /// a blank where a boat was.
    fn electLocked(self: *const Store, e: *const Entry, now_ms: i64) ?Reading {
        var stale_best: ?Slot = null;
        for (self.sources.items) |sid| {
            const slot = for (e.slots.items) |s| {
                if (s.source == sid) break s;
            } else continue;
            const age = now_ms - slot.ts_ms;
            if (age <= e.staleness_ms) {
                return .{
                    .value = slot.value,
                    .ts_ms = slot.ts_ms,
                    .age_ms = age,
                    .source = slot.source,
                    .stale = false,
                };
            }
            if (stale_best == null or slot.ts_ms > stale_best.?.ts_ms) stale_best = slot;
        }
        const slot = stale_best orelse return null;
        return .{
            .value = slot.value,
            .ts_ms = slot.ts_ms,
            .age_ms = now_ms - slot.ts_ms,
            .source = slot.source,
            .stale = true,
        };
    }

    /// Re-elect one entry and dirty its subscribers when the elected value, its
    /// timestamp, its source or its staleness changed. Age alone moving on does
    /// not count, or every tick would wake every subscriber.
    fn reelectLocked(self: *Store, idx: u32, now_ms: i64) bool {
        const e = &self.entries.items[idx];
        const now = self.electLocked(e, now_ms);
        const changed = !sameReading(e.last, now);
        e.last = now;
        if (!changed) return false;
        for (e.subs.items) |sid| {
            const sub = &(self.subs.items[sid] orelse continue);
            if (indexOfU32(sub.dirty.items, idx) != null) continue;
            // A dirty mark is a hint, and the dirty set is bounded by the
            // subscription's path count. If the append cannot allocate, the
            // subscriber misses one fanout and gets the value on the next
            // change; failing the publish instead would be worse.
            sub.dirty.append(self.alloc, idx) catch {};
        }
        return true;
    }
};

fn sameReading(a: ?Reading, b: ?Reading) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return a.?.source == b.?.source and a.?.ts_ms == b.?.ts_ms and
        a.?.stale == b.?.stale and a.?.value.eql(b.?.value);
}

fn indexOfU32(items: []const u32, v: u32) ?usize {
    for (items, 0..) |x, i| if (x == v) return i;
    return null;
}

/// Parse the `value` field of a publish update. Anything outside the prototype
/// vocabulary is rejected rather than coerced, so a malformed publish fails
/// loudly at the broker instead of drawing a boat at 0,0.
pub fn parseValue(alloc: std.mem.Allocator, text: []const u8) !Value {
    if (text.len > max_value_json) return error.ValueTooLarge;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch
        return error.InvalidValueJson;
    defer parsed.deinit();
    return switch (parsed.value) {
        .null => .none,
        .integer, .float, .number_string => .{ .number = try jsonNumber(parsed.value) },
        .object => |o| .{ .position = .{
            .lat = try jsonNumber(o.get("lat") orelse return error.UnsupportedValue),
            .lon = try jsonNumber(o.get("lon") orelse return error.UnsupportedValue),
        } },
        else => error.UnsupportedValue,
    };
}

fn jsonNumber(v: std.json.Value) !f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.UnsupportedValue,
        else => error.UnsupportedValue,
    };
}

// -- tests -------------------------------------------------------------------

const t = std.testing;

const pos_a = "{\"lat\":38.9763,\"lon\":-76.4767}";
const pos_b = "{\"lat\":39.0,\"lon\":-76.5}";

test "a value parses as number, position or null" {
    const a = t.allocator;
    try t.expectEqual(@as(f64, 2.9), (try parseValue(a, "2.9")).number);
    try t.expectEqual(@as(f64, 5), (try parseValue(a, "5")).number);
    try t.expect((try parseValue(a, "null")) == .none);
    const p = try parseValue(a, pos_a);
    try t.expectApproxEqAbs(@as(f64, 38.9763), p.position.lat, 1e-9);
    try t.expectApproxEqAbs(@as(f64, -76.4767), p.position.lon, 1e-9);
    try t.expectError(error.UnsupportedValue, parseValue(a, "\"EVER GIVEN\""));
    try t.expectError(error.UnsupportedValue, parseValue(a, "{\"lat\":1}"));
    try t.expectError(error.InvalidValueJson, parseValue(a, "{lat:1}"));
    try t.expectError(error.ValueTooLarge, parseValue(a, "0" ** (max_value_json + 1)));
}

test "a value writes back the JSON the payload carries" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("null", try (Value{ .none = {} }).toJson(&buf));
    try t.expectEqualStrings("2.9", try (Value{ .number = 2.9 }).toJson(&buf));
    try t.expectEqualStrings(
        "{\"lat\":38.9763,\"lon\":-76.4767}",
        try (Value{ .position = .{ .lat = 38.9763, .lon = -76.4767 } }).toJson(&buf),
    );
}

test "the first registered source wins while it is fresh" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    try s.registerSource(1);
    try s.registerSource(2);

    try s.set("navigation.position", pos_a, 1_000, 1);
    try s.set("navigation.position", pos_b, 1_000, 2);

    const r = s.readElected("navigation.position", 1_500).?;
    try t.expectEqual(@as(SourceId, 1), r.source);
    try t.expect(!r.stale);
    try t.expectEqual(@as(i64, 500), r.age_ms);
    try t.expectApproxEqAbs(@as(f64, 38.9763), r.value.position.lat, 1e-9);
}

test "a stale elected value falls back to the next fresh source" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    try s.registerSource(1);
    try s.registerSource(2);

    try s.set("navigation.position", pos_a, 1_000, 1); // the boat's GPS, then silent
    try s.set("navigation.position", pos_b, 20_000, 2); // the phone keeps publishing

    // 20 s after source 1's fix: past the 5 s window, so source 2 is elected.
    const r = s.readElected("navigation.position", 21_000).?;
    try t.expectEqual(@as(SourceId, 2), r.source);
    try t.expect(!r.stale);
    try t.expectApproxEqAbs(@as(f64, 39.0), r.value.position.lat, 1e-9);

    // Source 1 speaks again and takes the path back.
    try s.set("navigation.position", pos_a, 21_000, 1);
    try t.expectEqual(@as(SourceId, 1), s.readElected("navigation.position", 21_100).?.source);
}

test "with every source stale the most recent value reads as stale" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    try s.registerSource(1);
    try s.registerSource(2);
    try s.set("navigation.position", pos_a, 1_000, 1);
    try s.set("navigation.position", pos_b, 5_000, 2);

    const r = s.readElected("navigation.position", 60_000).?;
    try t.expectEqual(@as(SourceId, 2), r.source);
    try t.expect(r.stale);
    try t.expectEqual(@as(i64, 55_000), r.age_ms);
}

test "one staleness window rules every path and a family can be overridden" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    try s.set("environment.wind.directionTrue", "215", 0, 1);
    try s.set("environment.depth.belowTransducer", "2.9", 0, 1);

    try t.expect(!s.readElected("environment.wind.directionTrue", 4_000).?.stale);
    try t.expect(!s.readElected("environment.depth.belowTransducer", 4_000).?.stale);
    try t.expect(s.readElected("environment.wind.directionTrue", 6_000).?.stale);
    try t.expect(s.readElected("environment.depth.belowTransducer", 6_000).?.stale);

    try s.setFamilyStaleness("environment.wind.", 30_000);
    try t.expect(!s.readElected("environment.wind.directionTrue", 20_000).?.stale);
    try t.expect(s.readElected("environment.depth.belowTransducer", 20_000).?.stale);
}

test "an unregistered source publishes at lowest priority" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    try s.registerSource(7);
    try s.set("navigation.headingTrue", "10", 0, 9); // never registered
    try s.set("navigation.headingTrue", "20", 0, 7);
    const r = s.readElected("navigation.headingTrue", 0).?;
    try t.expectEqual(@as(SourceId, 7), r.source);
    try t.expectEqual(@as(f64, 20), r.value.number);
}

test "clearing a source removes what it wrote and nothing else" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    try s.registerSource(1);
    try s.registerSource(2);
    try s.set("navigation.position", pos_a, 1_000, 1);
    try s.set("navigation.position", pos_b, 1_000, 2);
    try s.set("environment.depth.belowTransducer", "2.9", 1_000, 1);

    s.clearSource(1, 1_100);

    const p = s.readElected("navigation.position", 1_100).?;
    try t.expectEqual(@as(SourceId, 2), p.source);
    try t.expect(s.readElected("environment.depth.belowTransducer", 1_100) == null);

    // The cleared source keeps its rank when it comes back.
    try s.set("navigation.position", pos_a, 1_200, 1);
    try t.expectEqual(@as(SourceId, 1), s.readElected("navigation.position", 1_200).?.source);
}

test "a subscriber collects each changed path once per flush" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer out.deinit(t.allocator);

    const sub = try s.subscribe(5, &.{ "navigation.position", "navigation.speedOverGround" });

    // Subscribing dirties the paths so the first flush delivers current state,
    // which is "no value yet" here.
    try t.expect(s.hasChanges(sub));
    try s.collectChanged(sub, 0, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expect(out.items[0].reading == null);
    out.clearRetainingCapacity();

    // Ten writes to one path between flushes coalesce into one change.
    for (0..10) |i| {
        try s.set("navigation.position", pos_a, @intCast(1_000 + i), 1);
    }
    try s.set("environment.depth.belowTransducer", "2.9", 1_000, 1); // not subscribed
    try s.collectChanged(sub, 1_010, &out);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expectEqualStrings("navigation.position", out.items[0].path);
    try t.expectEqual(@as(i64, 1_009), out.items[0].reading.?.ts_ms);
    out.clearRetainingCapacity();

    // Nothing changed since, so nothing is collected.
    try t.expect(!s.hasChanges(sub));
    try s.collectChanged(sub, 1_020, &out);
    try t.expectEqual(@as(usize, 0), out.items.len);

    // A write that does not change the elected value stays quiet: source 2 is
    // outranked by source 1, which is still fresh.
    try s.registerSource(2);
    try s.set("navigation.position", pos_b, 1_020, 2);
    try t.expect(!s.hasChanges(sub));
}

test "an election that changes with time alone reaches the subscriber" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer out.deinit(t.allocator);
    try s.registerSource(1);
    try s.registerSource(2);

    const sub = try s.subscribe(5, &.{"navigation.position"});
    try s.set("navigation.position", pos_a, 0, 1); // the boat's GPS, then silent
    try s.set("navigation.position", pos_b, 2_000, 2); // the phone, still going
    try s.collectChanged(sub, 2_000, &out);
    try t.expectEqual(@as(SourceId, 1), out.items[0].reading.?.source);
    out.clearRetainingCapacity();

    // No write happens; source 1 simply ages out of its 5 s window and hands over.
    try t.expectEqual(@as(usize, 0), s.refresh(4_000));
    try t.expect(!s.hasChanges(sub));
    try t.expectEqual(@as(usize, 1), s.refresh(6_000));
    try s.collectChanged(sub, 6_000, &out);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expect(!out.items[0].reading.?.stale);
    try t.expectEqual(@as(SourceId, 2), out.items[0].reading.?.source);

    // Both stale: the most recent value reads, flagged, rather than vanishing.
    try t.expectEqual(@as(usize, 1), s.refresh(20_000));
    out.clearRetainingCapacity();
    try s.collectChanged(sub, 20_000, &out);
    try t.expect(out.items[0].reading.?.stale);
    try t.expectEqual(@as(SourceId, 2), out.items[0].reading.?.source);
}

test "clearing a source tells its subscribers the value is gone" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer out.deinit(t.allocator);

    const sub = try s.subscribe(5, &.{"navigation.position"});
    try s.set("navigation.position", pos_a, 1_000, 1);
    try s.collectChanged(sub, 1_000, &out);
    out.clearRetainingCapacity();

    s.clearSource(1, 1_100);
    try s.collectChanged(sub, 1_100, &out);
    try t.expectEqual(@as(usize, 1), out.items.len);
    try t.expect(out.items[0].reading == null);
}

test "clearing a source drops the subscriptions it owned" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    var out: std.ArrayList(Change) = .empty;
    defer out.deinit(t.allocator);

    const sub = try s.subscribe(5, &.{"navigation.position"});
    s.clearSource(5, 0);
    try t.expect(!s.hasChanges(sub));
    try s.collectChanged(sub, 0, &out); // an inert handle, not a crash
    try t.expectEqual(@as(usize, 0), out.items.len);

    // Publishing to a path the dropped subscriber watched must not touch it.
    try s.set("navigation.position", pos_a, 0, 1);
    try t.expect(!s.hasChanges(sub));
}

test "unsubscribing stops the changes" {
    var s = try Store.init(t.allocator);
    defer s.deinit();
    const sub = try s.subscribe(5, &.{"navigation.position"});
    s.unsubscribe(sub);
    try s.set("navigation.position", pos_a, 0, 1);
    try t.expect(!s.hasChanges(sub));
    s.unsubscribe(sub); // twice is a no-op
}
