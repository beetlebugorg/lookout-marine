//! The plugin side of the lookout ABI. Import this, declare two functions, and
//! you have a plugin.
//!
//!   const lk = @import("lk");
//!
//!   comptime { lk.registerPlugin(@This()); }
//!
//!   pub fn start(s: lk.Start) !void {
//!       _ = lk.subscribePaths(&.{"navigation.position"});
//!   }
//!
//!   pub fn onEvent(e: lk.Event) !void {
//!       switch (e) {
//!           .store_changed => |json| { ... },
//!           else => {},
//!       }
//!   }
//!
//! `registerPlugin` emits the five exports PROTOTYPE.md requires — lk_abi,
//! lk_alloc, lk_free, lk_start, lk_event — and routes lk_start / lk_event to
//! your two functions. Unknown event kinds are answered 0 without reaching you,
//! which is what the ABI says must happen.
//!
//! TARGET. wasm32-freestanding: no WASI, no filesystem, no clock but the two
//! the host lends you, and no threads. Everything is single-threaded by
//! contract, so plugin state is plain globals.
//!
//! MEMORY. One bump arena, described at `Arena` below. The short version:
//!
//!   * `lk.scratch()` is a std.mem.Allocator you may use freely inside start
//!     and onEvent. It is RESET the moment your function returns, so nothing
//!     allocated from it survives the event that allocated it.
//!   * State that must survive goes in a global — a fixed array, a counter, a
//!     struct. There is no general-purpose heap and there is no free list.
//!   * The host's inbound payload is allocated through lk_alloc from the same
//!     arena and released after your call, so a burst of events does not grow
//!     linear memory.
//!
//! JSON. `std.json` works here as long as it is given an allocator, and
//! `scratch()` is one. The helpers below cover what the prototype's plugins
//! actually need — reading a start config, walking a STORE_CHANGED or
//! AIS_CHANGED payload, and writing publish / overlay / status / alert
//! payloads into a caller buffer.

const std = @import("std");

/// The ABI version this library speaks. `lk_abi` returns it.
pub const abi_version: u32 = 1;

// ---------------------------------------------------------------------------
// The host imports, exactly as PROTOTYPE.md freezes them
// ---------------------------------------------------------------------------

const host = struct {
    extern "lookout" fn log(level: u32, ptr: [*]const u8, len: u32) void;
    extern "lookout" fn now_ms() i64;
    extern "lookout" fn mono_ms() i64;
    extern "lookout" fn publish(ptr: [*]const u8, len: u32) i32;
    extern "lookout" fn ais_upsert(ptr: [*]const u8, len: u32) i32;
    extern "lookout" fn overlay(ptr: [*]const u8, len: u32) i32;
    extern "lookout" fn chrome_status(ptr: [*]const u8, len: u32) void;
    extern "lookout" fn alert(ptr: [*]const u8, len: u32) i32;
    extern "lookout" fn tcp_connect(host_ptr: [*]const u8, host_len: u32, port: u32) i64;
    extern "lookout" fn tcp_send(id: i64, ptr: [*]const u8, len: u32) i32;
    extern "lookout" fn tcp_close(id: i64) void;
    extern "lookout" fn timer_set(delay_ms: i64, periodic: u32) i64;
    extern "lookout" fn timer_cancel(id: i64) void;
    extern "lookout" fn subscribe(ptr: [*]const u8, len: u32) i32;
    extern "lookout" fn ais_subscribe() i32;
};

pub const Level = enum(u32) { debug = 0, info = 1, warn = 2, err = 3 };

/// Log one line. Nothing is added: no prefix, no newline — the host stamps the
/// plugin id and the level.
pub fn logMsg(level: Level, msg: []const u8) void {
    host.log(@intFromEnum(level), msg.ptr, @intCast(msg.len));
}

/// Log a formatted line. Truncated at 512 bytes; a log line is never
/// load-bearing and this must not allocate.
pub fn logf(level: Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    logMsg(level, w.buffered());
}

/// Wall clock, milliseconds since the epoch. Stamp published values with this.
pub fn nowMs() i64 {
    return host.now_ms();
}

/// Monotonic milliseconds. Measure intervals with this; it does not jump when
/// the boat's clock is set from a fresh GPS fix.
pub fn monoMs() i64 {
    return host.mono_ms();
}

/// Publish a `{"updates":[...]}` batch. Returns the number of updates the host
/// accepted, or -1. `Publish` below writes the JSON.
pub fn publishJson(json: []const u8) i32 {
    return host.publish(json.ptr, @intCast(json.len));
}

/// Upsert a `{"targets":[...]}` batch. `sog` is METRES PER SECOND, not knots:
/// everything crossing this ABI is SI.
pub fn aisUpsertJson(json: []const u8) i32 {
    return host.ais_upsert(json.ptr, @intCast(json.len));
}

