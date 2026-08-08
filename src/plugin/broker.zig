//! The host side of the plugin API: the twenty-nine native functions a plugin
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
const net = @import("net.zig");
const webio = @import("webio.zig");

const win = net.win;
const Addr = net.Addr;
const max_addrs = net.max_addrs;
const io = std.Io.Threaded.global_single_threaded.io();

pub const Lock = vstore.Lock;
pub const SourceId = vstore.SourceId;

// ---- event kinds (PROTOTYPE.md) --------------------------------------------

pub const Kind = struct {
    pub const config_changed: u32 = 1;
    pub const timer: u32 = 3;
    pub const tcp_connected: u32 = 4;
    pub const tcp_data: u32 = 5;
    pub const tcp_closed: u32 = 6;
    pub const udp_data: u32 = 7;
    pub const http_response: u32 = 8;
    pub const file_opened: u32 = 9;
    pub const store_changed: u32 = 10;
    pub const ais_changed: u32 = 11;
    pub const ws_open: u32 = 12;
    pub const ws_data: u32 = 13;
    pub const ws_closed: u32 = 14;
    pub const table_open: u32 = 15;
    pub const table_closed: u32 = 16;
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
    net_udp,
    net_http,
    net_ws,
    vessel_publish,
    ais_publish,
    vessel_read,
    ais_read,
    overlay_draw,
    alerts_raise,
    storage,
    files,

    pub fn name(self: Cap) []const u8 {
        return switch (self) {
            .net_tcp_client => "net.tcp-client",
            .net_udp => "net.udp",
            .net_http => "net.http",
            .net_ws => "net.ws",
            .vessel_publish => "vessel.publish",
            .ais_publish => "ais.publish",
            .vessel_read => "vessel.read",
            .ais_read => "ais.read",
            .overlay_draw => "overlay.draw",
            .alerts_raise => "alerts.raise",
            .storage => "storage",
            .files => "files",
        };
    }

    /// True when the capability is meaningless without a list of hosts. A
    /// manifest that asks for one of these as a bare name is refused: "may
    /// reach any server on the internet" is not a sentence a mariner can
    /// consent to, and an empty list is the same grant written shorter.
    pub fn needsHosts(self: Cap) bool {
        return self == .net_http or self == .net_ws;
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

/// Longest chrome status text kept per plugin. Anything longer is truncated
/// rather than allocated per update.
///
/// One line needs a fraction of this. The room is for a status that carries an
/// `items` array — one entry per row of a settings LIST, which is how the
/// nmea0183 plugin reports each connection separately. Eight connections of
/// `{"id":…,"state":…,"detail":…}` fit with the envelope.
pub const max_status = 768;
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
    /// The hostnames `http_fetch` may reach, from the manifest's `net.http`
    /// grant. Borrowed from the host's manifest, like `id`. Empty means the
    /// plugin may reach nothing, which is what an ungranted plugin has.
    http_hosts: []const []const u8 = &.{},
    /// The same for `ws_connect`, from the `net.ws` grant.
    ws_hosts: []const []const u8 = &.{},
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

// ---- tables (specs/plugins/table.md) ---------------------------------------

/// The budgets one table lives inside, the house pattern: a batch that would
/// take a table past any of them is refused whole and logged, never trimmed.
/// Sixteen columns is what a declaration may carry; 512 rows is what a shell
/// will show.
pub const max_table_columns = 16;
pub const max_table_rows = 512;

/// Tables one plugin may declare. One surface per declaration; a plugin with
/// five of them is building an application, not reporting data.
pub const max_tables = 4;

/// Longest key, heading and text cell kept. Longer refuses the declaration or
/// the batch rather than cutting a name in half.
pub const max_table_key = 48;
pub const max_table_label = 64;
pub const max_table_cell = 96;

/// The shortest gap between two ACCEPTED batches for one table. The spec's
/// rate is one update per status cadence, which is a second; the slack is for
/// a plugin timer landing a few milliseconds early.
pub const table_min_interval_ms: i64 = 900;

/// What a column carries, which is what makes shell-side sorting honest. The
/// plugin sends SI and the shell formats for the mariner's units, the reverse
/// of the pick report, because a table sorts and converts where a pick shows
/// one formatted line.
pub const ColumnType = enum {
    /// Metres.
    distance,
    /// Metres per second.
    speed,
    /// Degrees true.
    bearing,
    /// Seconds.
    duration,
    number,
    text,
    /// "alarm", "warning" or null. The shell colours the row by it.
    flag,

    pub fn name(self: ColumnType) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?ColumnType {
        inline for (comptime std.enums.values(ColumnType)) |c| {
            if (std.mem.eql(u8, text, @tagName(c))) return c;
        }
        return null;
    }

    /// True when the cell holds a number, which is what the shell sorts on.
    pub fn numeric(self: ColumnType) bool {
        return switch (self) {
            .distance, .speed, .bearing, .duration, .number => true,
            .text, .flag => false,
        };
    }
};

pub const Column = struct {
    key: []u8,
    label: []u8,
    type: ColumnType,
};

/// One cell. `none` is a cell the plugin sent as null, which the shell renders
/// as a dash: never heard and heard as zero are different readings and stay
/// different here.
pub const Cell = union(enum) {
    none,
    num: f64,
    text: []u8,
};

/// A flag cell's rank, for sorting a `flag` column: an alarm before a warning
/// before anything else, and a cell with nothing in it last of all.
fn flagRank(cell: Cell) u8 {
    return switch (cell) {
        .text => |s| if (std.mem.eql(u8, s, "alarm"))
            0
        else if (std.mem.eql(u8, s, "warning")) 1 else 2,
        else => 3,
    };
}

pub const Row = struct {
    id: []u8,
    /// THE PLUGIN OWNS THE ORDERING POLICY: the mariner's column sort applies
    /// within a band and never across one, so a plugin that puts its alarmed
    /// rows in band 0 keeps them at the top whatever column is sorted by.
    band: i32,
    /// One per declared column, in declaration order.
    cells: []Cell,
    /// Where the row is, when the declaration's `at` named two keys and the
    /// row carried both. A row with a position is locatable: the shell centres
    /// the chart on it and pins its bubble.
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Arrival order, which is the tiebreak that makes the sort total. Two
    /// rows equal on the sorted column keep the order they were first seen in,
    /// so a table does not shuffle under the mariner's hands.
    seq: u64 = 0,
};

/// One declared table and the rows a plugin has fed it.
pub const Table = struct {
    /// Registry index of the plugin that declared it.
    plugin: u32,
    /// Manifest id, borrowed from the plugin record like `Plugin.id`.
    plugin_id: []const u8,
    key: []u8,
    title: []u8,
    /// The menu the shell opens it from: "Vessels".
    menu: []u8,
    columns: []Column,
    /// The column the shell sorts by until the mariner says otherwise. Empty
    /// when the declaration named none.
    sort_key: []u8,
    sort_asc: bool = true,
    /// The two row keys carrying a position, empty when the table declares no
    /// `at`. They need not be declared columns.
    at_lat: []u8,
    at_lon: []u8,
    rows: std.ArrayList(Row) = .empty,
    /// True while a shell has the dialog on screen. The plugin is told, so it
    /// does not build rows nobody is looking at.
    open: bool = false,
    /// When the last batch was accepted, monotonic.
    last_ms: i64 = 0,
    /// Bumps on every accepted batch. A shell reloads when it changes and
    /// leaves the table alone when it does not.
    seq: u64 = 0,
    next_row_seq: u64 = 0,
    /// Batches refused over budget. The first one is logged and then one in a
    /// hundred, so a plugin sending too fast says so without filling the log.
    refused: u64 = 0,

    fn column(self: *const Table, key: []const u8) ?usize {
        for (self.columns, 0..) |c, i| {
            if (std.mem.eql(u8, c.key, key)) return i;
        }
        return null;
    }

    fn row(self: *Table, id: []const u8) ?*Row {
        for (self.rows.items) |*r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }
};

fn freeCells(alloc: std.mem.Allocator, cells: []Cell) void {
    for (cells) |c| switch (c) {
        .text => |s| alloc.free(s),
        else => {},
    };
    alloc.free(cells);
}

fn freeRow(alloc: std.mem.Allocator, r: Row) void {
    alloc.free(r.id);
    freeCells(alloc, r.cells);
}

fn freeTable(alloc: std.mem.Allocator, tab: *Table) void {
    for (tab.rows.items) |r| freeRow(alloc, r);
    tab.rows.deinit(alloc);
    for (tab.columns) |c| {
        alloc.free(c.key);
        alloc.free(c.label);
    }
    alloc.free(tab.columns);
    alloc.free(tab.key);
    alloc.free(tab.title);
    alloc.free(tab.menu);
    alloc.free(tab.sort_key);
    alloc.free(tab.at_lat);
    alloc.free(tab.at_lon);
}

/// The order a table is read in: band first and always ascending, then the
/// column the shell asked for, then the order the rows arrived in.
///
/// A cell with nothing in it sorts LAST in both directions. A dash is not a
/// small number, and the mariner sorting by CPA is asking which vessel is
/// closest, not which one has never said.
const Order = struct {
    rows: []const Row,
    col: ?usize,
    asc: bool,
    kind: ColumnType,

    fn less(self: Order, a: u32, b: u32) bool {
        const x = self.rows[a];
        const y = self.rows[b];
        if (x.band != y.band) return x.band < y.band;
        if (self.col) |c| {
            if (self.compare(x.cells[c], y.cells[c])) |ord| return switch (ord) {
                .lt => self.asc,
                .gt => !self.asc,
                .eq => x.seq < y.seq,
            };
            // One of them is empty and the other is not: empty last, whichever
            // way the column is sorted.
            return x.cells[c] != .none;
        }
        return x.seq < y.seq;
    }

    /// How two cells of this column compare, or null when exactly one of them
    /// is empty.
    fn compare(self: Order, a: Cell, b: Cell) ?std.math.Order {
        if (self.kind == .flag) {
            const ra = flagRank(a);
            const rb = flagRank(b);
            return std.math.order(ra, rb);
        }
        if (a == .none and b == .none) return .eq;
        if (a == .none or b == .none) return null;
        return switch (a) {
            .num => |x| std.math.order(x, if (b == .num) b.num else 0),
            .text => |x| std.ascii.orderIgnoreCase(x, if (b == .text) b.text else ""),
            .none => .eq,
        };
    }
};

/// One string field of a JSON object, or "" when it is missing or is not a
/// string. Declarations and batches are small documents written by a plugin,
/// so a wrong type reads as absent rather than failing the whole batch.
fn jsonText(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (o.get(key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

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

/// One bound UDP port. There is no connection and no state: a datagram in is
/// an event, a datagram out is one call.
const Udp = struct {
    id: i64,
    plugin: u32,
    fd: net.Socket,
    /// The port actually bound, which is not the one asked for when the plugin
    /// asked for 0.
    port: u16,
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

/// Read chunk for a plugin socket. One TCP_DATA event per read; the plugin
/// reassembles lines itself.
const read_chunk = 8192;

/// Longest datagram delivered as a UDP_DATA event.
///
/// One datagram is one event. A 9 KB datagram is dropped, not split.
pub const udp_max_datagram = 8192;

/// Native stack for a resolver thread. It runs getaddrinfo and connect and
/// nothing else — it never enters wasm — so it needs far less than the
/// 16 MiB Zig would otherwise reserve per attempt.
const resolver_stack_bytes: usize = 512 * 1024;

/// Native stack for a fetch or a WebSocket thread. Larger than a resolver's:
/// TLS puts four record buffers of about 16 KiB each on the heap but keeps
/// working state on the stack, and the certificate chain walk is recursive.
const worker_stack_bytes: usize = 1024 * 1024;

/// How long `stop` waits for the worker threads before it says so. They are
/// detached and call back into the broker, so the wait itself is not optional;
/// the line exists because a dead nameserver makes it a long one.
const worker_wait_warn_ms: u32 = 1000;

/// Fetches allowed at once across every plugin. Each holds a thread and a TLS
/// session of about 70 KiB, and a chartplotter downloading four things at once
/// is already doing more than one mariner asked for.
pub const http_max_inflight: u32 = 4;

/// Largest response body a fetch will hold. Over this the fetch fails and says
/// so: a plugin that wants a 200 MB GRIB asks for it in ranges.
pub const http_max_body: usize = 4 * 1024 * 1024;

/// Longest `http_fetch` or `ws_connect` request JSON accepted.
const request_json_max = 8 * 1024;

/// WebSocket frames `ws_send` will hold for one connection's own thread, and
/// the bytes they may total. Over either, `ws_send` refuses: a plugin writing
/// faster than the socket drains is told so rather than growing the heap.
const ws_max_queued_frames = 64;
const ws_max_queued_bytes = 256 * 1024;

/// A key, a value, the keys one plugin may hold and the bytes they may total.
pub const storage_max_key = 128;
pub const storage_max_value = 64 * 1024;
pub const storage_max_keys = 256;
pub const storage_max_total = 1024 * 1024;

/// Open files one plugin may hold, and the most one `file_read` returns.
pub const files_per_plugin = 8;
pub const file_read_max = 1024 * 1024;

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
            while (i < self.udps.items.len) {
                if (self.udps.items[i].plugin != index) {
                    i += 1;
                    continue;
                }
                const u = self.udps.orderedRemove(i);
                if (net.valid(u.fd)) net.close(u.fd);
            }
            i = 0;
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
        }
        if (id.len > 0) self.overlay.remove(id);
        self.vessels.clearSource(source, now_ms);
        _ = self.ais.clearSource(source) catch {};
    }

    // -- tables ---------------------------------------------------------------

    /// Take one table declaration from a plugin. A declaration under a key the
    /// plugin already declared replaces it and drops its rows, because the
    /// columns may have moved under them. 0 on success, -1 when the
    /// declaration is refused, and a refusal always says why.
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

    /// One declaration, allocated but not yet registered. Every refusal is
    /// logged here, so the caller only has to pass the error on.
    fn buildTable(self: *Broker, p: *Plugin, o: std.json.ObjectMap) !Table {
        const alloc = self.alloc;
        const key = jsonText(o, "key");
        if (key.len == 0 or key.len > max_table_key) {
            self.say(level_warn, p.id, "table: a declaration needs a key of 1 to {d} bytes", .{max_table_key});
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

    fn wakeIo(self: *Broker) void {
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
        self.mu.unlock();
        if (!net.valid(fd)) return -1;

        const wrote = net.udpSendTo(fd, data, &addrs[0]);
        if (wrote < 0) return -1;
        _ = n;
        return @intCast(wrote);
    }

    /// Close a UDP port the plugin opened. Reaped by the I/O thread, with no
    /// event: the plugin asked, so it already knows.
    pub fn closeUdp(self: *Broker, plugin: u32, id: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = 0;
        while (i < self.udps.items.len) : (i += 1) {
            const u = self.udps.items[i];
            if (u.id != id or u.plugin != plugin) continue;
            _ = self.udps.orderedRemove(i);
            if (net.valid(u.fd)) net.close(u.fd);
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

    fn idOf(self: *Broker, plugin: u32) []const u8 {
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
    fn retireFetch(self: *Broker, f: *Fetch) void {
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

    fn retireWs(self: *Broker, w: *Ws) void {
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
                self.pushLocked(plugin, Kind.timer, @bitCast(id), "");
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

/// Which socket a poll slot belongs to. A UDP port and a TCP connection share
/// one id space, so the flag says which list to look in rather than which id
/// range to compare against.
const Owner = struct { id: i64, udp: bool };

// ---- an HTTP fetch in flight --------------------------------------------------

/// What `http_fetch` was asked for, copied out of the plugin's memory: the
/// worker thread outlives the call that started it.
const FetchRequest = struct {
    method: []u8,
    url: []u8,
    range: []u8,
    headers: []webio.Header,

    fn deinit(self: *FetchRequest, alloc: std.mem.Allocator) void {
        alloc.free(self.method);
        alloc.free(self.url);
        alloc.free(self.range);
        for (self.headers) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        if (self.headers.len > 0) alloc.free(self.headers);
        self.* = undefined;
    }
};

/// One fetch, owned by its own thread and listed in the broker only so it can
/// be cancelled. `fd` and `cancelled` are guarded by the broker's `mu`.
const Fetch = struct {
    br: *Broker,
    id: i64,
    plugin: u32,
    req: FetchRequest,
    fd: net.Socket = net.invalid,
    cancelled: bool = false,

    /// Give up. Shutting the socket down — rather than closing it — makes the
    /// worker's blocking read return at once while the descriptor stays valid
    /// under the thread that owns it.
    fn cancelLocked(self: *Fetch) void {
        self.cancelled = true;
        if (net.valid(self.fd)) net.shutdownBoth(self.fd);
    }
};

/// Told by webio which socket the fetch is using, and told again with
/// `net.invalid` before that socket is closed. Both happen under `mu`, which is
/// what makes `cancelLocked` safe: it either sees a live descriptor and shuts
/// it down, or sees none and does nothing.
fn fetchSocket(ctx: ?*anyopaque, fd: net.Socket) void {
    const f: *Fetch = @ptrCast(@alignCast(ctx orelse return));
    f.br.mu.lock();
    defer f.br.mu.unlock();
    f.fd = fd;
}

fn fetchMain(f: *Fetch) void {
    const br = f.br;
    defer {
        br.retireFetch(f);
        _ = br.workers.fetchSub(1, .acq_rel);
    }
    var resp = webio.fetch(br.alloc, .{
        .method = f.req.method,
        .url = f.req.url,
        .headers = f.req.headers,
        .range = f.req.range,
        .max_body = http_max_body,
        .socket_ctx = f,
        .onSocket = fetchSocket,
    }) catch |e| {
        deliverFetchError(f, @errorName(e));
        return;
    };
    defer resp.deinit();
    deliverFetch(f, &resp);
}

/// True when the plugin that asked is gone, or the host is shutting down. A
/// cancelled fetch delivers nothing: the queue it would push into is being torn
/// down, and an event nobody will handle is worse than no event.
fn fetchCancelled(f: *Fetch) bool {
    f.br.mu.lock();
    defer f.br.mu.unlock();
    return f.cancelled;
}

/// `u32 json_len | status+headers JSON | raw body`. One buffer, because a
/// plugin needs both halves and the API carries one payload per event.
fn deliverFetch(f: *Fetch, resp: *webio.Response) void {
    if (fetchCancelled(f)) return;
    const alloc = f.br.alloc;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(alloc);
    json.print(alloc, "{{\"status\":{d},\"url\":", .{resp.status}) catch return;
    writeJsonString(&json, alloc, resp.url) catch return;
    json.appendSlice(alloc, ",\"headers\":{") catch return;
    for (resp.headers, 0..) |h, i| {
        if (i > 0) json.append(alloc, ',') catch return;
        writeJsonString(&json, alloc, h.name) catch return;
        json.append(alloc, ':') catch return;
        writeJsonString(&json, alloc, h.value) catch return;
    }
    json.appendSlice(alloc, "}}") catch return;

    var payload = alloc.alloc(u8, 4 + json.items.len + resp.body.len) catch return;
    defer alloc.free(payload);
    std.mem.writeInt(u32, payload[0..4], @intCast(json.items.len), .little);
    @memcpy(payload[4 .. 4 + json.items.len], json.items);
    @memcpy(payload[4 + json.items.len ..], resp.body);
    f.br.push(f.plugin, Kind.http_response, @bitCast(f.id), payload);
}

/// A fetch that never produced a response answers with status 0 and the reason.
/// The plugin still gets exactly one HTTP_RESPONSE per request id, so nothing
/// has to time a request out on its own.
fn deliverFetchError(f: *Fetch, reason: []const u8) void {
    f.br.say(level_warn, f.br.idOf(f.plugin), "http_fetch {s}: {s}", .{ f.req.url, reason });
    if (fetchCancelled(f)) return;
    var buf: [768]u8 = undefined;
    var w = std.Io.Writer.fixed(buf[4..]);
    w.writeAll("{\"status\":0,\"url\":") catch return;
    writeJsonStringTo(&w, f.req.url);
    w.writeAll(",\"headers\":{},\"error\":") catch return;
    writeJsonStringTo(&w, reason);
    w.writeAll("}") catch return;
    const json_len = w.buffered().len;
    std.mem.writeInt(u32, buf[0..4], @intCast(json_len), .little);
    f.br.push(f.plugin, Kind.http_response, @bitCast(f.id), buf[0 .. 4 + json_len]);
}

// ---- a WebSocket in flight ----------------------------------------------------

/// One WebSocket, owned by its own thread. Everything here except `br`, `id`,
/// `plugin`, `url` and `protocols` is guarded by the broker's `mu`.
///
/// The thread reads; `ws_send` only QUEUES. One thread produces every outgoing
/// frame, which is what keeps two TLS records from being encrypted at once, and
/// it means a plugin's `ws_send` returns in microseconds however slow the peer
/// is.
const Ws = struct {
    br: *Broker,
    id: i64,
    plugin: u32,
    url: []u8,
    protocols: []u8,
    fd: net.Socket = net.invalid,
    /// Wakes the connection's thread out of poll when there is something to
    /// write or the connection must close.
    wake: [2]net.Socket = .{ net.invalid, net.invalid },
    out: std.ArrayList([]u8) = .empty,
    out_bytes: usize = 0,
    closing: bool = false,
    cancelled: bool = false,

    fn cancelLocked(self: *Ws) void {
        self.cancelled = true;
        self.closing = true;
        self.wakeLocked();
        if (net.valid(self.fd)) net.shutdownBoth(self.fd);
    }

    fn wakeLocked(self: *Ws) void {
        if (!net.valid(self.wake[1])) return;
        const one = [_]u8{0};
        _ = net.send(self.wake[1], &one);
    }

    fn free(self: *Ws, alloc: std.mem.Allocator) void {
        for (self.out.items) |m| alloc.free(m);
        self.out.deinit(alloc);
        alloc.free(self.url);
        alloc.free(self.protocols);
        for (self.wake) |fd| {
            if (net.valid(fd)) net.close(fd);
        }
        alloc.destroy(self);
    }
};

/// How long the connection's thread waits in poll before looking at its own
/// flags again. A wake byte cuts it short, so this only bounds the case where
/// the wake pair could not be made.
const ws_poll_ms: i32 = 200;

fn wsMain(w: *Ws) void {
    const br = w.br;
    defer {
        br.retireWs(w);
        _ = br.workers.fetchSub(1, .acq_rel);
    }

    const url = webio.Url.parse(w.url) catch |e| {
        wsClosed(w, 0, @errorName(e));
        return;
    };
    const stream = webio.Stream.open(br.alloc, url) catch |e| {
        wsClosed(w, 0, @errorName(e));
        return;
    };
    {
        br.mu.lock();
        defer br.mu.unlock();
        w.fd = stream.fd;
    }
    defer {
        {
            br.mu.lock();
            defer br.mu.unlock();
            w.fd = net.invalid;
        }
        stream.close();
    }

    var hs: webio.Handshake = .{};
    webio.wsHandshake(stream, url, w.protocols, &hs) catch |e| {
        wsClosed(w, 0, @errorName(e));
        return;
    };
    {
        var open_json: [128]u8 = undefined;
        var ow = std.Io.Writer.fixed(&open_json);
        ow.writeAll("{\"protocol\":") catch {};
        writeJsonStringTo(&ow, hs.chosen());
        ow.writeAll("}") catch {};
        if (!wsCancelled(w)) br.push(w.plugin, Kind.ws_open, @bitCast(w.id), ow.buffered());
    }

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(br.alloc);
    var msg_op: webio.Opcode = .continuation;
    var code: u16 = 1006;
    var reason: []const u8 = "";
    var reason_buf: [125]u8 = undefined;

    loop: while (true) {
        if (!wsDrainOut(w, stream)) break;
        {
            br.mu.lock();
            const want_close = w.closing;
            const cancelled = w.cancelled;
            br.mu.unlock();
            if (cancelled) return;
            if (want_close) {
                webio.writeFrame(stream, .close, &[_]u8{ 0x03, 0xe8 }) catch {};
                code = 1000;
                break;
            }
        }

        // Decrypted bytes can be waiting inside the TLS reader while the socket
        // itself has nothing new, so ask the stream before asking the kernel.
        if (!stream.hasBuffered()) {
            var fds = [_]net.pollfd{
                .{ .fd = stream.fd, .events = net.POLL.IN, .revents = 0 },
                .{ .fd = w.wake[0], .events = net.POLL.IN, .revents = 0 },
            };
            const n = if (net.valid(w.wake[0])) net.poll(&fds, ws_poll_ms) else net.poll(fds[0..1], ws_poll_ms);
            if (n == 0) continue;
            if (net.valid(w.wake[0]) and fds[1].revents != 0) net.drainWake(w.wake[0]);
            if (fds[0].revents == 0) continue;
        }

        const r = stream.reader();
        const head = webio.readFrameHead(r) catch |e| {
            reason = @errorName(e);
            break;
        };
        switch (head.opcode) {
            .ping, .pong, .close => {
                const payload = r.take(@intCast(head.len)) catch break;
                switch (head.opcode) {
                    .ping => webio.writeFrame(stream, .pong, payload) catch break :loop,
                    .close => {
                        const c = webio.closePayload(payload);
                        code = c.code;
                        const n = @min(c.reason.len, reason_buf.len);
                        @memcpy(reason_buf[0..n], c.reason[0..n]);
                        reason = reason_buf[0..n];
                        webio.writeFrame(stream, .close, payload) catch {};
                        break :loop;
                    },
                    else => {},
                }
            },
            .text, .binary => {
                // A new data frame while a fragment is still open is the one
                // interleaving RFC 6455 forbids.
                if (msg.items.len > 0) {
                    reason = "ProtocolError";
                    break;
                }
                msg_op = head.opcode;
                webio.readPayloadInto(br.alloc, r, &msg, @intCast(head.len)) catch |e| {
                    reason = @errorName(e);
                    break;
                };
                if (head.fin) wsMessage(w, msg_op, msg.items) else continue;
                msg.clearRetainingCapacity();
            },
            .continuation => {
                webio.readPayloadInto(br.alloc, r, &msg, @intCast(head.len)) catch |e| {
                    reason = @errorName(e);
                    break;
                };
                if (msg.items.len > webio.max_message) {
                    reason = "MessageTooLarge";
                    break;
                }
                if (!head.fin) continue;
                wsMessage(w, msg_op, msg.items);
                msg.clearRetainingCapacity();
            },
            else => {
                reason = "ProtocolError";
                break;
            },
        }
    }
    wsClosed(w, code, reason);
}

/// Write whatever `ws_send` queued. False when the socket would not take it,
/// which ends the connection.
fn wsDrainOut(w: *Ws, stream: *webio.Stream) bool {
    while (true) {
        var next: ?[]u8 = null;
        {
            w.br.mu.lock();
            defer w.br.mu.unlock();
            if (w.out.items.len > 0) {
                const frame = w.out.orderedRemove(0);
                w.out_bytes -= frame.len;
                next = frame;
            }
        }
        const frame = next orelse return true;
        defer w.br.alloc.free(frame);
        webio.writeFrame(stream, .text, frame) catch return false;
    }
}

/// One reassembled message. A binary message is dropped with a line: the API
/// carries WS_DATA as text, and a plugin handed bytes it cannot tell from text
/// would parse them as JSON.
fn wsMessage(w: *Ws, opcode: webio.Opcode, payload: []const u8) void {
    if (opcode != .text) {
        w.br.say(level_warn, w.br.idOf(w.plugin), "ws: dropped a {d}-byte binary message", .{payload.len});
        return;
    }
    if (wsCancelled(w)) return;
    w.br.push(w.plugin, Kind.ws_data, @bitCast(w.id), payload);
}

fn wsCancelled(w: *Ws) bool {
    w.br.mu.lock();
    defer w.br.mu.unlock();
    return w.cancelled;
}

/// The one event every WebSocket ends with, whether it failed to connect, was
/// closed by the peer or was closed by the plugin. `code` 0 means it never
/// opened and `reason` names what stopped it.
fn wsClosed(w: *Ws, code: u16, reason: []const u8) void {
    if (wsCancelled(w)) return;
    var buf: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    out.print("{{\"code\":{d},\"reason\":", .{code}) catch return;
    writeJsonStringTo(&out, reason);
    out.writeAll("}") catch return;
    w.br.push(w.plugin, Kind.ws_closed, @bitCast(w.id), out.buffered());
}

// ---- per-plugin storage -------------------------------------------------------

const KvEntry = struct { key: []u8, value: []u8 };

/// One plugin's key-value store, in memory and in `<dir>/<id>.json`.
///
/// The file holds base64 values because a value is BYTES: a plugin may store a
/// packed struct or a compressed blob, and JSON has no way to say so. Keys stay
/// literal, which is why they are limited to printable ASCII.
const KvStore = struct {
    plugin: u32,
    id: []const u8,
    entries: std.ArrayList(KvEntry) = .empty,
    /// Key and value bytes held, against `storage_max_total`.
    bytes: usize = 0,
    loaded: bool = false,

    fn deinit(self: *KvStore, alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    fn get(self: *const KvStore, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    fn put(self: *KvStore, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        for (self.entries.items, 0..) |*e, i| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            // An empty value is a delete. It saves a `storage_del` import for
            // the one thing a plugin needs it for: forgetting a preference.
            if (value.len == 0) {
                self.bytes -= e.key.len + e.value.len;
                alloc.free(e.key);
                alloc.free(e.value);
                _ = self.entries.orderedRemove(i);
                return;
            }
            if (self.bytes - e.value.len + value.len > storage_max_total) return error.StorageFull;
            const owned = try alloc.dupe(u8, value);
            self.bytes = self.bytes - e.value.len + value.len;
            alloc.free(e.value);
            e.value = owned;
            return;
        }
        if (value.len == 0) return;
        if (self.entries.items.len >= storage_max_keys) return error.TooManyKeys;
        if (self.bytes + key.len + value.len > storage_max_total) return error.StorageFull;
        const k = try alloc.dupe(u8, key);
        errdefer alloc.free(k);
        const v = try alloc.dupe(u8, value);
        errdefer alloc.free(v);
        try self.entries.append(alloc, .{ .key = k, .value = v });
        self.bytes += key.len + value.len;
    }

    fn fileName(self: *const KvStore, buf: []u8) []const u8 {
        // A manifest id is reverse-DNS, but nothing checks that, so anything
        // that could leave the directory becomes an underscore.
        const n = @min(self.id.len, buf.len - 5);
        for (self.id[0..n], 0..) |c, i| buf[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => c,
            else => '_',
        };
        @memcpy(buf[n .. n + 5], ".json");
        return buf[0 .. n + 5];
    }

    fn load(self: *KvStore, alloc: std.mem.Allocator, dir: []const u8) !void {
        if (self.loaded) return;
        self.loaded = true;
        var name_buf: [192]u8 = undefined;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, self.fileName(&name_buf) });
        defer alloc.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(storage_max_total * 2)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer alloc.free(text);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.BadStorageFile;
        const list = parsed.value.object.get("kv") orelse return;
        if (list != .array) return error.BadStorageFile;
        const dec = std.base64.standard.Decoder;
        for (list.array.items) |item| {
            if (item != .object) continue;
            const key = switch (item.object.get("k") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const b64 = switch (item.object.get("b64") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const size = dec.calcSizeForSlice(b64) catch continue;
            if (size == 0 or size > storage_max_value) continue;
            const value = try alloc.alloc(u8, size);
            defer alloc.free(value);
            dec.decode(value, b64) catch continue;
            self.put(alloc, key, value) catch continue;
        }
    }

    fn save(self: *KvStore, alloc: std.mem.Allocator, dir: []const u8) !void {
        var name_buf: [192]u8 = undefined;
        const name = self.fileName(&name_buf);
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir) catch {};

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"v\":1,\"kv\":[");
        const enc = std.base64.standard.Encoder;
        var b64: [4 * ((storage_max_value + 2) / 3) + 4]u8 = undefined;
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"k\":");
            try writeJsonString(&out, alloc, e.key);
            try out.appendSlice(alloc, ",\"b64\":\"");
            try out.appendSlice(alloc, enc.encode(&b64, e.value));
            try out.appendSlice(alloc, "\"}");
        }
        try out.appendSlice(alloc, "]}");

        // Written beside the real file and renamed over it, so a power cut
        // during a save loses the change rather than the whole store.
        const tmp = try std.fmt.allocPrint(alloc, "{s}/{s}.tmp", .{ dir, name });
        defer alloc.free(tmp);
        const final = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        defer alloc.free(final);
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = out.items });
        try cwd.rename(tmp, cwd, final, io);
    }
};

/// `<data root>/lookout/plugins`, the platform's own place for data that must
/// survive. Deliberately NOT the cache root `lookout_set_cache_dir` names: a
/// cache is purgeable and a mariner's saved plugin state is not.
fn defaultStorageDir(alloc: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.c.getenv("APPDATA") orelse return null;
        const s = std.mem.span(appdata);
        if (s.len == 0) return null;
        return std.fmt.allocPrint(alloc, "{s}\\lookout\\plugins", .{s}) catch null;
    }
    if (std.c.getenv("XDG_DATA_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout/plugins", .{s}) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    if (home.len == 0) return null;
    return switch (builtin.os.tag) {
        .macos, .ios => std.fmt.allocPrint(alloc, "{s}/Library/Application Support/lookout/plugins", .{home}) catch null,
        else => std.fmt.allocPrint(alloc, "{s}/.local/share/lookout/plugins", .{home}) catch null,
    };
}

/// A storage key is printable ASCII with no quote and no backslash. It goes
/// into a JSON file as itself, and a key that could break that shape is a key
/// nobody could read back.
fn printableKey(key: []const u8) bool {
    for (key) |c| {
        if (c < 0x20 or c > 0x7e or c == '"' or c == '\\') return false;
    }
    return true;
}

/// One granted file. There is no `file_open` import: every one of these was
/// handed over by the host on a mariner's behalf.
const FileHandle = struct {
    id: i64,
    plugin: u32,
    file: std.Io.File,
    write: bool,
    /// Bytes written so far, so `file_write` appends without a seek.
    written: u64 = 0,
};

fn baseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[cut + 1 ..];
}

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

/// The same escaping, into a fixed writer. Overflow is dropped: every caller
/// here is building a one-line envelope into a stack buffer.
fn writeJsonStringTo(w: *std.Io.Writer, s: []const u8) void {
    w.writeByte('"') catch return;
    for (s) |c| switch (c) {
        '"' => w.writeAll("\\\"") catch return,
        '\\' => w.writeAll("\\\\") catch return,
        '\n' => w.writeAll("\\n") catch return,
        '\r' => w.writeAll("\\r") catch return,
        '\t' => w.writeAll("\\t") catch return,
        0...8, 11, 12, 14...31 => w.print("\\u{x:0>4}", .{c}) catch return,
        else => w.writeByte(c) catch return,
    };
    w.writeByte('"') catch return;
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

/// A table declaration, and the rows that feed it. Chrome, like
/// `chrome_status`: no capability gates either, because a table shows the
/// mariner what the plugin is already allowed to know.
fn hostTableDeclare(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    return p.broker.declareTable(p, bytes(ptr, len));
}

fn hostTableUpdate(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    return p.broker.updateTable(p, bytes(ptr, len));
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
    // Closing a socket the plugin already holds is harmless, but the contract
    // says every net import is checked per call, and a contract with one
    // exception is a contract nobody trusts.
    if (!allow(p, .net_tcp_client, "tcp_close")) return;
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

// -- UDP ----------------------------------------------------------------------

fn hostUdpOpen(env: wasm.c.wasm_exec_env_t, port: u32) callconv(.c) i64 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_udp, "udp_open")) return -1;
    if (port > 65535) return -1;
    return p.broker.openUdp(p.index, @intCast(port));
}

fn hostUdpSend(
    env: wasm.c.wasm_exec_env_t,
    id: i64,
    ptr: [*c]const u8,
    len: u32,
    host_ptr: [*c]const u8,
    host_len: u32,
    port: u32,
) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_udp, "udp_send")) return -1;
    if (port == 0 or port > 65535) return -1;
    return p.broker.sendUdp(p.index, id, bytes(ptr, len), bytes(host_ptr, host_len), @intCast(port));
}

fn hostUdpClose(env: wasm.c.wasm_exec_env_t, id: i64) callconv(.c) void {
    const p = caller(env) orelse return;
    if (!allow(p, .net_udp, "udp_close")) return;
    p.broker.closeUdp(p.index, id);
}

// -- the host allowlist ---------------------------------------------------------

/// The one host-list entry that is not a hostname. It grants THIS BOAT'S OWN
/// NETWORK and nothing beyond it.
///
/// A plugin whose server is a mariner's setting cannot have that address in its
/// manifest — a Signal K server lives at whatever the boat's network calls it.
/// Naming every private address instead would be a manifest nobody could read.
/// So `local` is the grant for "a server on the network this boat is on", which
/// is a sentence a mariner can weigh, and it still refuses the internet.
pub const local_token = "local";

/// Whether a URL's host is on the boat's own network. Judged from the TEXT, not
/// from what it resolves to: the check runs before any lookup, and a resolver
/// answer could change between the check and the connect.
///
/// It covers loopback, the three RFC 1918 ranges, RFC 3927 link-local, IPv6
/// loopback, RFC 4193 unique-local and IPv6 link-local, and the `.local` names
/// mDNS serves. A public name is not local however it resolves.
pub fn isLocalHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (host.len > 6 and std.ascii.endsWithIgnoreCase(host, ".local")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;

    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        // An IPv6 literal. fc00::/7 is unique-local, fe80::/10 link-local.
        var lower: [8]u8 = undefined;
        const n = @min(host.len, lower.len);
        _ = std.ascii.lowerString(lower[0..n], host[0..n]);
        const head = lower[0..n];
        if (std.mem.startsWith(u8, head, "fc") or std.mem.startsWith(u8, head, "fd")) return true;
        if (std.mem.startsWith(u8, head, "fe8") or std.mem.startsWith(u8, head, "fe9")) return true;
        if (std.mem.startsWith(u8, head, "fea") or std.mem.startsWith(u8, head, "feb")) return true;
        return false;
    }

    var parts: [4]u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |piece| {
        if (count == parts.len) return false;
        parts[count] = std.fmt.parseInt(u8, piece, 10) catch return false;
        count += 1;
    }
    if (count != 4) return false;
    return switch (parts[0]) {
        10, 127 => true,
        172 => parts[1] >= 16 and parts[1] <= 31,
        192 => parts[1] == 168,
        169 => parts[1] == 254,
        else => false,
    };
}

