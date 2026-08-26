//! The host side of the plugin API: the twenty-nine native functions a plugin
//! imports from module `lookout`, the grants that gate them, and the one I/O
//! thread that owns sockets, timers and the subscriber fanout.
//!
//! WHAT THIS FILE IS. `wasm.zig` moves bytes across the boundary; this layer
//! decides what those bytes mean. Every import in PROTOTYPE.md's frozen table
//! is implemented exactly once, checked against the calling plugin's manifest
//! capabilities, and turned into a call on the vessel store, the AIS store, the
//! overlay store or a socket.
//!
//! WHERE THE PARTS ARE. This file holds the `Broker` itself: the state every
//! plugin shares, the I/O thread, and the calls the natives make on it.
//! `broker/` holds the rest, each part with its own tests.
//!
//!   caps.zig           event kinds, log levels and the capability vocabulary
//!   budgets.zig        the per-plugin record and what it may take
//!   tables.zig         a plugin's tabular surface
//!   queue.zig          the per-plugin event FIFO
//!   sockets.zig        what the I/O thread keeps per socket and timer
//!   http.zig           an HTTP fetch in flight
//!   ws.zig             a WebSocket in flight
//!   storage.zig        per-plugin key-value storage and granted files
//!   registry_json.zig  the JSON the host writes and reads
//!   natives.zig        the import table a plugin calls
//!   testing.zig        the fixtures those parts share in their tests
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
const net = @import("net.zig");
const webio = @import("webio.zig");

const caps = @import("broker/caps.zig");
const alerts = @import("broker/alerts.zig");
const budgets = @import("broker/budgets.zig");
const tables = @import("broker/tables.zig");
const queue = @import("broker/queue.zig");
const sockets = @import("broker/sockets.zig");
const http = @import("broker/http.zig");
// `ws` names a local in the handle test below, so this one is suffixed.
const ws_mod = @import("broker/ws.zig");
const storage = @import("broker/storage.zig");
const registry_json = @import("broker/registry_json.zig");
const natives = @import("broker/natives.zig");
const testing = @import("broker/testing.zig");

comptime {
    // A Zig test build collects a file's tests only when the file is analysed,
    // and reaching a type through a re-export does not analyse the file it came
    // from. These references do, so every part's tests run wherever this one's
    // do.
    _ = caps;
    _ = alerts;
    _ = budgets;
    _ = tables;
    _ = queue;
    _ = sockets;
    _ = http;
    _ = ws_mod;
    _ = storage;
    _ = registry_json;
    _ = natives;
}

const win = net.win;
const Addr = net.Addr;
const max_addrs = net.max_addrs;
const io = std.Io.Threaded.global_single_threaded.io();

pub const Lock = vstore.Lock;
pub const SourceId = vstore.SourceId;

// ---- what the parts hold ----------------------------------------------------
//
// The plugin layer reaches all of this as `broker.<name>`, whichever part of
// broker/ it lives in.

pub const Kind = caps.Kind;
pub const level_debug = caps.level_debug;
pub const level_info = caps.level_info;
pub const level_warn = caps.level_warn;
pub const level_err = caps.level_err;
pub const LogFn = caps.LogFn;
pub const Cap = caps.Cap;
pub const Caps = caps.Caps;
pub const ViewBox = registry_json.ViewBox;

pub const max_status = budgets.max_status;

pub const max_alerts_per_plugin = alerts.max_alerts_per_plugin;
pub const max_alert_title = alerts.max_alert_title;
pub const max_alert_body = alerts.max_alert_body;
pub const alert_clear_ms = alerts.alert_clear_ms;
pub const Severity = alerts.Severity;
pub const Alert = alerts.Alert;

pub const default_wire_bytes_per_s = budgets.default_wire_bytes_per_s;
pub const default_log_lines_per_s = budgets.default_log_lines_per_s;
pub const budget_say_ms = budgets.budget_say_ms;
pub const Budgets = budgets.Budgets;
pub const Budget = budgets.Budget;
pub const max_budget_note = budgets.max_budget_note;
pub const Plugin = budgets.Plugin;

pub const max_table_columns = tables.max_table_columns;
pub const max_table_rows = tables.max_table_rows;
pub const max_tables = tables.max_tables;
pub const max_table_key = tables.max_table_key;
pub const max_table_label = tables.max_table_label;
pub const max_table_cell = tables.max_table_cell;
pub const table_min_interval_ms = tables.table_min_interval_ms;
pub const ColumnType = tables.ColumnType;
pub const Column = tables.Column;
pub const Cell = tables.Cell;
pub const Row = tables.Row;
pub const Table = tables.Table;

pub const Event = queue.Event;

pub const tick_ms = sockets.tick_ms;
pub const ais_min_interval_ms = sockets.ais_min_interval_ms;

/// VIEW_CHANGED's own cadence: wire.md promises at most 2 Hz, independent of
/// whatever the AIS fanout is tuned to.
pub const view_min_interval_ms: i64 = 500;
pub const udp_max_datagram = sockets.udp_max_datagram;

pub const http_max_inflight = http.http_max_inflight;
pub const http_max_body = http.http_max_body;

pub const storage_max_key = storage.storage_max_key;
pub const storage_max_value = storage.storage_max_value;
pub const storage_max_keys = storage.storage_max_keys;
pub const storage_max_total = storage.storage_max_total;
pub const files_per_plugin = storage.files_per_plugin;
pub const file_read_max = storage.file_read_max;

pub const local_token = natives.local_token;
pub const isLocalHost = natives.isLocalHost;
pub const registerNatives = natives.registerNatives;
pub const unregisterNatives = natives.unregisterNatives;
pub const max_memory_bytes = natives.max_memory_bytes;
pub const wasm_page_bytes = natives.wasm_page_bytes;
pub const max_memory_pages = natives.max_memory_pages;

// The parts the Broker itself works in, which stay inside the plugin layer.
const defaultLog = caps.defaultLog;
const Queue = queue.Queue;
const max_queued = queue.max_queued;
const max_plugins = queue.max_plugins;
const pause_reads_at = queue.pause_reads_at;
const ConnState = sockets.ConnState;
const Conn = sockets.Conn;
const Udp = sockets.Udp;
const Timer = sockets.Timer;
pub const max_timer_delay_ms = sockets.max_timer_delay_ms;
pub const max_timers_per_plugin = sockets.max_timers_per_plugin;
const Owner = sockets.Owner;
const read_chunk = sockets.read_chunk;
const resolver_stack_bytes = sockets.resolver_stack_bytes;
const Fetch = http.Fetch;
const FetchRequest = http.FetchRequest;
const fetchMain = http.fetchMain;
const Ws = ws_mod.Ws;
const wsMain = ws_mod.wsMain;
const ws_max_queued_frames = ws_mod.ws_max_queued_frames;
const ws_max_queued_bytes = ws_mod.ws_max_queued_bytes;
const KvStore = storage.KvStore;
const FileHandle = storage.FileHandle;
const defaultStorageDir = storage.defaultStorageDir;
const printableKey = storage.printableKey;
const baseName = storage.baseName;
const Order = tables.Order;
const AlertOrder = alerts.Order;
const freeAlert = alerts.freeAlert;
const freeCells = tables.freeCells;
const freeRow = tables.freeRow;
const freeTable = tables.freeTable;
const jsonText = tables.jsonText;
const jsonInt = registry_json.jsonInt;
const jsonNum = registry_json.jsonNum;
const writeAisChanged = registry_json.writeAisChanged;
const writeViewChanged = registry_json.writeViewChanged;
const writeJsonString = registry_json.writeJsonString;
const writeJsonStringTo = registry_json.writeJsonStringTo;
const writeStoreChanged = registry_json.writeStoreChanged;

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

/// Native stack for a fetch or a WebSocket thread. Larger than a resolver's:
/// TLS puts four record buffers of about 16 KiB each on the heap but keeps
/// working state on the stack, and the certificate chain walk is recursive.
const worker_stack_bytes: usize = 1024 * 1024;

/// How long `stop` waits for the worker threads before it says so. They are
/// detached and call back into the broker, so the wait itself is not optional;
/// the line exists because a dead nameserver makes it a long one.
const worker_wait_warn_ms: u32 = 1000;

// ---- the broker ------------------------------------------------------------