/// Post an overlay batch, `{"set":[...],"del":[...]}`. `Overlay` writes it.
pub fn overlayJson(json: []const u8) i32 {
    return host.overlay(json.ptr, @intCast(json.len));
}

/// One line of chrome, `{"state":"running","detail":"42 msg/s"}`. The host
/// keeps the latest per plugin and logs transitions, so posting the same
/// status repeatedly is free.
pub fn statusJson(json: []const u8) void {
    host.chrome_status(json.ptr, @intCast(json.len));
}

/// Raise an alert, `{"severity":"alarm","title":"...","body":"..."}`. Needs
/// the `alerts.raise` capability; without it this returns -1 and the host logs
/// the refusal.
pub fn alertJson(json: []const u8) i32 {
    return host.alert(json.ptr, @intCast(json.len));
}

/// Open a TCP connection. Returns a connection id at once — the connect itself
/// completes on the host's I/O thread and arrives as `.tcp_connected`, or as
/// `.tcp_closed` if it failed. RECONNECTING IS YOURS: the host never retries.
pub fn tcpConnect(hostname: []const u8, port: u16) i64 {
    return host.tcp_connect(hostname.ptr, @intCast(hostname.len), port);
}

pub fn tcpSend(id: i64, data: []const u8) i32 {
    return host.tcp_send(id, data.ptr, @intCast(data.len));
}

pub fn tcpClose(id: i64) void {
    host.tcp_close(id);
}

/// A timer. `periodic` repeats every `delay_ms`; otherwise it fires once.
/// Fires as `.timer` carrying the id this returns.
pub fn timerSet(delay_ms: i64, periodic: bool) i64 {
    return host.timer_set(delay_ms, if (periodic) 1 else 0);
}

pub fn timerCancel(id: i64) void {
    host.timer_cancel(id);
}

/// Subscribe to vessel paths. One subscription per plugin: calling again
/// REPLACES the path list. Changes arrive as `.store_changed`.
pub fn subscribePaths(paths: []const []const u8) i32 {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeByte('[') catch return -1;
    for (paths, 0..) |p, i| {
        if (i > 0) w.writeByte(',') catch return -1;
        writeJsonString(&w, p) catch return -1;
    }
    w.writeByte(']') catch return -1;
    const json = w.buffered();
    return host.subscribe(json.ptr, @intCast(json.len));
}

/// Ask for the AIS target set. The whole snapshot arrives as `.ais_changed`,
/// at most twice a second and only when something moved.
pub fn aisSubscribe() i32 {
    return host.ais_subscribe();
}

// ---------------------------------------------------------------------------
// The bump arena
// ---------------------------------------------------------------------------