/// Whether this plugin's manifest named the host in `url`.
///
/// The grant is per HOST, not per capability: `net.http` on its own grants
/// nothing, and the allowlist is what the mariner consented to. Matching is
/// exact and case-insensitive. There are no wildcards: a plugin that needs two
/// servers names two servers, and nobody has to reason about what `*.noaa.gov`
/// covers at three in the morning.
fn allowUrl(p: *Plugin, cap: Cap, call: []const u8, url_text: []const u8) bool {
    if (!allow(p, cap, call)) return false;
    const url = webio.Url.parse(url_text) catch {
        p.broker.say(level_warn, p.id, "{s}: {s} is not a URL this host can fetch", .{ call, url_text });
        return false;
    };
    const hosts = if (cap == .net_http) p.http_hosts else p.ws_hosts;
    for (hosts) |h| {
        if (std.mem.eql(u8, h, local_token)) {
            if (isLocalHost(url.host)) return true;
            continue;
        }
        if (webio.sameHost(h, url.host)) return true;
    }
    p.denied += 1;
    p.broker.denied += 1;
    p.broker.say(level_err, p.id, "denied {s}: {s} is not in the manifest's {s} host list", .{ call, url.host, cap.name() });
    return false;
}

// -- HTTP -----------------------------------------------------------------------