pub const Broker = struct {
    alloc: std.mem.Allocator,
    vessels: *vstore.Store,
    ais: *ais_store.AisStore,
    overlay: OverlaySink,
    watchdog: WatchdogSink = .{},
    log_ctx: ?*anyopaque = null,
    log_fn: LogFn = defaultLog,
    /// The metered ceilings every plugin lives inside. The shipped numbers
    /// unless a harness moves them; see `Budgets`.
    budgets: Budgets = .{},

    mu: Lock = .{},
    /// One FIFO per plugin, indexed by the host's registry index.
    queues: std.ArrayList(Queue) = .empty,

    plugins: std.ArrayList(*Plugin) = .empty,
    conns: std.ArrayList(Conn) = .empty,
    udps: std.ArrayList(Udp) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    /// Fetches and WebSockets in flight, each owned by its own thread and
    /// listed here only so `dropPlugin` and `stop` can reach it.
    fetches: std.ArrayList(*Fetch) = .empty,
    wss: std.ArrayList(*Ws) = .empty,
    /// One key-value store per plugin, loaded from disk on first use.
    kv: std.ArrayList(KvStore) = .empty,
    /// Every table any plugin has declared, with the rows it has fed them.
    tables: std.ArrayList(Table) = .empty,
    /// Every alert raised and not yet cleared. A shell polls `alerts_seq` and
    /// re-reads the list when it moves.
    alerts: std.ArrayList(Alert) = .empty,
    alerts_seq: u64 = 0,
    next_alert_id: u64 = 1,
    /// Files the host granted to plugins.
    files: std.ArrayList(FileHandle) = .empty,
    /// Where the per-plugin key-value files live, or null when no writable
    /// place could be found — in which case storage works and is forgotten at
    /// shutdown.
    storage_dir: ?[]u8 = null,
    storage_dir_resolved: bool = false,
    /// ONE counter for every handle a plugin holds: connections, UDP ports,
    /// fetches, WebSockets and files. A plugin can therefore never confuse two
    /// of its own handles, and a log line naming a number names one thing.
    next_id: i64 = 1,
    next_timer: i64 = 1,

    io_thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Detached worker threads still running: name lookups, fetches and
    /// WebSockets. `stop` waits for it to reach zero, because every one of them
    /// calls back into this broker and it must outlive them.
    workers: std.atomic.Value(u32) = .init(0),
    /// Fetches running now, against `http_max_inflight`.
    fetching: u32 = 0,
    /// Self-pipe: a native run on the dispatch thread writes one byte so the
    /// I/O thread leaves poll at once instead of finishing its current wait.
    /// Without it a 5 ms timer set from inside an event could fire 100 ms late.
    /// A pipe on POSIX, a loopback socket pair on Windows (see net.wakePair).
    wake: [2]net.Socket = .{ net.invalid, net.invalid },

    next_tick: i64 = 0,
    last_ais_ms: i64 = 0,
    last_ais_seq: u64 = 0,
    /// The chart camera's footprint as the shell last reported it, and the one
    /// the VIEW_CHANGED fanout last sent. `cur_view` is written by the render
    /// thread under its own tiny lock, so a frame never queues behind `mu`;
    /// `sent_view` is touched only on the I/O thread and needs none.
    view_mu: vstore.Lock = .{},
    cur_view: ?ViewBox = null,
    sent_view: ?ViewBox = null,
    last_view_ms: i64 = 0,
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
            for (q.wake) |fd| {
                if (net.valid(fd)) net.close(fd);
            }
        }
        self.queues.deinit(self.alloc);
        for (self.conns.items) |*c| {
            if (net.valid(c.fd)) net.close(c.fd);
            c.out.deinit(self.alloc);
            self.alloc.free(c.host);
        }
        self.conns.deinit(self.alloc);
        for (self.udps.items) |u| {
            if (net.valid(u.fd)) net.close(u.fd);
        }
        self.udps.deinit(self.alloc);
        self.timers.deinit(self.alloc);
        // `stop` waited for every worker, so these two lists are empty; the
        // deinit is here so a broker that never started still frees them.
        self.fetches.deinit(self.alloc);
        self.wss.deinit(self.alloc);
        for (self.kv.items) |*store| store.deinit(self.alloc);
        self.kv.deinit(self.alloc);
        for (self.tables.items) |*tab| freeTable(self.alloc, tab);
        self.tables.deinit(self.alloc);
        for (self.alerts.items) |a| freeAlert(self.alloc, a);
        self.alerts.deinit(self.alloc);
        for (self.files.items) |*f| f.file.close(io);
        self.files.deinit(self.alloc);
        if (self.storage_dir) |d| self.alloc.free(d);
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

    /// This plugin's queue, created on first use, with the wake pair its
    /// dispatch thread parks on. A pair that cannot be made stays invalid
    /// and parking degrades to the bounded poll.
    fn queueForLocked(self: *Broker, plugin: u32) !*Queue {
        if (plugin >= max_plugins) return error.TooManyPlugins;
        while (self.queues.items.len <= plugin) {
            try self.queues.append(self.alloc, .{});
            net.wakePair(&self.queues.items[self.queues.items.len - 1].wake) catch {};
        }
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
        _ = self.pushLocked(plugin, kind, handle, payload);
    }

    /// False when the event was dropped rather than queued. Most callers have
    /// nothing to do about that; the view fanout retries.
    fn pushLocked(self: *Broker, plugin: u32, kind: u32, handle: u64, payload: []const u8) bool {
        return self.pushLockedJoined(plugin, kind, handle, payload, "");
    }

    /// `pushLocked` for a payload that arrives in two pieces: an envelope and
    /// the bytes it describes. Joining them at the point the queue's own copy
    /// is made means the caller never builds a copy of its own, and a publish
    /// nobody is listening to allocates nothing at all.
    fn pushLockedJoined(self: *Broker, plugin: u32, kind: u32, handle: u64, head: []const u8, body: []const u8) bool {
        const q = self.queueForLocked(plugin) catch return false;
        if (q.depth() >= max_queued and kind != Kind.shutdown) {
            self.dropLocked(q, plugin, kind);
            return false;
        }
        const owned = self.alloc.alloc(u8, head.len + body.len) catch {
            self.dropLocked(q, plugin, kind);
            return false;
        };
        @memcpy(owned[0..head.len], head);
        @memcpy(owned[head.len..], body);
        q.items.append(self.alloc, .{
            .plugin = plugin,
            .kind = kind,
            .handle = handle,
            .payload = owned,
        }) catch {
            self.alloc.free(owned);
            self.dropLocked(q, plugin, kind);
            return false;
        };
        // The plugin's dispatch thread may be parked on its wake pipe.
        if (net.valid(q.wake[1])) {
            const one = [_]u8{0};
            _ = net.send(q.wake[1], &one);
        }
        return true;
    }

    /// A dropped event, counted and — for the first one, and then rarely —
    /// said out loud. A silent drop is a plugin that quietly misses fixes.
    ///
    /// The plugin is told through a flag rather than a note: this runs on the
    /// I/O thread, and the status line is the dispatch thread's to write. The
    /// dispatch thread picks the flag up between events.
    fn dropLocked(self: *Broker, q: *Queue, plugin: u32, kind: u32) void {
        q.dropped += 1;
        if (self.pluginAtLocked(plugin)) |p| {
            p.dropped_events = q.dropped;
            p.queue_over.store(true, .monotonic);
        }
        if (q.dropped != 1 and q.dropped % 1000 != 0) return;
        const id = self.idOfLocked(plugin);
        self.say(level_warn, id, "queue full at {d} events: dropped event {d} ({d} dropped so far)", .{ max_queued, kind, q.dropped });
    }

    fn pluginAtLocked(self: *Broker, plugin: u32) ?*Plugin {
        for (self.plugins.items) |p| {
            if (p.index == plugin) return p;
        }
        return null;
    }

    fn idOfLocked(self: *Broker, plugin: u32) []const u8 {
        const p = self.pluginAtLocked(plugin) orelse return "host";
        return p.id;
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

    /// Park one plugin's dispatch thread until an event lands in its queue,
    /// or `timeout_ms` passes — the bounded fallback that lets the stop and
    /// kill flags be seen even when no event ever comes. An idle plugin costs
    /// one wakeup per timeout instead of a hundred a second.
    pub fn waitEvents(self: *Broker, plugin: u32, timeout_ms: i32) void {
        var fd: net.Socket = net.invalid;
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (plugin < self.queues.items.len) {
                const q = &self.queues.items[plugin];
                // A push between the pop that answered null and this park has
                // its byte in the pipe already; the poll returns at once.
                if (q.depth() != 0) return;
                fd = q.wake[0];
            }
        }
        if (!net.valid(fd)) {
            sleepMs(8);
            return;
        }
        var fds = [_]net.pollfd{.{ .fd = fd, .events = net.POLL.IN, .revents = 0 }};
        _ = net.poll(&fds, timeout_ms);
        if (fds[0].revents != 0) net.drainWake(fd);
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
        var span: u32 = 1;
        {
            self.mu.lock();
            defer self.mu.unlock();

            for (self.plugins.items) |p| {
                if (p.index != index) continue;
                p.enabled = false;
                id = p.id;
                source = p.source;
                span = p.source_span;
                if (p.sub) |s| {
                    self.vessels.unsubscribe(s);
                    p.sub = null;
                }
                p.ais_sub = false;
                p.view_sub = false;
                p.view_pending = false;
            }

            // Queued events for a plugin that will never run them again.
            self.clearQueueLocked(index);

            // Marked and shut down, never closed here: the I/O thread may be
            // between its locked lookup and a recv on the copied fd, and a
            // descriptor number closed now can be reused before that recv —
            // which would hand this plugin's queue another connection's
            // bytes. Shutdown unblocks the recv; the I/O thread's reap does
            // the close, the same division the Fetch and Ws paths use.
            for (self.conns.items) |*c| {
                if (c.plugin != index or c.closing) continue;
                c.closing = true;
                if (net.valid(c.fd)) net.shutdownBoth(c.fd);
            }
            for (self.udps.items) |*u| {
                if (u.plugin != index or u.closing) continue;
                u.closing = true;
                if (net.valid(u.fd)) net.shutdownBoth(u.fd);
            }
            self.wakeIo();
            var i: usize = 0;
            while (i < self.timers.items.len) {
                if (self.timers.items[i].plugin == index) {
                    _ = self.timers.orderedRemove(i);
                } else i += 1;
            }
            i = 0;
            while (i < self.files.items.len) {
                if (self.files.items[i].plugin != index) {
                    i += 1;
                    continue;
                }
                var f = self.files.orderedRemove(i);
                f.file.close(io);
            }
            // A fetch and a WebSocket are owned by their own threads, so they
            // are told to stop rather than freed here. Each unwinds, finds
            // itself cancelled and delivers nothing.
            for (self.fetches.items) |f| {
                if (f.plugin == index) f.cancelLocked();
            }
            for (self.wss.items) |w| {
                if (w.plugin == index) w.cancelLocked();
            }
            // What it stored stays on disk. A plugin that traps and is loaded
            // again next time must find its settings where it left them.
            self.dropKvLocked(index);
            // Its tables go with it: the declaration was the plugin's, and a
            // dialog fed by nobody is a dialog telling the mariner lies.
            i = 0;
            while (i < self.tables.items.len) {
                if (self.tables.items[i].plugin != index) {
                    i += 1;
                    continue;
                }
                var tab = self.tables.orderedRemove(i);
                freeTable(self.alloc, &tab);
            }
            // Its alerts go too. Nothing is left watching the condition, so
            // nothing can ever say it has passed, and an alarm the mariner
            // cannot make stop by fixing the boat is a lie.
            self.dropAlertsLocked(index);
        }
        if (id.len > 0) self.overlay.remove(id);
        self.clearVesselSources(source, span, now_ms);
        self.clearAisSources(source, span);
    }

    /// Take back what a capability produced, for a plugin that still runs.
    /// A revoked grant stops future calls, and what earlier calls drew or
    /// published must go with it: a frozen overlay object or a held value
    /// reads as live data and is not.
    pub fn withdraw(self: *Broker, index: u32, cap: Cap, now_ms: i64) void {
        var id: []const u8 = "";
        var source: SourceId = 0;
        var span: u32 = 1;
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.plugins.items) |p| {
                if (p.index != index) continue;
                id = p.id;
                source = p.source;
                span = p.source_span;
                // A revoked READ grant must stop the stream already flowing,
                // not just refuse the next subscribe call.
                switch (cap) {
                    .vessel_read => if (p.sub) |sid| {
                        self.vessels.unsubscribe(sid);
                        p.sub = null;
                    },
                    .ais_read => p.ais_sub = false,
                    .view_read => {
                        p.view_sub = false;
                        p.view_pending = false;
                    },
                    else => {},
                }
                break;
            }
        }
        switch (cap) {
            .overlay_draw => if (id.len > 0) self.overlay.remove(id),
            .vessel_publish => self.clearVesselSources(source, span, now_ms),
            .ais_publish => self.clearAisSources(source, span),
            .alerts_raise => self.dropAlerts(index),
            else => {},
        }
    }

    /// Drop the values every id in a plugin's block published. The whole block
    /// goes, not the first id alone: a plugin holds one source per connection,
    /// so clearing only its own would leave each gateway's last value on the
    /// chart looking live.
    fn clearVesselSources(self: *Broker, base: SourceId, span: u32, now_ms: i64) void {
        for (0..span) |k| self.vessels.clearSource(base + @as(SourceId, @intCast(k)), now_ms);
    }

    /// The same for the AIS targets each id in the block last updated.
    fn clearAisSources(self: *Broker, base: SourceId, span: u32) void {
        for (0..span) |k| _ = self.ais.clearSource(base + @as(SourceId, @intCast(k))) catch {};
    }

    // -- alerts ---------------------------------------------------------------

    /// Take one alert from a plugin, deduplicated.
    ///
    /// ONE CONDITION IS ONE ALERT, and what tells two apart is the plugin and
    /// the identity of the alert. A payload carrying a `key` says that
    /// identity outright, so two vessels closing are two alarms and one vessel
    /// restated is one however the words come out. A payload with no key falls
    /// back to its title and body. `Alert.restatedBy` holds the rule.
    ///
    /// A restatement updates the alert in place, words and all, and leaves the
    /// acknowledgement where it is: silence is the mariner's decision and a
    /// plugin saying the same thing again does not take it back. A LOUDER
    /// restatement does take it back, because a warning that has become an
    /// alarm is news.
    ///
    /// The caller has already checked the capability and logged the line.
    pub fn raiseAlert(self: *Broker, p: *Plugin, json: []const u8) void {
        const raised = alerts.Raised.parse(json) orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        const now = monoMs();
        self.clearAlertsLocked(now);

        for (self.alerts.items) |*a| {
            if (a.plugin != p.index) continue;
            if (!a.restatedBy(raised)) continue;
            a.last_ms = now;
            var news = self.setAlertWordsLocked(a, raised);
            if (raised.severity.louderThan(a.severity)) {
                a.severity = raised.severity;
                a.acknowledged = false;
                news = true;
            }
            if (news) self.alerts_seq += 1;
            return;
        }
        if (!self.makeAlertRoomLocked(p.index)) {
            self.say(level_warn, p.id, "alert refused: {d} unacknowledged alert(s) already raised", .{max_alerts_per_plugin});
            return;
        }
        const key = self.alloc.dupe(u8, raised.key) catch return;
        const title = self.alloc.dupe(u8, raised.title) catch {
            self.alloc.free(key);
            return;
        };
        const body = self.alloc.dupe(u8, raised.body) catch {
            self.alloc.free(key);
            self.alloc.free(title);
            return;
        };
        self.alerts.append(self.alloc, .{
            .plugin = p.index,
            .plugin_id = p.id,
            .id = self.next_alert_id,
            .severity = raised.severity,
            .key = key,
            .title = title,
            .body = body,
            .raised_ms = wallMs(),
            .last_ms = now,
        }) catch {
            self.alloc.free(key);
            self.alloc.free(title);
            self.alloc.free(body);
            return;
        };
        self.next_alert_id += 1;
        self.alerts_seq += 1;
    }

    /// Put the restated words on an alert already up. True when they are not
    /// what it was already saying, so the caller moves the sequence and the
    /// shell re-reads. An allocation that fails leaves the older words in
    /// place: words a few seconds out of date still name the danger.
    fn setAlertWordsLocked(self: *Broker, a: *Alert, raised: alerts.Raised) bool {
        if (std.mem.eql(u8, a.title, raised.title) and std.mem.eql(u8, a.body, raised.body)) return false;
        const title = self.alloc.dupe(u8, raised.title) catch return false;
        const body = self.alloc.dupe(u8, raised.body) catch {
            self.alloc.free(title);
            return false;
        };
        self.alloc.free(a.title);
        self.alloc.free(a.body);
        a.title = title;
        a.body = body;
        return true;
    }

    /// Silence one alert. What an acknowledgement names is one alert and not a
    /// class of condition: a mariner who has seen the vessel crossing ahead has
    /// not seen the one coming up astern, and one control for both would hide
    /// the second. True when an alert holds that id.
    pub fn ackAlert(self: *Broker, id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.alerts.items) |*a| {
            if (a.id != id) continue;
            if (!a.acknowledged) {
                a.acknowledged = true;
                a.last_ms = monoMs();
                self.alerts_seq += 1;
            }
            return true;
        }
        return false;
    }

    /// Every live alert, most urgent first: what nobody has answered, then the
    /// loudest, then the oldest.
    pub fn alertsJson(self: *Broker, out: *std.ArrayList(u8)) !void {
        self.mu.lock();
        defer self.mu.unlock();
        self.clearAlertsLocked(monoMs());
        const alloc = self.alloc;

        const order = try alloc.alloc(u32, self.alerts.items.len);
        defer alloc.free(order);
        for (order, 0..) |*x, i| x.* = @intCast(i);
        std.mem.sort(u32, order, AlertOrder{ .alerts = self.alerts.items }, AlertOrder.less);

        try out.print(alloc, "{{\"seq\":{d},\"alerts\":[", .{self.alerts_seq});
        for (order, 0..) |idx, n| {
            const a = self.alerts.items[idx];
            if (n > 0) try out.append(alloc, ',');
            try out.print(alloc, "{{\"id\":{d},\"plugin\":", .{a.id});
            try writeJsonString(out, alloc, a.plugin_id);
            try out.print(alloc, ",\"severity\":\"{s}\",\"title\":", .{a.severity.name()});
            try writeJsonString(out, alloc, a.title);
            try out.appendSlice(alloc, ",\"body\":");
            try writeJsonString(out, alloc, a.body);
            try out.print(alloc, ",\"raised\":{d},\"acknowledged\":{s}}}", .{
                a.raised_ms,
                if (a.acknowledged) "true" else "false",
            });
        }
        try out.appendSlice(alloc, "]}");
    }

    /// Retire the alerts nobody is keeping alive. An ACKNOWLEDGED alert with
    /// nothing happening to it for `alert_clear_ms` is a condition that has
    /// passed, so the same condition returning raises a fresh alert and sounds
    /// again. An unacknowledged one never retires here: an alarm ends when the
    /// mariner ends it, not when it gets old.
    fn clearAlertsLocked(self: *Broker, now_ms: i64) void {
        var i: usize = 0;
        while (i < self.alerts.items.len) {
            const a = self.alerts.items[i];
            if (!a.acknowledged or now_ms - a.last_ms < alert_clear_ms) {
                i += 1;
                continue;
            }
            _ = self.alerts.orderedRemove(i);
            freeAlert(self.alloc, a);
            self.alerts_seq += 1;
        }
    }

    /// Room for one more of this plugin's alerts. The oldest one the mariner
    /// has already answered gives way first, because a danger nobody has seen
    /// outranks a decision already made. False when every one of them is
    /// unanswered, and the raise is refused rather than quietly dropping an
    /// alarm still sounding.
    fn makeAlertRoomLocked(self: *Broker, index: u32) bool {
        var live: usize = 0;
        var oldest: ?usize = null;
        for (self.alerts.items, 0..) |a, i| {
            if (a.plugin != index) continue;
            live += 1;
            if (!a.acknowledged) continue;
            if (oldest == null or a.id < self.alerts.items[oldest.?].id) oldest = i;
        }
        if (live < max_alerts_per_plugin) return true;
        const at = oldest orelse return false;
        const gone = self.alerts.orderedRemove(at);
        freeAlert(self.alloc, gone);
        self.alerts_seq += 1;
        return true;
    }

    fn dropAlerts(self: *Broker, index: u32) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.dropAlertsLocked(index);
    }

    fn dropAlertsLocked(self: *Broker, index: u32) void {
        var i: usize = 0;
        while (i < self.alerts.items.len) {
            if (self.alerts.items[i].plugin != index) {
                i += 1;
                continue;
            }
            const gone = self.alerts.orderedRemove(i);
            freeAlert(self.alloc, gone);
            self.alerts_seq += 1;
        }
    }

    // -- tables ---------------------------------------------------------------

    /// Take one table declaration from a plugin. A declaration under a key the
    /// plugin already declared replaces it and drops its rows, because the
    /// columns may have moved under them. The key must be one the manifest
    /// carried. 0 on success, -1 when the declaration is refused, and a
    /// refusal always says why.
    pub fn declareTable(self: *Broker, p: *Plugin, json: []const u8) i32 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch {
            self.say(level_warn, p.id, "table: malformed declaration JSON", .{});
            return -1;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.say(level_warn, p.id, "table: a declaration is a JSON object", .{});
            return -1;
        }
        var tab = self.buildTable(p, parsed.value.object) catch return -1;

        self.mu.lock();
        defer self.mu.unlock();
        for (self.tables.items) |*old| {
            if (old.plugin != p.index or !std.mem.eql(u8, old.key, tab.key)) continue;
            // The dialog does not close because the plugin re-declared: the
            // mariner is still looking at it, and the plugin still owns it.
            tab.open = old.open;
            freeTable(self.alloc, old);
            old.* = tab;
            return 0;
        }
        var mine: usize = 0;
        for (self.tables.items) |old| {
            if (old.plugin == p.index) mine += 1;
        }
        if (mine >= max_tables) {
            self.say(level_warn, p.id, "table {s}: {d} tables already declared; {d} allowed", .{ tab.key, mine, max_tables });
            freeTable(self.alloc, &tab);
            return -1;
        }
        self.tables.append(self.alloc, tab) catch {
            freeTable(self.alloc, &tab);
            return -1;
        };
        return 0;
    }

    /// True when `key` is one of the table keys the manifest declared.
    fn keyDeclared(keys: []const []const u8, key: []const u8) bool {
        for (keys) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    /// One declaration, allocated but not yet registered. Every refusal is
    /// logged here, so the caller only has to pass the error on.
    fn buildTable(self: *Broker, p: *Plugin, o: std.json.ObjectMap) !Table {
        const alloc = self.alloc;
        const key = jsonText(o, "key");
        if (key.len == 0 or key.len > max_table_key) {
            self.say(level_warn, p.id, "table: a declaration needs a key of 1 to {d} bytes", .{max_table_key});
            return error.BadDeclaration;
        }
        // THE MANIFEST IS THE CONSENT. A table is a window with a menu item in
        // front of the mariner, and the manifest is where they were told about
        // it. A module that asks for one the manifest never carried is asking
        // for a surface nobody agreed to, so it is refused by key and named in
        // the log. The SDK generates both declarations from one source, so a
        // plugin only ever reaches this line after its manifest was edited
        // apart from its code.
        if (!keyDeclared(p.table_keys, key)) {
            self.say(level_warn, p.id, "table {s}: the manifest declares no table under that key; refused", .{key});
            return error.BadDeclaration;
        }
        const cols_v = o.get("columns") orelse std.json.Value{ .null = {} };
        const n_cols = if (cols_v == .array) cols_v.array.items.len else 0;
        if (n_cols == 0 or n_cols > max_table_columns) {
            self.say(level_warn, p.id, "table {s}: {d} columns declared; 1 to {d} allowed", .{ key, n_cols, max_table_columns });
            return error.BadDeclaration;
        }

        var tab = Table{
            .plugin = p.index,
            .plugin_id = p.id,
            .key = try alloc.dupe(u8, key),
            .title = try alloc.dupe(u8, jsonText(o, "title")),
            .menu = try alloc.dupe(u8, jsonText(o, "menu")),
            .columns = try alloc.alloc(Column, n_cols),
            .sort_key = &.{},
            .at_lat = &.{},
            .at_lon = &.{},
        };
        // Every column starts empty, so a refusal part way through the loop
        // frees exactly what was built and nothing else: freeing an empty
        // slice is a no-op.
        for (tab.columns) |*c| c.* = .{ .key = &.{}, .label = &.{}, .type = .text };
        var built: usize = 0;
        errdefer freeTable(alloc, &tab);

        for (cols_v.array.items) |cv| {
            if (cv != .object) {
                self.say(level_warn, p.id, "table {s}: a column is a JSON object", .{key});
                return error.BadDeclaration;
            }
            const co = cv.object;
            const ckey = jsonText(co, "key");
            const label = jsonText(co, "label");
            const type_name = jsonText(co, "type");
            const ctype = ColumnType.fromName(type_name) orelse {
                self.say(level_warn, p.id, "table {s}: column \"{s}\" has type \"{s}\", which is not one of distance, speed, bearing, duration, number, text, flag", .{ key, ckey, type_name });
                return error.BadDeclaration;
            };
            if (ckey.len == 0 or ckey.len > max_table_key or label.len > max_table_label) {
                self.say(level_warn, p.id, "table {s}: a column needs a key of 1 to {d} bytes and a label of at most {d}", .{ key, max_table_key, max_table_label });
                return error.BadDeclaration;
            }
            for (tab.columns[0..built]) |c| {
                if (!std.mem.eql(u8, c.key, ckey)) continue;
                self.say(level_warn, p.id, "table {s}: two columns called \"{s}\"", .{ key, ckey });
                return error.BadDeclaration;
            }
            tab.columns[built] = .{
                .key = try alloc.dupe(u8, ckey),
                .label = try alloc.dupe(u8, label),
                .type = ctype,
            };
            built += 1;
        }

        if (o.get("sort")) |sv| {
            if (sv == .object) {
                const want = jsonText(sv.object, "key");
                if (want.len > 0) {
                    if (tab.column(want) == null) {
                        self.say(level_warn, p.id, "table {s}: the default sort names column \"{s}\", which is not declared", .{ key, want });
                        return error.BadDeclaration;
                    }
                    alloc.free(tab.sort_key);
                    tab.sort_key = try alloc.dupe(u8, want);
                }
                tab.sort_asc = switch (sv.object.get("ascending") orelse std.json.Value{ .bool = true }) {
                    .bool => |b| b,
                    else => true,
                };
            }
        }
        if (o.get("at")) |av| {
            if (av == .object) {
                const lat = jsonText(av.object, "lat");
                const lon = jsonText(av.object, "lon");
                if (lat.len == 0 or lon.len == 0 or lat.len > max_table_key or lon.len > max_table_key) {
                    self.say(level_warn, p.id, "table {s}: \"at\" names both a lat key and a lon key or neither", .{key});
                    return error.BadDeclaration;
                }
                alloc.free(tab.at_lat);
                alloc.free(tab.at_lon);
                tab.at_lat = try alloc.dupe(u8, lat);
                tab.at_lon = try alloc.dupe(u8, lon);
            }
        }
        return tab;
    }

    /// One keyed batch: `{"key":..,"upsert":[{..}],"remove":[".."]}`. Returns
    /// the number of rows the batch touched, or -1 when it was refused whole.
    ///
    /// A batch is refused for want of a declaration, for arriving inside the
    /// status cadence, or for taking the table past its row budget. It is
    /// never half applied: the mariner reading a table is reading one moment.
    pub fn updateTable(self: *Broker, p: *Plugin, json: []const u8) i32 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch {
            self.say(level_warn, p.id, "table: malformed update JSON", .{});
            return -1;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return -1;
        const o = parsed.value.object;
        const key = jsonText(o, "key");

        const upserts: []const std.json.Value = switch (o.get("upsert") orelse std.json.Value{ .null = {} }) {
            .array => |a| a.items,
            else => &.{},
        };
        const removes: []const std.json.Value = switch (o.get("remove") orelse std.json.Value{ .null = {} }) {
            .array => |a| a.items,
            else => &.{},
        };

        self.mu.lock();
        defer self.mu.unlock();

        const tab = self.tableLocked(p.index, key) orelse {
            self.say(level_warn, p.id, "table {s}: no such table is declared", .{key});
            return -1;
        };

        const now = monoMs();
        if (tab.last_ms != 0 and now - tab.last_ms < table_min_interval_ms) {
            self.refuseBatchLocked(p, tab, "one update per status cadence; this one is {d} ms after the last", .{now - tab.last_ms});
            return -1;
        }

        // What the table would hold afterwards, counted before anything is
        // touched: removals first, then the ids the batch adds.
        var final: usize = tab.rows.items.len;
        for (removes, 0..) |rv, i| {
            const id = if (rv == .string) rv.string else continue;
            // An id listed twice takes one row off, not two.
            var earlier = false;
            for (removes[0..i]) |pv| {
                if (pv == .string and std.mem.eql(u8, pv.string, id)) earlier = true;
            }
            if (!earlier and tab.row(id) != null) final -= 1;
        }
        for (upserts, 0..) |uv, i| {
            if (uv != .object) continue;
            const id = jsonText(uv.object, "id");
            if (id.len == 0) continue;
            if (tab.row(id) != null) {
                // A row this batch removed and then sent again is back.
                var was_removed = false;
                for (removes) |rv| {
                    if (rv == .string and std.mem.eql(u8, rv.string, id)) was_removed = true;
                }
                if (was_removed) final += 1;
                continue;
            }
            var earlier = false;
            for (upserts[0..i]) |pv| {
                if (pv == .object and std.mem.eql(u8, jsonText(pv.object, "id"), id)) earlier = true;
            }
            if (!earlier) final += 1;
        }
        if (final > max_table_rows) {
            self.refuseBatchLocked(p, tab, "{d} rows over the {d}-row budget", .{ final - max_table_rows, max_table_rows });
            return -1;
        }

        var touched: i32 = 0;
        for (removes) |rv| {
            const id = if (rv == .string) rv.string else continue;
            for (tab.rows.items, 0..) |r, i| {
                if (!std.mem.eql(u8, r.id, id)) continue;
                freeRow(self.alloc, tab.rows.orderedRemove(i));
                touched += 1;
                break;
            }
        }
        for (upserts) |uv| {
            if (uv != .object) continue;
            if (self.applyRowLocked(p, tab, uv.object)) touched += 1;
        }

        tab.last_ms = now;
        tab.seq += 1;
        return touched;
    }

    /// One upserted row, replacing whatever stood under its id. False when the
    /// row could not be taken; the batch carries on, the way a bad update in a
    /// publish batch does.
    fn applyRowLocked(self: *Broker, p: *Plugin, tab: *Table, o: std.json.ObjectMap) bool {
        const alloc = self.alloc;
        const id = jsonText(o, "id");
        if (id.len == 0 or id.len > max_table_key) return false;

        const cells = alloc.alloc(Cell, tab.columns.len) catch return false;
        var built: usize = 0;
        for (tab.columns) |c| {
            const v = o.get(c.key) orelse std.json.Value{ .null = {} };
            cells[built] = cell: {
                if (c.type.numeric()) {
                    const n = jsonNum(v) orelse break :cell .none;
                    break :cell .{ .num = n };
                }
                const s = switch (v) {
                    .string => |x| x,
                    else => break :cell .none,
                };
                if (s.len == 0) break :cell .none;
                if (s.len > max_table_cell) {
                    self.say(level_warn, p.id, "table {s}: a \"{s}\" cell of {d} bytes is over the {d}-byte cell budget", .{ tab.key, c.key, s.len, max_table_cell });
                    break :cell .none;
                }
                break :cell .{ .text = alloc.dupe(u8, s) catch break :cell .none };
            };
            built += 1;
        }

        var lat: ?f64 = null;
        var lon: ?f64 = null;
        if (tab.at_lat.len > 0) {
            lat = jsonNum(o.get(tab.at_lat) orelse std.json.Value{ .null = {} });
            lon = jsonNum(o.get(tab.at_lon) orelse std.json.Value{ .null = {} });
            if (lat == null or lon == null) {
                lat = null;
                lon = null;
            }
        }
        const band: i32 = @intCast(std.math.clamp(jsonInt(o.get("band")) orelse 0, 0, 255));

        if (tab.row(id)) |r| {
            freeCells(alloc, r.cells);
            r.cells = cells;
            r.band = band;
            r.lat = lat;
            r.lon = lon;
            return true;
        }
        const owned_id = alloc.dupe(u8, id) catch {
            freeCells(alloc, cells);
            return false;
        };
        tab.rows.append(alloc, .{
            .id = owned_id,
            .band = band,
            .cells = cells,
            .lat = lat,
            .lon = lon,
            .seq = tab.next_row_seq,
        }) catch {
            alloc.free(owned_id);
            freeCells(alloc, cells);
            return false;
        };
        tab.next_row_seq += 1;
        return true;
    }

    /// A batch dropped over budget. The first one is said out loud and then one
    /// in a hundred: a plugin sending too fast has to hear about it, and a
    /// plugin sending too fast must not be able to fill the log.
    fn refuseBatchLocked(self: *Broker, p: *Plugin, tab: *Table, comptime fmt: []const u8, args: anytype) void {
        tab.refused += 1;
        if (tab.refused != 1 and tab.refused % 100 != 0) return;
        var buf: [200]u8 = undefined;
        const why = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        self.say(level_warn, p.id, "table {s}: batch refused, {s} ({d} refused so far)", .{ tab.key, why, tab.refused });
    }

    fn tableLocked(self: *Broker, plugin: u32, key: []const u8) ?*Table {
        for (self.tables.items) |*tab| {
            if (tab.plugin == plugin and std.mem.eql(u8, tab.key, key)) return tab;
        }
        return null;
    }

    fn tableByIdLocked(self: *Broker, plugin_id: []const u8, key: []const u8) ?*Table {
        for (self.tables.items) |*tab| {
            if (std.mem.eql(u8, tab.plugin_id, plugin_id) and std.mem.eql(u8, tab.key, key)) return tab;
        }
        return null;
    }

    /// Every table every plugin has declared: what a shell builds its menu and
    /// its columns from.
    pub fn tablesJson(self: *Broker, out: *std.ArrayList(u8)) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const alloc = self.alloc;
        try out.appendSlice(alloc, "{\"tables\":[");
        for (self.tables.items, 0..) |*tab, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"plugin\":");
            try writeJsonString(out, alloc, tab.plugin_id);
            try out.appendSlice(alloc, ",\"key\":");
            try writeJsonString(out, alloc, tab.key);
            try out.appendSlice(alloc, ",\"title\":");
            try writeJsonString(out, alloc, tab.title);
            try out.appendSlice(alloc, ",\"menu\":");
            try writeJsonString(out, alloc, tab.menu);
            try out.appendSlice(alloc, ",\"columns\":[");
            for (tab.columns, 0..) |c, k| {
                if (k > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, "{\"key\":");
                try writeJsonString(out, alloc, c.key);
                try out.appendSlice(alloc, ",\"label\":");
                try writeJsonString(out, alloc, c.label);
                try out.appendSlice(alloc, ",\"type\":\"");
                try out.appendSlice(alloc, c.type.name());
                try out.appendSlice(alloc, "\"}");
            }
            try out.appendSlice(alloc, "],\"sort\":{\"key\":");
            try writeJsonString(out, alloc, tab.sort_key);
            try out.print(alloc, ",\"ascending\":{s}}}", .{if (tab.sort_asc) "true" else "false"});
            if (tab.at_lat.len > 0) {
                try out.appendSlice(alloc, ",\"at\":{\"lat\":");
                try writeJsonString(out, alloc, tab.at_lat);
                try out.appendSlice(alloc, ",\"lon\":");
                try writeJsonString(out, alloc, tab.at_lon);
                try out.append(alloc, '}');
            }
            try out.print(alloc, ",\"open\":{s},\"rows\":{d},\"seq\":{d}}}", .{
                if (tab.open) "true" else "false",
                tab.rows.items.len,
                tab.seq,
            });
        }
        try out.appendSlice(alloc, "]}");
    }

    /// One table's rows, IN ORDER: band first, then the column the shell asked
    /// for, then arrival. The band is the plugin's ordering policy and the
    /// column sort never crosses one, so an alarmed row holds the top of the
    /// table whatever the mariner sorted by.
    ///
    /// `sort_key` empty (or naming no column) takes the declared default.
    /// False when no such table is declared.
    pub fn tableRowsJson(
        self: *Broker,
        plugin_id: []const u8,
        key: []const u8,
        sort_key: []const u8,
        ascending: bool,
        out: *std.ArrayList(u8),
    ) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        const alloc = self.alloc;
        const tab = self.tableByIdLocked(plugin_id, key) orelse return false;

        var col: ?usize = null;
        var asc = ascending;
        if (sort_key.len > 0) col = tab.column(sort_key);
        if (col == null) {
            col = if (tab.sort_key.len > 0) tab.column(tab.sort_key) else null;
            asc = tab.sort_asc;
        }

        const order = try alloc.alloc(u32, tab.rows.items.len);
        defer alloc.free(order);
        for (order, 0..) |*x, i| x.* = @intCast(i);
        const kind: ColumnType = if (col) |c| tab.columns[c].type else .text;
        std.mem.sort(u32, order, Order{
            .rows = tab.rows.items,
            .col = col,
            .asc = asc,
            .kind = kind,
        }, Order.less);

        try out.appendSlice(alloc, "{\"key\":");
        try writeJsonString(out, alloc, tab.key);
        try out.print(alloc, ",\"seq\":{d},\"open\":{s},\"sort\":{{\"key\":", .{ tab.seq, if (tab.open) "true" else "false" });
        try writeJsonString(out, alloc, if (col) |c| tab.columns[c].key else "");
        try out.print(alloc, ",\"ascending\":{s}}},\"rows\":[", .{if (asc) "true" else "false"});
        for (order, 0..) |idx, n| {
            const r = tab.rows.items[idx];
            if (n > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"id\":");
            try writeJsonString(out, alloc, r.id);
            try out.print(alloc, ",\"band\":{d}", .{r.band});
            if (r.lat) |lat| {
                if (r.lon) |lon| try out.print(alloc, ",\"at\":[{d},{d}]", .{ lon, lat });
            }
            try out.appendSlice(alloc, ",\"cells\":[");
            for (r.cells, 0..) |c, k| {
                if (k > 0) try out.append(alloc, ',');
                switch (c) {
                    .none => try out.appendSlice(alloc, "null"),
                    .num => |x| if (std.math.isFinite(x))
                        try out.print(alloc, "{d}", .{x})
                    else
                        try out.appendSlice(alloc, "null"),
                    .text => |x| try writeJsonString(out, alloc, x),
                }
            }
            try out.appendSlice(alloc, "]}");
        }
        try out.appendSlice(alloc, "]}");
        return true;
    }

    /// Tell a plugin its table is on screen, or is not. The plugin builds rows
    /// only while it is: a dialog nobody opened costs the boat nothing.
    /// False when no such table is declared.
    pub fn setTableOpen(self: *Broker, plugin_id: []const u8, key: []const u8, open: bool) bool {
        var plugin: u32 = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            const tab = self.tableByIdLocked(plugin_id, key) orelse return false;
            if (tab.open == open) return true;
            tab.open = open;
            plugin = tab.plugin;
            // A table nobody is watching keeps no rows: the plugin describes
            // the whole set again the moment it is opened.
            if (!open) {
                for (tab.rows.items) |r| freeRow(self.alloc, r);
                tab.rows.clearRetainingCapacity();
                tab.last_ms = 0;
                tab.seq += 1;
            }
        }
        var buf: [max_table_key + 16]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "{{\"key\":\"{s}\"}}", .{key}) catch "{}";
        self.push(plugin, if (open) Kind.table_open else Kind.table_closed, 0, payload);
        return true;
    }

    /// True while a shell has this table on screen.
    pub fn tableOpen(self: *Broker, plugin_id: []const u8, key: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const tab = self.tableByIdLocked(plugin_id, key) orelse return false;
        return tab.open;
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
        const id = self.next_id;
        self.next_id += 1;
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
            // A broker that was never started can still have workers: a native
            // run during `lk_start` reaches this file before the I/O thread
            // exists.
            self.stopWorkers();
            self.awaitWorkers();
            return;
        };
        self.stopping.store(true, .release);
        self.wakeIo();
        th.join();
        self.io_thread = null;
        // The workers write into this broker and are detached, so they have to
        // be gone before anything it owns is. The wake pipe stays open until
        // they are: the last thing each does is write to it.
        self.stopWorkers();
        self.awaitWorkers();
        for (self.wake) |fd| if (net.valid(fd)) net.close(fd);
        self.wake = .{ net.invalid, net.invalid };
    }

    fn awaitWorkers(self: *Broker) void {
        var waited: u32 = 0;
        var said = false;
        while (self.workers.load(.acquire) > 0) : (waited += 2) {
            if (!said and waited >= worker_wait_warn_ms) {
                said = true;
                self.say(level_warn, "host", "waiting for {d} network worker(s) to finish", .{self.workers.load(.acquire)});
            }
            sleepMs(2);
        }
    }

    /// Tell every fetch and every WebSocket to give up, and shut down their
    /// sockets so a thread parked in a blocking read returns at once instead of
    /// waiting out its 20 s timeout. The threads free themselves; nothing here
    /// joins one, because a peer that stopped answering must not be able to
    /// hold the application open.
    fn stopWorkers(self: *Broker) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.fetches.items) |f| f.cancelLocked();
        for (self.wss.items) |w| w.cancelLocked();
    }

    pub fn wakeIo(self: *Broker) void {
        if (!net.valid(self.wake[1])) return;
        const one = [_]u8{0};
        _ = net.send(self.wake[1], &one);
    }

    fn ioMain(self: *Broker) void {
        var fds: std.ArrayList(net.pollfd) = .empty;
        defer fds.deinit(self.alloc);
        // Parallel to `fds` after the wake pipe: which socket each slot is.
        var owners: std.ArrayList(Owner) = .empty;
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
            _ = self.workers.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{ .stack_size = resolver_stack_bytes }, resolveMain, .{req}) catch |e| {
                _ = self.workers.fetchSub(1, .acq_rel);
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
        const fd: ?net.Socket = net.dial(host, req.port) catch |e| blk: {
            self.say(level_warn, "host", "tcp connect to {s}:{d} failed: {s}", .{ host, req.port, @errorName(e) });
            break :blk null;
        };
        self.finishConn(req.id, req.plugin, fd);
        // The poll set has no slot for a socket that did not exist when it was
        // built, so say so rather than waiting out the tick.
        self.wakeIo();
        self.alloc.destroy(req);
        _ = self.workers.fetchSub(1, .acq_rel);
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
    fn buildPollSet(self: *Broker, fds: *std.ArrayList(net.pollfd), owners: *std.ArrayList(Owner)) i32 {
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
            owners.append(self.alloc, .{ .id = c.id, .udp = false }) catch break;
        }
        // A UDP port has nothing to connect and nothing queued to write, so it
        // only ever asks to read — and the same backpressure rule applies: a
        // plugin behind on its queue stops being handed datagrams, which the
        // kernel then drops at the socket instead of the host dropping them at
        // a full queue.
        for (self.udps.items) |*u| {
            if (!net.valid(u.fd) or u.closing) continue;
            if (self.pausedLocked(u.plugin)) continue;
            fds.append(self.alloc, .{ .fd = u.fd, .events = net.POLL.IN, .revents = 0 }) catch break;
            owners.append(self.alloc, .{ .id = u.id, .udp = true }) catch break;
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

    fn serviceSockets(self: *Broker, fds: []net.pollfd, owners: []const Owner) void {
        for (fds, 0..) |pfd, i| {
            if (i >= owners.len) break;
            if (pfd.revents == 0) continue;
            if (owners[i].udp) {
                self.serviceUdp(owners[i].id);
                continue;
            }
            self.serviceOne(owners[i].id, pfd.revents);
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

    /// Sockets tcp_close, udp_close or a plugin drop marked. Done outside the
    /// poll walk so a close cannot invalidate the slot being serviced, and
    /// ONLY here for conns and udps: this thread is the one that reads them,
    /// so a close here can never race its own recv.
    fn reapClosing(self: *Broker) void {
        while (true) {
            var id: i64 = 0;
            {
                self.mu.lock();
                defer self.mu.unlock();
                const c = for (self.conns.items) |*c| {
                    if (c.closing) break c;
                } else break;
                id = c.id;
            }
            self.closeConn(id, 0, false);
        }
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.udps.items.len) {
            if (!self.udps.items[i].closing) {
                i += 1;
                continue;
            }
            // Under mu, like closeConn: sendUdp holds mu across its send, so
            // the descriptor cannot be closed and reused mid-send.
            const u = self.udps.orderedRemove(i);
            if (net.valid(u.fd)) net.close(u.fd);
        }
    }

    // -- UDP, as the natives use it ------------------------------------------

    /// Bind a UDP port and hand back its id. There is no connect and no
    /// handshake, so unlike `openConn` this either works now or fails now.
    pub fn openUdp(self: *Broker, plugin: u32, port: u16) i64 {
        const fd = net.udpBind(port) catch |e| {
            self.say(level_warn, self.idOf(plugin), "udp_open {d}: {s}", .{ port, @errorName(e) });
            return -1;
        };
        const bound = net.udpPort(fd);
        self.mu.lock();
        const id = self.next_id;
        self.next_id += 1;
        self.udps.append(self.alloc, .{ .id = id, .plugin = plugin, .fd = fd, .port = bound }) catch {
            self.mu.unlock();
            net.close(fd);
            return -1;
        };
        self.mu.unlock();
        self.wakeIo();
        return id;
    }

    /// Send one datagram. `host` must be an IP LITERAL: a name would need a
    /// resolver, and this runs on the plugin's own dispatch thread where a
    /// blocking lookup would eat the watchdog budget. 255.255.255.255 works,
    /// which is what NMEA over UDP uses.
    pub fn sendUdp(self: *Broker, plugin: u32, id: i64, data: []const u8, host: []const u8, port: u16) i32 {
        if (data.len > udp_max_datagram) return -1;
        var addrs: [max_addrs]Addr = undefined;
        const n = net.resolveNumeric(host, port, &addrs) catch {
            self.say(level_warn, self.idOf(plugin), "udp_send: {s} is not an IP address", .{host});
            return -1;
        };
        self.mu.lock();
        var fd: net.Socket = net.invalid;
        for (self.udps.items) |u| {
            if (u.id == id and u.plugin == plugin and !u.closing) fd = u.fd;
        }
        if (!net.valid(fd)) {
            self.mu.unlock();
            return -1;
        }
        // Sent under mu: the send does not block, and the reap closes UDP
        // descriptors under mu, so this one cannot be closed and reused
        // between the lookup and the sendto.
        const wrote = net.udpSendTo(fd, data, &addrs[0]);
        self.mu.unlock();
        if (wrote < 0) return -1;
        _ = n;
        return @intCast(wrote);
    }

    /// Close a UDP port the plugin opened. Marked here, closed by the I/O
    /// thread's reap — a close on this thread races the recvfrom the I/O
    /// thread may be inside. No event: the plugin asked, so it already knows.
    pub fn closeUdp(self: *Broker, plugin: u32, id: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.udps.items) |*u| {
            if (u.id != id or u.plugin != plugin or u.closing) continue;
            u.closing = true;
            if (net.valid(u.fd)) net.shutdownBoth(u.fd);
            self.wakeIo();
            return;
        }
    }

    /// One datagram off one bound port, on the I/O thread.
    ///
    /// The buffer is one byte over the cap so an oversize datagram is visible:
    /// recvfrom truncates silently, and a plugin handed the first 8192 bytes of
    /// a 9 KB NMEA burst would parse a corrupt sentence and never know.
    fn serviceUdp(self: *Broker, id: i64) void {
        var fd: net.Socket = net.invalid;
        var plugin: u32 = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.udps.items) |u| {
                if (u.id == id and !u.closing) {
                    fd = u.fd;
                    plugin = u.plugin;
                }
            }
        }
        if (!net.valid(fd)) return;

        var buf: [udp_max_datagram + 1]u8 = undefined;
        while (true) {
            const n = net.udpRecv(fd, &buf);
            if (n < 0) return;
            if (n > udp_max_datagram) {
                self.say(level_warn, self.idOf(plugin), "udp: dropped a datagram over {d} bytes", .{udp_max_datagram});
                continue;
            }
            self.push(plugin, Kind.udp_data, @bitCast(id), buf[0..@intCast(n)]);
            // One pass reads what is queued; the poll loop comes back for more.
            return;
        }
    }

    pub fn idOf(self: *Broker, plugin: u32) []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.idOfLocked(plugin);
    }

    // -- HTTP, as the natives use it -----------------------------------------

    /// Start a fetch on a thread of its own and hand back its id. Everything
    /// slow — the name lookup, the TLS handshake, the body — happens there, so
    /// neither the plugin's dispatch thread nor the I/O thread waits for a
    /// server.
    pub fn startFetch(self: *Broker, plugin: u32, req: FetchRequest) i64 {
        const f = self.alloc.create(Fetch) catch return -1;
        f.* = .{ .br = self, .id = 0, .plugin = plugin, .req = req };

        self.mu.lock();
        if (self.fetching >= http_max_inflight) {
            self.mu.unlock();
            self.say(level_warn, self.idOf(plugin), "http_fetch refused: {d} fetches already running", .{self.fetching});
            f.req.deinit(self.alloc);
            self.alloc.destroy(f);
            return -1;
        }
        const id = self.next_id;
        self.next_id += 1;
        f.id = id;
        self.fetches.append(self.alloc, f) catch {
            self.mu.unlock();
            f.req.deinit(self.alloc);
            self.alloc.destroy(f);
            return -1;
        };
        self.fetching += 1;
        self.mu.unlock();

        _ = self.workers.fetchAdd(1, .acq_rel);
        const th = std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, fetchMain, .{f}) catch |e| {
            _ = self.workers.fetchSub(1, .acq_rel);
            self.say(level_warn, self.idOf(plugin), "http_fetch: no thread: {s}", .{@errorName(e)});
            self.retireFetch(f);
            return -1;
        };
        th.detach();
        return id;
    }

    /// Take a fetch out of the list and free it. Called by its own thread, and
    /// by `startFetch` when the thread could not be made.
    pub fn retireFetch(self: *Broker, f: *Fetch) void {
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.fetches.items, 0..) |item, i| {
                if (item == f) {
                    _ = self.fetches.orderedRemove(i);
                    break;
                }
            }
            if (self.fetching > 0) self.fetching -= 1;
        }
        f.req.deinit(self.alloc);
        self.alloc.destroy(f);
    }

    // -- WebSocket, as the natives use it -------------------------------------

    /// Open a WebSocket on a thread of its own and hand back its id. The
    /// handshake happens there; the plugin hears WS_OPEN or WS_CLOSED.
    pub fn openWs(self: *Broker, plugin: u32, url: []u8, protocols: []u8) i64 {
        const w = self.alloc.create(Ws) catch {
            self.alloc.free(url);
            self.alloc.free(protocols);
            return -1;
        };
        w.* = .{ .br = self, .id = 0, .plugin = plugin, .url = url, .protocols = protocols };
        // Without the pair every send, close and shutdown waits out the full
        // ws_poll_ms; the poll timeout stays as the fallback when a host has
        // no descriptors to spare.
        net.wakePair(&w.wake) catch {};

        self.mu.lock();
        const id = self.next_id;
        self.next_id += 1;
        w.id = id;
        self.wss.append(self.alloc, w) catch {
            self.mu.unlock();
            w.free(self.alloc);
            return -1;
        };
        self.mu.unlock();

        _ = self.workers.fetchAdd(1, .acq_rel);
        const th = std.Thread.spawn(.{ .stack_size = worker_stack_bytes }, wsMain, .{w}) catch |e| {
            _ = self.workers.fetchSub(1, .acq_rel);
            self.say(level_warn, self.idOf(plugin), "ws_connect: no thread: {s}", .{@errorName(e)});
            self.retireWs(w);
            return -1;
        };
        th.detach();
        return id;
    }

    /// Queue one text message for a WebSocket's own thread to write. The write
    /// itself never happens here: a TLS record must be produced by one thread
    /// at a time, and the dispatch thread has a watchdog budget to keep.
    pub fn sendWs(self: *Broker, plugin: u32, id: i64, text: []const u8) i32 {
        if (text.len > webio.max_message) return -1;
        const owned = self.alloc.dupe(u8, text) catch return -1;
        self.mu.lock();
        const w = self.wsForLocked(plugin, id) orelse {
            self.mu.unlock();
            self.alloc.free(owned);
            return -1;
        };
        if (w.out.items.len >= ws_max_queued_frames or w.out_bytes + owned.len > ws_max_queued_bytes) {
            self.mu.unlock();
            self.alloc.free(owned);
            return -1;
        }
        w.out.append(self.alloc, owned) catch {
            self.mu.unlock();
            self.alloc.free(owned);
            return -1;
        };
        w.out_bytes += owned.len;
        w.wakeLocked();
        self.mu.unlock();
        return @intCast(text.len);
    }

    /// Ask a WebSocket to close. Its thread sends the close frame and answers
    /// with WS_CLOSED, so a plugin sees the same event whoever started it.
    pub fn closeWs(self: *Broker, plugin: u32, id: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        const w = self.wsForLocked(plugin, id) orelse return;
        w.closing = true;
        w.wakeLocked();
    }

    fn wsForLocked(self: *Broker, plugin: u32, id: i64) ?*Ws {
        for (self.wss.items) |w| {
            if (w.id == id and w.plugin == plugin and !w.cancelled) return w;
        }
        return null;
    }

    pub fn retireWs(self: *Broker, w: *Ws) void {
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.wss.items, 0..) |item, i| {
                if (item == w) {
                    _ = self.wss.orderedRemove(i);
                    break;
                }
            }
        }
        w.free(self.alloc);
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
                _ = self.pushLocked(plugin, Kind.timer, @bitCast(id), "");
            }
        }
    }

    // -- storage --------------------------------------------------------------

    /// Point the per-plugin key-value files at a directory the application
    /// owns. Call before `start`. Without it the broker finds the platform's
    /// own place for data that must survive; if there is none, storage still
    /// works and is forgotten at shutdown.
    ///
    /// This is DATA, not cache. `lookout_set_cache_dir` names a directory the
    /// operating system may purge, and a plugin's saved settings must not live
    /// where a low-disk sweep can take them.
    pub fn setStorageDir(self: *Broker, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.storage_dir) |d| self.alloc.free(d);
        self.storage_dir = self.alloc.dupe(u8, path) catch null;
        self.storage_dir_resolved = true;
    }

    /// The directory in force, resolved once. Null when nothing writable was
    /// found, which is said out loud the first time a plugin stores anything.
    fn storageDirLocked(self: *Broker) ?[]const u8 {
        if (!self.storage_dir_resolved) {
            self.storage_dir_resolved = true;
            self.storage_dir = defaultStorageDir(self.alloc);
            if (self.storage_dir == null) {
                self.say(level_warn, "host", "no writable data directory: plugin storage is memory only", .{});
            }
        }
        return self.storage_dir;
    }

    /// This plugin's store, loaded from its file the first time it is asked
    /// for. A file that will not parse is logged and treated as empty rather
    /// than refused: a plugin that cannot start because its saved state is
    /// corrupt is worse than one that starts with none.
    fn kvForLocked(self: *Broker, plugin: u32) ?*KvStore {
        for (self.kv.items) |*store| {
            if (store.plugin == plugin) return store;
        }
        const id = self.idOfLocked(plugin);
        self.kv.append(self.alloc, .{ .plugin = plugin, .id = id }) catch return null;
        const store = &self.kv.items[self.kv.items.len - 1];
        const dir = self.storageDirLocked() orelse return store;
        store.load(self.alloc, dir) catch |e| {
            self.say(level_warn, id, "storage: {s}.json not read: {s}", .{ id, @errorName(e) });
        };
        return store;
    }

    /// The size of the value under `key`, or -1 when there is none. `out` is
    /// written only when the value FITS: the two-call pattern is to ask with a
    /// zero-length buffer, then ask again with one the right size.
    pub fn storageGet(self: *Broker, plugin: u32, key: []const u8, out: []u8) i32 {
        if (key.len == 0 or key.len > storage_max_key) return -1;
        self.mu.lock();
        defer self.mu.unlock();
        const store = self.kvForLocked(plugin) orelse return -1;
        const value = store.get(key) orelse return -1;
        if (value.len <= out.len) @memcpy(out[0..value.len], value);
        return @intCast(value.len);
    }

    /// Write `value` under `key`, or delete the key when `value` is empty.
    /// Returns 0, or -1 when a cap is in the way.
    pub fn storagePut(self: *Broker, plugin: u32, key: []const u8, value: []const u8) i32 {
        if (key.len == 0 or key.len > storage_max_key or !printableKey(key)) return -1;
        if (value.len > storage_max_value) return -1;
        self.mu.lock();
        defer self.mu.unlock();
        const store = self.kvForLocked(plugin) orelse return -1;
        store.put(self.alloc, key, value) catch |e| {
            self.say(level_warn, store.id, "storage_put {s}: {s}", .{ key, @errorName(e) });
            return -1;
        };
        const dir = self.storageDirLocked() orelse return 0;
        // Write through. A put is a mariner changing something, not a data
        // stream, so the cost is a few hundred microseconds a few times an
        // hour, and nothing is lost if the application is killed.
        store.save(self.alloc, dir) catch |e| {
            self.say(level_warn, store.id, "storage: {s}.json not written: {s}", .{ store.id, @errorName(e) });
            return -1;
        };
        return 0;
    }

    /// Forget a plugin's in-memory store. The FILE stays: a plugin that
    /// trapped must find its settings again next time it loads.
    fn dropKvLocked(self: *Broker, plugin: u32) void {
        for (self.kv.items, 0..) |*store, i| {
            if (store.plugin != plugin) continue;
            store.deinit(self.alloc);
            _ = self.kv.orderedRemove(i);
            return;
        }
    }

    // -- files ----------------------------------------------------------------

    /// Give one plugin one file, and tell it with a FILE_OPENED event. This is
    /// the ONLY way a plugin reaches the filesystem: there is no `file_open`
    /// import, so a path a mariner did not choose cannot be opened.
    ///
    /// The picker that would call this is chrome nobody has built. The API is
    /// here so that when it is built, nothing about the API has to change — and
    /// so a plugin like the GRIB reader can be driven from the harness today.
    pub fn grantFile(self: *Broker, plugin: u32, path: []const u8, write: bool) !i64 {
        const cwd = std.Io.Dir.cwd();
        const file = if (write)
            try cwd.createFile(io, path, .{})
        else
            try cwd.openFile(io, path, .{});
        errdefer file.close(io);
        const size: u64 = if (write) 0 else blk: {
            const st = file.stat(io) catch break :blk 0;
            break :blk st.size;
        };

        var id: i64 = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            var held: usize = 0;
            for (self.files.items) |f| {
                if (f.plugin == plugin) held += 1;
            }
            if (held >= files_per_plugin) return error.TooManyFiles;
            id = self.next_id;
            self.next_id += 1;
            try self.files.append(self.alloc, .{ .id = id, .plugin = plugin, .file = file, .write = write });
        }

        var json: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&json);
        w.writeAll("{\"name\":") catch {};
        writeJsonStringTo(&w, baseName(path));
        w.print(",\"size\":{d},\"mode\":\"{s}\"}}", .{ size, if (write) "write" else "read" }) catch {};
        self.push(plugin, Kind.file_opened, @bitCast(id), w.buffered());
        return id;
    }

    /// Read from a granted file at an absolute offset. Returns the bytes read,
    /// 0 at end of file, or -1.
    pub fn fileRead(self: *Broker, plugin: u32, handle: i64, offset: i64, out: []u8) i32 {
        if (offset < 0) return -1;
        const file = self.fileFor(plugin, handle) orelse return -1;
        const n = file.readPositionalAll(io, out, @intCast(offset)) catch return -1;
        return @intCast(n);
    }

    /// Append to a granted write file. Returns the bytes written, or -1.
    pub fn fileWrite(self: *Broker, plugin: u32, handle: i64, data: []const u8) i32 {
        self.mu.lock();
        var file: ?std.Io.File = null;
        var at: u64 = 0;
        var slot: ?*FileHandle = null;
        for (self.files.items) |*f| {
            if (f.id == handle and f.plugin == plugin and f.write) {
                file = f.file;
                at = f.written;
                slot = f;
            }
        }
        self.mu.unlock();
        const f = file orelse return -1;
        f.writePositionalAll(io, data, at) catch return -1;
        self.mu.lock();
        defer self.mu.unlock();
        // Re-found rather than kept: the list may have moved while the write
        // was in flight, and the handle may have been revoked under it.
        for (self.files.items) |*item| {
            if (item.id == handle and item.plugin == plugin) item.written = at + data.len;
        }
        return @intCast(data.len);
    }

    /// Give a granted file back. The host also closes every handle a plugin
    /// holds when it retires, so this is politeness rather than hygiene — but a
    /// plugin that opens a GRIB an hour needs it.
    pub fn fileClose(self: *Broker, plugin: u32, handle: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.files.items, 0..) |*f, i| {
            if (f.id != handle or f.plugin != plugin) continue;
            f.file.close(io);
            _ = self.files.orderedRemove(i);
            return;
        }
    }

    fn fileFor(self: *Broker, plugin: u32, handle: i64) ?std.Io.File {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.files.items) |f| {
            if (f.id == handle and f.plugin == plugin) return f.file;
        }
        return null;
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
        self.fanoutView(mono);
    }

    /// One bus frame, from `publisher`, to every enabled plugin whose
    /// `bus.read` grant lists the topic — the grant IS the subscription, so a
    /// revoked grant stops delivery by itself. The publisher never hears its
    /// own frame: the cheap loop guard. Returns subscribers reached; a full
    /// queue drops for that plugin alone, counted and said like any drop.
    ///
    /// The payload is the HTTP_RESPONSE envelope shape:
    /// `u32 json_len | {"topic":…,"from":…} | raw bytes`.
    pub fn busPublish(self: *Broker, publisher: *const budgets.Plugin, topic: []const u8, data: []const u8) i32 {
        // Room for a 128-byte manifest id escaped to \uXXXX at every byte.
        var head_buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(head_buf[4..]);
        w.writeAll("{\"topic\":") catch return -1;
        writeJsonStringTo(&w, topic);
        w.writeAll(",\"from\":") catch return -1;
        writeJsonStringTo(&w, publisher.id);
        w.writeAll("}") catch return -1;
        const json_len = w.buffered().len;
        std.mem.writeInt(u32, head_buf[0..4], @intCast(json_len), .little);
        const head = head_buf[0 .. 4 + json_len];

        self.mu.lock();
        defer self.mu.unlock();
        var reached: i32 = 0;
        for (self.plugins.items) |p| {
            if (!p.enabled or p == publisher) continue;
            if (!p.caps.contains(.bus_read)) continue;
            if (!caps.topicListed(p.sub_topics, topic)) continue;
            if (self.pushLockedJoined(p.index, Kind.bus_data, 0, head, data)) reached += 1;
        }
        return reached;
    }

    /// The chart camera's footprint, pushed by the render thread whenever a
    /// frame was drawn. Takes only `view_mu`, so a frame never queues behind
    /// the broker's own lock; the fanout tick decides whether anyone hears
    /// about it. Quantized to ~1 cm so GPS noise under follow-ship does not
    /// defeat the moved-view dedupe with last-ULP wiggle.
    pub fn setView(self: *Broker, v: ViewBox) void {
        const q = ViewBox{
            .min_lat = quantizeDeg(v.min_lat),
            .min_lon = quantizeDeg(v.min_lon),
            .max_lat = quantizeDeg(v.max_lat),
            .max_lon = quantizeDeg(v.max_lon),
        };
        self.view_mu.lock();
        defer self.view_mu.unlock();
        self.cur_view = q;
    }

    fn fanoutView(self: *Broker, mono: i64) void {
        if (mono - self.last_view_ms < view_min_interval_ms) return;
        // Advanced on every CHECK, not only on a send: gated by send alone an
        // idle broker would rerun the whole body on each 100 ms tick forever.
        // A push dropped on a full queue stays owed via view_pending and is
        // retried on the next 500 ms check.
        self.last_view_ms = mono;
        const view = blk: {
            self.view_mu.lock();
            defer self.view_mu.unlock();
            break :blk self.cur_view orelse return;
        };
        const moved = if (self.sent_view) |sent| !sent.eql(view) else true;

        // Serialized before `mu`: four floats, and the render thread may be
        // waiting on this lock.
        var buf: [192]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        writeViewChanged(&w, view) catch return;
        const json = w.buffered();

        self.mu.lock();
        defer self.mu.unlock();
        for (self.plugins.items) |p| {
            if (!p.enabled or !p.view_sub) continue;
            if (!moved and !p.view_pending) continue;
            // A push dropped on a full queue stays owed: a static view never
            // re-fires the moved check, so pending is the only retry.
            p.view_pending = !self.pushLocked(p.index, Kind.view_changed, 0, json);
        }
        self.sent_view = view;
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
            _ = self.pushLocked(p.index, Kind.ais_changed, 0, json.items);
        }
    }
};

