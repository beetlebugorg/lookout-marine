//! The host side of the plugin ABI: the sixteen native functions a plugin
//! imports from module `lookout`, the grants that gate them, and the one I/O
//! thread that owns sockets, timers and the subscriber fanout.
//!
//! WHAT THIS FILE IS. `wasm.zig` moves bytes across the boundary; this file
//! decides what those bytes mean. Every import in PROTOTYPE.md's frozen table
//! is implemented here exactly once, checked against the calling plugin's
//! manifest capabilities, and turned into a call on the vessel store, the AIS
//! store, the overlay store or a socket.
//!
//! GRANTS. A call the manifest did not ask for returns -1 (void imports return
//! nothing) and is logged. It does NOT trap: a plugin that asks for something
//! it was not given is misconfigured, not malicious, and killing it would hide
//! the misconfiguration behind a stack trace. The natives are registered for
//! every plugin, so the check is per call, not per instantiation.
//!
//! THREADS. Three, and only three:
//!   * the caller's thread, during load/start — natives may run here before
//!     the dispatch thread exists;
//!   * the host's DISPATCH thread, inside a wasm call — every native runs
//!     here in steady state;
//!   * this file's I/O thread — poll on the plugin sockets, timer deadlines,
//!     and the 100 ms fanout tick. It only ever ENQUEUES events; it never
//!     enters wasm.
//! `mu` guards the queue, the connection list, the timer list and the plugin
//! records. It is the OUTERMOST lock: code holding it may take the vessel,
//! AIS or overlay store's lock, never the other way round.
//!
//! THE FANOUT TICK is the reason the I/O thread exists at all. It calls
//! `Store.refresh` FIRST: a fix ageing out of its window and handing over to
//! the next source produces no write, so without the refresh a staleness
//! handover would never reach a subscriber.

const std = @import("std");
const wasm = @import("wasm.zig");
const vstore = @import("store.zig");
const ais_store = @import("aisstore.zig");

pub const Lock = vstore.Lock;
pub const SourceId = vstore.SourceId;

// ---- event kinds (PROTOTYPE.md) --------------------------------------------

pub const Kind = struct {
    pub const config_changed: u32 = 1;
    pub const timer: u32 = 3;
    pub const tcp_connected: u32 = 4;
    pub const tcp_data: u32 = 5;
    pub const tcp_closed: u32 = 6;
    pub const store_changed: u32 = 10;
    pub const ais_changed: u32 = 11;
    pub const shutdown: u32 = 99;
};

// ---- log levels ------------------------------------------------------------

pub const level_debug: u32 = 0;
pub const level_info: u32 = 1;
pub const level_warn: u32 = 2;
pub const level_err: u32 = 3;