/// `{"method":"GET","url":"https://…","headers":{"accept":"*/*"},"range":"bytes=0-1023"}`.
/// Only `url` is required.
fn hostHttpFetch(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i64 {
    const p = caller(env) orelse return -1;
    const text = bytes(ptr, len);
    if (text.len == 0 or text.len > request_json_max) return -1;
    const alloc = p.broker.alloc;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
        _ = allow(p, .net_http, "http_fetch");
        p.broker.say(level_warn, p.id, "http_fetch: malformed JSON", .{});
        return -1;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return -1;
    const o = parsed.value.object;
    const url = switch (o.get("url") orelse return -1) {
        .string => |s| s,
        else => return -1,
    };
    if (!allowUrl(p, .net_http, "http_fetch", url)) return -1;

    const method = switch (o.get("method") orelse std.json.Value{ .string = "GET" }) {
        .string => |s| s,
        else => "GET",
    };
    // GET and HEAD only. A plugin that can POST can exfiltrate, and nothing in
    // the marine use cases needs one.
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD")) {
        p.broker.say(level_warn, p.id, "http_fetch: method {s} is not GET or HEAD", .{method});
        return -1;
    }
    const range = switch (o.get("range") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };

    var req = FetchRequest{
        .method = alloc.dupe(u8, method) catch return -1,
        .url = undefined,
        .range = undefined,
        .headers = &.{},
    };
    req.url = alloc.dupe(u8, url) catch {
        alloc.free(req.method);
        return -1;
    };
    req.range = alloc.dupe(u8, range) catch {
        alloc.free(req.method);
        alloc.free(req.url);
        return -1;
    };
    if (o.get("headers")) |hv| {
        if (hv == .object) {
            var list: std.ArrayList(webio.Header) = .empty;
            var it = hv.object.iterator();
            while (it.next()) |kv| {
                const value = switch (kv.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                if (!safeHeader(kv.key_ptr.*) or !safeHeader(value)) continue;
                const name = alloc.dupe(u8, kv.key_ptr.*) catch break;
                const val = alloc.dupe(u8, value) catch {
                    alloc.free(name);
                    break;
                };
                list.append(alloc, .{ .name = name, .value = val }) catch {
                    alloc.free(name);
                    alloc.free(val);
                    break;
                };
            }
            req.headers = list.toOwnedSlice(alloc) catch &.{};
        }
    }
    return p.broker.startFetch(p.index, req);
}

/// A header name or value with a control byte in it could inject a second
/// header. Anything that is not printable ASCII is dropped, header and all.
fn safeHeader(text: []const u8) bool {
    if (text.len == 0 or text.len > 256) return false;
    for (text) |c| {
        if (c < 0x20 or c > 0x7e or c == ':') return false;
    }
    return true;
}

// -- WebSocket ------------------------------------------------------------------

/// `{"url":"wss://…","protocols":["v1.signalk"]}`. Only `url` is required.
fn hostWsConnect(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i64 {
    const p = caller(env) orelse return -1;
    const text = bytes(ptr, len);
    if (text.len == 0 or text.len > request_json_max) return -1;
    const alloc = p.broker.alloc;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
        _ = allow(p, .net_ws, "ws_connect");
        p.broker.say(level_warn, p.id, "ws_connect: malformed JSON", .{});
        return -1;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return -1;
    const url = switch (parsed.value.object.get("url") orelse return -1) {
        .string => |s| s,
        else => return -1,
    };
    if (!allowUrl(p, .net_ws, "ws_connect", url)) return -1;

    // The subprotocols go out as one comma-separated header, which is how RFC
    // 6455 writes a list.
    var protocols: std.ArrayList(u8) = .empty;
    defer protocols.deinit(alloc);
    if (parsed.value.object.get("protocols")) |pv| {
        if (pv == .array) {
            for (pv.array.items) |item| {
                const name = switch (item) {
                    .string => |s| s,
                    else => continue,
                };
                if (!safeHeader(name)) continue;
                if (protocols.items.len > 0) protocols.appendSlice(alloc, ", ") catch break;
                protocols.appendSlice(alloc, name) catch break;
            }
        }
    }
    const url_owned = alloc.dupe(u8, url) catch return -1;
    const proto_owned = alloc.dupe(u8, protocols.items) catch {
        alloc.free(url_owned);
        return -1;
    };
    return p.broker.openWs(p.index, url_owned, proto_owned);
}

fn hostWsSend(env: wasm.c.wasm_exec_env_t, id: i64, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_ws, "ws_send")) return -1;
    return p.broker.sendWs(p.index, id, bytes(ptr, len));
}

