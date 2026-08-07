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
//! THREADS.
//!   * the caller's thread, during load/start — natives may run here before
//!     any dispatch thread exists;
//!   * ONE DISPATCH THREAD PER PLUGIN (host.zig owns them), inside a wasm
//!     call — every native runs on the thread of the plugin that called it.
//!     Each plugin has its OWN FIFO here, so a plugin stuck in a loop stalls
//!     only itself;
//!   * this file's I/O thread — poll on the plugin sockets, timer deadlines,
//!     the 100 ms fanout tick and the watchdog scan. It only ever ENQUEUES
//!     events, never enters wasm and never joins a dispatch thread, so no
//!     plugin can hold it up;
//!   * a short-lived resolver thread per tcp_connect, which runs getaddrinfo
//!     and hands the socket back. It touches nothing else.
//!
//! LOCK ORDER, outermost first:
//!   1. `mu` — the per-plugin queues, the connection list, the timer list and
//!      the plugin records. Code holding it may take the locks below it;
//!      nothing below it ever takes `mu`.
//!   2. the vessel store's and the AIS store's own locks.
//! Two sinks sit outside that ladder. The LOG sink is a leaf: it may be called
//! with `mu` held (an overflow drop is reported from inside the queue) and must
//! never take a broker lock. The OVERLAY sink is called with NO broker lock
//! held, because the overlay store is also the renderer's. WAMR's locks are
//! taken only by wasm.zig calls, which are never made under `mu` — including
//! the watchdog's terminate, which runs on the I/O thread holding nothing.
//!
//! THE FANOUT TICK is the reason the I/O thread exists at all. It calls
//! `Store.refresh` FIRST: a fix ageing out of its window and handing over to
//! the next source produces no write, so without the refresh a staleness
//! handover would never reach a subscriber. The same tick runs the host's
//! watchdog, which is why the tick period sets the watchdog's precision.

const std = @import("std");
const builtin = @import("builtin");
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