/// A bump arena over a static buffer that grows linear memory when it runs
/// out. There is no free list: `lk_free` pops the most recent allocation and
/// otherwise does nothing, and the dispatch wrapper resets the arena to where
/// it stood before each start/event call.
///
/// Consequences worth knowing:
///   * allocation is a pointer add;
///   * freeing out of order is a no-op, which is safe because the reset at the
///     end of the call reclaims everything anyway;
///   * an allocation that outlives its event is a bug this arena will not
///     catch — put lasting state in a global.
///
/// GROWTH DOES NOT ACCUMULATE. An event needing more scratch than the region
/// holds grows linear memory, and the grown pages are contiguous with the end
/// of that memory — so once the arena lives out there it is extended in place
/// and every live pointer, mark and offset stays put. The one move is the
/// first growth, off the static buffer: that buffer is left behind for the
/// life of the instance, not once per event. Steady-state events of any size
/// that fits therefore settle at the high-water mark of the largest single
/// event and grow no further.
///
/// ADDRESS 0 IS NEVER RETURNED. The host reads a 0 from lk_alloc as "the
/// plugin is out of memory", so the arena refuses to hand out the null app
/// address even if the linker were to place its buffer there.
const Arena = struct {
    /// Enough for the host's largest inbound payload (an AIS snapshot) plus a
    /// plugin's JSON scratch, without ever touching memory growth in practice.
    const static_bytes = 256 * 1024;
    const wasm_page = 64 * 1024;

    var buf: [static_bytes]u8 align(16) = undefined;
    /// Start of the region being bumped through: the static buffer until the
    /// first growth, a run of grown pages after it.
    var base: usize = 0;
    var cur: usize = 0;
    var end: usize = 0;
    /// Bumped every time `base` moves. A mark taken in an older region names
    /// nothing in this one, so `release` rewinds to `base` instead — see there.
    var region: u32 = 0;

    /// Where the bump pointer stood, and in which region. Not a bare address:
    /// an address alone cannot say whether the arena has moved under it.
    const Mark = struct { region: u32, cur: usize };

    fn ensureInit() void {
        if (end != 0) return;
        base = @intFromPtr(&buf);
        if (base == 0) base = 16; // see above; unreachable with any real layout
        cur = base;
        end = @intFromPtr(&buf) + buf.len;
    }

    fn bump(len: usize, alignment: usize) ?[*]u8 {
        ensureInit();
        if (len == 0) return @ptrFromInt(alignment);
        var start = std.mem.alignForward(usize, cur, alignment);
        if (start + len > end) {
            if (!grow(len + alignment)) return null;
            start = std.mem.alignForward(usize, cur, alignment);
            if (start + len > end) return null;
        }
        cur = start + len;
        if (start == 0) return null;
        return @ptrFromInt(start);
    }

    /// Make room for `need` more bytes.
    ///
    /// When the region already ends at the end of linear memory — true of
    /// every region this ever creates — the new pages land directly on top of
    /// it and only `end` moves: no allocation is abandoned and no live pointer
    /// changes. Otherwise (the static buffer, or another allocator having
    /// grown memory in between) the arena moves into a fresh run of pages and
    /// counts a new region.
    fn grow(need: usize) bool {
        const pages = (need + wasm_page - 1) / wasm_page;
        if (@as(usize, @intCast(@wasmMemorySize(0))) * wasm_page == end) {
            const prev = @wasmMemoryGrow(0, pages);
            if (prev < 0) return false;
            end += pages * wasm_page;
            return true;
        }
        const prev = @wasmMemoryGrow(0, pages + 1);
        if (prev < 0) return false;
        base = @as(usize, @intCast(prev)) * wasm_page;
        cur = base;
        end = base + (pages + 1) * wasm_page;
        region +%= 1;
        return true;
    }

    /// Pop `mem` if it is the most recent allocation in the current region;
    /// otherwise do nothing.
    fn pop(mem: []u8) void {
        const addr = @intFromPtr(mem.ptr);
        if (addr >= base and addr + mem.len == cur) cur = addr;
    }

    fn mark() Mark {
        ensureInit();
        return .{ .region = region, .cur = cur };
    }

    /// Rewind to `m`. If the arena moved regions since the mark was taken,
    /// everything the mark could name lives in the region that was left
    /// behind, and is dead at this point too — so the rewind goes to the base
    /// of the region in use, which reclaims the whole call either way.
    fn release(m: Mark) void {
        if (m.region != region) {
            cur = base;
        } else if (m.cur >= base and m.cur <= cur) cur = m.cur;
    }
};

const arena_vtable = std.mem.Allocator.VTable{
    .alloc = arenaAlloc,
    .resize = arenaResize,
    .remap = arenaRemap,
    .free = arenaFree,
};

fn arenaAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    return Arena.bump(len, alignment.toByteUnits());
}

fn arenaResize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const addr = @intFromPtr(mem.ptr);
    // Only the most recent allocation can change size in place; anything else
    // may shrink (nothing to do) but never grow.
    if (addr < Arena.base or addr + mem.len != Arena.cur) return new_len <= mem.len;
    if (addr + new_len > Arena.end) return false;
    Arena.cur = addr + new_len;
    return true;
}

fn arenaRemap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    if (arenaResize(ctx, mem, alignment, new_len, ra)) return mem.ptr;
    return null;
}

fn arenaFree(_: *anyopaque, mem: []u8, _: std.mem.Alignment, _: usize) void {
    Arena.pop(mem);
}

var arena_state: u8 = 0;