fn hostWsClose(env: wasm.c.wasm_exec_env_t, id: i64) callconv(.c) void {
    const p = caller(env) orelse return;
    if (!allow(p, .net_ws, "ws_close")) return;
    p.broker.closeWs(p.index, id);
}

// -- storage ---------------------------------------------------------------------

fn hostStorageGet(
    env: wasm.c.wasm_exec_env_t,
    kptr: [*c]const u8,
    klen: u32,
    vptr: [*c]u8,
    vcap: u32,
) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .storage, "storage_get")) return -1;
    const out: []u8 = if (vcap == 0 or vptr == null) &[_]u8{} else vptr[0..vcap];
    return p.broker.storageGet(p.index, bytes(kptr, klen), out);
}

fn hostStoragePut(
    env: wasm.c.wasm_exec_env_t,
    kptr: [*c]const u8,
    klen: u32,
    vptr: [*c]const u8,
    vlen: u32,
) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .storage, "storage_put")) return -1;
    return p.broker.storagePut(p.index, bytes(kptr, klen), bytes(vptr, vlen));
}

// -- files -------------------------------------------------------------------------

fn hostFileRead(
    env: wasm.c.wasm_exec_env_t,
    handle: i64,
    offset: i64,
    ptr: [*c]u8,
    cap: u32,
) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .files, "file_read")) return -1;
    if (cap == 0 or ptr == null) return 0;
    const want = @min(cap, file_read_max);
    return p.broker.fileRead(p.index, handle, offset, ptr[0..want]);
}

fn hostFileWrite(env: wasm.c.wasm_exec_env_t, handle: i64, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .files, "file_write")) return -1;
    return p.broker.fileWrite(p.index, handle, bytes(ptr, len));
}