/// The host's watchdog, run from the fanout tick.
///
/// Behind a function pointer for the same reason OverlaySink is: this file must
/// not import host.zig, and the instances the watchdog terminates are the
/// host's. The broker supplies only the clock and the thread to run on — it has
/// no opinion about what "too long" means.
pub const WatchdogSink = struct {
    ctx: ?*anyopaque = null,
    tickFn: ?*const fn (ctx: ?*anyopaque, mono_ms: i64) void = null,

    pub fn tick(self: WatchdogSink, mono_ms: i64) void {
        const f = self.tickFn orelse return;
        f(self.ctx, mono_ms);
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

    /// Replace the chrome status. Normally the plugin's own words, through
    /// `chrome_status`; the host also writes here when it disables a plugin,
    /// which is the one case where nobody is left inside the module to say
    /// what happened. Returns true when the text actually changed.
    pub fn setStatus(self: *Plugin, text: []const u8) bool {
        const n = @min(text.len, max_status);
        const changed = n != self.status_len or !std.mem.eql(u8, self.status_buf[0..n], text[0..n]);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
        return changed;
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

/// ONE FIFO PER PLUGIN, this deep. Over this the prototype's four plugins
/// never queue more than a few dozen events; the cap exists so a plugin that
/// stops consuming cannot grow its queue without bound — and because the
/// queues are separate, the plugin that stops consuming is the only one that
/// loses events.
const max_queued = 1024;

/// Above this depth the I/O thread stops READING that plugin's sockets, which
/// pushes the backlog into the kernel's receive buffer and then onto the peer
/// as TCP window pressure. Three quarters leaves room for the events a paused
/// plugin still gets — timers and fanout, which have nowhere to push back to.
const pause_reads_at = max_queued * 3 / 4;

/// Highest plugin index a queue is kept for. Indices come from the host's
/// registry, so this is a sanity bound on the array a stray push could grow,
/// not a product decision about how many plugins may run.
const max_plugins = 64;

/// One plugin's inbound FIFO.
const Queue = struct {
    items: std.ArrayList(Event) = .empty,
    /// Read cursor. The queue compacts when the cursor has passed half of it,
    /// so a steady stream neither shifts every pop nor grows without bound.
    head: usize = 0,
    /// Events discarded because this queue was full.
    dropped: u64 = 0,
    /// True while this plugin's sockets are not being read.
    paused: bool = false,

    fn depth(self: *const Queue) usize {
        return self.items.items.len - self.head;
    }
};

// ---- sockets and timers ----------------------------------------------------

const ConnState = enum { resolving, connecting, open };

const Conn = struct {
    id: i64,
    plugin: u32,
    state: ConnState,
    fd: net.Socket = net.invalid,
    /// Kept until the socket is connected: a resolver thread reads it, so the
    /// plugin's tcp_connect never blocks on DNS and neither does the I/O
    /// thread.
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

/// Native stack for a resolver thread. It runs getaddrinfo and connect and
/// nothing else — it never enters wasm — so it needs far less than the
/// 16 MiB Zig would otherwise reserve per attempt.
const resolver_stack_bytes: usize = 512 * 1024;

/// How long `stop` waits for the resolver threads before it says so. They are
/// detached and call back into the broker, so the wait itself is not optional;
/// the line exists because a dead nameserver makes it a long one.
const resolver_wait_warn_ms: u32 = 1000;

// ---- the broker ------------------------------------------------------------

pub const Broker = struct {
    alloc: std.mem.Allocator,
    vessels: *vstore.Store,
    ais: *ais_store.AisStore,
    overlay: OverlaySink,
    watchdog: WatchdogSink = .{},
    log_ctx: ?*anyopaque = null,
    log_fn: LogFn = defaultLog,

    mu: Lock = .{},
    /// One FIFO per plugin, indexed by the host's registry index.
    queues: std.ArrayList(Queue) = .empty,

    plugins: std.ArrayList(*Plugin) = .empty,
    conns: std.ArrayList(Conn) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    next_conn: i64 = 1,
    next_timer: i64 = 1,

    io_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Resolver threads still running. `stop` waits for it to reach zero: they
    /// are detached and they call back into this broker, so it must outlive
    /// them.
    resolvers: std.atomic.Value(u32) = .init(0),
    /// Self-pipe: a native run on the dispatch thread writes one byte so the
    /// I/O thread leaves poll at once instead of finishing its current wait.
    /// Without it a 5 ms timer set from inside an event could fire 100 ms late.
    /// A pipe on POSIX, a loopback socket pair on Windows (see net.wakePair).
    wake: [2]net.Socket = .{ net.invalid, net.invalid },

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
        for (self.queues.items) |*q| {
            for (q.items.items[q.head..]) |e| self.alloc.free(e.payload);
            q.items.deinit(self.alloc);
        }
        self.queues.deinit(self.alloc);
        for (self.conns.items) |*c| {
            if (net.valid(c.fd)) net.close(c.fd);
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

    /// Install the host's watchdog. Set it before `start`; clear it (both
    /// arguments null) before the instances it terminates go away.
    pub fn setWatchdog(self: *Broker, ctx: ?*anyopaque, f: ?*const fn (ctx: ?*anyopaque, mono_ms: i64) void) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.watchdog = .{ .ctx = ctx, .tickFn = f };
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
        _ = try self.queueForLocked(p.index);
        try self.plugins.append(self.alloc, p);
    }

    /// Forget a plugin that never finished loading. Its queue stays (indices
    /// are reused by the next load attempt) but is emptied, so a half-started
    /// plugin leaves no events and no dangling record behind.
    pub fn removePlugin(self: *Broker, p: *Plugin) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.plugins.items, 0..) |q, i| {
            if (q == p) {
                _ = self.plugins.orderedRemove(i);
                break;
            }
        }
        self.clearQueueLocked(p.index);
    }

    // -- the queues ----------------------------------------------------------

    /// This plugin's queue, created on first use.
    fn queueForLocked(self: *Broker, plugin: u32) !*Queue {
        if (plugin >= max_plugins) return error.TooManyPlugins;
        while (self.queues.items.len <= plugin) try self.queues.append(self.alloc, .{});
        return &self.queues.items[plugin];
    }

    /// Enqueue one event for one plugin, copying `payload`. Over the cap the
    /// event is dropped and counted against THAT plugin: the queues are
    /// separate, so a plugin that stops consuming loses only its own events.
    ///
    /// SHUTDOWN ignores the cap. It is the one event a plugin must receive to
    /// close its sockets and stop drawing, and dropping it because the plugin
    /// was already in trouble is exactly backwards.
    pub fn push(self: *Broker, plugin: u32, kind: u32, handle: u64, payload: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.pushLocked(plugin, kind, handle, payload);
    }

    fn pushLocked(self: *Broker, plugin: u32, kind: u32, handle: u64, payload: []const u8) void {
        const q = self.queueForLocked(plugin) catch return;
        if (q.depth() >= max_queued and kind != Kind.shutdown) {
            self.dropLocked(q, plugin, kind);
            return;
        }
        const owned = self.alloc.dupe(u8, payload) catch {
            self.dropLocked(q, plugin, kind);
            return;
        };
        q.items.append(self.alloc, .{
            .plugin = plugin,
            .kind = kind,
            .handle = handle,
            .payload = owned,
        }) catch {
            self.alloc.free(owned);
            self.dropLocked(q, plugin, kind);
        };
    }

    /// A dropped event, counted and — for the first one, and then rarely —
    /// said out loud. A silent drop is a plugin that quietly misses fixes.
    fn dropLocked(self: *Broker, q: *Queue, plugin: u32, kind: u32) void {
        q.dropped += 1;
        if (q.dropped != 1 and q.dropped % 1000 != 0) return;
        const id = self.idOfLocked(plugin);
        self.say(level_warn, id, "queue full at {d} events: dropped event {d} ({d} dropped so far)", .{ max_queued, kind, q.dropped });
    }

    fn idOfLocked(self: *Broker, plugin: u32) []const u8 {
        for (self.plugins.items) |p| {
            if (p.index == plugin) return p.id;
        }
        return "host";
    }

    /// The next event for one plugin, or null. The caller owns the payload and
    /// frees it with `freeEvent`.
    pub fn popFor(self: *Broker, plugin: u32) ?Event {
        self.mu.lock();
        defer self.mu.unlock();
        if (plugin >= self.queues.items.len) return null;
        const q = &self.queues.items[plugin];
        if (q.head >= q.items.items.len) {
            if (q.head > 0) {
                q.items.clearRetainingCapacity();
                q.head = 0;
            }
            return null;
        }
        const e = q.items.items[q.head];
        q.head += 1;
        if (q.head > 64 and q.head * 2 > q.items.items.len) {
            const rest = q.items.items.len - q.head;
            std.mem.copyForwards(Event, q.items.items[0..rest], q.items.items[q.head..]);
            q.items.shrinkRetainingCapacity(rest);
            q.head = 0;
        }
        return e;
    }

    pub fn freeEvent(self: *Broker, e: Event) void {
        self.alloc.free(e.payload);
    }

    /// Throw away everything queued for one plugin. Its dispatch thread calls
    /// this on the way out.
    pub fn clearQueue(self: *Broker, plugin: u32) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.clearQueueLocked(plugin);
    }

    fn clearQueueLocked(self: *Broker, plugin: u32) void {
        if (plugin >= self.queues.items.len) return;
        const q = &self.queues.items[plugin];
        for (q.items.items[q.head..]) |e| self.alloc.free(e.payload);
        q.items.clearRetainingCapacity();
        q.head = 0;
    }

    /// Events waiting across every plugin.
    pub fn queued(self: *Broker) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var n: usize = 0;
        for (self.queues.items) |*q| n += q.depth();
        return n;
    }

    pub fn queuedFor(self: *Broker, plugin: u32) usize {
        self.mu.lock();
        defer self.mu.unlock();
        if (plugin >= self.queues.items.len) return 0;
        return self.queues.items[plugin].depth();
    }

    /// Events this plugin lost to a full queue.
    pub fn droppedFor(self: *Broker, plugin: u32) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        if (plugin >= self.queues.items.len) return 0;
        return self.queues.items[plugin].dropped;
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
            self.clearQueueLocked(index);

            var i: usize = 0;
            while (i < self.conns.items.len) {
                if (self.conns.items[i].plugin != index) {
                    i += 1;
                    continue;
                }
                var c = self.conns.orderedRemove(i);
                if (net.valid(c.fd)) net.close(c.fd);
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
        try net.wakePair(&self.wake);
        self.next_tick = monoMs() + tick_ms;
        self.stopping.store(false, .release);
        self.io_thread = try std.Thread.spawn(.{}, ioMain, .{self});
    }

    pub fn stop(self: *Broker) void {
        const th = self.io_thread orelse {
            self.awaitResolvers();
            return;
        };
        self.stopping.store(true, .release);
        self.wakeIo();
        th.join();
        self.io_thread = null;
        // The resolvers write into this broker and are detached, so they have
        // to be gone before anything it owns is. The wake pipe stays open until
        // they are: the last thing each does is write to it.
        self.awaitResolvers();
        for (self.wake) |fd| if (net.valid(fd)) net.close(fd);
        self.wake = .{ net.invalid, net.invalid };
    }

    fn awaitResolvers(self: *Broker) void {
        var waited: u32 = 0;
        var said = false;
        while (self.resolvers.load(.acquire) > 0) : (waited += 2) {
            if (!said and waited >= resolver_wait_warn_ms) {
                said = true;
                self.say(level_warn, "host", "waiting for {d} name lookup(s) to finish", .{self.resolvers.load(.acquire)});
            }
            sleepMs(2);
        }
    }

    fn wakeIo(self: *Broker) void {
        if (!net.valid(self.wake[1])) return;
        const one = [_]u8{0};
        _ = net.send(self.wake[1], &one);
    }

    fn ioMain(self: *Broker) void {
        var fds: std.ArrayList(net.pollfd) = .empty;
        defer fds.deinit(self.alloc);
        // Parallel to `fds` after the wake pipe: which connection each slot is.
        var owners: std.ArrayList(i64) = .empty;
        defer owners.deinit(self.alloc);

        while (!self.stopping.load(.acquire)) {
            self.startPending();
            const timeout = self.buildPollSet(&fds, &owners);
            const n = net.poll(fds.items, timeout);
            if (n > 0) {
                if (fds.items[0].revents != 0) net.drainWake(self.wake[0]);
                self.serviceSockets(fds.items[1..], owners.items);
            }
            if (net.poll_misses_connect_error) self.checkConnecting();
            self.fireTimers();
            self.fanout();
        }
    }

    /// One pending connect, handed to a resolver thread.
    const Resolve = struct {
        br: *Broker,
        id: i64,
        plugin: u32,
        port: u16,
        host_len: usize,
        host: [256]u8,
    };

    /// Hand anything tcp_connect queued to a resolver thread of its own.
    ///
    /// getaddrinfo BLOCKS — on a dead nameserver for seconds — and this used to
    /// run inline here, which meant one plugin's bad hostname stopped every
    /// other plugin's timers, fanout and socket reads for the duration. A
    /// connect is rare (a reconnect loop is one every two seconds at worst), so
    /// a thread per attempt is the cheap answer at this scale; a resolver pool
    /// is the answer at a larger one.
    fn startPending(self: *Broker) void {
        while (true) {
            var id: i64 = 0;
            var plugin: u32 = 0;
            var port: u16 = 0;
            var host_buf: [256]u8 = undefined;
            var host_len: usize = 0;
            {
                self.mu.lock();
                defer self.mu.unlock();
                const c = for (self.conns.items) |*c| {
                    if (c.state == .resolving and !c.closing) break c;
                } else return;
                id = c.id;
                plugin = c.plugin;
                port = c.port;
                host_len = @min(c.host.len, host_buf.len);
                @memcpy(host_buf[0..host_len], c.host[0..host_len]);
                // Claim it before unlocking so the next pass does not retry it.
                c.state = .connecting;
            }

            const req = self.alloc.create(Resolve) catch {
                self.finishConn(id, plugin, null);
                continue;
            };
            req.* = .{ .br = self, .id = id, .plugin = plugin, .port = port, .host_len = host_len, .host = undefined };
            @memcpy(req.host[0..host_len], host_buf[0..host_len]);

            // Counted before the spawn: `stop` waits on this, and the thread
            // may finish before spawn even returns.
            _ = self.resolvers.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{ .stack_size = resolver_stack_bytes }, resolveMain, .{req}) catch |e| {
                _ = self.resolvers.fetchSub(1, .acq_rel);
                self.alloc.destroy(req);
                self.say(level_warn, "host", "no thread to resolve a connect: {s}", .{@errorName(e)});
                self.finishConn(id, plugin, null);
                continue;
            };
            th.detach();
        }
    }

    /// Resolve one hostname and start the connect, off the I/O thread. The
    /// socket comes back mid-handshake and the I/O thread finishes it on
    /// POLLOUT, exactly as before.
    fn resolveMain(req: *Resolve) void {
        const self = req.br;
        const host = req.host[0..req.host_len];
        const fd: ?net.Socket = dial(host, req.port) catch |e| blk: {
            self.say(level_warn, "host", "tcp connect to {s}:{d} failed: {s}", .{ host, req.port, @errorName(e) });
            break :blk null;
        };
        self.finishConn(req.id, req.plugin, fd);
        // The poll set has no slot for a socket that did not exist when it was
        // built, so say so rather than waiting out the tick.
        self.wakeIo();
        self.alloc.destroy(req);
        _ = self.resolvers.fetchSub(1, .acq_rel);
    }

    /// Attach the socket to its connection, or report the failure as a close.
    fn finishConn(self: *Broker, id: i64, plugin: u32, fd: ?net.Socket) void {
        var gone = false;
        {
            self.mu.lock();
            defer self.mu.unlock();
            const idx = self.connIndexLocked(id) orelse {
                if (fd) |f| net.close(f);
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
    ///
    /// BACKPRESSURE lives here. A plugin whose queue is near full has POLL.IN
    /// left off its sockets, so its data backs up in the kernel receive buffer
    /// and from there onto the peer, and the host stops allocating events it
    /// cannot deliver. Only that plugin's sockets go quiet; a slow AIS plugin
    /// does not stop the NMEA feed. On POSIX errors and hangups still arrive,
    /// because poll reports those whether they were asked for or not; the loop
    /// below says what Windows does instead.
    fn buildPollSet(self: *Broker, fds: *std.ArrayList(net.pollfd), owners: *std.ArrayList(i64)) i32 {
        self.mu.lock();
        defer self.mu.unlock();

        fds.clearRetainingCapacity();
        owners.clearRetainingCapacity();
        fds.append(self.alloc, .{ .fd = self.wake[0], .events = net.POLL.IN, .revents = 0 }) catch {};
        for (self.conns.items) |*c| {
            if (!net.valid(c.fd) or c.closing) continue;
            var events: i16 = 0;
            if (!self.pausedLocked(c.plugin)) events |= net.POLL.IN;
            if (c.state == .connecting or c.out.items.len > 0) events |= net.POLL.OUT;
            // A paused socket with nothing to write asks for nothing. WSAPoll
            // rejects such an entry, so Windows leaves it out and picks the
            // error up on the pass after the plugin drains.
            if (events == 0 and net.poll_needs_events) continue;
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

    /// Whether this plugin's sockets are being read, with the state change
    /// logged once each way so a stalled plugin is visible rather than merely
    /// slow.
    fn pausedLocked(self: *Broker, plugin: u32) bool {
        if (plugin >= self.queues.items.len) return false;
        const q = &self.queues.items[plugin];
        const want = q.depth() >= pause_reads_at;
        if (want != q.paused) {
            q.paused = want;
            const id = self.idOfLocked(plugin);
            if (want) {
                self.say(level_warn, id, "queue at {d} events: pausing this plugin's socket reads", .{q.depth()});
            } else {
                self.say(level_info, id, "queue drained to {d} events: reading again", .{q.depth()});
            }
        }
        return want;
    }

    fn serviceSockets(self: *Broker, fds: []net.pollfd, owners: []const i64) void {
        for (fds, 0..) |pfd, i| {
            if (i >= owners.len) break;
            if (pfd.revents == 0) continue;
            self.serviceOne(owners[i], pfd.revents);
        }
        self.reapClosing();
    }

    fn serviceOne(self: *Broker, id: i64, revents: i16) void {
        var plugin: u32 = 0;
        var fd: net.Socket = net.invalid;
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
            const err = net.soError(fd);
            if (err != 0 or (revents & (net.POLL.ERR | net.POLL.HUP | net.POLL.NVAL)) != 0) {
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

        if ((revents & net.POLL.OUT) != 0) self.flushConn(id);

        if ((revents & net.POLL.IN) != 0) {
            var buf: [read_chunk]u8 = undefined;
            const n = net.recv(fd, &buf);
            if (n > 0) {
                self.push(plugin, Kind.tcp_data, @bitCast(id), buf[0..@intCast(n)]);
            } else if (n == 0) {
                self.closeConn(id, plugin, true);
                return;
            } else if (!net.retryable()) {
                self.closeConn(id, plugin, true);
                return;
            }
        }
        if ((revents & (net.POLL.ERR | net.POLL.HUP | net.POLL.NVAL)) != 0) {
            self.closeConn(id, plugin, true);
        }
    }

    /// Ask every connecting socket whether it has failed. Windows only:
    /// WSAPoll never reports a failed non-blocking connect — no POLLERR, no
    /// POLLHUP — so without this a refused connect would sit in `connecting`
    /// for ever. SO_ERROR does report it. The cap is a pass limit, not a
    /// total: a connect left over is checked on the next pass, 100 ms later.
    fn checkConnecting(self: *Broker) void {
        var ids: [16]i64 = undefined;
        var socks: [16]net.Socket = undefined;
        var plugins: [16]u32 = undefined;
        var n: usize = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.conns.items) |*c| {
                if (c.state != .connecting or c.closing or !net.valid(c.fd)) continue;
                if (n == ids.len) break;
                ids[n] = c.id;
                socks[n] = c.fd;
                plugins[n] = c.plugin;
                n += 1;
            }
        }
        for (0..n) |i| {
            if (net.soError(socks[i]) != 0) self.closeConn(ids[i], plugins[i], true);
        }
    }

    fn flushConn(self: *Broker, id: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.connIndexLocked(id) orelse return;
        const c = &self.conns.items[idx];
        while (c.out.items.len > 0) {
            const n = net.send(c.fd, c.out.items);
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
            if (net.valid(c.fd)) net.close(c.fd);
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

        // The watchdog goes first and runs with no lock held: it may terminate
        // an instance, and the dispatch thread that then unwinds needs `mu` to
        // clean up. It never joins that thread — the I/O thread must not be
        // able to wait on a plugin.
        const wd = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            break :blk self.watchdog;
        };
        wd.tick(mono);

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
        if (tg.aton) {
            try out.appendSlice(alloc, ",\"aton\":true");
            if (tg.aton_type) |v| try out.print(alloc, ",\"aton_type\":{d}", .{v});
            if (tg.virtual_aton) try out.appendSlice(alloc, ",\"virtual\":true");
            if (tg.off_position) |v| try out.print(alloc, ",\"off_position\":{s}", .{if (v) "true" else "false"});
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
            .aton = jsonBool(o.get("aton")),
            .aton_type = atonType(o.get("aton_type")),
            .virtual_aton = jsonBool(o.get("virtual")),
            .off_position = jsonBool(o.get("off_position")),
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
    // Only transitions: a plugin posting the same status at 1 Hz would
    // otherwise fill the log with the line that says nothing changed.
    if (p.setStatus(text)) p.broker.say(level_info, p.id, "status {s}", .{text});
}

/// The log level an alert of this severity goes out at: alarm at error,
/// warning at warn, notice and caution at info.
///
/// The prototype has no alarm surface, so an alert IS its log line, and the
/// line has to carry the difference between "you may want to know" and "act
/// now": an alarm at info is an alarm nobody sees, and a notice at error is an
/// operator who learns to ignore red. Anything unrecognised — including a
/// payload with no severity at all — is treated as an alarm, because an
/// unreadable severity is not a reason to be quiet.
///
/// `caution` is here because that is the third name plugins/common/lk.zig
/// offers; `notice` is the name the ruling used. Both mean the same tier.
fn alertLevel(json: []const u8) u32 {
    const sev = jsonStringField(json, "severity") orelse return level_err;
    if (std.mem.eql(u8, sev, "notice") or std.mem.eql(u8, sev, "caution")) return level_info;
    if (std.mem.eql(u8, sev, "warning")) return level_warn;
    return level_err;
}

/// The string value of a top-level-ish `"key":"value"` pair, by scan rather
/// than by parse: this runs on every alert and the payload is the plugin's own
/// one-line JSON, not a document.
fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var quoted: [32]u8 = undefined;
    if (key.len + 2 > quoted.len) return null;
    quoted[0] = '"';
    @memcpy(quoted[1 .. 1 + key.len], key);
    quoted[1 + key.len] = '"';
    const at = std.mem.indexOf(u8, json, quoted[0 .. key.len + 2]) orelse return null;
    var i = at + key.len + 2;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfScalarPos(u8, json, i, '"') orelse return null;
    return json[i..end];
}

fn hostAlert(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .alerts_raise, "alert")) return -1;
    const text = bytes(ptr, len);
    const n = @min(text.len, max_alert);
    @memcpy(p.alert_buf[0..n], text[0..n]);
    p.alert_len = n;
    p.broker.say(alertLevel(text), p.id, "ALERT {s}", .{text});
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
/// so this reads the platform clock directly.
pub fn wallMs() i64 {
    if (builtin.os.tag == .windows) {
        // FILETIME counts 100 ns ticks from 1601-01-01. 11644473600 seconds
        // separate that epoch from the Unix one.
        var ft: [2]u32 = .{ 0, 0 };
        win.GetSystemTimeAsFileTime(&ft);
        const ticks = (@as(u64, ft[1]) << 32) | ft[0];
        return @intCast(@divTrunc(ticks, 10_000) -% 11_644_473_600_000);
    } else {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
}

/// Monotonic milliseconds: timer deadlines and fanout pacing, which must not
/// jump when the clock is set.
pub fn monoMs() i64 {
    if (builtin.os.tag == .windows) {
        // The performance counter is the monotonic clock on Windows.
        // GetTickCount64 is monotonic too but steps by the 10-16 ms timer
        // tick, which is coarse against a 5 ms plugin timer. The 128-bit
        // multiply keeps a counter of years from overflowing.
        var freq: i64 = 0;
        var now: i64 = 0;
        if (win.QueryPerformanceFrequency(&freq) == 0 or freq == 0) return wallMs();
        _ = win.QueryPerformanceCounter(&now);
        return @intCast(@divTrunc(@as(i128, now) * 1000, freq));
    } else {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return wallMs();
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
}

/// A kernel sleep. Zig 0.16's std.Thread.sleep wants an Io this layer does not
/// take; the same externs the rest of the core uses (src/lock.zig).
pub fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        win.Sleep(ms);
    } else {
        const p = struct {
            extern "c" fn usleep(usec: u32) c_int;
        };
        _ = p.usleep(ms * 1000);
    }
}

/// Resolve `host` and start a non-blocking connect. The socket comes back
/// mid-handshake; the I/O thread completes it on POLLOUT.
fn dial(host: []const u8, port: u16) !net.Socket {
    var addrs: [max_addrs]Addr = undefined;
    const n = try net.resolve(host, port, &addrs);
    for (addrs[0..n]) |*a| {
        const s = net.socket(a);
        if (!net.valid(s)) continue;
        net.setNonBlocking(s);
        if (net.connect(s, a)) return s;
        net.close(s);
    }
    return error.ConnectFailed;
}

// ---- the socket layer --------------------------------------------------------
//
// Everything platform-specific about a plugin socket is here. The broker above
// names `net` and nothing else, so the I/O thread reads the same on both.
//
// POSIX and Winsock disagree on three things that reach the caller. A handle is
// a small signed fd on POSIX and an opaque unsigned SOCKET on Windows, so -1 is
// not the sentinel and `>= 0` is not the test — hence `net.invalid` and
// `net.valid`. An error is in errno on POSIX and in WSAGetLastError on Windows.
// And read/write serve any POSIX fd but no Windows socket, which needs
// recv/send. Two flags say where the two poll calls differ; the broker reads
// them, so the difference is stated once.

/// One resolved candidate address, copied out of the resolver's own list so
/// that list is freed before the connect. 128 bytes is a sockaddr_storage.
const Addr = struct {
    family: i32,
    socktype: i32,
    protocol: i32,
    len: u32,
    raw: [128]u8 align(8),
};

/// Candidates kept per name. A name with more records than this keeps the
/// first eight; the rest are not tried.
const max_addrs = 8;

const net = if (builtin.os.tag == .windows) net_windows else net_posix;

const net_posix = struct {
    pub const Socket = std.c.fd_t;
    pub const invalid: Socket = -1;
    pub const pollfd = std.c.pollfd;
    pub const POLL = std.c.POLL;
    /// poll reports a failed connect as POLLERR/POLLHUP, and accepts an entry
    /// that asks for nothing.
    pub const poll_misses_connect_error = false;
    pub const poll_needs_events = false;

    pub fn valid(s: Socket) bool {
        return s >= 0;
    }

    pub fn poll(fds: []pollfd, timeout_ms: i32) usize {
        return std.posix.poll(fds, timeout_ms) catch 0;
    }

    pub fn close(s: Socket) void {
        _ = std.c.close(s);
    }

    pub fn setNonBlocking(s: Socket) void {
        const flags = std.c.fcntl(s, std.c.F.GETFL, @as(c_int, 0));
        if (flags < 0) return;
        const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        _ = std.c.fcntl(s, std.c.F.SETFL, flags | nonblock);
    }

    /// Bytes read, 0 for the peer's EOF, -1 for an error.
    pub fn recv(s: Socket, buf: []u8) isize {
        return std.c.read(s, buf.ptr, buf.len);
    }

    /// Bytes written, or -1.
    pub fn send(s: Socket, buf: []const u8) isize {
        return std.c.write(s, buf.ptr, buf.len);
    }

    /// Whether the last recv/send failed only because it would have blocked.
    pub fn retryable() bool {
        const e = std.c.errno(@as(c_int, -1));
        return e == .AGAIN or e == .INTR;
    }

    pub fn soError(s: Socket) i32 {
        var err: i32 = 0;
        var len: std.c.socklen_t = @sizeOf(i32);
        _ = std.c.getsockopt(s, std.c.SOL.SOCKET, std.c.SO.ERROR, &err, &len);
        return err;
    }

    pub fn shutdownWrite(s: Socket) void {
        _ = std.c.shutdown(s, 1);
    }

    pub fn resolve(host: []const u8, port: u16, out: *[max_addrs]Addr) !usize {
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

        var n: usize = 0;
        var it: ?*std.c.addrinfo = list;
        while (it) |ai| : (it = ai.next) {
            if (n == out.len) break;
            const addr = ai.addr orelse continue;
            if (ai.addrlen > out[n].raw.len) continue;
            out[n] = .{
                .family = @intCast(ai.family),
                .socktype = @intCast(ai.socktype),
                .protocol = @intCast(ai.protocol),
                .len = @intCast(ai.addrlen),
                .raw = undefined,
            };
            @memcpy(out[n].raw[0..ai.addrlen], @as([*]const u8, @ptrCast(addr))[0..ai.addrlen]);
            n += 1;
        }
        if (n == 0) return error.ResolveFailed;
        return n;
    }

    pub fn socket(a: *const Addr) Socket {
        return std.c.socket(@bitCast(a.family), @bitCast(a.socktype), @bitCast(a.protocol));
    }

    /// True when the socket is connected or the handshake is under way.
    pub fn connect(s: Socket, a: *const Addr) bool {
        if (std.c.connect(s, @ptrCast(&a.raw), a.len) == 0) return true;
        const e = std.c.errno(@as(c_int, -1));
        return e == .INPROGRESS or e == .INTR or e == .ALREADY;
    }

    pub fn wakePair(out: *[2]Socket) !void {
        if (std.c.pipe(out) != 0) return error.PipeFailed;
        setNonBlocking(out[0]);
        setNonBlocking(out[1]);
    }

    pub fn drainWake(s: Socket) void {
        var buf: [64]u8 = undefined;
        while (recv(s, &buf) > 0) {}
    }

    /// A loopback listener on an ephemeral port. Test support only.
    pub fn listen4(port_out: *u16) !Socket {
        const s = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (!valid(s)) return error.SocketFailed;
        errdefer close(s);
        var yes: c_int = 1;
        _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.c.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (std.c.bind(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(s, 1) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
        if (std.c.getsockname(s, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        port_out.* = std.mem.bigToNative(u16, addr.port);
        return s;
    }

    pub fn accept(s: Socket) !Socket {
        const peer = std.c.accept(s, null, null);
        if (!valid(peer)) return error.AcceptFailed;
        return peer;
    }
};

/// kernel32 entry points. Declared here rather than taken from std: Zig 0.16's
/// std.os.windows.kernel32 carries none of them, and the WINAPI convention is
/// required for a correct x86 build (src/lock.zig takes the same posture).
const win = struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    extern "kernel32" fn QueryPerformanceCounter(v: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(v: *i64) callconv(.winapi) i32;
    extern "kernel32" fn GetSystemTimeAsFileTime(ft: *[2]u32) callconv(.winapi) void;
};

const net_windows = struct {
    // ws2_32, declared here for the same reason as `win` above: Zig 0.16's
    // std.os.windows.ws2_32 was cut back to types when sockets moved behind
    // std.Io, and std.c's Windows socket declarations point at the members it
    // no longer has.
    const SOCKET = usize;
    const socklen = i32;

    const AF_INET: i32 = 2;
    const AF_UNSPEC: i32 = 0;
    const SOCK_STREAM: i32 = 1;
    const SOL_SOCKET: i32 = 0xFFFF;
    const SO_ERROR: i32 = 0x1007;
    const IPPROTO_TCP: i32 = 6;
    const TCP_NODELAY: i32 = 0x0001;
    const SD_SEND: i32 = 1;
    /// FIONBIO. The high bits are the IOC_IN|sizeof(u_long) encoding.
    const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));
    const WSAEWOULDBLOCK: i32 = 10035;
    const WSAEINPROGRESS: i32 = 10036;
    const WSAEALREADY: i32 = 10037;
    const WSAEINTR: i32 = 10004;

    /// WSADATA as opaque bytes. Its field order differs between _WIN64 and
    /// x86 and nothing here reads it, so the size is all that matters. The
    /// real thing is about 400 bytes.
    const WSADATA = extern struct { raw: [512]u8 align(8) = @splat(0) };

    const sockaddr = extern struct { family: u16, data: [14]u8 };
    const sockaddr_in = extern struct {
        family: u16 = @intCast(AF_INET),
        port: u16,
        addr: u32,
        zero: [8]u8 = @splat(0),
    };

    /// Windows orders ai_canonname before ai_addr (as Darwin does) and makes
    /// ai_addrlen a size_t, so this cannot be std.c.addrinfo.
    const addrinfo = extern struct {
        flags: i32,
        family: i32,
        socktype: i32,
        protocol: i32,
        addrlen: usize,
        canonname: ?[*:0]u8,
        addr: ?*sockaddr,
        next: ?*addrinfo,
    };

    /// A namespace so the exported names stay the real ws2_32 ones while this
    /// module also has a `socket`, a `recv` and a `send` of its own.
    const ws = struct {
        extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) i32;
        extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
        extern "ws2_32" fn WSAPoll(fds: [*]pollfd, count: u32, timeout: i32) callconv(.winapi) i32;
        extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
        extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
        extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, arg: *u32) callconv(.winapi) i32;
        extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
        extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
        extern "ws2_32" fn connect(s: SOCKET, addr: *const sockaddr, len: socklen) callconv(.winapi) i32;
        extern "ws2_32" fn bind(s: SOCKET, addr: *const sockaddr, len: socklen) callconv(.winapi) i32;
        extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
        extern "ws2_32" fn accept(s: SOCKET, addr: ?*sockaddr, len: ?*socklen) callconv(.winapi) SOCKET;
        extern "ws2_32" fn getsockname(s: SOCKET, addr: *sockaddr, len: *socklen) callconv(.winapi) i32;
        extern "ws2_32" fn getsockopt(s: SOCKET, lvl: i32, opt: i32, val: [*]u8, len: *socklen) callconv(.winapi) i32;
        extern "ws2_32" fn setsockopt(s: SOCKET, lvl: i32, opt: i32, val: [*]const u8, len: socklen) callconv(.winapi) i32;
        extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
        extern "ws2_32" fn getaddrinfo(node: [*:0]const u8, service: [*:0]const u8, hints: *const addrinfo, res: *?*addrinfo) callconv(.winapi) i32;
        extern "ws2_32" fn freeaddrinfo(ai: *addrinfo) callconv(.winapi) void;
    };

    pub const Socket = SOCKET;
    /// INVALID_SOCKET. An unsigned handle, so this is not -1 and a valid
    /// socket is not "greater than zero".
    pub const invalid: Socket = ~@as(SOCKET, 0);

    pub const pollfd = extern struct { fd: SOCKET, events: i16, revents: i16 };

    pub const POLL = struct {
        pub const RDNORM: i16 = 0x0100;
        pub const RDBAND: i16 = 0x0200;
        pub const IN: i16 = RDNORM | RDBAND;
        pub const WRNORM: i16 = 0x0010;
        pub const OUT: i16 = WRNORM;
        pub const ERR: i16 = 0x0001;
        pub const HUP: i16 = 0x0002;
        pub const NVAL: i16 = 0x0004;
    };

    /// WSAPoll does not report a failed non-blocking connect, and it rejects
    /// an entry whose events are zero. The broker works around both.
    pub const poll_misses_connect_error = true;
    pub const poll_needs_events = true;

    pub fn valid(s: Socket) bool {
        return s != invalid;
    }

    /// WSAStartup runs once per process, before any other ws2_32 call. It is
    /// reference counted, so the flag keeps one count rather than making the
    /// call safe. Nothing calls WSACleanup: Winsock goes down with the
    /// process, and the host may start and stop many times inside one.
    var started = std.atomic.Value(u32).init(0);

    fn startup() void {
        if (started.load(.acquire) == 2) return;
        if (started.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            var data: WSADATA = .{};
            _ = ws.WSAStartup(0x0202, &data); // 2.2
            started.store(2, .release);
            return;
        }
        while (started.load(.acquire) != 2) win.Sleep(0);
    }

    pub fn poll(fds: []pollfd, timeout_ms: i32) usize {
        const n = ws.WSAPoll(fds.ptr, @intCast(fds.len), timeout_ms);
        return if (n > 0) @intCast(n) else 0;
    }

    pub fn close(s: Socket) void {
        _ = ws.closesocket(s);
    }

    pub fn setNonBlocking(s: Socket) void {
        var on: u32 = 1;
        _ = ws.ioctlsocket(s, FIONBIO, &on);
    }

    pub fn recv(s: Socket, buf: []u8) isize {
        const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
        return ws.recv(s, buf.ptr, len, 0);
    }

    pub fn send(s: Socket, buf: []const u8) isize {
        const len: i32 = @intCast(@min(buf.len, std.math.maxInt(i32)));
        return ws.send(s, buf.ptr, len, 0);
    }

    pub fn retryable() bool {
        const e = ws.WSAGetLastError();
        return e == WSAEWOULDBLOCK or e == WSAEINTR;
    }

    pub fn soError(s: Socket) i32 {
        var err: i32 = 0;
        var len: socklen = @sizeOf(i32);
        _ = ws.getsockopt(s, SOL_SOCKET, SO_ERROR, @ptrCast(&err), &len);
        return err;
    }

    pub fn shutdownWrite(s: Socket) void {
        _ = ws.shutdown(s, SD_SEND);
    }

    pub fn resolve(host: []const u8, port: u16, out: *[max_addrs]Addr) !usize {
        startup();
        var host_z: [256]u8 = undefined;
        if (host.len >= host_z.len) return error.HostTooLong;
        @memcpy(host_z[0..host.len], host);
        host_z[host.len] = 0;
        var port_z: [8]u8 = undefined;
        const ps = try std.fmt.bufPrintZ(&port_z, "{d}", .{port});

        var hints: addrinfo = std.mem.zeroes(addrinfo);
        hints.family = AF_UNSPEC;
        hints.socktype = SOCK_STREAM;
        var res: ?*addrinfo = null;
        if (ws.getaddrinfo(@ptrCast(&host_z), ps.ptr, &hints, &res) != 0) return error.ResolveFailed;
        const list = res orelse return error.ResolveFailed;
        defer ws.freeaddrinfo(list);

        var n: usize = 0;
        var it: ?*addrinfo = list;
        while (it) |ai| : (it = ai.next) {
            if (n == out.len) break;
            const addr = ai.addr orelse continue;
            if (ai.addrlen > out[n].raw.len) continue;
            out[n] = .{
                .family = ai.family,
                .socktype = ai.socktype,
                .protocol = ai.protocol,
                .len = @intCast(ai.addrlen),
                .raw = undefined,
            };
            @memcpy(out[n].raw[0..ai.addrlen], @as([*]const u8, @ptrCast(addr))[0..ai.addrlen]);
            n += 1;
        }
        if (n == 0) return error.ResolveFailed;
        return n;
    }

    pub fn socket(a: *const Addr) Socket {
        startup();
        return ws.socket(a.family, a.socktype, a.protocol);
    }

    pub fn connect(s: Socket, a: *const Addr) bool {
        if (ws.connect(s, @ptrCast(&a.raw), @intCast(a.len)) == 0) return true;
        const e = ws.WSAGetLastError();
        return e == WSAEWOULDBLOCK or e == WSAEINPROGRESS or e == WSAEALREADY;
    }

    /// A loopback socket pair, because Windows has no pipe a socket poll can
    /// watch. The listener is on this thread's own loopback, so the blocking
    /// connect completes into the accept backlog without waiting on anything.
    /// The write end turns Nagle off: a one-byte wake must not wait for an ack.
    pub fn wakePair(out: *[2]Socket) !void {
        startup();
        const lst = ws.socket(AF_INET, SOCK_STREAM, 0);
        if (!valid(lst)) return error.PipeFailed;
        defer close(lst);
        var addr = sockaddr_in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (ws.bind(lst, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) return error.PipeFailed;
        if (ws.listen(lst, 1) != 0) return error.PipeFailed;
        var len: socklen = @sizeOf(sockaddr_in);
        if (ws.getsockname(lst, @ptrCast(&addr), &len) != 0) return error.PipeFailed;

        const wr = ws.socket(AF_INET, SOCK_STREAM, 0);
        if (!valid(wr)) return error.PipeFailed;
        errdefer close(wr);
        if (ws.connect(wr, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) return error.PipeFailed;
        const rd = ws.accept(lst, null, null);
        if (!valid(rd)) return error.PipeFailed;

        var yes: i32 = 1;
        _ = ws.setsockopt(wr, IPPROTO_TCP, TCP_NODELAY, @ptrCast(&yes), @sizeOf(i32));
        setNonBlocking(rd);
        setNonBlocking(wr);
        out.* = .{ rd, wr };
    }

    pub fn drainWake(s: Socket) void {
        var buf: [64]u8 = undefined;
        while (recv(s, &buf) > 0) {}
    }

    pub fn listen4(port_out: *u16) !Socket {
        startup();
        const s = ws.socket(AF_INET, SOCK_STREAM, 0);
        if (!valid(s)) return error.SocketFailed;
        errdefer close(s);
        var addr = sockaddr_in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (ws.bind(s, @ptrCast(&addr), @sizeOf(sockaddr_in)) != 0) return error.BindFailed;
        if (ws.listen(s, 1) != 0) return error.ListenFailed;
        var len: socklen = @sizeOf(sockaddr_in);
        if (ws.getsockname(s, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        port_out.* = std.mem.bigToNative(u16, addr.port);
        return s;
    }

    pub fn accept(s: Socket) !Socket {
        const peer = ws.accept(s, null, null);
        if (!valid(peer)) return error.AcceptFailed;
        return peer;
    }
};

fn jsonNum(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonBool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// A navaid type code. Out of the 0..31 the wire format defines it reads as
/// unknown, so a bad value loses the type rather than the whole target.
fn atonType(v: ?std.json.Value) ?u8 {
    const n = jsonInt(v) orelse return null;
    return if (n >= 0 and n <= 31) @intCast(n) else null;
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

test "each plugin's queue is its own FIFO and compacts as it drains" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    for (0..300) |i| b.push(@intCast(i % 3), Kind.timer, i, "x");
    try t.expectEqual(@as(usize, 300), b.queued());
    try t.expectEqual(@as(usize, 100), b.queuedFor(1));

    // Each plugin sees its own events, in the order they were pushed, and none
    // of anybody else's.
    for (0..3) |p| {
        for (0..100) |n| {
            const e = b.popFor(@intCast(p)).?;
            defer b.freeEvent(e);
            try t.expectEqual(@as(u64, n * 3 + p), e.handle);
            try t.expectEqual(@as(u32, @intCast(p)), e.plugin);
        }
        try t.expect(b.popFor(@intCast(p)) == null);
    }
    try t.expectEqual(@as(usize, 0), b.queued());
}

test "a plugin that stops consuming loses its own events and nobody else's" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();
    b.setLog(null, silentLog);

    for (0..max_queued + 50) |i| b.push(0, Kind.timer, i, "");
    b.push(1, Kind.timer, 7, "");

    try t.expectEqual(@as(usize, max_queued), b.queuedFor(0));
    try t.expectEqual(@as(u64, 50), b.droppedFor(0));
    // The neighbour is untouched: separate queues, separate caps.
    try t.expectEqual(@as(usize, 1), b.queuedFor(1));
    try t.expectEqual(@as(u64, 0), b.droppedFor(1));
    // The FIFO keeps the OLDEST events; the overflow is at the tail.
    const first = b.popFor(0).?;
    defer b.freeEvent(first);
    try t.expectEqual(@as(u64, 0), first.handle);

    // SHUTDOWN ignores the cap: a plugin in trouble is exactly the one that
    // has to hear it.
    b.push(0, Kind.shutdown, 0, "");
    try t.expectEqual(@as(usize, max_queued), b.queuedFor(0));
    try t.expectEqual(@as(u64, 50), b.droppedFor(0));
}

test "an alert's severity picks the log level it goes out at" {
    try t.expectEqual(level_err, alertLevel("{\"severity\":\"alarm\",\"title\":\"CPA\"}"));
    try t.expectEqual(level_warn, alertLevel("{\"severity\":\"warning\",\"title\":\"shallow\"}"));
    try t.expectEqual(level_info, alertLevel("{\"severity\":\"notice\",\"title\":\"waypoint\"}"));
    try t.expectEqual(level_info, alertLevel("{\"severity\":\"caution\",\"title\":\"wind\"}"));
    // A severity nobody recognises, or none at all, is treated as an alarm.
    try t.expectEqual(level_err, alertLevel("{\"severity\":\"whatever\"}"));
    try t.expectEqual(level_err, alertLevel("{\"title\":\"no severity here\"}"));
    // The body must not decide the level: only the severity field is read.
    try t.expectEqual(level_err, alertLevel("{\"severity\":\"alarm\",\"body\":\"notice the warning\"}"));
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
    try t.expectEqual(@as(usize, 0), b.queuedFor(1));
    const a = b.popFor(0).?;
    b.freeEvent(a);
    const c = b.popFor(0).?;
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
    defer net.close(peer);
    try t.expectEqual(Kind.tcp_connected, try expectEvent(&b, 2_000));

    _ = net.send(peer, "$GPRMC,\r\n");
    try t.expectEqual(Kind.tcp_data, try expectEvent(&b, 2_000));

    // ...and the other direction: what the plugin sends reaches the peer.
    try t.expectEqual(@as(i32, 4), b.sendConn(0, id, "ping"));
    var got: [16]u8 = undefined;
    var n: isize = 0;
    var waited: u32 = 0;
    while (n <= 0 and waited < 2_000) : (waited += 5) {
        n = net.recv(peer, &got);
        if (n <= 0) sleepMs(5);
    }
    try t.expectEqualStrings("ping", got[0..@intCast(n)]);

    // The peer hanging up is a TCP_CLOSED, and the connection is gone.
    net.shutdownWrite(peer); // our side then reads EOF
    try t.expectEqual(Kind.tcp_closed, try expectEvent(&b, 2_000));
    b.mu.lock();
    const remaining = b.conns.items.len;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), remaining);
}

test "a backed-up plugin stops being read from, and its neighbour does not" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();
    b.setLog(null, silentLog);

    var srv = try Listener.open();
    defer srv.close();
    try b.start();

    // One socket each for two plugins.
    try t.expect(b.openConn(0, "127.0.0.1", srv.port) > 0);
    const peer0 = try srv.accept();
    defer net.close(peer0);
    try t.expectEqual(Kind.tcp_connected, try expectEvent(&b, 2_000));

    try t.expect(b.openConn(1, "127.0.0.1", srv.port) > 0);
    const peer1 = try srv.accept();
    defer net.close(peer1);
    var waited: u32 = 0;
    while (b.queuedFor(1) == 0 and waited < 2_000) : (waited += 5) sleepMs(5);
    const connected1 = b.popFor(1) orelse return error.NoEvent;
    b.freeEvent(connected1);

    // Plugin 0 stops consuming: fill its queue to the watermark, then let the
    // I/O thread rebuild its poll set before anything is written.
    for (0..pause_reads_at) |i| b.push(0, Kind.timer, i, "");
    b.wakeIo();
    sleepMs(150);

    _ = net.send(peer0, "$GPRMC,\r\n");
    _ = net.send(peer1, "$GPRMC,\r\n");
    sleepMs(400);

    // Nothing was read for plugin 0 — its depth is exactly what was pushed —
    // while plugin 1's data came through on the same I/O thread.
    try t.expectEqual(@as(usize, pause_reads_at), b.queuedFor(0));
    try t.expectEqual(@as(u64, 0), b.droppedFor(0));
    try t.expectEqual(@as(usize, 1), b.queuedFor(1));
    const data1 = b.popFor(1) orelse return error.NoEvent;
    defer b.freeEvent(data1);
    try t.expectEqual(Kind.tcp_data, data1.kind);

    // Once plugin 0 catches up, reading resumes and the bytes are still there:
    // the pause held them in the kernel rather than throwing them away.
    while (b.popFor(0)) |e| b.freeEvent(e);
    b.wakeIo();
    try t.expectEqual(Kind.tcp_data, try expectEvent(&b, 2_000));
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

/// The next event's kind for plugin 0, waiting up to `timeout_ms`.
fn expectEvent(b: *Broker, timeout_ms: u32) !u32 {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (b.popFor(0)) |e| {
            defer b.freeEvent(e);
            return e.kind;
        }
        sleepMs(5);
    }
    return error.NoEvent;
}

/// A loopback listener on an ephemeral port, for the socket tests.
const Listener = struct {
    fd: net.Socket,
    port: u16,

    fn open() !Listener {
        var port: u16 = 0;
        const fd = try net.listen4(&port);
        return .{ .fd = fd, .port = port };
    }

    fn accept(self: *Listener) !net.Socket {
        return net.accept(self.fd);
    }

    fn close(self: *Listener) void {
        net.close(self.fd);
    }
};