/// Where plugin log lines, grant refusals and alerts go. `plugin` is the
/// manifest id, or "host" for the host's own lines. The default prints to
/// stderr; the harness and the tests install their own.
pub const LogFn = *const fn (ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void;

fn levelName(level: u32) []const u8 {
    return switch (level) {
        0 => "debug",
        1 => "info",
        2 => "warn",
        else => "error",
    };
}

fn defaultLog(ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void {
    _ = ctx;
    std.debug.print("plugin {s} [{s}] {s}\n", .{ plugin, levelName(level), msg });
}

// ---- capabilities ----------------------------------------------------------

/// The manifest's capability vocabulary. A plugin is granted a subset.
pub const Cap = enum {
    net_tcp_client,
    vessel_publish,
    ais_publish,
    vessel_read,
    ais_read,
    overlay_draw,
    alerts_raise,

    pub fn name(self: Cap) []const u8 {
        return switch (self) {
            .net_tcp_client => "net.tcp-client",
            .vessel_publish => "vessel.publish",
            .ais_publish => "ais.publish",
            .vessel_read => "vessel.read",
            .ais_read => "ais.read",
            .overlay_draw => "overlay.draw",
            .alerts_raise => "alerts.raise",
        };
    }

    pub fn fromName(text: []const u8) ?Cap {
        inline for (comptime std.enums.values(Cap)) |c| {
            if (std.mem.eql(u8, text, c.name())) return c;
        }
        return null;
    }
};

pub const Caps = std.EnumSet(Cap);

// ---- the overlay the broker draws into -------------------------------------

/// The overlay store, behind two function pointers.
///
/// `src/overlay.zig` lives one directory up, which a module rooted at
/// src/plugin/ cannot import (the same constraint that made store.zig copy its
/// lock). Indirecting through this keeps host.zig and broker.zig buildable on
/// their own — which is what lets the host smoke test compile them without the
/// chart core — and costs one indirect call per overlay batch.
pub const OverlaySink = struct {
    ctx: ?*anyopaque = null,
    applyFn: ?*const fn (ctx: ?*anyopaque, source: []const u8, json: []const u8) anyerror!void = null,
    removeFn: ?*const fn (ctx: ?*anyopaque, source: []const u8) void = null,

    pub fn apply(self: OverlaySink, source: []const u8, json: []const u8) anyerror!void {
        const f = self.applyFn orelse return;
        return f(self.ctx, source, json);
    }

    pub fn remove(self: OverlaySink, source: []const u8) void {
        const f = self.removeFn orelse return;
        f(self.ctx, source);
    }
};

// ---- per-plugin state ------------------------------------------------------

/// Longest chrome status text kept per plugin. PROTOTYPE.md's chrome is one
/// string; anything longer is truncated rather than allocated per update.
pub const max_status = 160;
/// Longest alert text kept per plugin (severity + title + body, as posted).
pub const max_alert = 400;

/// What a native needs to know about its caller. The host allocates one per
/// plugin and hands its address to `Instance.setUserData`, so every native
/// reaches it with one `wasm.callerUserData`.
pub const Plugin = struct {
    broker: *Broker,
    /// Index into the host's registry. Tags queued events.
    index: u32,
    /// Manifest id, e.g. "org.beetlebug.nmea0183". Borrowed from the host and
    /// used as the overlay namespace.
    id: []const u8,
    /// This plugin's provenance in the vessel and AIS stores.
    source: SourceId,
    caps: Caps,
    /// False once the plugin has trapped or been shut down: natives from an
    /// in-flight call still work, but nothing new is delivered.
    enabled: bool = true,
    /// Its vessel-store subscription, once it has called `subscribe`.
    sub: ?vstore.SubId = null,
    ais_sub: bool = false,
    status_buf: [max_status]u8 = @splat(0),
    status_len: usize = 0,
    alert_buf: [max_alert]u8 = @splat(0),
    alert_len: usize = 0,
    /// Calls refused for want of a capability. The smoke test asserts on this.
    denied: u32 = 0,

    pub fn status(self: *const Plugin) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn lastAlert(self: *const Plugin) []const u8 {
        return self.alert_buf[0..self.alert_len];
    }
};

// ---- the event queue -------------------------------------------------------

pub const Event = struct {
    /// Registry index of the plugin this is for.
    plugin: u32,
    kind: u32,
    handle: u64,
    /// Owned by the broker; the dispatch thread frees it after delivery.
    payload: []u8,
};

/// One global FIFO across all plugins, one event in flight. Over this the
/// prototype's four plugins never queue more than a few dozen events; the cap
/// exists so a plugin that stops consuming cannot grow the queue without
/// bound.
const max_queued = 4096;

// ---- sockets and timers ----------------------------------------------------

const ConnState = enum { resolving, connecting, open };

const Conn = struct {
    id: i64,
    plugin: u32,
    state: ConnState,
    fd: std.c.fd_t = -1,
    /// Kept until the socket is connected: the I/O thread resolves, so the
    /// plugin's tcp_connect never blocks on DNS.
    host: []u8,
    port: u16,
    /// Bytes tcp_send handed over, not yet written.
    out: std.ArrayList(u8) = .empty,
    /// Set by tcp_close; the I/O thread reaps it without an event.
    closing: bool = false,
};

const Timer = struct {
    id: i64,
    plugin: u32,
    /// Monotonic ms.
    due: i64,
    /// 0 for a one-shot.
    period: i64,
};

/// How often the fanout tick runs. STORE_CHANGED is specified at <=10 Hz, so
/// the tick sets the rate and the store's dirty set does the coalescing.
pub const tick_ms: i64 = 100;
/// AIS_CHANGED is specified at <=2 Hz.
pub const ais_min_interval_ms: i64 = 500;
/// Targets not heard from for this long go on the fanout tick.
pub const ais_evict_ms: i64 = 600_000;

/// Read chunk for a plugin socket. One TCP_DATA event per read; the plugin
/// reassembles lines itself.
const read_chunk = 8192;

// ---- the broker ------------------------------------------------------------

pub const Broker = struct {
    alloc: std.mem.Allocator,
    vessels: *vstore.Store,
    ais: *ais_store.AisStore,
    overlay: OverlaySink,
    log_ctx: ?*anyopaque = null,
    log_fn: LogFn = defaultLog,

    mu: Lock = .{},
    queue: std.ArrayList(Event) = .empty,
    /// Read cursor. The queue compacts when the cursor has passed half of it,
    /// so a steady stream neither shifts every pop nor grows without bound.
    head: usize = 0,
    dropped: u64 = 0,

    plugins: std.ArrayList(*Plugin) = .empty,
    conns: std.ArrayList(Conn) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    next_conn: i64 = 1,
    next_timer: i64 = 1,

    io_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Self-pipe: a native run on the dispatch thread writes one byte so the
    /// I/O thread leaves poll at once instead of finishing its current wait.
    /// Without it a 5 ms timer set from inside an event could fire 100 ms late.
    wake: [2]std.c.fd_t = .{ -1, -1 },

    next_tick: i64 = 0,
    last_ais_ms: i64 = 0,
    last_ais_seq: u64 = 0,
    /// Grant refusals across all plugins.
    denied: u32 = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        vessels: *vstore.Store,
        ais: *ais_store.AisStore,
        overlay: OverlaySink,
    ) Broker {
        return .{ .alloc = alloc, .vessels = vessels, .ais = ais, .overlay = overlay };
    }

    /// Stops the I/O thread if it is running, then releases everything the
    /// broker owns. Plugin records belong to the host and are not freed here.
    pub fn deinit(self: *Broker) void {
        self.stop();
        for (self.queue.items[self.head..]) |e| self.alloc.free(e.payload);
        self.queue.deinit(self.alloc);
        for (self.conns.items) |*c| {
            if (c.fd >= 0) _ = std.c.close(c.fd);
            c.out.deinit(self.alloc);
            self.alloc.free(c.host);
        }
        self.conns.deinit(self.alloc);
        self.timers.deinit(self.alloc);
        self.plugins.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn setLog(self: *Broker, ctx: ?*anyopaque, f: LogFn) void {
        self.log_ctx = ctx;
        self.log_fn = f;
    }

    /// Log one formatted line. Truncated at 512 bytes rather than allocated:
    /// a log line is never load-bearing and this runs on the I/O thread too.
    pub fn say(self: *Broker, level: u32, who: []const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        self.log_fn(self.log_ctx, level, who, msg);
    }

    pub fn registerPlugin(self: *Broker, p: *Plugin) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.plugins.append(self.alloc, p);
    }

    // -- the queue -----------------------------------------------------------

    /// Enqueue one event, copying `payload`. Over the cap the event is dropped
    /// and counted: refusing to allocate is better than an unbounded queue,
    /// and the plugin that stopped consuming is the one that loses events.
    pub fn push(self: *Broker, plugin: u32, kind: u32, handle: u64, payload: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.pushLocked(plugin, kind, handle, payload);
    }

    fn pushLocked(self: *Broker, plugin: u32, kind: u32, handle: u64, payload: []const u8) void {
        if (self.queue.items.len - self.head >= max_queued) {
            self.dropped += 1;
            return;
        }
        const owned = self.alloc.dupe(u8, payload) catch {
            self.dropped += 1;
            return;
        };
        self.queue.append(self.alloc, .{
            .plugin = plugin,
            .kind = kind,
            .handle = handle,
            .payload = owned,
        }) catch {
            self.alloc.free(owned);
            self.dropped += 1;
        };
    }

    /// The next event, or null. The caller owns the payload and frees it with
    /// `freeEvent`.
    pub fn pop(self: *Broker) ?Event {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.head >= self.queue.items.len) {
            if (self.head > 0) {
                self.queue.clearRetainingCapacity();
                self.head = 0;
            }
            return null;
        }
        const e = self.queue.items[self.head];
        self.head += 1;
        if (self.head > 64 and self.head * 2 > self.queue.items.len) {
            const rest = self.queue.items.len - self.head;
            std.mem.copyForwards(Event, self.queue.items[0..rest], self.queue.items[self.head..]);
            self.queue.shrinkRetainingCapacity(rest);
            self.head = 0;
        }
        return e;
    }

    pub fn freeEvent(self: *Broker, e: Event) void {
        self.alloc.free(e.payload);
    }

    pub fn queued(self: *Broker) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.queue.items.len - self.head;
    }

    // -- disabling a plugin --------------------------------------------------

    /// Everything a trapped, refused or shut-down plugin must leave behind:
    /// its queued events, its sockets, its timers, its overlay objects and its
    /// store contributions. Called by the host; safe to call twice.
    pub fn dropPlugin(self: *Broker, index: u32, now_ms: i64) void {
        var id: []const u8 = "";
        var source: SourceId = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();

            for (self.plugins.items) |p| {
                if (p.index != index) continue;
                p.enabled = false;
                id = p.id;
                source = p.source;
                if (p.sub) |s| {
                    self.vessels.unsubscribe(s);
                    p.sub = null;
                }
                p.ais_sub = false;
            }

            // Queued events for a plugin that will never run them again.
            var w: usize = self.head;
            var r: usize = self.head;
            while (r < self.queue.items.len) : (r += 1) {
                const e = self.queue.items[r];
                if (e.plugin == index) {
                    self.alloc.free(e.payload);
                    continue;
                }
                self.queue.items[w] = e;
                w += 1;
            }
            self.queue.shrinkRetainingCapacity(w);

            var i: usize = 0;
            while (i < self.conns.items.len) {
                if (self.conns.items[i].plugin != index) {
                    i += 1;
                    continue;
                }
                var c = self.conns.orderedRemove(i);
                if (c.fd >= 0) _ = std.c.close(c.fd);
                c.out.deinit(self.alloc);
                self.alloc.free(c.host);
            }
            i = 0;
            while (i < self.timers.items.len) {
                if (self.timers.items[i].plugin == index) {
                    _ = self.timers.orderedRemove(i);
                } else i += 1;
            }
        }
        if (id.len > 0) self.overlay.remove(id);
        self.vessels.clearSource(source, now_ms);
        _ = self.ais.clearSource(source) catch {};
    }

    // -- sockets, as the natives use them ------------------------------------

    /// Register a connection and hand back its id at once. The resolve and the
    /// connect happen on the I/O thread, so a plugin never blocks mid-event on
    /// a name lookup or a slow handshake; the outcome arrives as
    /// TCP_CONNECTED or TCP_CLOSED.
    pub fn openConn(self: *Broker, plugin: u32, hostname: []const u8, port: u16) i64 {
        if (hostname.len == 0 or hostname.len > 255) return -1;
        const owned = self.alloc.dupe(u8, hostname) catch return -1;
        self.mu.lock();
        const id = self.next_conn;
        self.next_conn += 1;
        self.conns.append(self.alloc, .{
            .id = id,
            .plugin = plugin,
            .state = .resolving,
            .host = owned,
            .port = port,
        }) catch {
            self.mu.unlock();
            self.alloc.free(owned);
            return -1;
        };
        self.mu.unlock();
        self.wakeIo();
        return id;
    }

    /// Queue bytes for the I/O thread to write. Returns how many were taken,
    /// or -1 for an unknown connection or one belonging to another plugin.
    pub fn sendConn(self: *Broker, plugin: u32, id: i64, data: []const u8) i32 {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.connIndexLocked(id) orelse return -1;
        const c = &self.conns.items[idx];
        if (c.plugin != plugin or c.closing) return -1;
        c.out.appendSlice(self.alloc, data) catch return -1;
        self.wakeIo();
        return @intCast(data.len);
    }

    /// Mark a connection for close. The I/O thread reaps it without a
    /// TCP_CLOSED event: the plugin asked, so it already knows.
    pub fn requestClose(self: *Broker, plugin: u32, id: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.connIndexLocked(id) orelse return;
        if (self.conns.items[idx].plugin != plugin) return;
        self.conns.items[idx].closing = true;
        self.wakeIo();
    }

    // -- the I/O thread ------------------------------------------------------

    pub fn start(self: *Broker) !void {
        if (self.io_thread != null) return;
        if (std.c.pipe(&self.wake) != 0) return error.PipeFailed;
        setNonBlocking(self.wake[0]);
        setNonBlocking(self.wake[1]);
        self.next_tick = monoMs() + tick_ms;
        self.stopping.store(false, .release);
        self.io_thread = try std.Thread.spawn(.{}, ioMain, .{self});
    }

    pub fn stop(self: *Broker) void {
        const th = self.io_thread orelse return;
        self.stopping.store(true, .release);
        self.wakeIo();
        th.join();
        self.io_thread = null;
        for (self.wake) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        self.wake = .{ -1, -1 };
    }

    fn wakeIo(self: *Broker) void {
        if (self.wake[1] < 0) return;
        const one = [_]u8{0};
        _ = std.c.write(self.wake[1], &one, 1);
    }

    fn ioMain(self: *Broker) void {
        var fds: std.ArrayList(std.c.pollfd) = .empty;
        defer fds.deinit(self.alloc);
        // Parallel to `fds` after the wake pipe: which connection each slot is.
        var owners: std.ArrayList(i64) = .empty;
        defer owners.deinit(self.alloc);

        while (!self.stopping.load(.acquire)) {
            self.startPending();
            const timeout = self.buildPollSet(&fds, &owners);
            const n = std.posix.poll(fds.items, timeout) catch 0;
            if (n > 0) {
                if (fds.items[0].revents != 0) drainPipe(self.wake[0]);
                self.serviceSockets(fds.items[1..], owners.items);
            }
            self.fireTimers();
            self.fanout();
        }
    }

    /// Resolve and connect anything tcp_connect handed over. Runs on the I/O
    /// thread so a name lookup never stalls a plugin mid-event.
    fn startPending(self: *Broker) void {
        while (true) {
            var id: i64 = 0;
            var host_copy: [256]u8 = undefined;
            var host_len: usize = 0;
            var port: u16 = 0;
            var plugin: u32 = 0;
            {
                self.mu.lock();
                defer self.mu.unlock();
                const c = for (self.conns.items) |*c| {
                    if (c.state == .resolving and !c.closing) break c;
                } else {
                    return;
                };
                id = c.id;
                host_len = @min(c.host.len, host_copy.len);
                @memcpy(host_copy[0..host_len], c.host[0..host_len]);
                port = c.port;
                plugin = c.plugin;
                // Claim it before unlocking so the next pass does not retry it.
                c.state = .connecting;
            }

            const fd = dial(host_copy[0..host_len], port) catch |e| {
                self.say(level_warn, "host", "tcp connect to {s}:{d} failed: {s}", .{ host_copy[0..host_len], port, @errorName(e) });
                self.finishConn(id, plugin, null);
                continue;
            };
            self.finishConn(id, plugin, fd);
        }
    }

    /// Attach the socket to its connection, or report the failure as a close.
    fn finishConn(self: *Broker, id: i64, plugin: u32, fd: ?std.c.fd_t) void {
        var gone = false;
        {
            self.mu.lock();
            defer self.mu.unlock();
            const idx = self.connIndexLocked(id) orelse {
                if (fd) |f| _ = std.c.close(f);
                return;
            };
            if (fd) |f| {
                self.conns.items[idx].fd = f;
                return;
            }
            var c = self.conns.orderedRemove(idx);
            c.out.deinit(self.alloc);
            self.alloc.free(c.host);
            gone = true;
        }
        if (gone) self.push(plugin, Kind.tcp_closed, @bitCast(id), "");
    }

    fn connIndexLocked(self: *Broker, id: i64) ?usize {
        for (self.conns.items, 0..) |c, i| if (c.id == id) return i;
        return null;
    }

    /// Poll set: the wake pipe first, then one slot per connection with a
    /// socket. Returns the timeout in ms — the nearest of the next timer and
    /// the next fanout tick, so an idle host wakes 10 times a second.
    fn buildPollSet(self: *Broker, fds: *std.ArrayList(std.c.pollfd), owners: *std.ArrayList(i64)) i32 {
        self.mu.lock();
        defer self.mu.unlock();

        fds.clearRetainingCapacity();
        owners.clearRetainingCapacity();
        fds.append(self.alloc, .{ .fd = self.wake[0], .events = std.c.POLL.IN, .revents = 0 }) catch {};
        for (self.conns.items) |*c| {
            if (c.fd < 0 or c.closing) continue;
            var events: i16 = std.c.POLL.IN;
            if (c.state == .connecting or c.out.items.len > 0) events |= std.c.POLL.OUT;
            fds.append(self.alloc, .{ .fd = c.fd, .events = events, .revents = 0 }) catch break;
            owners.append(self.alloc, c.id) catch break;
        }

        const now = monoMs();
        var deadline = self.next_tick;
        for (self.timers.items) |tm| {
            if (tm.due < deadline) deadline = tm.due;
        }
        const wait = deadline - now;
        return @intCast(std.math.clamp(wait, 0, tick_ms));
    }

    fn serviceSockets(self: *Broker, fds: []std.c.pollfd, owners: []const i64) void {
        for (fds, 0..) |pfd, i| {
            if (i >= owners.len) break;
            if (pfd.revents == 0) continue;
            self.serviceOne(owners[i], pfd.revents);
        }
        self.reapClosing();
    }

    fn serviceOne(self: *Broker, id: i64, revents: i16) void {
        var plugin: u32 = 0;
        var fd: std.c.fd_t = -1;
        var state: ConnState = .open;
        {
            self.mu.lock();
            defer self.mu.unlock();
            const idx = self.connIndexLocked(id) orelse return;
            const c = &self.conns.items[idx];
            if (c.closing) return;
            plugin = c.plugin;
            fd = c.fd;
            state = c.state;
        }

        if (state == .connecting) {
            var err: i32 = 0;
            var len: std.c.socklen_t = @sizeOf(i32);
            _ = std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &err, &len);
            if (err != 0 or (revents & (std.c.POLL.ERR | std.c.POLL.HUP | std.c.POLL.NVAL)) != 0) {
                self.closeConn(id, plugin, true);
                return;
            }
            {
                self.mu.lock();
                defer self.mu.unlock();
                const idx = self.connIndexLocked(id) orelse return;
                self.conns.items[idx].state = .open;
            }
            self.push(plugin, Kind.tcp_connected, @bitCast(id), "");
            return;
        }

        if ((revents & std.c.POLL.OUT) != 0) self.flushConn(id);

        if ((revents & std.c.POLL.IN) != 0) {
            var buf: [read_chunk]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            if (n > 0) {
                self.push(plugin, Kind.tcp_data, @bitCast(id), buf[0..@intCast(n)]);
            } else if (n == 0) {
                self.closeConn(id, plugin, true);
                return;
            } else {
                const e = std.c.errno(n);
                if (e != .AGAIN and e != .INTR) {
                    self.closeConn(id, plugin, true);
                    return;
                }
            }
        }
        if ((revents & (std.c.POLL.ERR | std.c.POLL.HUP | std.c.POLL.NVAL)) != 0) {
            self.closeConn(id, plugin, true);
        }
    }

    fn flushConn(self: *Broker, id: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.connIndexLocked(id) orelse return;
        const c = &self.conns.items[idx];
        while (c.out.items.len > 0) {
            const n = std.c.write(c.fd, c.out.items.ptr, c.out.items.len);
            if (n <= 0) return;
            const wrote: usize = @intCast(n);
            std.mem.copyForwards(u8, c.out.items[0 .. c.out.items.len - wrote], c.out.items[wrote..]);
            c.out.shrinkRetainingCapacity(c.out.items.len - wrote);
        }
    }

    /// Take a connection down. `notify` sends TCP_CLOSED — true when the peer
    /// or an error ended it, false when the plugin asked for the close.
    fn closeConn(self: *Broker, id: i64, plugin: u32, notify: bool) void {
        {
            self.mu.lock();
            defer self.mu.unlock();
            const idx = self.connIndexLocked(id) orelse return;
            var c = self.conns.orderedRemove(idx);
            if (c.fd >= 0) _ = std.c.close(c.fd);
            c.out.deinit(self.alloc);
            self.alloc.free(c.host);
        }
        if (notify) self.push(plugin, Kind.tcp_closed, @bitCast(id), "");
    }

    /// Sockets tcp_close marked. Done outside the poll walk so a close cannot
    /// invalidate the slot being serviced.
    fn reapClosing(self: *Broker) void {
        while (true) {
            var id: i64 = 0;
            {
                self.mu.lock();
                defer self.mu.unlock();
                const c = for (self.conns.items) |*c| {
                    if (c.closing) break c;
                } else return;
                id = c.id;
            }
            self.closeConn(id, 0, false);
        }
    }

    fn fireTimers(self: *Broker) void {
        const now = monoMs();
        while (true) {
            var id: i64 = 0;
            var plugin: u32 = 0;
            {
                self.mu.lock();
                defer self.mu.unlock();
                var hit: ?usize = null;
                for (self.timers.items, 0..) |tm, i| {
                    if (tm.due <= now) {
                        hit = i;
                        break;
                    }
                }
                const i = hit orelse return;
                id = self.timers.items[i].id;
                plugin = self.timers.items[i].plugin;
                if (self.timers.items[i].period > 0) {
                    // Advance past now rather than by one period: a host that
                    // was blocked must not then fire a burst of catch-up ticks.
                    const p = self.timers.items[i].period;
                    var due = self.timers.items[i].due + p;
                    if (due <= now) due = now + p;
                    self.timers.items[i].due = due;
                } else _ = self.timers.orderedRemove(i);
                self.pushLocked(plugin, Kind.timer, @bitCast(id), "");
            }
        }
    }

    // -- the fanout tick -----------------------------------------------------

    fn fanout(self: *Broker) void {
        const mono = monoMs();
        if (mono < self.next_tick) return;
        self.next_tick = mono + tick_ms;
        const now = wallMs();

        // FIRST: a handover that happens because a value went stale produces no
        // write, so without this the subscriber never hears about it.
        _ = self.vessels.refresh(now);

        self.fanoutStore(now);
        self.fanoutAis(now, mono);
    }

    fn fanoutStore(self: *Broker, now: i64) void {
        var changes: std.ArrayList(vstore.Change) = .empty;
        defer changes.deinit(self.vessels.alloc);
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.alloc);

        var i: usize = 0;
        while (true) {
            var plugin: u32 = 0;
            var sub: vstore.SubId = 0;
            {
                self.mu.lock();
                defer self.mu.unlock();
                if (i >= self.plugins.items.len) return;
                const p = self.plugins.items[i];
                i += 1;
                if (!p.enabled) continue;
                sub = p.sub orelse continue;
                plugin = p.index;
            }
            if (!self.vessels.hasChanges(sub)) continue;

            changes.clearRetainingCapacity();
            self.vessels.collectChanged(sub, now, &changes) catch continue;
            if (changes.items.len == 0) continue;

            json.clearRetainingCapacity();
            writeStoreChanged(&json, self.alloc, changes.items, now) catch continue;
            self.push(plugin, Kind.store_changed, 0, json.items);
        }
    }

    fn fanoutAis(self: *Broker, now: i64, mono: i64) void {
        _ = self.ais.evict(now) catch {};
        if (mono - self.last_ais_ms < ais_min_interval_ms) return;
        const seq = self.ais.seq();
        if (seq == self.last_ais_seq) return;
        self.last_ais_ms = mono;
        self.last_ais_seq = seq;

        const snap = self.ais.snapshot(self.alloc) catch return;
        defer self.alloc.free(snap);
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.alloc);
        writeAisChanged(&json, self.alloc, snap, now) catch return;

        self.mu.lock();
        defer self.mu.unlock();
        for (self.plugins.items) |p| {
            if (!p.enabled or !p.ais_sub) continue;
            self.pushLocked(p.index, Kind.ais_changed, 0, json.items);
        }
    }
};