fn hostFileClose(env: wasm.c.wasm_exec_env_t, handle: i64) callconv(.c) void {
    const p = caller(env) orelse return;
    if (!allow(p, .files, "file_close")) return;
    p.broker.fileClose(p.index, handle);
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
    .{ .name = "table_declare", .func = @ptrCast(&hostTableDeclare), .signature = "(*~)i" },
    .{ .name = "table_update", .func = @ptrCast(&hostTableUpdate), .signature = "(*~)i" },
    .{ .name = "alert", .func = @ptrCast(&hostAlert), .signature = "(*~)i" },
    .{ .name = "tcp_connect", .func = @ptrCast(&hostTcpConnect), .signature = "(*~i)I" },
    .{ .name = "tcp_send", .func = @ptrCast(&hostTcpSend), .signature = "(I*~)i" },
    .{ .name = "tcp_close", .func = @ptrCast(&hostTcpClose), .signature = "(I)" },
    .{ .name = "timer_set", .func = @ptrCast(&hostTimerSet), .signature = "(Ii)I" },
    .{ .name = "timer_cancel", .func = @ptrCast(&hostTimerCancel), .signature = "(I)" },
    .{ .name = "subscribe", .func = @ptrCast(&hostSubscribe), .signature = "(*~)i" },
    .{ .name = "ais_subscribe", .func = @ptrCast(&hostAisSubscribe), .signature = "()i" },
    .{ .name = "udp_open", .func = @ptrCast(&hostUdpOpen), .signature = "(i)I" },
    .{ .name = "udp_send", .func = @ptrCast(&hostUdpSend), .signature = "(I*~*~i)i" },
    .{ .name = "udp_close", .func = @ptrCast(&hostUdpClose), .signature = "(I)" },
    .{ .name = "http_fetch", .func = @ptrCast(&hostHttpFetch), .signature = "(*~)I" },
    .{ .name = "ws_connect", .func = @ptrCast(&hostWsConnect), .signature = "(*~)I" },
    .{ .name = "ws_send", .func = @ptrCast(&hostWsSend), .signature = "(I*~)i" },
    .{ .name = "ws_close", .func = @ptrCast(&hostWsClose), .signature = "(I)" },
    .{ .name = "storage_get", .func = @ptrCast(&hostStorageGet), .signature = "(*~*~)i" },
    .{ .name = "storage_put", .func = @ptrCast(&hostStoragePut), .signature = "(*~*~)i" },
    .{ .name = "file_read", .func = @ptrCast(&hostFileRead), .signature = "(II*~)i" },
    .{ .name = "file_write", .func = @ptrCast(&hostFileWrite), .signature = "(I*~)i" },
    .{ .name = "file_close", .func = @ptrCast(&hostFileClose), .signature = "(I)" },
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
    try t.expect(Cap.fromName("net.mqtt") == null);
    // Only the two that reach a named server take a host list.
    try t.expect(Cap.net_http.needsHosts());
    try t.expect(Cap.net_ws.needsHosts());
    try t.expect(!Cap.net_tcp_client.needsHosts());
    try t.expect(!Cap.storage.needsHosts());
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

// ---- tables ----------------------------------------------------------------

/// A broker with one plugin record, for the table tests. The record is the
/// host's in the real thing; here it is a local the fixture lends out.
const TableFixture = struct {
    vessels: *vstore.Store,
    ais: *ais_store.AisStore,
    broker: Broker,
    plugin: Plugin = undefined,

    fn init() !*TableFixture {
        const a = t.allocator;
        const self = try a.create(TableFixture);
        self.vessels = try a.create(vstore.Store);
        self.vessels.* = try vstore.Store.init(a);
        self.ais = try a.create(ais_store.AisStore);
        self.ais.* = ais_store.AisStore.init(a);
        self.broker = Broker.init(a, self.vessels, self.ais, .{});
        self.broker.setLog(null, silentLog);
        self.plugin = .{
            .broker = &self.broker,
            .index = 0,
            .id = "org.example.table",
            .source = 1,
            .caps = Caps.initEmpty(),
        };
        return self;
    }

    fn deinit(self: *TableFixture) void {
        const a = t.allocator;
        self.broker.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        a.destroy(self.ais);
        a.destroy(self.vessels);
        a.destroy(self);
    }

    fn declare(self: *TableFixture, json: []const u8) i32 {
        return self.broker.declareTable(&self.plugin, json);
    }

    fn update(self: *TableFixture, json: []const u8) i32 {
        return self.broker.updateTable(&self.plugin, json);
    }

    /// Let the next batch through. The cadence is a wall-clock rule and a test
    /// is not going to wait a second for it.
    fn rewindCadence(self: *TableFixture) void {
        self.broker.mu.lock();
        defer self.broker.mu.unlock();
        for (self.broker.tables.items) |*tab| tab.last_ms = 0;
    }

    fn rows(self: *TableFixture, sort_key: []const u8, ascending: bool, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        try t.expect(try self.broker.tableRowsJson("org.example.table", "targets", sort_key, ascending, out));
    }
};

/// The declaration the tests work against: one of every kind of column that
/// sorts differently, and a position.
const test_table_decl =
    "{\"key\":\"targets\",\"title\":\"AIS Targets\",\"menu\":\"Vessels\",\"columns\":[" ++
    "{\"key\":\"name\",\"label\":\"Vessel\",\"type\":\"text\"}," ++
    "{\"key\":\"cpa\",\"label\":\"CPA\",\"type\":\"distance\"}," ++
    "{\"key\":\"state\",\"label\":\"\",\"type\":\"flag\"}]," ++
    "\"sort\":{\"key\":\"cpa\",\"ascending\":true},\"at\":{\"lat\":\"lat\",\"lon\":\"lon\"}}";

/// The ids of the rows a query answers with, in order.
fn rowOrder(alloc: std.mem.Allocator, json: []const u8, out: *std.ArrayList([]const u8)) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    for (out.items) |s| alloc.free(s);
    out.clearRetainingCapacity();
    for (parsed.value.object.get("rows").?.array.items) |r| {
        // The slice is the parse's, so it is copied into the caller's list.
        try out.append(alloc, try alloc.dupe(u8, r.object.get("id").?.string));
    }
}

fn freeOrder(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

test "the mariner's sort applies within a band and never across one" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));

    // ALARM is the alarmed vessel: it is the farthest away and its name sorts
    // last, so every sort below would put it at the bottom if the band did not
    // hold it at the top.
    try t.expectEqual(@as(i32, 4), f.update(
        "{\"key\":\"targets\",\"upsert\":[" ++
            "{\"id\":\"1\",\"band\":1,\"name\":\"BRAVO\",\"cpa\":400,\"lat\":38.9,\"lon\":-76.4}," ++
            "{\"id\":\"2\",\"band\":1,\"name\":\"ALPHA\",\"cpa\":900}," ++
            "{\"id\":\"3\",\"band\":1,\"name\":\"CHARLIE\"}," ++
            "{\"id\":\"4\",\"band\":0,\"name\":\"ZULU\",\"cpa\":5000,\"state\":\"alarm\"}]}",
    ));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    var order: std.ArrayList([]const u8) = .empty;
    defer freeOrder(a, &order);

    // By CPA, the declared sort: the alarm first because of its band, then the
    // closest, and the vessel that has never reported one LAST, because a dash is not
    // a small number.
    try f.rows("cpa", true, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqual(@as(usize, 4), order.items.len);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("1", order.items[1]);
    try t.expectEqualStrings("2", order.items[2]);
    try t.expectEqualStrings("3", order.items[3]);

    // By name, ascending and descending: the order under the alarm turns over,
    // the alarm does not move.
    try f.rows("name", true, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("2", order.items[1]);
    try t.expectEqualStrings("1", order.items[2]);
    try t.expectEqualStrings("3", order.items[3]);

    try f.rows("name", false, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("3", order.items[1]);
    try t.expectEqualStrings("1", order.items[2]);
    try t.expectEqualStrings("2", order.items[3]);

    // Sorted by the flag column itself, the alarm is still one band up and the
    // rest keep the order they arrived in.
    try f.rows("state", false, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("1", order.items[1]);

    // An unknown sort key falls back to the declared one rather than to no
    // order at all.
    try f.rows("nonesuch", false, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("1", order.items[1]);
    try t.expectEqualStrings("2", order.items[2]);

    // The position rides with the row that has one, and only with that row.
    try t.expect(std.mem.indexOf(u8, json.items, "\"at\":[-76.4,38.9]") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"id\":\"2\",\"band\":1,\"cells\"") != null);
    // A cell the plugin did not send is null on the wire, and a dash on screen.
    try t.expect(std.mem.indexOf(u8, json.items, "[\"CHARLIE\",null,null]") != null);
}

test "rows equal on the sorted column keep the order they arrived in" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));
    try t.expectEqual(@as(i32, 3), f.update(
        "{\"key\":\"targets\",\"upsert\":[" ++
            "{\"id\":\"c\",\"band\":1,\"name\":\"SAME\",\"cpa\":100}," ++
            "{\"id\":\"a\",\"band\":1,\"name\":\"SAME\",\"cpa\":100}," ++
            "{\"id\":\"b\",\"band\":1,\"name\":\"SAME\",\"cpa\":100}]}",
    ));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    var order: std.ArrayList([]const u8) = .empty;
    defer freeOrder(a, &order);
    for ([_]bool{ true, false }) |asc| {
        try f.rows("cpa", asc, &json);
        try rowOrder(a, json.items, &order);
        try t.expectEqualStrings("c", order.items[0]);
        try t.expectEqualStrings("a", order.items[1]);
        try t.expectEqualStrings("b", order.items[2]);
    }
}

test "a batch over a budget is refused whole, and the table keeps what it had" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));

    // Exactly the budget goes in.
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(a);
    try batch.appendSlice(a, "{\"key\":\"targets\",\"upsert\":[");
    for (0..max_table_rows) |i| {
        if (i > 0) try batch.append(a, ',');
        try batch.print(a, "{{\"id\":\"{d}\",\"band\":1,\"cpa\":{d}}}", .{ i, i });
    }
    try batch.appendSlice(a, "]}");
    try t.expectEqual(@as(i32, max_table_rows), f.update(batch.items));

    // One more row is one row too many: the batch is refused whole.
    f.rewindCadence();
    try t.expectEqual(@as(i32, -1), f.update(
        "{\"key\":\"targets\",\"upsert\":[{\"id\":\"over\",\"band\":1,\"cpa\":1}]}",
    ));
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.rows("cpa", true, &json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"over\"") == null);

    // A batch that makes room for what it adds is taken.
    f.rewindCadence();
    try t.expectEqual(@as(i32, 2), f.update(
        "{\"key\":\"targets\",\"remove\":[\"0\"]," ++
            "\"upsert\":[{\"id\":\"over\",\"band\":1,\"cpa\":1}]}",
    ));
    try f.rows("cpa", true, &json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"over\"") != null);

    // And a batch inside the status cadence is refused whatever is in it.
    try t.expectEqual(@as(i32, -1), f.update(
        "{\"key\":\"targets\",\"upsert\":[{\"id\":\"over\",\"band\":1,\"cpa\":2}]}",
    ));

    // A batch for a table nobody declared is refused too.
    f.rewindCadence();
    try t.expectEqual(@as(i32, -1), f.update("{\"key\":\"nosuch\",\"upsert\":[]}"));
}

test "a declaration the shell could not render is refused with a reason" {
    const f = try TableFixture.init();
    defer f.deinit();

    // Seventeen columns, one over the budget.
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(t.allocator);
    try wide.appendSlice(t.allocator, "{\"key\":\"wide\",\"title\":\"W\",\"menu\":\"M\",\"columns\":[");
    for (0..max_table_columns + 1) |i| {
        if (i > 0) try wide.append(t.allocator, ',');
        try wide.print(t.allocator, "{{\"key\":\"c{d}\",\"label\":\"C\",\"type\":\"number\"}}", .{i});
    }
    try wide.appendSlice(t.allocator, "]}");
    try t.expectEqual(@as(i32, -1), f.declare(wide.items));

    // A column type the shell has no idea how to sort or show.
    try t.expectEqual(@as(i32, -1), f.declare(
        "{\"key\":\"t\",\"title\":\"T\",\"menu\":\"M\"," ++
            "\"columns\":[{\"key\":\"a\",\"label\":\"A\",\"type\":\"colour\"}]}",
    ));
    // A default sort naming a column that is not there.
    try t.expectEqual(@as(i32, -1), f.declare(
        "{\"key\":\"t\",\"title\":\"T\",\"menu\":\"M\"," ++
            "\"columns\":[{\"key\":\"a\",\"label\":\"A\",\"type\":\"number\"}]," ++
            "\"sort\":{\"key\":\"b\"}}",
    ));
    // Two columns under one key: a cell would land in both.
    try t.expectEqual(@as(i32, -1), f.declare(
        "{\"key\":\"t\",\"title\":\"T\",\"menu\":\"M\",\"columns\":[" ++
            "{\"key\":\"a\",\"label\":\"A\",\"type\":\"number\"}," ++
            "{\"key\":\"a\",\"label\":\"B\",\"type\":\"text\"}]}",
    ));
    try t.expectEqual(@as(i32, -1), f.declare("not json at all"));

    // None of them left anything behind.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);
    try f.broker.tablesJson(&json);
    try t.expectEqualStrings("{\"tables\":[]}", json.items);
}