/// The per-call scratch allocator. Valid for the duration of `start` or
/// `onEvent` and reset the instant either returns.
pub fn scratch() std.mem.Allocator {
    return .{ .ptr = &arena_state, .vtable = &arena_vtable };
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

pub const TcpData = struct { conn: i64, bytes: []const u8 };

/// What `onEvent` receives. The payload slices point into the arena and are
/// gone when your handler returns; copy anything you keep.
pub const Event = union(enum) {
    /// The plugin's whole settings object, `{"cpa_limit":926,...}`, after the
    /// mariner changed one of them. Every field the manifest's schema declares
    /// is present, so a handler reads what it wants and never merges.
    config_changed: []const u8,
    /// The timer id `timerSet` returned.
    timer: i64,
    tcp_connected: i64,
    tcp_data: TcpData,
    tcp_closed: i64,
    /// `{"values":[{"path":..,"value":..,"ts":..,"age_ms":..}]}`. A value of
    /// null means the path has NO value any more — the source was cleared —
    /// not that it published a null. `readings` parses it.
    store_changed: []const u8,
    /// `{"targets":[...]}`, the full set. `targets` parses it.
    ais_changed: []const u8,
    /// Last thing you will ever be handed. Close sockets, post a final status.
    shutdown,
};

/// What `start` receives: the host's `{"abi":1,"config":{...}}`, parsed.
pub const Start = struct {
    abi: u32,
    /// The `config` object. Use `cfgStr` / `cfgInt` to read it.
    config: std.json.Value,
};

const kind_config_changed: u32 = 1;
const kind_timer: u32 = 3;
const kind_tcp_connected: u32 = 4;
const kind_tcp_data: u32 = 5;
const kind_tcp_closed: u32 = 6;
const kind_store_changed: u32 = 10;
const kind_ais_changed: u32 = 11;
const kind_shutdown: u32 = 99;

/// Emit the five ABI exports and wire them to `P.start` and `P.onEvent`.
/// Call once, at container scope, from the plugin's root file:
///
///   comptime { lk.registerPlugin(@This()); }
pub fn registerPlugin(comptime P: type) void {
    const Impl = struct {
        fn abi() callconv(.c) u32 {
            return abi_version;
        }

        fn alloc(len: u32) callconv(.c) ?[*]u8 {
            return Arena.bump(@intCast(len), 8);
        }

        fn free(ptr: [*]u8, len: u32) callconv(.c) void {
            Arena.pop(ptr[0..@intCast(len)]);
        }

        fn start(ptr: [*]const u8, len: u32) callconv(.c) i32 {
            const mark = Arena.mark();
            defer Arena.release(mark);
            const text = ptr[0..@intCast(len)];

            const root = std.json.parseFromSliceLeaky(std.json.Value, scratch(), text, .{}) catch {
                logf(.err, "lk_start: config is not JSON", .{});
                return -1;
            };
            if (root != .object) return -1;
            const abi_field: u32 = switch (root.object.get("abi") orelse std.json.Value{ .integer = 0 }) {
                .integer => |i| if (i > 0 and i <= 0xffff_ffff) @intCast(i) else 0,
                else => 0,
            };
            if (abi_field != abi_version) {
                logf(.err, "lk_start: host speaks ABI {d}, this plugin speaks {d}", .{ abi_field, abi_version });
                return -1;
            }
            const cfg = root.object.get("config") orelse std.json.Value{ .null = {} };
            P.start(.{ .abi = abi_field, .config = cfg }) catch |e| {
                logf(.err, "start failed: {s}", .{@errorName(e)});
                return -1;
            };
            return 0;
        }

        fn event(kind: u32, handle: u64, ptr: [*]const u8, len: u32) callconv(.c) i32 {
            const mark = Arena.mark();
            defer Arena.release(mark);
            const payload: []const u8 = if (len == 0) &[_]u8{} else ptr[0..@intCast(len)];
            const id: i64 = @bitCast(handle);
            const ev: Event = switch (kind) {
                kind_config_changed => .{ .config_changed = payload },
                kind_timer => .{ .timer = id },
                kind_tcp_connected => .{ .tcp_connected = id },
                kind_tcp_data => .{ .tcp_data = .{ .conn = id, .bytes = payload } },
                kind_tcp_closed => .{ .tcp_closed = id },
                kind_store_changed => .{ .store_changed = payload },
                kind_ais_changed => .{ .ais_changed = payload },
                kind_shutdown => .shutdown,
                // The ABI says an unknown kind is ignored and answered 0. A
                // future host must be able to add events without breaking a
                // plugin built today.
                else => return 0,
            };
            P.onEvent(ev) catch |e| {
                logf(.err, "event {d} failed: {s}", .{ kind, @errorName(e) });
                return -1;
            };
            return 0;
        }
    };
    @export(&Impl.abi, .{ .name = "lk_abi", .linkage = .strong });
    @export(&Impl.alloc, .{ .name = "lk_alloc", .linkage = .strong });
    @export(&Impl.free, .{ .name = "lk_free", .linkage = .strong });
    @export(&Impl.start, .{ .name = "lk_start", .linkage = .strong });
    @export(&Impl.event, .{ .name = "lk_event", .linkage = .strong });
}

// ---------------------------------------------------------------------------
// Reading what the host sends
// ---------------------------------------------------------------------------

/// One entry of a STORE_CHANGED payload.
pub const Reading = struct {
    path: []const u8,
    value: std.json.Value,
    ts_ms: i64,
    age_ms: i64,

    /// True when the path has no value at all any more. Treat it as removal:
    /// stop drawing whatever the value fed.
    pub fn removed(self: Reading) bool {
        return self.value == .null;
    }

    pub fn number(self: Reading) ?f64 {
        return jnum(self.value);
    }

    /// `.{ lat, lon }`, or null when the value is not a position.
    pub fn position(self: Reading) ?[2]f64 {
        if (self.value != .object) return null;
        const lat = jnum(self.value.object.get("lat") orelse return null) orelse return null;
        const lon = jnum(self.value.object.get("lon") orelse return null) orelse return null;
        return .{ lat, lon };
    }
};

/// Parse a `.store_changed` payload. The slice and its strings live in the
/// scratch arena, so they are gone when your handler returns.
pub fn readings(payload: []const u8) []const Reading {
    const a = scratch();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{}) catch return &.{};
    if (root != .object) return &.{};
    const arr = root.object.get("values") orelse return &.{};
    if (arr != .array) return &.{};
    const out = a.alloc(Reading, arr.array.items.len) catch return &.{};
    var n: usize = 0;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const path = jstr(o.get("path") orelse continue) orelse continue;
        out[n] = .{
            .path = path,
            .value = o.get("value") orelse std.json.Value{ .null = {} },
            .ts_ms = jint(o.get("ts") orelse std.json.Value{ .integer = 0 }) orelse 0,
            .age_ms = jint(o.get("age_ms") orelse std.json.Value{ .integer = 0 }) orelse 0,
        };
        n += 1;
    }
    return out[0..n];
}