// ---- JSON the host writes ---------------------------------------------------

/// `{"values":[{"path":..,"value":..,"ts":..,"age_ms":..}]}`.
///
/// A path with no value left — its only source was cleared, or the plugin that
/// owned it was disabled — is emitted as `{"path":..,"value":null}` with no
/// timestamp. A null value IS the removal; there is no separate "del" list, and
/// a timestamp on a value that no longer exists would be a lie.
fn writeStoreChanged(out: *std.ArrayList(u8), alloc: std.mem.Allocator, changes: []const vstore.Change, now: i64) !void {
    try out.appendSlice(alloc, "{\"values\":[");
    var first = true;
    var vbuf: [vstore.max_value_json]u8 = undefined;
    for (changes) |ch| {
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.appendSlice(alloc, "{\"path\":");
        try writeJsonString(out, alloc, ch.path);
        const r = ch.reading orelse {
            try out.appendSlice(alloc, ",\"value\":null}");
            continue;
        };
        const text = r.value.toJson(&vbuf) catch "null";
        try out.print(alloc, ",\"value\":{s},\"ts\":{d},\"age_ms\":{d}}}", .{ text, r.ts_ms, now - r.ts_ms });
    }
    try out.appendSlice(alloc, "]}");
}

/// `{"targets":[{"mmsi":..,...,"age_ms":..}]}` — the full snapshot, absent
/// fields omitted rather than sent as null, so a plugin can tell "never heard"
/// from "heard as zero".
fn writeAisChanged(out: *std.ArrayList(u8), alloc: std.mem.Allocator, targets: []const ais_store.Target, now: i64) !void {
    try out.appendSlice(alloc, "{\"targets\":[");
    for (targets, 0..) |tg, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "{{\"mmsi\":{d}", .{tg.mmsi});
        if (tg.lat) |v| try out.print(alloc, ",\"lat\":{d}", .{v});
        if (tg.lon) |v| try out.print(alloc, ",\"lon\":{d}", .{v});
        if (tg.sog) |v| try out.print(alloc, ",\"sog\":{d}", .{v});
        if (tg.cog) |v| try out.print(alloc, ",\"cog\":{d}", .{v});
        if (tg.heading) |v| try out.print(alloc, ",\"heading\":{d}", .{v});
        if (tg.name()) |n| {
            try out.appendSlice(alloc, ",\"name\":");
            try writeJsonString(out, alloc, n);
        }
        try out.print(alloc, ",\"ts\":{d},\"age_ms\":{d}}}", .{ tg.ts_ms, now - tg.ts_ms });
    }
    try out.appendSlice(alloc, "]}");
}