test "a declaration reaches the shell, and closing the dialog empties it" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));
    try t.expectEqual(@as(i32, 1), f.update(
        "{\"key\":\"targets\",\"upsert\":[{\"id\":\"1\",\"band\":0,\"name\":\"ZULU\",\"state\":\"alarm\"}]}",
    ));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.broker.tablesJson(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"plugin\":\"org.example.table\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"menu\":\"Vessels\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"type\":\"distance\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"sort\":{\"key\":\"cpa\",\"ascending\":true}") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"at\":{\"lat\":\"lat\",\"lon\":\"lon\"}") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"rows\":1") != null);

    // Opening tells the plugin so, and so does closing.
    try t.expect(f.broker.setTableOpen("org.example.table", "targets", true));
    try t.expect(f.broker.tableOpen("org.example.table", "targets"));
    const opened = f.broker.popFor(0).?;
    defer f.broker.freeEvent(opened);
    try t.expectEqual(Kind.table_open, opened.kind);
    try t.expectEqualStrings("{\"key\":\"targets\"}", opened.payload);

    try t.expect(f.broker.setTableOpen("org.example.table", "targets", false));
    const closed = f.broker.popFor(0).?;
    defer f.broker.freeEvent(closed);
    try t.expectEqual(Kind.table_closed, closed.kind);
    // A table nobody is watching keeps no rows: the plugin describes the whole
    // set again the moment it is opened.
    json.clearRetainingCapacity();
    try f.broker.tablesJson(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"rows\":0") != null);
    // And a table the plugin never declared answers nothing at all.
    try t.expect(!f.broker.setTableOpen("org.example.table", "nosuch", true));
    json.clearRetainingCapacity();
    try t.expect(!try f.broker.tableRowsJson("org.example.other", "targets", "", true, &json));
}

test "a plugin that goes takes its tables with it" {
    const f = try TableFixture.init();
    defer f.deinit();
    try f.broker.registerPlugin(&f.plugin);
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));
    f.broker.dropPlugin(0, 1000);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);
    try f.broker.tablesJson(&json);
    try t.expectEqualStrings("{\"tables\":[]}", json.items);
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

// ---- the tests for the mediated I/O ------------------------------------------
//
// Every one of these runs a real server on loopback rather than a mock, so what
// is proved is the wire and not a stub: a datagram through the kernel, an HTTP
// head parsed off a socket, an RFC 6455 handshake with its accept hash, a file
// on disk. No test here reaches the network, and none needs python.

/// The four stores every broker test needs, in one place.
const Fixture = struct {
    vessels: vstore.Store,
    ais: ais_store.AisStore,
    br: Broker,

    fn init(alloc: std.mem.Allocator) !*Fixture {
        const self = try alloc.create(Fixture);
        self.* = .{
            .vessels = try vstore.Store.init(alloc),
            .ais = ais_store.AisStore.init(alloc),
            .br = undefined,
        };
        self.br = Broker.init(alloc, &self.vessels, &self.ais, .{});
        self.br.setLog(null, silentLog);
        return self;
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        self.br.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        alloc.destroy(self);
    }
};

/// The next event for one plugin, or an error. The caller frees the payload.
fn nextEvent(b: *Broker, plugin: u32, timeout_ms: u32) !Event {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (b.popFor(plugin)) |e| return e;
        sleepMs(5);
    }
    return error.NoEvent;
}

test "a bound UDP port turns each datagram into one event, and drops an oversize one" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();

    const id = b.openUdp(0, 0);
    try t.expect(id > 0);
    b.mu.lock();
    const port = b.udps.items[0].port;
    b.mu.unlock();
    try t.expect(port != 0);

    // A second port stands in for the instrument on the network.
    const sender = try net.udpBind(0);
    defer net.close(sender);
    var addrs: [max_addrs]Addr = undefined;
    _ = try net.resolveNumeric("127.0.0.1", port, &addrs);

    _ = net.udpSendTo(sender, "$GPRMC,123519,A\r\n", &addrs[0]);
    const e = try nextEvent(b, 0, 2_000);
    defer b.freeEvent(e);
    try t.expectEqual(Kind.udp_data, e.kind);
    try t.expectEqual(@as(u64, @bitCast(id)), e.handle);
    try t.expectEqualStrings("$GPRMC,123519,A\r\n", e.payload);

    // One datagram is one event. A datagram over the cap is dropped whole
    // rather than delivered truncated, which would look like a valid short
    // sentence to a parser.
    var big: [udp_max_datagram + 100]u8 = undefined;
    @memset(&big, 'x');
    _ = net.udpSendTo(sender, &big, &addrs[0]);
    _ = net.udpSendTo(sender, "after", &addrs[0]);
    const after = try nextEvent(b, 0, 2_000);
    defer b.freeEvent(after);
    try t.expectEqualStrings("after", after.payload);

    // A datagram exactly at the cap still goes through.
    _ = net.udpSendTo(sender, big[0..udp_max_datagram], &addrs[0]);
    const at_cap = try nextEvent(b, 0, 2_000);
    defer b.freeEvent(at_cap);
    try t.expectEqual(@as(usize, udp_max_datagram), at_cap.payload.len);
}

test "udp_send reaches a port, and refuses a name it would have to resolve" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();

    const id = b.openUdp(0, 0);
    try t.expect(id > 0);

    const peer = try net.udpBind(0);
    defer net.close(peer);
    const peer_port = net.udpPort(peer);

    try t.expectEqual(@as(i32, 5), b.sendUdp(0, id, "hello", "127.0.0.1", peer_port));
    var buf: [64]u8 = undefined;
    var got: isize = -1;
    var waited: u32 = 0;
    while (got <= 0 and waited < 2_000) : (waited += 5) {
        got = net.udpRecv(peer, &buf);
        if (got <= 0) sleepMs(5);
    }
    try t.expectEqualStrings("hello", buf[0..@intCast(got)]);

    // A name would need a resolver, and this runs on the plugin's own thread
    // under the watchdog's budget. Literals only.
    try t.expectEqual(@as(i32, -1), b.sendUdp(0, id, "hello", "localhost", peer_port));
    // Another plugin's port is not this plugin's to send from.
    try t.expectEqual(@as(i32, -1), b.sendUdp(1, id, "hello", "127.0.0.1", peer_port));
    // A datagram over the cap never leaves.
    var big: [udp_max_datagram + 1]u8 = undefined;
    try t.expectEqual(@as(i32, -1), b.sendUdp(0, id, &big, "127.0.0.1", peer_port));

    b.closeUdp(0, id);
    b.mu.lock();
    const left = b.udps.items.len;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), left);
}

// -- the scratch HTTP server ----------------------------------------------------

/// 36 bytes, so a range is easy to read by eye in a failure.
const test_body = "0123456789abcdefghijklmnopqrstuvwxyz";

/// A loopback HTTP/1.1 server for the fetch tests. One thread, one connection
/// at a time, a canned reply per path, and Range honoured on /plain.
const TestHttp = struct {
    alloc: std.mem.Allocator,
    fd: net.Socket,
    port: u16,
    th: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Requests answered, so a test can prove a redirect made two.
    served: std.atomic.Value(u32) = .init(0),

    fn open(alloc: std.mem.Allocator) !*TestHttp {
        const self = try alloc.create(TestHttp);
        var port: u16 = 0;
        const fd = try net.listen4(&port);
        net.setNonBlocking(fd);
        self.* = .{ .alloc = alloc, .fd = fd, .port = port };
        self.th = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }

    fn close(self: *TestHttp) void {
        self.stopping.store(true, .release);
        if (self.th) |th| th.join();
        net.close(self.fd);
        self.alloc.destroy(self);
    }

    fn run(self: *TestHttp) void {
        while (!self.stopping.load(.acquire)) {
            var fds = [_]net.pollfd{.{ .fd = self.fd, .events = net.POLL.IN, .revents = 0 }};
            if (net.poll(&fds, 20) == 0) continue;
            const peer = net.accept(self.fd) catch continue;
            defer net.close(peer);
            self.serve(peer);
        }
    }

    fn serve(self: *TestHttp, peer: net.Socket) void {
        // macOS hands an accepted socket the listener's O_NONBLOCK, so a read
        // here would fail with EAGAIN before the request had arrived and the
        // server would answer nothing at all. Blocking, with a deadline so a
        // broken test cannot hang the suite.
        net.setBlocking(peer);
        net.setTimeouts(peer, 3_000);
        var head: [4096]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, head[0..used], "\r\n\r\n") == null) {
            if (used == head.len) return;
            const n = net.recv(peer, head[used..]);
            if (n <= 0) return;
            used += @intCast(n);
        }
        _ = self.served.fetchAdd(1, .acq_rel);
        const text = head[0..used];
        const line_end = std.mem.indexOf(u8, text, "\r\n") orelse return;
        var it = std.mem.tokenizeScalar(u8, text[0..line_end], ' ');
        _ = it.next() orelse return; // method
        const target = it.next() orelse return;

        var out: [1024]u8 = undefined;
        if (std.mem.eql(u8, target, "/plain")) {
            if (rangeOf(text)) |r| {
                const from = @min(r[0], test_body.len);
                const to = @min(r[1] + 1, test_body.len);
                const slice = test_body[from..to];
                const msg = std.fmt.bufPrint(&out, "HTTP/1.1 206 Partial Content\r\ncontent-type: text/plain\r\n" ++
                    "content-range: bytes {d}-{d}/{d}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{
                    from, to - 1, test_body.len, slice.len, slice,
                }) catch return;
                _ = net.send(peer, msg);
                return;
            }
            const msg = std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n" ++
                "content-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ test_body.len, test_body }) catch return;
            _ = net.send(peer, msg);
        } else if (std.mem.eql(u8, target, "/chunked")) {
            _ = net.send(peer, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n" ++
                "a\r\n0123456789\r\n1a\r\nabcdefghijklmnopqrstuvwxyz\r\n0\r\n\r\n");
        } else if (std.mem.eql(u8, target, "/moved")) {
            _ = net.send(peer, "HTTP/1.1 302 Found\r\nlocation: /plain\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
        } else if (std.mem.eql(u8, target, "/away")) {
            _ = net.send(peer, "HTTP/1.1 302 Found\r\nlocation: http://elsewhere.invalid/x\r\n" ++
                "content-length: 0\r\nconnection: close\r\n\r\n");
        } else if (std.mem.eql(u8, target, "/huge")) {
            _ = net.send(peer, "HTTP/1.1 200 OK\r\ncontent-length: 99999999\r\nconnection: close\r\n\r\n");
        } else {
            _ = net.send(peer, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
        }
    }

    /// `bytes=a-b` out of a request head, or null.
    fn rangeOf(text: []const u8) ?[2]usize {
        const at = std.ascii.indexOfIgnoreCase(text, "range: bytes=") orelse return null;
        const rest = text[at + "range: bytes=".len ..];
        const end = std.mem.indexOf(u8, rest, "\r\n") orelse return null;
        const dash = std.mem.indexOfScalar(u8, rest[0..end], '-') orelse return null;
        const from = std.fmt.parseInt(usize, rest[0..dash], 10) catch return null;
        const to = std.fmt.parseInt(usize, rest[dash + 1 .. end], 10) catch return null;
        return .{ from, to };
    }
};

/// Start a fetch and wait for its HTTP_RESPONSE, split back into the JSON head
/// and the raw body the envelope carries.
const FetchResult = struct {
    event: Event,
    json: []const u8,
    body: []const u8,
};

fn fetchOnce(b: *Broker, url: []const u8, range: []const u8) !FetchResult {
    const alloc = b.alloc;
    const req = FetchRequest{
        .method = try alloc.dupe(u8, "GET"),
        .url = try alloc.dupe(u8, url),
        .range = try alloc.dupe(u8, range),
        .headers = &.{},
    };
    const id = b.startFetch(0, req);
    if (id <= 0) return error.FetchRefused;
    const e = try nextEvent(b, 0, 10_000);
    if (e.kind != Kind.http_response) {
        b.freeEvent(e);
        return error.WrongEvent;
    }
    const json_len = std.mem.readInt(u32, e.payload[0..4], .little);
    return .{
        .event = e,
        .json = e.payload[4 .. 4 + json_len],
        .body = e.payload[4 + json_len ..],
    };
}