/// One AIS target from an `.ais_changed` payload. Absent fields are null:
/// "never heard" and "heard as zero" are different things at sea.
pub const Target = struct {
    mmsi: u32,
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Metres per second.
    sog: ?f64 = null,
    cog: ?f64 = null,
    heading: ?f64 = null,
    name: ?[]const u8 = null,
    /// True when this is an aid to navigation, not a vessel: no CPA, no
    /// vector, and its own aging.
    aton: bool = false,
    /// The navaid type, 0..31, as type 21 carries it.
    aton_type: ?u8 = null,
    /// True for an aid with nothing in the water behind it.
    virtual_aton: bool = false,
    /// True when the aid reports itself off its charted position; null when it
    /// has never said either way.
    off_position: ?bool = null,
    ts_ms: i64 = 0,
    age_ms: i64 = 0,

    pub fn hasPosition(self: Target) bool {
        return self.lat != null and self.lon != null;
    }
};

/// Parse an `.ais_changed` payload. Scratch-allocated, like `readings`.
pub fn targets(payload: []const u8) []const Target {
    const a = scratch();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{}) catch return &.{};
    if (root != .object) return &.{};
    const arr = root.object.get("targets") orelse return &.{};
    if (arr != .array) return &.{};
    const out = a.alloc(Target, arr.array.items.len) catch return &.{};
    var n: usize = 0;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const mmsi = jint(o.get("mmsi") orelse continue) orelse continue;
        if (mmsi <= 0 or mmsi > 0xffff_ffff) continue;
        out[n] = .{
            .mmsi = @intCast(mmsi),
            .lat = jnumOpt(o.get("lat")),
            .lon = jnumOpt(o.get("lon")),
            .sog = jnumOpt(o.get("sog")),
            .cog = jnumOpt(o.get("cog")),
            .heading = jnumOpt(o.get("heading")),
            .name = if (o.get("name")) |v| jstr(v) else null,
            .aton = jboolOpt(o.get("aton")) orelse false,
            .aton_type = atonType(o.get("aton_type")),
            .virtual_aton = jboolOpt(o.get("virtual")) orelse false,
            .off_position = jboolOpt(o.get("off_position")),
            .ts_ms = jintOpt(o.get("ts")) orelse 0,
            .age_ms = jintOpt(o.get("age_ms")) orelse 0,
        };
        n += 1;
    }
    return out[0..n];
}

/// A string out of the start config, or `fallback`.
pub fn cfgStr(config: std.json.Value, key: []const u8, fallback: []const u8) []const u8 {
    if (config != .object) return fallback;
    const v = config.object.get(key) orelse return fallback;
    return jstr(v) orelse fallback;
}

/// An integer out of the start config, or `fallback`.
pub fn cfgInt(config: std.json.Value, key: []const u8, fallback: i64) i64 {
    if (config != .object) return fallback;
    const v = config.object.get(key) orelse return fallback;
    return jint(v) orelse fallback;
}