fn writeJsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        0...8, 11, 12, 14...31 => try out.print(alloc, "\\u{x:0>4}", .{c}),
        else => try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

// ---- the natives ------------------------------------------------------------

/// The calling plugin, or null when the instance has no user data (which only
/// happens if a module is driven outside the host).
fn caller(env: wasm.c.wasm_exec_env_t) ?*Plugin {
    const raw = wasm.callerUserData(env) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn bytes(ptr: [*c]const u8, len: u32) []const u8 {
    if (len == 0 or ptr == null) return &[_]u8{};
    return ptr[0..len];
}

/// Grant check. Refusal is a log line and a -1, never a trap.
fn allow(p: *Plugin, cap: Cap, call: []const u8) bool {
    if (p.caps.contains(cap)) return true;
    p.denied += 1;
    p.broker.denied += 1;
    p.broker.say(level_err, p.id, "denied {s}: manifest does not request capability {s}", .{ call, cap.name() });
    return false;
}

fn hostLog(env: wasm.c.wasm_exec_env_t, level: u32, ptr: [*c]const u8, len: u32) callconv(.c) void {
    const p = caller(env) orelse return;
    p.broker.log_fn(p.broker.log_ctx, @min(level, level_err), p.id, bytes(ptr, len));
}

fn hostNowMs(env: wasm.c.wasm_exec_env_t) callconv(.c) i64 {
    _ = env;
    return wallMs();
}

fn hostMonoMs(env: wasm.c.wasm_exec_env_t) callconv(.c) i64 {
    _ = env;
    return monoMs();
}

fn hostPublish(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .vessel_publish, "publish")) return -1;
    return applyPublish(p, bytes(ptr, len));
}