/// One centimetre of latitude, the resolution the view dedupe compares at.
/// Public because the camera compares against it too: the two dedupes have to
/// round the same way or the cheaper one never hits.
pub fn quantizeDeg(v: f64) f64 {
    return @round(v * 1e7) / 1e7;
}

// ---- the clock ---------------------------------------------------------------

/// Wall clock, milliseconds since the epoch: what a `ts` on the wire means and
/// what the stores are stamped with. Zig 0.16 dropped std.time.milliTimestamp,
/// so this reads the platform clock directly.
///
/// src/clock.zig holds the same read for the core. The plugin host is rooted as
/// its own module by several test targets, so it cannot import a file above
/// src/plugin; merging the two costs a module dependency in every one of those
/// targets.
pub fn wallMs() i64 {
    if (comptime builtin.os.tag == .windows) {
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
    if (comptime builtin.os.tag == .windows) {
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
    if (comptime builtin.os.tag == .windows) {
        win.Sleep(ms);
    } else {
        const p = struct {
            extern "c" fn usleep(usec: u32) c_int;
        };
        _ = p.usleep(ms * 1000);
    }
}

const t = std.testing;
const Fixture = testing.Fixture;
const removeScratch = testing.removeScratch;
const scratchDir = testing.scratchDir;

test "dropping a plugin takes its queued events and its store contributions" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    // Three ids: the plugin's own and one for each of two connections. What it
    // published under any of them is its contribution, so all three go.
    var p = Plugin{
        .broker = &b,
        .index = 1,
        .id = "org.beetlebug.gone",
        .source = 1,
        .source_span = 3,
        .caps = Caps.initEmpty(),
    };
    try b.registerPlugin(&p);
    for ([_]SourceId{ 1, 2, 3 }) |sid| {
        try vessels.registerSource(sid);
        try vessels.set("navigation.position", "{\"lat\":1,\"lon\":2}", 0, sid);
        try ais.upsert(.{ .mmsi = 5 + sid, .lat = 1, .lon = 2, .ts_ms = 0 }, sid);
    }

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

test "a bus frame reaches exactly the plugins whose grant lists the topic" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    var pub_caps = Caps.initEmpty();
    pub_caps.insert(.bus_publish);
    // The publisher also READS the topic, to prove it never hears itself.
    pub_caps.insert(.bus_read);
    var read_caps = Caps.initEmpty();
    read_caps.insert(.bus_read);

    const topic_list = [_][]const u8{"nmea0183"};
    const other_list = [_][]const u8{"mob"};
    var publisher = Plugin{
        .broker = &b,
        .index = 0,
        .id = "org.beetlebug.nmea0183",
        .source = 1,
        .caps = pub_caps,
        .pub_topics = &topic_list,
        .sub_topics = &topic_list,
    };
    var reader = Plugin{
        .broker = &b,
        .index = 1,
        .id = "org.beetlebug.aiscast",
        .source = 2,
        .caps = read_caps,
        .sub_topics = &topic_list,
    };
    // Listed the topic but the grant was revoked: silence.
    var revoked = Plugin{
        .broker = &b,
        .index = 2,
        .id = "org.example.revoked",
        .source = 3,
        .caps = Caps.initEmpty(),
        .sub_topics = &topic_list,
    };
    // Holds bus.read for a different topic: silence.
    var elsewhere = Plugin{
        .broker = &b,
        .index = 3,
        .id = "org.example.elsewhere",
        .source = 4,
        .caps = read_caps,
        .sub_topics = &other_list,
    };
    try b.registerPlugin(&publisher);
    try b.registerPlugin(&reader);
    try b.registerPlugin(&revoked);
    try b.registerPlugin(&elsewhere);

    const line = "\\s:lk1*4F\\!AIVDM,1,1,,A,13HOI:0P0000VOHLCnHQKwvL05Ip,0*23";
    try t.expectEqual(@as(i32, 1), b.busPublish(&publisher, "nmea0183", line));
    try t.expectEqual(@as(usize, 0), b.queuedFor(0));
    try t.expectEqual(@as(usize, 1), b.queuedFor(1));
    try t.expectEqual(@as(usize, 0), b.queuedFor(2));
    try t.expectEqual(@as(usize, 0), b.queuedFor(3));

    // The one delivered frame carries the envelope and the bytes untouched.
    const e = b.popFor(1).?;
    defer b.freeEvent(e);
    try t.expectEqual(Kind.bus_data, e.kind);
    const json_len = std.mem.readInt(u32, e.payload[0..4], .little);
    try t.expectEqualStrings(
        "{\"topic\":\"nmea0183\",\"from\":\"org.beetlebug.nmea0183\"}",
        e.payload[4 .. 4 + json_len],
    );
    try t.expectEqualStrings(line, e.payload[4 + json_len ..]);
}

test "withdrawing a grant takes back every source the plugin owns" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    // One plugin with two connections, and a second plugin beside it whose
    // values are nobody else's to take back.
    var p = Plugin{
        .broker = &b,
        .index = 0,
        .id = "org.beetlebug.nmea0183",
        .source = 1,
        .source_span = 3,
        .caps = Caps.initEmpty(),
    };
    try b.registerPlugin(&p);
    var other = Plugin{ .broker = &b, .index = 1, .id = "org.beetlebug.signalk", .source = 4, .caps = Caps.initEmpty() };
    try b.registerPlugin(&other);
    for ([_]SourceId{ 1, 2, 3, 4 }) |sid| {
        try vessels.registerSource(sid);
        try vessels.set("navigation.position", "{\"lat\":1,\"lon\":2}", 0, sid);
        try ais.upsert(.{ .mmsi = 899000100 + sid, .lat = 1, .lon = 2, .ts_ms = 0 }, sid);
    }

    // The mariner switches the plugin's publishing grant off. Every id it
    // owns clears, or a revoked plugin leaves a connection's last fix on the
    // chart reading as live.
    b.withdraw(0, .vessel_publish, 100);
    try t.expectEqual(@as(SourceId, 4), vessels.readElected("navigation.position", 100).?.source);
    // The AIS grant was not the one revoked, so nothing there moved.
    try t.expectEqual(@as(usize, 4), ais.count());

    b.withdraw(0, .ais_publish, 100);
    try t.expectEqual(@as(usize, 1), ais.count());
    try t.expect(ais.get(899000104) != null);
}