test "a fetch answers with one enveloped event carrying status, headers and body" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const plain = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/plain", .{srv.port});

    const r = try fetchOnce(b, plain, "");
    defer b.freeEvent(r.event);
    try t.expect(std.mem.indexOf(u8, r.json, "\"status\":200") != null);
    try t.expect(std.mem.indexOf(u8, r.json, "\"content-type\":\"text/plain\"") != null);
    try t.expect(std.mem.indexOf(u8, r.json, plain) != null);
    try t.expectEqualStrings(test_body, r.body);
    // The envelope's length prefix is what splits the two halves, so the two
    // slices must account for the whole payload.
    try t.expectEqual(4 + r.json.len + r.body.len, r.event.payload.len);
}

test "a Range request comes back as 206 with only the bytes it asked for" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const plain = try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/plain", .{srv.port});

    const r = try fetchOnce(b, plain, "bytes=10-19");
    defer b.freeEvent(r.event);
    try t.expect(std.mem.indexOf(u8, r.json, "\"status\":206") != null);
    try t.expect(std.mem.indexOf(u8, r.json, "\"content-range\":\"bytes 10-19/36\"") != null);
    try t.expectEqualStrings("abcdefghij", r.body);
}

test "a chunked body reassembles and a same-host redirect is followed" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const r = try fetchOnce(b, try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/chunked", .{srv.port}), "");
    defer b.freeEvent(r.event);
    try t.expect(std.mem.indexOf(u8, r.json, "\"status\":200") != null);
    try t.expectEqualStrings(test_body, r.body);

    var url2: [64]u8 = undefined;
    const moved = try fetchOnce(b, try std.fmt.bufPrint(&url2, "http://127.0.0.1:{d}/moved", .{srv.port}), "");
    defer b.freeEvent(moved.event);
    try t.expect(std.mem.indexOf(u8, moved.json, "\"status\":200") != null);
    try t.expectEqualStrings(test_body, moved.body);
    // The redirect really was two requests, and the final URL is the one the
    // body came from rather than the one the plugin asked for.
    try t.expectEqual(@as(u32, 3), srv.served.load(.acquire));
    try t.expect(std.mem.indexOf(u8, moved.json, "/plain") != null);
}

test "a fetch that fails still answers exactly once, with status 0 and a reason" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestHttp.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    // A redirect that leaves the host would leave the manifest's allowlist with
    // it, so the fetch stops instead of following.
    const away = try fetchOnce(b, try std.fmt.bufPrint(&url, "http://127.0.0.1:{d}/away", .{srv.port}), "");
    defer b.freeEvent(away.event);
    try t.expect(std.mem.indexOf(u8, away.json, "\"status\":0") != null);
    try t.expect(std.mem.indexOf(u8, away.json, "RedirectOffHost") != null);
    try t.expectEqual(@as(usize, 0), away.body.len);

    // A body over the cap is refused by its content-length, before a byte of it
    // is read. Range is the documented way past this.
    var url2: [64]u8 = undefined;
    const huge = try fetchOnce(b, try std.fmt.bufPrint(&url2, "http://127.0.0.1:{d}/huge", .{srv.port}), "");
    defer b.freeEvent(huge.event);
    try t.expect(std.mem.indexOf(u8, huge.json, "BodyTooLarge") != null);

    // Nothing listening at all is the same shape: one event, status 0.
    const dead = try fetchOnce(b, "http://127.0.0.1:9/nothing", "");
    defer b.freeEvent(dead.event);
    try t.expect(std.mem.indexOf(u8, dead.json, "\"status\":0") != null);
}

// -- the scratch WebSocket server -------------------------------------------------

/// A loopback RFC 6455 server for the WebSocket tests. It performs the real
/// handshake — accept hash included — then runs one script: a fragmented text
/// message, a ping, an echo of whatever the client sends, and a close.
const TestWs = struct {
    alloc: std.mem.Allocator,
    fd: net.Socket,
    port: u16,
    th: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Set when the client answered the ping with a matching pong.
    got_pong: std.atomic.Value(bool) = .init(false),
    /// What the client sent, so a test can prove ws_send masked it correctly.
    echoed: [128]u8 = @splat(0),
    echoed_len: std.atomic.Value(usize) = .init(0),

    fn open(alloc: std.mem.Allocator) !*TestWs {
        const self = try alloc.create(TestWs);
        var port: u16 = 0;
        const fd = try net.listen4(&port);
        net.setNonBlocking(fd);
        self.* = .{ .alloc = alloc, .fd = fd, .port = port };
        self.th = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }

    fn close(self: *TestWs) void {
        self.stopping.store(true, .release);
        if (self.th) |th| th.join();
        net.close(self.fd);
        self.alloc.destroy(self);
    }

    fn run(self: *TestWs) void {
        while (!self.stopping.load(.acquire)) {
            var fds = [_]net.pollfd{.{ .fd = self.fd, .events = net.POLL.IN, .revents = 0 }};
            if (net.poll(&fds, 20) == 0) continue;
            const peer = net.accept(self.fd) catch continue;
            defer net.close(peer);
            self.serve(peer) catch {};
            return;
        }
    }

    fn serve(self: *TestWs, peer: net.Socket) !void {
        // Blocking for the handshake, for the reason TestHttp.serve gives.
        net.setBlocking(peer);
        net.setTimeouts(peer, 3_000);
        var head: [2048]u8 = undefined;
        var used: usize = 0;
        while (std.mem.indexOf(u8, head[0..used], "\r\n\r\n") == null) {
            if (used == head.len) return error.HeadTooLong;
            const n = net.recv(peer, head[used..]);
            if (n <= 0) return error.Closed;
            used += @intCast(n);
        }
        const text = head[0..used];
        const at = std.ascii.indexOfIgnoreCase(text, "sec-websocket-key:") orelse return error.NoKey;
        const rest = text[at + "sec-websocket-key:".len ..];
        const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.NoKey;
        const key = std.mem.trim(u8, rest[0..end], " \t");
        var accept: [28]u8 = undefined;
        webio.acceptFor(key, &accept);

        var reply: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&reply, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\nSec-WebSocket-Protocol: v1.signalk\r\n\r\n", .{accept});
        _ = net.send(peer, msg);

        // One message in two fragments: a text frame that is not final, then a
        // continuation that is. A client that treats each frame as a message
        // would report two halves of a JSON object.
        _ = net.send(peer, &[_]u8{ 0x01, 0x07 } ++ "{\"upda".* ++ [_]u8{'t'});
        _ = net.send(peer, &[_]u8{ 0x80, 0x08 } ++ "es\":[1]}".*);
        // A ping the client must answer with the same payload.
        _ = net.send(peer, &[_]u8{ 0x89, 0x04 } ++ "ping".*);

        // Non-blocking again for the script: the loop below polls for the
        // client's pong and its message rather than waiting for either.
        net.setNonBlocking(peer);
        // Read whatever the client sends: its pong, then its text message.
        var buf: [512]u8 = undefined;
        var deadline: u32 = 0;
        while (deadline < 4_000) : (deadline += 5) {
            const n = net.recv(peer, &buf);
            if (n <= 0) {
                if (n == 0) break;
                sleepMs(5);
                continue;
            }
            var i: usize = 0;
            while (i + 2 <= @as(usize, @intCast(n))) {
                const opcode = buf[i] & 0x0f;
                const masked = (buf[i + 1] & 0x80) != 0;
                const len: usize = buf[i + 1] & 0x7f;
                var at2 = i + 2;
                var mask: [4]u8 = .{ 0, 0, 0, 0 };
                if (masked) {
                    @memcpy(&mask, buf[at2 .. at2 + 4]);
                    at2 += 4;
                }
                var payload: [128]u8 = undefined;
                const keep = @min(len, payload.len);
                for (0..keep) |k| payload[k] = buf[at2 + k] ^ mask[k & 3];
                // A client frame is always masked. An unmasked one would be a
                // protocol error, and this asserts the client got it right.
                if (!masked) return error.UnmaskedClientFrame;
                if (opcode == 0xa and std.mem.eql(u8, payload[0..keep], "ping")) {
                    self.got_pong.store(true, .release);
                } else if (opcode == 0x1) {
                    @memcpy(self.echoed[0..keep], payload[0..keep]);
                    self.echoed_len.store(keep, .release);
                    // Echo it back so the plugin side sees a round trip.
                    var frame: [136]u8 = undefined;
                    frame[0] = 0x81;
                    frame[1] = @intCast(keep);
                    @memcpy(frame[2 .. 2 + keep], payload[0..keep]);
                    _ = net.send(peer, frame[0 .. 2 + keep]);
                } else if (opcode == 0x8) {
                    _ = net.send(peer, &[_]u8{ 0x88, 0x02, 0x03, 0xe8 });
                    return;
                }
                i = at2 + len;
            }
        }
    }
};

test "a WebSocket opens, reassembles a fragmented message, answers a ping and closes" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();
    const srv = try TestWs.open(a);
    defer srv.close();

    var url: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/signalk/v1/stream", .{srv.port});
    const id = b.openWs(0, try a.dupe(u8, text), try a.dupe(u8, "v1.signalk"));
    try t.expect(id > 0);

    const opened = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(opened);
    try t.expectEqual(Kind.ws_open, opened.kind);
    try t.expectEqual(@as(u64, @bitCast(id)), opened.handle);
    // The server chose a subprotocol and the host reports which.
    try t.expectEqualStrings("{\"protocol\":\"v1.signalk\"}", opened.payload);

    // Two frames, one message: the plugin never learns it was fragmented.
    const data = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(data);
    try t.expectEqual(Kind.ws_data, data.kind);
    try t.expectEqualStrings("{\"updates\":[1]}", data.payload);

    // The ping was answered by the connection's own thread, with no plugin
    // involved and no event raised.
    var waited: u32 = 0;
    while (!srv.got_pong.load(.acquire) and waited < 3_000) : (waited += 5) sleepMs(5);
    try t.expect(srv.got_pong.load(.acquire));

    // ws_send masks its frame, the server unmasks it and echoes it back.
    try t.expectEqual(@as(i32, 6), b.sendWs(0, id, "hello!"));
    const echo = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(echo);
    try t.expectEqual(Kind.ws_data, echo.kind);
    try t.expectEqualStrings("hello!", echo.payload);

    // The plugin closing gets the same WS_CLOSED any other ending gets.
    b.closeWs(0, id);
    const closed = try nextEvent(b, 0, 5_000);
    defer b.freeEvent(closed);
    try t.expectEqual(Kind.ws_closed, closed.kind);
    try t.expect(std.mem.indexOf(u8, closed.payload, "\"code\":1000") != null);

    // Another plugin's socket is not this plugin's to write to or close.
    try t.expectEqual(@as(i32, -1), b.sendWs(1, id, "no"));
}

test "a WebSocket that cannot connect answers WS_CLOSED with code 0 and a reason" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;
    try b.start();

    const id = b.openWs(0, try a.dupe(u8, "ws://127.0.0.1:9/none"), try a.dupe(u8, ""));
    try t.expect(id > 0);
    const closed = try nextEvent(b, 0, 10_000);
    defer b.freeEvent(closed);
    try t.expectEqual(Kind.ws_closed, closed.kind);
    try t.expect(std.mem.indexOf(u8, closed.payload, "\"code\":0") != null);
}

// -- storage -----------------------------------------------------------------------