/// `{"updates":[{"path":..,"value":..,"ts":..}]}`. A bad update is skipped and
/// counted; a batch that is not an object at all fails. The return is the
/// number of updates applied, so a plugin can see its own typos.
fn applyPublish(p: *Plugin, json: []const u8) i32 {
    const alloc = p.broker.alloc;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch {
        p.broker.say(level_warn, p.id, "publish: malformed JSON", .{});
        return -1;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return -1;
    const updates = parsed.value.object.get("updates") orelse return -1;
    if (updates != .array) return -1;

    var applied: i32 = 0;
    for (updates.array.items) |u| {
        if (u != .object) continue;
        const o = u.object;
        const path = switch (o.get("path") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const ts = jsonInt(o.get("ts")) orelse wallMs();
        // The store parses the value from its JSON TEXT, so re-emit the node.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);
        writeJsonValue(&text, alloc, o.get("value") orelse std.json.Value{ .null = {} }) catch continue;
        p.broker.vessels.set(path, text.items, ts, p.source) catch |e| {
            p.broker.say(level_warn, p.id, "publish {s}: {s}", .{ path, @errorName(e) });
            continue;
        };
        applied += 1;
    }
    return applied;
}

fn hostAisUpsert(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .ais_publish, "ais_upsert")) return -1;
    const alloc = p.broker.alloc;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes(ptr, len), .{}) catch {
        p.broker.say(level_warn, p.id, "ais_upsert: malformed JSON", .{});
        return -1;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return -1;
    const targets = parsed.value.object.get("targets") orelse return -1;
    if (targets != .array) return -1;

    var applied: i32 = 0;
    for (targets.array.items) |tv| {
        if (tv != .object) continue;
        const o = tv.object;
        const mmsi = jsonInt(o.get("mmsi")) orelse continue;
        if (mmsi <= 0 or mmsi > std.math.maxInt(u32)) continue;
        const upd = ais_store.Update{
            .mmsi = @intCast(mmsi),
            .lat = jsonNum(o.get("lat")),
            .lon = jsonNum(o.get("lon")),
            // SI everywhere: `sog` on the wire is METRES PER SECOND, the same
            // unit navigation.speedOverGround carries. The AIS wire format
            // reports knots; converting is the parsing plugin's job, not the
            // store's, so nothing downstream has to ask which unit it holds.
            .sog = jsonNum(o.get("sog")),
            .cog = jsonNum(o.get("cog")),
            .heading = jsonNum(o.get("heading")),
            .name = switch (o.get("name") orelse std.json.Value{ .null = {} }) {
                .string => |s| s,
                else => null,
            },
            .ts_ms = jsonInt(o.get("ts")) orelse wallMs(),
        };
        p.broker.ais.upsert(upd, p.source) catch |e| {
            p.broker.say(level_warn, p.id, "ais_upsert {d}: {s}", .{ mmsi, @errorName(e) });
            continue;
        };
        applied += 1;
    }
    return applied;
}