pub fn jstr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn jnum(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn jint(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn jbool(v: std.json.Value) ?bool {
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn jnumOpt(v: ?std.json.Value) ?f64 {
    return jnum(v orelse return null);
}

fn jboolOpt(v: ?std.json.Value) ?bool {
    return jbool(v orelse return null);
}

/// A navaid type code. Anything outside 0..31 loses the type, not the target.
fn atonType(v: ?std.json.Value) ?u8 {
    const n = jintOpt(v) orelse return null;
    return if (n >= 0 and n <= 31) @intCast(n) else null;
}

fn jintOpt(v: ?std.json.Value) ?i64 {
    return jint(v orelse return null);
}

// ---------------------------------------------------------------------------
// Writing what the host reads
// ---------------------------------------------------------------------------

/// A JSON writer over a caller-owned buffer. Overflow is remembered, not
/// returned at every call site: a payload that did not fit is refused whole at
/// `send` rather than sent half-written.
pub const Buf = struct {
    w: std.Io.Writer,
    overflowed: bool = false,

    pub fn init(buffer: []u8) Buf {
        return .{ .w = .fixed(buffer) };
    }

    pub fn raw(self: *Buf, text: []const u8) void {
        self.w.writeAll(text) catch {
            self.overflowed = true;
        };
    }

    pub fn print(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        self.w.print(fmt, args) catch {
            self.overflowed = true;
        };
    }

    /// A quoted, escaped JSON string.
    pub fn str(self: *Buf, s: []const u8) void {
        writeJsonString(&self.w, s) catch {
            self.overflowed = true;
        };
    }

    /// A finite number, or `null` — an infinity or a NaN in a payload is a bug
    /// the host would reject, so it never leaves here.
    pub fn num(self: *Buf, v: f64) void {
        if (std.math.isFinite(v)) self.print("{d}", .{v}) else self.raw("null");
    }

    pub fn bytes(self: *Buf) []const u8 {
        return self.w.buffered();
    }
};

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Builds `{"updates":[...]}` into a caller buffer and sends it.
///
///   var buf: [512]u8 = undefined;
///   var p = lk.Publish.init(&buf);
///   p.position("navigation.position", lat, lon, ts);
///   p.number("navigation.speedOverGround", sog_mps, ts);
///   _ = p.send();
pub const Publish = struct {
    b: Buf,
    n: usize = 0,

    pub fn init(buffer: []u8) Publish {
        var p = Publish{ .b = Buf.init(buffer) };
        p.b.raw("{\"updates\":[");
        return p;
    }

    fn open(self: *Publish, path: []const u8) void {
        if (self.n > 0) self.b.raw(",");
        self.n += 1;
        self.b.raw("{\"path\":");
        self.b.str(path);
        self.b.raw(",\"value\":");
    }

    pub fn number(self: *Publish, path: []const u8, v: f64, ts_ms: i64) void {
        self.open(path);
        self.b.num(v);
        self.b.print(",\"ts\":{d}}}", .{ts_ms});
    }

    pub fn position(self: *Publish, path: []const u8, lat: f64, lon: f64, ts_ms: i64) void {
        self.open(path);
        self.b.raw("{\"lat\":");
        self.b.num(lat);
        self.b.raw(",\"lon\":");
        self.b.num(lon);
        self.b.print("}},\"ts\":{d}}}", .{ts_ms});
    }

    /// Publish a null: this source has the path but no value for it right now.
    pub fn clear(self: *Publish, path: []const u8, ts_ms: i64) void {
        self.open(path);
        self.b.print("null,\"ts\":{d}}}", .{ts_ms});
    }

    /// Nothing to say is not an error; an empty batch is simply not sent.
    pub fn send(self: *Publish) i32 {
        if (self.n == 0) return 0;
        self.b.raw("]}");
        if (self.b.overflowed) {
            logf(.warn, "publish dropped: payload did not fit", .{});
            return -1;
        }
        return publishJson(self.b.bytes());
    }
};

/// Builds `{"targets":[...]}` for `ais_upsert`. `sog` is metres per second.
pub const AisUpsert = struct {
    b: Buf,
    n: usize = 0,

    pub fn init(buffer: []u8) AisUpsert {
        var u = AisUpsert{ .b = Buf.init(buffer) };
        u.b.raw("{\"targets\":[");
        return u;
    }

    pub fn target(self: *AisUpsert, t: Target) void {
        if (self.n > 0) self.b.raw(",");
        self.n += 1;
        self.b.print("{{\"mmsi\":{d}", .{t.mmsi});
        if (t.lat) |v| {
            self.b.raw(",\"lat\":");
            self.b.num(v);
        }
        if (t.lon) |v| {
            self.b.raw(",\"lon\":");
            self.b.num(v);
        }
        if (t.sog) |v| {
            self.b.raw(",\"sog\":");
            self.b.num(v);
        }
        if (t.cog) |v| {
            self.b.raw(",\"cog\":");
            self.b.num(v);
        }
        if (t.heading) |v| {
            self.b.raw(",\"heading\":");
            self.b.num(v);
        }
        if (t.name) |n| {
            self.b.raw(",\"name\":");
            self.b.str(n);
        }
        if (t.aton) {
            self.b.raw(",\"aton\":true");
            if (t.aton_type) |v| self.b.print(",\"aton_type\":{d}", .{v});
            if (t.virtual_aton) self.b.raw(",\"virtual\":true");
            if (t.off_position) |v| self.b.print(",\"off_position\":{s}", .{if (v) "true" else "false"});
        }
        self.b.print(",\"ts\":{d}}}", .{t.ts_ms});
    }

    pub fn send(self: *AisUpsert) i32 {
        if (self.n == 0) return 0;
        self.b.raw("]}");
        if (self.b.overflowed) {
            logf(.warn, "ais_upsert dropped: payload did not fit", .{});
            return -1;
        }
        return aisUpsertJson(self.b.bytes());
    }
};

/// The palette tokens PROTOTYPE.md freezes. A plugin names a token; the core
/// resolves it per day/dusk/night scheme, which is why an overlay never has an
/// RGB in it.
pub const Color = enum {
    ownship,
    target,
    target_danger,
    track,
    layline_port,
    layline_stbd,
    warning,

    pub fn text(self: Color) []const u8 {
        return @tagName(self);
    }
};

/// The symbol shapes the core draws. `aton` is a physical aid to navigation
/// and `aton_virtual` one that exists only as a broadcast.
pub const Sym = enum { ownship, target, aton, aton_virtual };

/// Builds `{"set":[...],"del":[...]}`.
///
/// DELETES FIRST. Call `del` before any `symbol` / `polyline` / `polygon`; a
/// delete after a shape is dropped with a log line. The host applies deletes
/// before sets whatever the order in the JSON, so this only makes the builder
/// match the semantics.
///
///   var buf: [4096]u8 = undefined;
///   var ov = lk.Overlay.init(&buf);
///   ov.del("stale-target");
///   ov.symbol("ownship", .ownship, lon, lat, hdg, .ownship, 1.0);
///   _ = ov.send();
pub const Overlay = struct {
    b: Buf,
    dels: usize = 0,
    sets: usize = 0,
    phase: enum { del, set } = .del,

    pub fn init(buffer: []u8) Overlay {
        var o = Overlay{ .b = Buf.init(buffer) };
        o.b.raw("{\"del\":[");
        return o;
    }

    pub fn del(self: *Overlay, id: []const u8) void {
        if (self.phase != .del) {
            logf(.warn, "overlay: del(\"{s}\") after a set is ignored", .{id});
            return;
        }
        if (self.dels > 0) self.b.raw(",");
        self.dels += 1;
        self.b.str(id);
    }

    fn beginSet(self: *Overlay) void {
        if (self.phase == .del) {
            self.b.raw("],\"set\":[");
            self.phase = .set;
        } else self.b.raw(",");
        self.sets += 1;
    }

    /// A symbol at lon/lat, rotated to a TRUE bearing (clockwise from north).
    pub fn symbol(self: *Overlay, id: []const u8, sym: Sym, lon: f64, lat: f64, rot_deg: f64, color: Color, scale: f64) void {
        self.symbolOpen(id, sym, lon, lat, rot_deg, color, scale);
        self.b.raw("}");
    }

    /// A symbol that rides own ship's DISPLAY position: the core carries the
    /// newest fix forward and substitutes it every frame, so the boat sits
    /// still on screen instead of stepping once a second. The lon/lat posted
    /// here is still the fix, and is what draws if the core has no carry.
    pub fn shipSymbol(self: *Overlay, id: []const u8, sym: Sym, lon: f64, lat: f64, rot_deg: f64, color: Color, scale: f64) void {
        self.symbolOpen(id, sym, lon, lat, rot_deg, color, scale);
        self.b.raw(",\"anchor\":\"ownship\"}");
    }

    /// Everything a symbol object holds except its closing brace, so a caller
    /// may append a `pick` before closing it.
    fn symbolOpen(self: *Overlay, id: []const u8, sym: Sym, lon: f64, lat: f64, rot_deg: f64, color: Color, scale: f64) void {
        self.beginSet();
        self.b.raw("{\"id\":");
        self.b.str(id);
        self.b.print(",\"kind\":\"symbol\",\"sym\":\"{s}\",\"at\":[", .{@tagName(sym)});
        self.b.num(lon);
        self.b.raw(",");
        self.b.num(lat);
        self.b.raw("],\"rot_deg\":");
        self.b.num(rot_deg);
        self.b.raw(",\"scale\":");
        self.b.num(scale);
        self.b.print(",\"color\":\"{s}\"", .{color.text()});
    }

    /// A symbol plus a `pick` payload: a title and rows of key/value pairs the
    /// shell shows on hover or on a tap. The core validates, escapes and caps
    /// the text. Values are strings, not numbers: the payload is what the
    /// mariner reads, and only the plugin knows the unit.
    pub fn symbolPick(
        self: *Overlay,
        id: []const u8,
        sym: Sym,
        lon: f64,
        lat: f64,
        rot_deg: f64,
        color: Color,
        scale: f64,
        title: []const u8,
        rows: []const [2][]const u8,
    ) void {
        self.symbolOpen(id, sym, lon, lat, rot_deg, color, scale);
        self.b.raw(",\"pick\":{\"title\":");
        self.b.str(title);
        self.b.raw(",\"rows\":[");
        for (rows, 0..) |r, i| {
            if (i > 0) self.b.raw(",");
            self.b.raw("[");
            self.b.str(r[0]);
            self.b.raw(",");
            self.b.str(r[1]);
            self.b.raw("]");
        }
        self.b.raw("]}}");
    }

    /// A polyline through `pts`, each `.{ lon, lat }`. `width_pt` is screen
    /// points, not metres — the core converts at the live zoom.
    pub fn polyline(self: *Overlay, id: []const u8, pts: []const [2]f64, width_pt: f64, color: Color, dash: bool) void {
        self.polylineAnchored(id, pts, width_pt, color, dash, false);
    }

    /// A line that travels with own ship's display position, keeping its shape
    /// and its first point on the boat — the heading line and the speed
    /// vector, which must not lag the hull between fixes.
    pub fn shipPolyline(self: *Overlay, id: []const u8, pts: []const [2]f64, width_pt: f64, color: Color, dash: bool) void {
        self.polylineAnchored(id, pts, width_pt, color, dash, true);
    }

    fn polylineAnchored(self: *Overlay, id: []const u8, pts: []const [2]f64, width_pt: f64, color: Color, dash: bool, ship: bool) void {
        self.beginSet();
        self.b.raw("{\"id\":");
        self.b.str(id);
        self.b.raw(",\"kind\":\"polyline\",\"pts\":[");
        self.points(pts);
        self.b.raw("],\"width_pt\":");
        self.b.num(width_pt);
        self.b.print(",\"dash\":{s},\"color\":\"{s}\"{s}}}", .{
            if (dash) "true" else "false",
            color.text(),
            if (ship) ",\"anchor\":\"ownship\"" else "",
        });
    }

    /// A filled ring. `alpha` multiplies the token's own alpha.
    pub fn polygon(self: *Overlay, id: []const u8, ring: []const [2]f64, color: Color, alpha: f64) void {
        self.beginSet();
        self.b.raw("{\"id\":");
        self.b.str(id);
        self.b.raw(",\"kind\":\"polygon\",\"ring\":[");
        self.points(ring);
        self.b.raw("],\"alpha\":");
        self.b.num(alpha);
        self.b.print(",\"color\":\"{s}\"}}", .{color.text()});
    }

    fn points(self: *Overlay, pts: []const [2]f64) void {
        for (pts, 0..) |p, i| {
            if (i > 0) self.b.raw(",");
            self.b.raw("[");
            self.b.num(p[0]);
            self.b.raw(",");
            self.b.num(p[1]);
            self.b.raw("]");
        }
    }

    pub fn send(self: *Overlay) i32 {
        if (self.dels == 0 and self.sets == 0) return 0;
        if (self.phase == .del) self.b.raw("],\"set\":[");
        self.b.raw("]}");
        if (self.b.overflowed) {
            logf(.warn, "overlay dropped: payload did not fit", .{});
            return -1;
        }
        return overlayJson(self.b.bytes());
    }
};

/// Post one line of chrome: `{"state":"running","detail":"..."}`.
pub fn status(state: []const u8, comptime detail_fmt: []const u8, args: anytype) void {
    var buf: [320]u8 = undefined;
    var b = Buf.init(&buf);
    b.raw("{\"state\":");
    b.str(state);
    b.raw(",\"detail\":");
    var detail: [200]u8 = undefined;
    var dw = std.Io.Writer.fixed(&detail);
    dw.print(detail_fmt, args) catch {};
    b.str(dw.buffered());
    b.raw("}");
    if (b.overflowed) return;
    statusJson(b.bytes());
}

pub const Severity = enum { alarm, warning, caution };

/// Raise an alert. Needs `alerts.raise`; -1 means the grant is missing or the
/// payload did not fit.
pub fn raiseAlert(severity: Severity, title: []const u8, body: []const u8) i32 {
    var buf: [512]u8 = undefined;
    var b = Buf.init(&buf);
    b.print("{{\"severity\":\"{s}\",\"title\":", .{@tagName(severity)});
    b.str(title);
    b.raw(",\"body\":");
    b.str(body);
    b.raw("}");
    if (b.overflowed) return -1;
    return alertJson(b.bytes());
}