test "dropping a plugin closes its UDP ports and its files" {
    const a = t.allocator;
    const dir = try scratchDir(a, "drop");
    defer a.free(dir);
    defer removeScratch(dir);
    const src = try std.fmt.allocPrint(a, "{s}/x.bin", .{dir});
    defer a.free(src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = "x" });

    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    var p = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.gone", .source = 1, .caps = Caps.initEmpty() };
    try b.registerPlugin(&p);

    try t.expect(b.openUdp(0, 0) > 0);
    const handle = try b.grantFile(0, src, false);
    b.dropPlugin(0, 0);

    b.mu.lock();
    const udps = b.udps.items.len;
    const files = b.files.items.len;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), udps);
    try t.expectEqual(@as(usize, 0), files);
    var buf: [4]u8 = undefined;
    try t.expectEqual(@as(i32, -1), b.fileRead(0, handle, 0, &buf));
}

test "each handle a plugin holds is a different number" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    // Connections, UDP ports, WebSockets and files come out of ONE counter, so
    // a plugin can never be handed the same number twice and a log line naming
    // a handle names one thing.
    const conn = b.openConn(0, "127.0.0.1", 10110);
    const udp = b.openUdp(0, 0);
    const ws = b.openWs(0, try a.dupe(u8, "ws://127.0.0.1:9/x"), try a.dupe(u8, ""));
    try t.expect(conn > 0 and udp > 0 and ws > 0);
    try t.expect(conn != udp and udp != ws and conn != ws);
}