fn hostOverlay(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .overlay_draw, "overlay")) return -1;
    p.broker.overlay.apply(p.id, bytes(ptr, len)) catch |e| {
        p.broker.say(level_warn, p.id, "overlay: {s}", .{@errorName(e)});
        return -1;
    };
    return 0;
}

fn hostChromeStatus(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) void {
    const p = caller(env) orelse return;
    const text = bytes(ptr, len);
    const n = @min(text.len, max_status);
    const changed = n != p.status_len or !std.mem.eql(u8, p.status_buf[0..n], text[0..n]);
    @memcpy(p.status_buf[0..n], text[0..n]);
    p.status_len = n;
    // Only transitions: a plugin posting the same status at 1 Hz would
    // otherwise fill the log with the line that says nothing changed.
    if (changed) p.broker.say(level_info, p.id, "status {s}", .{text});
}

fn hostAlert(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .alerts_raise, "alert")) return -1;
    const text = bytes(ptr, len);
    const n = @min(text.len, max_alert);
    @memcpy(p.alert_buf[0..n], text[0..n]);
    p.alert_len = n;
    // The prototype has no alarm surface, so an alert IS its log line, and it
    // goes out at error level whatever its severity says: a chartplotter that
    // swallows an alarm is worse than one that shouts a caution.
    p.broker.say(level_err, p.id, "ALERT {s}", .{text});
    return 0;
}

fn hostTcpConnect(env: wasm.c.wasm_exec_env_t, host_ptr: [*c]const u8, host_len: u32, port: u32) callconv(.c) i64 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_tcp_client, "tcp_connect")) return -1;
    if (port == 0 or port > 65535) return -1;
    return p.broker.openConn(p.index, bytes(host_ptr, host_len), @intCast(port));
}

fn hostTcpSend(env: wasm.c.wasm_exec_env_t, id: i64, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_tcp_client, "tcp_send")) return -1;
    return p.broker.sendConn(p.index, id, bytes(ptr, len));
}

fn hostTcpClose(env: wasm.c.wasm_exec_env_t, id: i64) callconv(.c) void {
    const p = caller(env) orelse return;
    p.broker.requestClose(p.index, id);
}

fn hostTimerSet(env: wasm.c.wasm_exec_env_t, delay_ms: i64, periodic: u32) callconv(.c) i64 {
    const p = caller(env) orelse return -1;
    const b = p.broker;
    // A zero or negative delay would spin the I/O thread; 1 ms is the floor.
    const delay = @max(delay_ms, 1);
    b.mu.lock();
    defer b.mu.unlock();
    const id = b.next_timer;
    b.next_timer += 1;
    b.timers.append(b.alloc, .{
        .id = id,
        .plugin = p.index,
        .due = monoMs() + delay,
        .period = if (periodic != 0) delay else 0,
    }) catch return -1;
    b.wakeIo();
    return id;
}

fn hostTimerCancel(env: wasm.c.wasm_exec_env_t, id: i64) callconv(.c) void {
    const p = caller(env) orelse return;
    const b = p.broker;
    b.mu.lock();
    defer b.mu.unlock();
    for (b.timers.items, 0..) |tm, i| {
        if (tm.id == id and tm.plugin == p.index) {
            _ = b.timers.orderedRemove(i);
            return;
        }
    }
}

fn hostSubscribe(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .vessel_read, "subscribe")) return -1;
    const alloc = p.broker.alloc;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes(ptr, len), .{}) catch {
        p.broker.say(level_warn, p.id, "subscribe: malformed JSON", .{});
        return -1;
    };
    defer parsed.deinit();
    if (parsed.value != .array) return -1;

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);
    for (parsed.value.array.items) |v| switch (v) {
        .string => |s| paths.append(alloc, s) catch return -1,
        else => {},
    };
    if (paths.items.len == 0) return -1;

    const b = p.broker;
    b.mu.lock();
    defer b.mu.unlock();
    // One subscription per plugin: a second call replaces the first, so a
    // plugin that re-subscribes on reconnect does not leak handles.
    if (p.sub) |old| b.vessels.unsubscribe(old);
    p.sub = b.vessels.subscribe(p.source, paths.items) catch {
        p.sub = null;
        return -1;
    };
    return @intCast(paths.items.len);
}