/// A directory of this test's own under the system temporary directory, removed
/// on the way out.
fn scratchDir(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const base = if (std.c.getenv("TMPDIR")) |x| std.mem.span(x) else "/tmp";
    const trimmed = if (base.len > 1 and base[base.len - 1] == '/') base[0 .. base.len - 1] else base;
    const path = try std.fmt.allocPrint(alloc, "{s}/lookout-plugin-test-{s}-{d}", .{ trimmed, name, monoMs() });
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn removeScratch(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

test "a plugin's storage round-trips, caps what it holds and survives a restart" {
    const a = t.allocator;
    const dir = try scratchDir(a, "storage");
    defer a.free(dir);
    defer removeScratch(dir);

    var value: [64]u8 = undefined;
    {
        const fx = try Fixture.init(a);
        defer fx.deinit(a);
        const b = &fx.br;
        b.setStorageDir(dir);
        var p = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.grib", .source = 1, .caps = Caps.initEmpty() };
        try b.registerPlugin(&p);

        // Absent is -1, not zero: a key that was never written and a key
        // written empty must not read the same.
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "last_run", &value));
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "last_run", "1754400000123"));

        // The two-call pattern: ask with nothing, learn the size, ask again.
        try t.expectEqual(@as(i32, 13), b.storageGet(0, "last_run", &[_]u8{}));
        try t.expectEqual(@as(i32, 13), b.storageGet(0, "last_run", &value));
        try t.expectEqualStrings("1754400000123", value[0..13]);

        // Bytes, not text: a value with a zero and a quote in it comes back
        // exactly as it went in.
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "blob", "a\x00b\"c\\d"));
        try t.expectEqual(@as(i32, 7), b.storageGet(0, "blob", &value));
        try t.expectEqualStrings("a\x00b\"c\\d", value[0..7]);

        // An empty value is a delete.
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "blob", ""));
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "blob", &value));

        // The caps. A key too long, a value too long, and a key that would
        // break the JSON file it lands in.
        var long_key: [storage_max_key + 1]u8 = @splat('k');
        try t.expectEqual(@as(i32, -1), b.storagePut(0, &long_key, "x"));
        const big = try a.alloc(u8, storage_max_value + 1);
        defer a.free(big);
        @memset(big, 'v');
        try t.expectEqual(@as(i32, -1), b.storagePut(0, "big", big));
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "big", big[0..storage_max_value]));
        try t.expectEqual(@as(i32, -1), b.storagePut(0, "new\nline", "x"));

        // The total. A megabyte of 64 KiB values is sixteen of them, less the
        // keys and what is already stored, and the one that would go over is
        // refused rather than evicting anything.
        var key_buf: [16]u8 = undefined;
        var filled: usize = 1;
        while (filled < 64) : (filled += 1) {
            const key = try std.fmt.bufPrint(&key_buf, "fill{d}", .{filled});
            if (b.storagePut(0, key, big[0..storage_max_value]) != 0) break;
        }
        try t.expect(filled < 64);
        b.mu.lock();
        const held = b.kv.items[0].bytes;
        b.mu.unlock();
        try t.expect(held <= storage_max_total);
        try t.expect(held + storage_max_value > storage_max_total);
    }

    // A new broker, the same directory: what the plugin stored is still there.
    {
        const fx = try Fixture.init(a);
        defer fx.deinit(a);
        const b = &fx.br;
        b.setStorageDir(dir);
        var p = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.grib", .source = 1, .caps = Caps.initEmpty() };
        try b.registerPlugin(&p);
        try t.expectEqual(@as(i32, 13), b.storageGet(0, "last_run", &value));
        try t.expectEqualStrings("1754400000123", value[0..13]);
        // And the key that was deleted is still deleted.
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "blob", &value));
    }

    // Another plugin's store is another file: one plugin cannot read or
    // overwrite what another saved.
    {
        const fx = try Fixture.init(a);
        defer fx.deinit(a);
        const b = &fx.br;
        b.setStorageDir(dir);
        var other = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.other", .source = 1, .caps = Caps.initEmpty() };
        try b.registerPlugin(&other);
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "last_run", &value));
    }
}

// -- files ---------------------------------------------------------------------------

test "a granted file reads at an offset, a granted write file appends, and a close ends it" {
    const a = t.allocator;
    const dir = try scratchDir(a, "files");
    defer a.free(dir);
    defer removeScratch(dir);

    const src = try std.fmt.allocPrint(a, "{s}/gfs.grib2", .{dir});
    defer a.free(src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = test_body });

    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    const handle = try b.grantFile(0, src, false);
    try t.expect(handle > 0);
    // The grant arrives as an event, so a plugin learns about a file the same
    // way it learns about everything else.
    const opened = try nextEvent(b, 0, 1_000);
    defer b.freeEvent(opened);
    try t.expectEqual(Kind.file_opened, opened.kind);
    try t.expectEqual(@as(u64, @bitCast(handle)), opened.handle);
    try t.expectEqualStrings("{\"name\":\"gfs.grib2\",\"size\":36,\"mode\":\"read\"}", opened.payload);

    var buf: [16]u8 = undefined;
    try t.expectEqual(@as(i32, 10), b.fileRead(0, handle, 10, buf[0..10]));
    try t.expectEqualStrings("abcdefghij", buf[0..10]);
    // A read past the end is zero bytes, not an error: that is how a plugin
    // chunking a GRIB knows it is done.
    try t.expectEqual(@as(i32, 0), b.fileRead(0, handle, test_body.len, &buf));
    // Another plugin's handle, and a negative offset.
    try t.expectEqual(@as(i32, -1), b.fileRead(1, handle, 0, &buf));
    try t.expectEqual(@as(i32, -1), b.fileRead(0, handle, -1, &buf));

    const out = try std.fmt.allocPrint(a, "{s}/out.kap", .{dir});
    defer a.free(out);
    const wh = try b.grantFile(0, out, true);
    const wopened = try nextEvent(b, 0, 1_000);
    defer b.freeEvent(wopened);
    try t.expectEqualStrings("{\"name\":\"out.kap\",\"size\":0,\"mode\":\"write\"}", wopened.payload);
    try t.expectEqual(@as(i32, 5), b.fileWrite(0, wh, "hello"));
    try t.expectEqual(@as(i32, 6), b.fileWrite(0, wh, " there"));
    // A read handle is not a write handle.
    try t.expectEqual(@as(i32, -1), b.fileWrite(0, handle, "no"));
    b.fileClose(0, wh);
    try t.expectEqual(@as(i32, -1), b.fileWrite(0, wh, "gone"));

    var written: [32]u8 = undefined;
    const got = try std.Io.Dir.cwd().readFile(io, out, &written);
    try t.expectEqualStrings("hello there", got);

    // A plugin holds eight files at most.
    var opened_count: usize = 1;
    while (opened_count < 32) : (opened_count += 1) {
        _ = b.grantFile(0, src, false) catch break;
    }
    try t.expectEqual(files_per_plugin, opened_count);
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

// -- the grants ------------------------------------------------------------------------

test "every mediated call is refused without its capability, and named in the log" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    var p = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.greedy", .source = 1, .caps = Caps.initEmpty() };
    const gated = [_]Cap{ .net_udp, .net_http, .net_ws, .storage, .files };
    for (gated, 0..) |cap, i| {
        try t.expect(!allow(&p, cap, cap.name()));
        try t.expectEqual(@as(u32, @intCast(i + 1)), p.denied);
    }
    // The same call with the grant in place is allowed and counts nothing.
    p.caps.insert(.storage);
    try t.expect(allow(&p, .storage, "storage_get"));
    try t.expectEqual(@as(u32, gated.len), p.denied);
}

test "a URL outside the manifest's host list is refused before a socket opens" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    var caps = Caps.initEmpty();
    caps.insert(.net_http);
    caps.insert(.net_ws);
    var p = Plugin{
        .broker = b,
        .index = 0,
        .id = "org.beetlebug.grib",
        .source = 1,
        .caps = caps,
        .http_hosts = &.{"nomads.ncep.noaa.gov"},
        .ws_hosts = &.{"demo.signalk.org"},
    };

    try t.expect(allowUrl(&p, .net_http, "http_fetch", "https://nomads.ncep.noaa.gov/cgi-bin/x.pl?f=1"));
    // The match is on the host and ignores case, the port and the path.
    try t.expect(allowUrl(&p, .net_http, "http_fetch", "http://NOMADS.ncep.NOAA.gov:8080/other"));
    try t.expectEqual(@as(u32, 0), p.denied);

    // A neighbouring name, a subdomain and the other capability's host are all
    // outside the list: there are no wildcards and no shared list.
    try t.expect(!allowUrl(&p, .net_http, "http_fetch", "https://nomads.ncep.noaa.gov.evil.test/x"));
    try t.expect(!allowUrl(&p, .net_http, "http_fetch", "https://tiles.ncep.noaa.gov/x"));
    try t.expect(!allowUrl(&p, .net_http, "http_fetch", "https://demo.signalk.org/x"));
    try t.expect(!allowUrl(&p, .net_ws, "ws_connect", "wss://nomads.ncep.noaa.gov/x"));
    try t.expectEqual(@as(u32, 4), p.denied);

    // Something that is not a URL is refused too, and is not counted as a
    // grant violation: it is a plugin with a bug, not one exceeding its grant.
    try t.expect(!allowUrl(&p, .net_http, "http_fetch", "nomads.ncep.noaa.gov"));
    try t.expectEqual(@as(u32, 4), p.denied);
    try t.expect(!allowUrl(&p, .net_http, "http_fetch", "ftp://nomads.ncep.noaa.gov/x"));

    // A plugin with the capability and no hosts can reach nothing, which is
    // what an ungranted plugin looks like from here.
    var bare = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.bare", .source = 1, .caps = caps };
    try t.expect(!allowUrl(&bare, .net_http, "http_fetch", "https://nomads.ncep.noaa.gov/x"));
}

test "the fetch count is capped, and a refused fetch frees what it was given" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    // The count is set by hand rather than by racing four real fetches: a
    // connect to a closed port is refused in microseconds, so a timing version
    // of this test would sometimes find a slot free and prove nothing.
    b.mu.lock();
    b.fetching = http_max_inflight;
    b.mu.unlock();

    const req = FetchRequest{
        .method = try a.dupe(u8, "GET"),
        .url = try a.dupe(u8, "http://127.0.0.1:9/x"),
        .range = try a.dupe(u8, ""),
        .headers = &.{},
    };
    try t.expectEqual(@as(i64, -1), b.startFetch(0, req));
    // The refusal took the request with it: what the plugin handed over is
    // owned by the broker from the call on, and the testing allocator fails
    // this test if the refusal path forgot it.
    b.mu.lock();
    const listed = b.fetches.items.len;
    b.fetching = 0;
    b.mu.unlock();
    try t.expectEqual(@as(usize, 0), listed);
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

test "the local token grants this boat's network and not the internet" {
    // Loopback, the three private ranges, link-local and the mDNS names.
    for ([_][]const u8{
        "localhost",      "LocalHost",     "127.0.0.1",     "10.0.0.9",
        "10.255.255.254", "172.16.0.1",    "172.31.255.1",  "192.168.1.9",
        "169.254.3.4",    "signalk.local", "SignalK.Local", "::1",
        "fd00::1",        "fe80::1",
    }) |h| try t.expect(isLocalHost(h));

    // Everything else, including the addresses next to a private range and a
    // public name that could resolve into one.
    for ([_][]const u8{
        "nomads.ncep.noaa.gov",    "8.8.8.8",     "172.15.0.1", "172.32.0.1",
        "192.169.1.1",             "11.0.0.1",    "local",      "notlocal",
        "example.local.evil.test", "2001:db8::1", "",
    }) |h| try t.expect(!isLocalHost(h));
}

test "a local grant lets a mariner's own server through and stops a public one" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);

    var caps = Caps.initEmpty();
    caps.insert(.net_ws);
    var p = Plugin{
        .broker = &fx.br,
        .index = 0,
        .id = "org.beetlebug.signalk",
        .source = 1,
        .caps = caps,
        .ws_hosts = &.{local_token},
    };

    // The address a mariner types for the server on their own boat.
    try t.expect(allowUrl(&p, .net_ws, "ws_connect", "ws://10.0.0.9:8375/signalk/v1/stream"));
    try t.expect(allowUrl(&p, .net_ws, "ws_connect", "ws://signalk.local:3000/signalk/v1/stream"));
    try t.expectEqual(@as(u32, 0), p.denied);
    // A server somewhere else is still refused: `local` is not a wildcard.
    try t.expect(!allowUrl(&p, .net_ws, "ws_connect", "wss://demo.signalk.org/signalk/v1/stream"));
    try t.expectEqual(@as(u32, 1), p.denied);
}