fn hostAisSubscribe(env: wasm.c.wasm_exec_env_t) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .ais_read, "ais_subscribe")) return -1;
    const b = p.broker;
    b.mu.lock();
    defer b.mu.unlock();
    p.ais_sub = true;
    // Deliver the current target set on the next tick rather than waiting for
    // a target to move.
    b.last_ais_seq = ~b.last_ais_seq;
    return 0;
}

/// The symbol table, exactly PROTOTYPE.md's frozen import list. WAMR keeps the
/// array pointer rather than copying, so this is a container-level var.
var natives = wasm.nativeSymbols(&.{
    .{ .name = "log", .func = @ptrCast(&hostLog), .signature = "(i*~)" },
    .{ .name = "now_ms", .func = @ptrCast(&hostNowMs), .signature = "()I" },
    .{ .name = "mono_ms", .func = @ptrCast(&hostMonoMs), .signature = "()I" },
    .{ .name = "publish", .func = @ptrCast(&hostPublish), .signature = "(*~)i" },
    .{ .name = "ais_upsert", .func = @ptrCast(&hostAisUpsert), .signature = "(*~)i" },
    .{ .name = "overlay", .func = @ptrCast(&hostOverlay), .signature = "(*~)i" },
    .{ .name = "chrome_status", .func = @ptrCast(&hostChromeStatus), .signature = "(*~)" },
    .{ .name = "alert", .func = @ptrCast(&hostAlert), .signature = "(*~)i" },
    .{ .name = "tcp_connect", .func = @ptrCast(&hostTcpConnect), .signature = "(*~i)I" },
    .{ .name = "tcp_send", .func = @ptrCast(&hostTcpSend), .signature = "(I*~)i" },
    .{ .name = "tcp_close", .func = @ptrCast(&hostTcpClose), .signature = "(I)" },
    .{ .name = "timer_set", .func = @ptrCast(&hostTimerSet), .signature = "(Ii)I" },
    .{ .name = "timer_cancel", .func = @ptrCast(&hostTimerCancel), .signature = "(I)" },
    .{ .name = "subscribe", .func = @ptrCast(&hostSubscribe), .signature = "(*~)i" },
    .{ .name = "ais_subscribe", .func = @ptrCast(&hostAisSubscribe), .signature = "()i" },
});

/// Register the import table under module name `lookout`. Process-global, like
/// the runtime: call once after `wasm.initRuntime`, before the first
/// instantiation. The host does this.
pub fn registerNatives() wasm.Error!void {
    try wasm.registerNatives("lookout", &natives);
}

pub fn unregisterNatives() void {
    wasm.unregisterNatives("lookout", &natives);
}

// ---- small helpers ----------------------------------------------------------

/// Wall clock, milliseconds since the epoch: what a `ts` on the wire means and
/// what the stores are stamped with. Zig 0.16 dropped std.time.milliTimestamp,
/// so this is the same clock_gettime the rest of the core reads.
pub fn wallMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Monotonic milliseconds: timer deadlines and fanout pacing, which must not
/// jump when the clock is set.
pub fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return wallMs();
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// A kernel sleep. Zig 0.16's std.Thread.sleep wants an Io this layer does not
/// take; the same extern the rest of the core uses (src/lock.zig).
pub fn sleepMs(ms: u32) void {
    const p = struct {
        extern "c" fn usleep(usec: u32) c_int;
    };
    _ = p.usleep(ms * 1000);
}

fn setNonBlocking(fd: std.c.fd_t) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock);
}

fn drainPipe(fd: std.c.fd_t) void {
    var buf: [64]u8 = undefined;
    while (std.c.read(fd, &buf, buf.len) > 0) {}
}

/// Resolve `host` and start a non-blocking connect. The socket comes back
/// mid-handshake; the I/O thread completes it on POLLOUT.
fn dial(host: []const u8, port: u16) !std.c.fd_t {
    var host_z: [256]u8 = undefined;
    if (host.len >= host_z.len) return error.HostTooLong;
    @memcpy(host_z[0..host.len], host);
    host_z[host.len] = 0;
    var port_z: [8]u8 = undefined;
    const ps = try std.fmt.bufPrintZ(&port_z, "{d}", .{port});

    var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    if (std.c.getaddrinfo(@ptrCast(&host_z), ps.ptr, &hints, &res) != @as(std.c.EAI, @enumFromInt(0)))
        return error.ResolveFailed;
    const list = res orelse return error.ResolveFailed;
    defer std.c.freeaddrinfo(list);

    var it: ?*std.c.addrinfo = list;
    while (it) |ai| : (it = ai.next) {
        const addr = ai.addr orelse continue;
        const fd = std.c.socket(@intCast(ai.family), @intCast(ai.socktype), @intCast(ai.protocol));
        if (fd < 0) continue;
        setNonBlocking(fd);
        if (std.c.connect(fd, addr, ai.addrlen) == 0) return fd;
        const e = std.c.errno(@as(c_int, -1));
        if (e == .INPROGRESS or e == .INTR or e == .ALREADY) return fd;
        _ = std.c.close(fd);
    }
    return error.ConnectFailed;
}

fn jsonNum(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonInt(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Re-emit a parsed JSON node as text. Only the shapes a published value may
/// take are written; anything else becomes null, which the store rejects.
fn writeJsonValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try out.appendSlice(alloc, "null"),
        .integer => |i| try out.print(alloc, "{d}", .{i}),
        .float => |f| {
            if (!std.math.isFinite(f)) return error.NotFinite;
            try out.print(alloc, "{d}", .{f});
        },
        .number_string => |s| try out.appendSlice(alloc, s),
        .object => |o| {
            const lat = jsonNum(o.get("lat")) orelse return error.Unsupported;
            const lon = jsonNum(o.get("lon")) orelse return error.Unsupported;
            try out.print(alloc, "{{\"lat\":{d},\"lon\":{d}}}", .{ lat, lon });
        },
        else => return error.Unsupported,
    }
}

// ---- tests -------------------------------------------------------------------

const t = std.testing;

test "capability names round-trip" {
    for (std.enums.values(Cap)) |c| {
        try t.expectEqual(c, Cap.fromName(c.name()).?);
    }
    try t.expect(Cap.fromName("net.udp") == null);
}

test "STORE_CHANGED carries values, and a cleared path as a bare null" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const changes = [_]vstore.Change{
        .{ .path = "navigation.position", .reading = .{
            .value = .{ .position = .{ .lat = 38.9763, .lon = -76.4767 } },
            .ts_ms = 1_000,
            .age_ms = 120,
            .source = 1,
            .stale = false,
        } },
        .{ .path = "environment.depth.belowTransducer", .reading = null },
    };
    try writeStoreChanged(&out, a, &changes, 1_120);
    try t.expectEqualStrings(
        "{\"values\":[" ++
            "{\"path\":\"navigation.position\",\"value\":{\"lat\":38.9763,\"lon\":-76.4767},\"ts\":1000,\"age_ms\":120}," ++
            "{\"path\":\"environment.depth.belowTransducer\",\"value\":null}]}",
        out.items,
    );
}

test "AIS_CHANGED omits fields never heard and always carries age" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var named = ais_store.Target{ .mmsi = 366123456, .lat = 38.98, .lon = -76.47, .sog = 2.6, .ts_ms = 1_000 };
    @memcpy(named.name_buf[0..10], "EVER GIVEN");
    named.name_len = 10;
    const targets = [_]ais_store.Target{ named, .{ .mmsi = 7, .ts_ms = 500 } };
    try writeAisChanged(&out, a, &targets, 2_000);
    try t.expectEqualStrings(
        "{\"targets\":[" ++
            "{\"mmsi\":366123456,\"lat\":38.98,\"lon\":-76.47,\"sog\":2.6,\"name\":\"EVER GIVEN\",\"ts\":1000,\"age_ms\":1000}," ++
            "{\"mmsi\":7,\"ts\":500,\"age_ms\":1500}]}",
        out.items,
    );
}

test "a JSON string is escaped, not pasted" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeJsonString(&out, a, "a\"b\\c\nd\x01");
    try t.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", out.items);
}

test "a published value re-emits as the text the store parses" {
    const a = t.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"lat\":38.9,\"lon\":-76.4}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeJsonValue(&out, a, parsed.value);
    try t.expectEqualStrings("{\"lat\":38.9,\"lon\":-76.4}", out.items);

    out.clearRetainingCapacity();
    try writeJsonValue(&out, a, .{ .float = 2.9 });
    try t.expectEqualStrings("2.9", out.items);
    out.clearRetainingCapacity();
    try writeJsonValue(&out, a, .{ .null = {} });
    try t.expectEqualStrings("null", out.items);
    try t.expectError(error.Unsupported, writeJsonValue(&out, a, .{ .string = "EVER GIVEN" }));
}

test "the event queue is FIFO across plugins and compacts as it drains" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    for (0..200) |i| b.push(@intCast(i % 3), Kind.timer, i, "x");
    try t.expectEqual(@as(usize, 200), b.queued());
    for (0..200) |i| {
        const e = b.pop().?;
        defer b.freeEvent(e);
        try t.expectEqual(@as(u64, i), e.handle);
        try t.expectEqual(@as(u32, @intCast(i % 3)), e.plugin);
    }
    try t.expect(b.pop() == null);
    try t.expectEqual(@as(usize, 0), b.queued());
}

test "dropping a plugin takes its queued events and its store contributions" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    var p = Plugin{ .broker = &b, .index = 1, .id = "org.beetlebug.gone", .source = 1, .caps = Caps.initEmpty() };
    try b.registerPlugin(&p);
    try vessels.set("navigation.position", "{\"lat\":1,\"lon\":2}", 0, 1);
    try ais.upsert(.{ .mmsi = 5, .lat = 1, .lon = 2, .ts_ms = 0 }, 1);

    b.push(0, Kind.timer, 1, "");
    b.push(1, Kind.timer, 2, "");
    b.push(0, Kind.timer, 3, "");
    b.dropPlugin(1, 100);

    try t.expect(!p.enabled);
    try t.expectEqual(@as(usize, 2), b.queued());
    const a = b.pop().?;
    b.freeEvent(a);
    const c = b.pop().?;
    defer b.freeEvent(c);
    try t.expectEqual(@as(u64, 1), a.handle);
    try t.expectEqual(@as(u64, 3), c.handle);
    try t.expect(vessels.readElected("navigation.position", 100) == null);
    try t.expectEqual(@as(usize, 0), ais.count());
}

test "a plugin socket connects, carries bytes both ways, and reports the close" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    var srv = try Listener.open();
    defer srv.close();

    try b.start();
    const id = b.openConn(0, "127.0.0.1", srv.port);
    try t.expect(id > 0);

    // accept() blocks here until the I/O thread's connect lands.
    const peer = try srv.accept();
    defer _ = std.c.close(peer);
    try t.expectEqual(Kind.tcp_connected, try expectEvent(&b, 2_000));

    _ = std.c.write(peer, "$GPRMC,\r\n", 9);
    try t.expectEqual(Kind.tcp_data, try expectEvent(&b, 2_000));

    // ...and the other direction: what the plugin sends reaches the peer.
    try t.expectEqual(@as(i32, 4), b.sendConn(0, id, "ping"));
    var got: [16]u8 = undefined;
    var n: isize = 0;
    var waited: u32 = 0;
    while (n <= 0 and waited < 2_000) : (waited += 5) {
        n = std.c.read(peer, &got, got.len);
        if (n <= 0) sleepMs(5);
    }
    try t.expectEqualStrings("ping", got[0..@intCast(n)]);

    // The peer hanging up is a TCP_CLOSED, and the connection is gone.
    _ = std.c.shutdown(peer, 1); // SHUT_WR: our side reads EOF
    try t.expectEqual(Kind.tcp_closed, try expectEvent(&b, 2_000));
    b.mu.lock();
    const remaining = b.conns.items.len;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), remaining);
}

test "a connection to nothing comes back as a close, not a hang" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();
    b.setLog(null, silentLog);

    try b.start();
    // A name no resolver answers, and a port nothing listens on.
    try t.expect(b.openConn(0, "no-such-host.invalid", 10110) > 0);
    try t.expectEqual(Kind.tcp_closed, try expectEvent(&b, 5_000));
}

fn silentLog(_: ?*anyopaque, _: u32, _: []const u8, _: []const u8) void {}

/// The next event's kind, waiting up to `timeout_ms`.
fn expectEvent(b: *Broker, timeout_ms: u32) !u32 {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (b.pop()) |e| {
            defer b.freeEvent(e);
            return e.kind;
        }
        sleepMs(5);
    }
    return error.NoEvent;
}

/// A loopback listener on an ephemeral port, for the socket tests.
const Listener = struct {
    fd: std.c.fd_t,
    port: u16,

    fn open() !Listener {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        var yes: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.c.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(fd, 1) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
        if (std.c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn accept(self: *Listener) !std.c.fd_t {
        const peer = std.c.accept(self.fd, null, null);
        if (peer < 0) return error.AcceptFailed;
        return peer;
    }

    fn close(self: *Listener) void {
        _ = std.c.close(self.fd);
    }
};
