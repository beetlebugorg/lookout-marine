//! The plugin registry, instance lifecycle and event loop.
//!
//! WHAT THIS FILE DOES. It turns a directory of manifests and .wasm modules
//! into running plugins: read the manifest, instantiate the module through
//! `wasm.zig`, hand it `lk_start`, then deliver events from the broker's queue
//! one at a time until shutdown. It owns nothing about what an event MEANS —
//! that is broker.zig — and nothing about the runtime's C API — that is
//! wasm.zig.
//!
//! THE API root.zig DRIVES
//!
//!   var h = try Host.init(alloc, &broker, .{});   // once
//!   defer h.deinit();
//!   try h.loadDir("zig-out/plugins");             // manifests + modules
//!   try h.start();                                // dispatch thread
//!   ...
//!   h.stop();                                     // SHUTDOWN, best effort
//!
//! ONE DISPATCH THREAD PER PLUGIN, each draining that plugin's own FIFO in the
//! broker. PROTOTYPE.md requires one event at a time PER plugin, which this
//! still gives: a plugin is entered by exactly one thread, ever. What it adds
//! is TIME ISOLATION — a plugin that takes a second over an event, or never
//! returns at all, delays nobody but itself. The single shared thread the
//! prototype started with made every plugin as slow as the slowest one.
//!
//! THE WATCHDOG is the other half of that. A dispatch thread publishes the
//! monotonic time at which it entered the module; the broker's 100 ms tick
//! reads those stamps on the I/O thread and terminates any instance that has
//! been inside longer than `Options.event_budget_ms`. The terminated call
//! comes back as a trap, lands in the ordinary disable path, and the plugin's
//! thread exits. The I/O thread never joins or waits on a stuck thread — if it
//! did, one bad plugin would take the sockets and timers down with it.
//!
//! LIFETIMES WAMR IMPOSES. Two buffers must outlive an instance and neither is
//! copied by the runtime: the module BYTES (loaded in place and patched) and
//! the NativeSymbol array (broker.zig holds that one in a container-level var).
//! Each registry entry therefore owns its byte buffer until the instance is
//! gone. The registry itself must not move while the dispatch threads are
//! running — each holds a pointer into it — so loading is refused once `start`
//! has been called.
//!
//! A TRAPPED PLUGIN IS TAKEN OUT OF SERVICE FIRST. WAMR's exception text is
//! logged, the instance is never entered again, and everything the plugin
//! contributed — overlay objects, vessel paths, AIS targets, sockets, timers,
//! queued events — is dropped. A chartplotter that keeps drawing the last
//! position a crashed plugin published is worse than one that draws nothing.
//!
//! THEN IT IS RESTARTED, on `default_restart_backoff_ms`: after a second, then
//! five, then thirty, and then not again. A plugin that traps once has probably
//! met one malformed sentence, and the mariner's instruments should come back
//! without a relaunch; a plugin that traps every time is broken, and the status
//! line says it stopped rather than restarting it under the mariner for ever.
//! The restart runs on the plugin's OWN dispatch thread, which is the only
//! thread allowed inside that instance. It gets a new instance of the module it
//! already has, its settings and its connections as they stand now, and an
//! empty scene; it does not get its globals back, because the instance is new.
//! THE ALLOWANCE IS GIVEN BACK after `default_restart_clean_ms` of clean
//! running, so the three attempts are three attempts at one bout of trouble
//! rather than three for the life of the app.
//!
//! WHERE THE PARTS ARE. This file holds the registry, the `Host` itself and the
//! threads that run the plugins. `host/` holds the rest, each part with its own
//! tests.
//!
//!   manifest.zig       the manifest a plugin ships, and its parser
//!   install.zig        the package, the grants, the consent sentences
//!   settings_json.zig  the JSON the settings surface is written in
//!   testing.zig        the fixtures those parts share in their tests

const std = @import("std");
const builtin = @import("builtin");

pub const wasm = @import("wasm.zig");
pub const store = @import("store.zig");
pub const aisstore = @import("aisstore.zig");
pub const broker = @import("broker.zig");
pub const webio = @import("webio.zig");

const manifest_mod = @import("host/manifest.zig");
const install = @import("host/install.zig");
const settings_json = @import("host/settings_json.zig");
const testing = @import("host/testing.zig");

comptime {
    // A Zig test build collects a file's tests only when the file is analysed,
    // and reaching a type through a re-export does not analyse the file it came
    // from. These references do, so every part's tests run wherever this one's
    // do.
    _ = manifest_mod;
    _ = install;
    _ = settings_json;
}

const io = std.Io.Threaded.global_single_threaded.io();

/// The API version this host speaks. A module reporting anything else is not
/// loaded — the exports may have the same names and a different meaning.
pub const api_version: u32 = 1;

/// Largest plugin module accepted. The prototype's plugins are tens of KiB;
/// the cap is here so a stray file in the plugin directory cannot be read into
/// memory whole.
pub const max_module_bytes: usize = 8 * 1024 * 1024;
pub const max_manifest_bytes: usize = 64 * 1024;

/// Longest version string a manifest may carry. "2024.12.31-rc1" is 14 bytes.
pub const max_version_bytes: usize = 32;

pub const Error = error{
    BadManifest,
    ApiMismatch,
    StartRefused,
    /// `configSet` named an id no plugin here answers to.
    UnknownPlugin,
    /// The config JSON is not an object, or a field it names does not match
    /// the kind the schema declares.
    BadConfig,
    /// `grantFile` named a plugin whose manifest did not ask for `files`, or
    /// `grantSet` named a capability the manifest never asked for.
    NotGranted,
    /// Two manifests claim the file type the mariner opened. Neither gets the
    /// file: see `openFile`.
    FileTypeConflict,
    /// A .lkplug was refused. The sentence saying why — the one the shell
    /// shows — is in `installMessage`.
    PackageRefused,
    /// `uninstall` named a bundled or developer plugin. Only what install put
    /// on disk can be taken off it.
    NotInstalled,
    /// `grantSet` named a capability no manifest could declare.
    UnknownCapability,
    /// This platform has no per-user plugin directory and `Options.install_root`
    /// was not set (Android's files dir has no path in the environment).
    NoInstallRoot,
    OutOfMemory,
};

// ---- what the parts hold ----------------------------------------------------
//
// The plugin layer reaches all of this as `host.<name>`, whichever part of
// host/ it lives in.

pub const Tab = manifest_mod.Tab;
pub const Field = manifest_mod.Field;
pub const List = manifest_mod.List;
pub const Manifest = manifest_mod.Manifest;
pub const max_fields = manifest_mod.max_fields;
pub const max_text_bytes = manifest_mod.max_text_bytes;
pub const max_list_rows = manifest_mod.max_list_rows;
pub const max_row_id = manifest_mod.max_row_id;
pub const max_file_types = manifest_mod.max_file_types;
pub const max_file_type = manifest_mod.max_file_type;
pub const max_hosts = manifest_mod.max_hosts;
pub const max_list_text = manifest_mod.max_list_text;
pub const parseManifest = manifest_mod.parseManifest;
pub const fileExtension = manifest_mod.fileExtension;
const chart_extensions = manifest_mod.chart_extensions;
const jsonNumber = manifest_mod.jsonNumber;

pub const max_install_msg = install.max_install_msg;
pub const max_zip_name = install.max_zip_name;
pub const max_grants_bytes = install.max_grants_bytes;
pub const grants_file = install.grants_file;
pub const sentence_order = install.sentence_order;
pub const writeSentence = install.writeSentence;
pub const installRootAlloc = install.installRootAlloc;
pub const idSafe = install.idSafe;
pub const writeGrantsJson = install.writeGrantsJson;
pub const parseGrants = install.parseGrants;
pub const versionLess = install.versionLess;
const writeSentences = install.writeSentences;
const pkgBaseName = install.pkgBaseName;
const storageFileName = install.storageFileName;
const storageDirDefault = install.storageDirDefault;

const writeSettings = settings_json.writeSettings;
const normalizeRows = settings_json.normalizeRows;
const freeRows = settings_json.freeRows;
const writeFieldCore = settings_json.writeFieldCore;
const writeFieldJson = settings_json.writeFieldJson;
const writeJsonString = settings_json.writeJsonString;

/// How long a plugin may stay inside ONE module call before the watchdog
/// terminates it.
///
/// A second is enormous for an event handler — the prototype's four take
/// microseconds — and small enough that a mariner watching a stuck plugin
/// disappear never sees the chart stall. Precision is one tick of the broker's
/// 100 ms I/O loop, so the kill lands between budget and budget + 100 ms; the
/// number is a floor on patience, not a deadline anybody meets exactly.
///
/// One budget for every plugin. Per-plugin budgets out of the manifest, and
/// criticality tiers that would let a chart-drawing plugin die while the
/// autopilot's is given longer, are the obvious next thing and are not built.
pub const default_event_budget_ms: i64 = 1000;

/// How long the host waits before each attempt to bring a faulted plugin back,
/// and — by its length — how many attempts there are.
///
/// A second is long enough that the bad event is behind it and short enough
/// that a mariner watching the wind instrument go blank sees it come back
/// rather than reaching for the app switcher. The five and the thirty are for a
/// plugin whose trouble is not one sentence: a server answering nonsense, a
/// gateway sending a frame it cannot parse. After the third the host stops,
/// because a plugin that cannot survive three starts is not going to survive a
/// fourth, and a restart loop under way at sea is worse than a plugin that is
/// visibly off.
pub const default_restart_backoff_ms = [_]i64{ 1_000, 5_000, 30_000 };

/// How long a plugin has to run clean before its restart allowance is given
/// back whole.
///
/// WITHOUT THIS the allowance is spent for the life of the app. A plugin that
/// meets one malformed sentence every few hours would use its three attempts
/// somewhere off Solomons and be dark for the rest of the passage, having in
/// fact recovered from every one of them. The schedule is there to stop a
/// restart LOOP, and three faults hours apart are not a loop.
///
/// Five minutes, and the number is chosen from the schedule rather than from
/// the sea: the whole backoff spans thirty-six seconds, so five minutes is an
/// order of magnitude past the longest wait in it. A plugin that flaps on the
/// same repeated input never reaches it — it faults again inside a second, as
/// the ones this schedule exists for do — and a plugin that ran clean for five
/// minutes did not fail to start; it met something in the data.
///
/// The clock starts when `lk_start` returns cleanly, and it starts again at
/// every restart, so a restart that comes up and falls straight back over
/// counts as the failed attempt it is.
pub const default_restart_clean_ms: i64 = 5 * 60 * 1000;

/// Where a plugin came from:
///
///   - `bundled`: the set that travels inside the application, loaded from a
///     directory the shell owns (Resources/Plugins in the macOS app). These
///     are the core plugins (own ship, AIS, NMEA 0183, Signal K, laylines),
///     and their ids are the product's, not a third party's.
///   - `installed`: what the mariner installed from a .lkplug.
///   - `developer`: the LOOKOUT_PLUGINS override.
///
/// It decides three things. Whether Settings offers Uninstall (only
/// `installed`). Who wins an id collision, which is `precedence` below. And
/// whether an id may be installed at all, since `unpackToTemp` refuses a
/// package that claims a bundled id.
pub const Origin = enum {
    bundled,
    installed,
    developer,

    /// WHO WINS AN ID TWO DIRECTORIES BOTH OFFER. Highest precedence keeps the
    /// id, whatever order the directories were scanned in.
    ///
    ///   developer beats everything: a developer who points LOOKOUT_PLUGINS at
    ///   a build directory is saying "run this copy", and the whole point of
    ///   the override is that it overrides.
    ///
    ///   bundled beats installed: the core plugins are the product's, and a
    ///   stale copy of one left under the install root from an older release
    ///   must not shadow the one inside the application. `unpackToTemp` refuses
    ///   a package claiming a bundled id, so the only way to have both is a
    ///   leftover, and a leftover never wins.
    ///
    /// Equal precedence keeps the copy already loaded, which is what makes
    /// loading the same directory twice a no-op.
    ///
    /// This used to be first-loaded-wins, which gave the same answer only
    /// because the shell happened to scan developer, then bundled, then
    /// installed. It is a rule now, so a shell that scans them in another order
    /// — or loads the installed set late, the way `lookout_plugins_load_installed`
    /// does — still runs the copy the mariner would expect.
    pub fn precedence(self: Origin) u8 {
        return switch (self) {
            .developer => 2,
            .bundled => 1,
            .installed => 0,
        };
    }
};

/// One loaded plugin, and the thread that runs it.
///
/// Heap-allocated, one address for its whole life: the dispatch thread and
/// the watchdog hold the pointer while the registry list grows under them,
/// which is what lets a plugin install while the chart runs.
pub const Entry = struct {
    manifest: Manifest,
    /// WAMR loads the module in place and keeps referring to this buffer.
    bytes: []align(8) u8,
    module: wasm.Module,
    inst: wasm.Instance,
    /// Heap-allocated so its address, which every native reaches through
    /// `wasm.callerUserData`, survives the registry list growing.
    state: *broker.Plugin,
    /// The value in force for each field of `manifest.settings`, in the same
    /// order. Guarded by the host's `cfg_mu`: a shell writes these from its own
    /// thread while the plugin runs.
    values: []f64 = &.{},
    /// The rows in force for each list of `manifest.lists`, in the same order,
    /// each an owned JSON array. Empty rows are `[]`. Guarded by `cfg_mu` with
    /// `values`.
    rows: [][]u8 = &.{},
    /// Cleared when the plugin trapped, was terminated, or was shut down.
    /// Atomic: its own dispatch thread writes it, the watchdog on the I/O
    /// thread and the harness read it.
    live: std.atomic.Value(bool) = .init(true),
    /// This plugin's dispatch thread, and its private stop flag.
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Monotonic ms at which the dispatch thread entered the module, or 0 when
    /// it is not inside one. Written by the dispatch thread on both sides of
    /// every call, read by the watchdog.
    entered_ms: std.atomic.Value(i64) = .init(0),
    /// How long the plugin had been inside the module when the watchdog
    /// terminated it, or 0 if it never did. Doubles as the "the watchdog got
    /// here first" flag, claimed with a compare-and-swap so one overrun is
    /// terminated once.
    killed_ms: std.atomic.Value(i64) = .init(0),
    /// Set once everything the plugin contributed has been dropped, so the
    /// clean-up runs exactly once whichever path reaches it. Cleared again by a
    /// restart, which is a plugin coming back into service.
    retired: std.atomic.Value(bool) = .init(false),
    /// Restart attempts spent since this plugin last started clean, indexing
    /// `Options.restart_backoff_ms`. Only the plugin's own dispatch thread
    /// writes it, and only that thread and the harness read it.
    restarts: usize = 0,
    /// Monotonic ms at which the dispatch thread should try to bring this
    /// plugin back, or 0 when it is finished for good. Written by the thread
    /// that retired it, taken by the dispatch thread.
    restart_at: std.atomic.Value(i64) = .init(0),
    /// Monotonic ms at which this plugin last came up cleanly, or 0 while an
    /// attempt is in flight. `scheduleRestart` reads it to decide whether the
    /// plugin has earned its allowance back; see `default_restart_clean_ms`.
    clean_since_ms: std.atomic.Value(i64) = .init(0),
    /// Where this plugin came from; see `Origin`.
    origin: Origin = .bundled,
    /// The capabilities in force: the manifest's set minus what the mariner
    /// switched off in Settings. `state.caps` is always a copy of this.
    grants: broker.Caps = broker.Caps.initEmpty(),
    /// The directory this plugin was loaded from, owned. For an installed
    /// plugin that is its own directory under the install root — the one
    /// `uninstall` deletes; for a flat set it is the shared directory, which
    /// is only ever read.
    dir: []u8 = &.{},
    /// True once `uninstall` tore the instance down. The slot stays — indices
    /// tag queued events and must keep meaning — but everything heavy is
    /// freed, and every walk over the registry skips the tombstone.
    removed: bool = false,

    pub fn isLive(self: *const Entry) bool {
        return self.live.load(.acquire);
    }
};

pub const Options = struct {
    /// `LOOKOUT_NMEA=host:port`, passed to the nmea0183 plugin's config.
    nmea_host: []const u8 = "127.0.0.1",
    nmea_port: u16 = 10110,
    /// Instantiation limits, carrying the linear-memory budget: 64 MiB per
    /// plugin, past which `memory.grow` is refused and the plugin's own
    /// allocation fails. The plugin sees the error, keeps running, and the
    /// refusal is named on its status line.
    limits: wasm.Limits = .{ .max_memory_pages = broker.max_memory_pages },
    /// How long `stop` waits for SHUTDOWN to reach every plugin before the
    /// dispatch threads are torn down anyway. Best effort by contract: a plugin
    /// stuck in a loop must not stop the app from closing.
    shutdown_ms: u32 = 500,
    /// The watchdog's budget for one module call. See
    /// `default_event_budget_ms`.
    event_budget_ms: i64 = default_event_budget_ms,
    /// The wait before each attempt to bring a faulted plugin back, and how
    /// many attempts there are. See `default_restart_backoff_ms`. An empty
    /// schedule never restarts anything, which is what the host did before
    /// there was a schedule.
    restart_backoff_ms: []const i64 = &default_restart_backoff_ms,
    /// How long a plugin must run clean before the attempts it spent are given
    /// back. See `default_restart_clean_ms`. Zero never gives them back, which
    /// is what the host did before the counter decayed.
    restart_clean_ms: i64 = default_restart_clean_ms,
    /// Where installed plugins live, overriding the platform's own place
    /// (install.md's table). Tests point it at scratch; a platform with no
    /// path in the environment (Android) must set it.
    install_root: []const u8 = "",
};

/// Longest disable reason kept. It has to fit inside the JSON status line the
/// host writes, which `broker.max_status` bounds.
const max_reason: usize = broker.max_status - 40;

/// How long `stop` lets an in-flight call finish after the threads have been
/// told to stop, before it terminates the instance so the join cannot hang.
/// Short: by this point the plugin has already had `shutdown_ms` to drain.
const shutdown_grace_ms: u32 = 100;

/// Native stack for a dispatch thread, one per plugin. Ample for the fast
/// interpreter plus the JSON the natives parse, and small enough to be cheap
/// per plugin.
///
/// It was once forced: with hardware bound checking on, WAMR's per-thread
/// setup mprotects the guard page below the thread's stack, and on macOS that
/// mprotect fails for stacks of 8 MiB and up — including Zig's 16 MiB default,
/// which made every call from this thread trap with "thread signal env not
/// inited". scripts/build-wamr.sh now builds with WAMR_DISABLE_HW_BOUND_CHECK,
/// so any stack size works; this one is kept because it is a good size, not
/// because it has to be.
const dispatch_stack_bytes: usize = 2 * 1024 * 1024;

/// WAMR keeps ONE runtime per process, and the native table is registered
/// against it. Counted so two Lookout handles in one process (the harness
/// opening a second chart, a test) do not tear down each other's runtime.
var runtime_refs: usize = 0;
var runtime_mu: store.Lock = .{};

fn runtimeAcquire() !void {
    runtime_mu.lock();
    defer runtime_mu.unlock();
    if (runtime_refs == 0) {
        try wasm.initRuntime();
        errdefer wasm.deinitRuntime();
        try broker.registerNatives();
        wasm.stdio_sink = stdioToLog;
    }
    runtime_refs += 1;
}

/// A plugin's WASI stdout and stderr, as log lines under that plugin's id.
///
/// A Go or Rust runtime prints to stdout before any plugin code runs — a panic,
/// a runtime warning — and those lines are the only sign of what went wrong.
/// `user_data` is the broker's per-plugin state, which is what lets the line
/// carry the plugin's name instead of arriving anonymously on the host's own
/// stderr. stdout goes out at info and stderr at warn: a language runtime uses
/// stderr for what it wants somebody to read.
///
/// A println costs the same log allowance as a `log` call: a plugin cannot get
/// around the budget by writing to stdout instead.
fn stdioToLog(user_data: ?*anyopaque, stream: wasm.Stream, line: []const u8) void {
    const p: *broker.Plugin = @ptrCast(@alignCast(user_data orelse return));
    if (!p.chargeLog()) return;
    p.broker.say(if (stream == .err) broker.level_warn else broker.level_info, p.id, "{s}", .{line});
}

fn runtimeRelease() void {
    runtime_mu.lock();
    defer runtime_mu.unlock();
    if (runtime_refs == 0) return;
    runtime_refs -= 1;
    if (runtime_refs != 0) return;
    wasm.stdio_sink = null;
    broker.unregisterNatives();
    wasm.deinitRuntime();
    // Process-wide, like the runtime: the last plugin layer out gives the root
    // certificates back.
    webio.deinitCaBundle();
}

pub const Host = struct {
    alloc: std.mem.Allocator,
    br: *broker.Broker,
    opts: Options,
    /// The registry. Pointers, not values: an entry's address must survive
    /// the list growing while dispatch threads and the watchdog hold it.
    entries: std.ArrayList(*Entry) = .empty,
    /// Guards the LIST itself — append on install, the tombstone flip on
    /// uninstall — against the watchdog iterating it on the I/O thread.
    /// Everything else that walks the registry runs on the shell's API
    /// thread, which the C ABI already serializes.
    reg_mu: store.Lock = .{},
    /// True between `start` and `stop`, while the dispatch threads exist.
    started: bool = false,
    /// The sentence the last refused install left behind, for the shell to
    /// show. NUL-terminated so the C ABI can hand it out borrowed.
    install_msg: [max_install_msg:0]u8 = @splat(0),
    install_msg_len: usize = 0,
    /// The install root in force, resolved once from `opts.install_root` or
    /// the platform default. Null until something needed it.
    root_cache: ?[]u8 = null,
    /// True between the first successful load and deinit.
    runtime_held: bool = false,
    /// Source ids are handed out in load order, which the vessel store reads
    /// as priority order. 1-based: 0 is the host's own reserved id.
    next_source: store.SourceId = 1,
    /// Guards every entry's `values`. A settings change comes from the shell's
    /// thread; the config JSON it produces is built under this lock and handed
    /// to the broker as a plain payload.
    cfg_mu: store.Lock = .{},

    pub fn init(alloc: std.mem.Allocator, br: *broker.Broker, opts: Options) Host {
        return .{ .alloc = alloc, .br = br, .opts = opts };
    }

    /// Stops everything and releases every instance, module and buffer. The
    /// broker is not owned here and is not stopped.
    pub fn deinit(self: *Host) void {
        self.stop();
        // The watchdog holds this host's address and runs on the broker's I/O
        // thread. `stop` joined that thread; clearing the hook keeps a broker
        // restarted without a host from reaching freed entries.
        self.br.setWatchdog(null, null);
        for (self.entries.items) |e| {
            // An uninstalled entry already gave its instance, module and
            // bytes back; the rest is freed here like everyone else's.
            if (!e.removed) {
                e.inst.deinit();
                e.module.deinit();
                self.alloc.free(e.bytes);
            }
            if (e.values.len > 0) self.alloc.free(e.values);
            freeRows(self.alloc, e.rows, e.rows.len);
            if (e.dir.len > 0) self.alloc.free(e.dir);
            e.manifest.deinit(self.alloc);
            self.alloc.destroy(e.state);
            self.alloc.destroy(e);
        }
        self.entries.deinit(self.alloc);
        if (self.root_cache) |r| self.alloc.free(r);
        if (self.runtime_held) {
            runtimeRelease();
            self.runtime_held = false;
        }
        self.* = undefined;
    }

    pub fn count(self: *const Host) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (!e.removed) n += 1;
        }
        return n;
    }

    /// The plugin state by manifest id, for the harness and the tests.
    pub fn find(self: *Host, id: []const u8) ?*broker.Plugin {
        const e = self.entryFor(id) orelse return null;
        return e.state;
    }

    /// How many restart attempts this plugin has spent since it last ran
    /// clean, for the tests. `restart_clean_ms` of clean running puts it back
    /// to zero; see `decayRestarts`.
    pub fn restartsFor(self: *Host, id: []const u8) ?usize {
        const e = self.entryFor(id) orelse return null;
        return e.restarts;
    }

    /// Move the clock that decides whether a plugin has earned its restart
    /// attempts back, for the tests. Backdating it is how a test proves the
    /// rule in milliseconds instead of sitting out five real minutes on a
    /// machine whose load it does not control.
    pub fn setCleanSince(self: *Host, id: []const u8, mono_ms: i64) void {
        const e = self.entryFor(id) orelse return;
        e.clean_since_ms.store(mono_ms, .release);
    }

    // -- loading -------------------------------------------------------------

    /// Load every plugin in `dir`, in two layouts at once:
    ///
    ///   - flat: `<id>.manifest.json` + `<id>.wasm`, which is what `zig build
    ///     plugins` installs and what LOOKOUT_PLUGINS points at;
    ///   - installed: `<id>/manifest.json` + `<id>/<id>.wasm`, which is what
    ///     `installPackage` writes under the install root.
    ///
    /// A plugin that fails to load is logged and skipped — one bad module must
    /// not take the others down with it. An id two directories both offer goes
    /// to the higher `Origin.precedence`: developer over bundled over
    /// installed, whichever directory was scanned first.
    ///
    /// Load order is the sorted file order, and load order IS source priority
    /// in the vessel store, so it is deterministic across machines. Loading
    /// while the dispatch threads run is fine: entries are stable pointers,
    /// and a new plugin gets its thread the moment it is appended.
    pub fn loadDir(self: *Host, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
            self.br.say(broker.level_warn, "host", "plugins: cannot open {s}: {s}", .{ dir_path, @errorName(e) });
            return e;
        };
        defer dir.close(io);

        // A flat directory is the developer override when it IS the override:
        // same path the environment names. Everything else flat is bundled.
        const flat_origin: Origin = blk: {
            const raw = std.c.getenv("LOOKOUT_PLUGINS") orelse break :blk .bundled;
            break :blk if (std.mem.eql(u8, std.mem.span(raw), dir_path)) .developer else .bundled;
        };

        var names: std.ArrayList([]u8) = .empty;
        var subdirs: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
            for (subdirs.items) |n| self.alloc.free(n);
            subdirs.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (try it.next(io)) |ent| {
            if (ent.kind == .directory) {
                if (ent.name.len == 0 or ent.name[0] == '.') continue;
                try subdirs.append(self.alloc, try self.alloc.dupe(u8, ent.name));
                continue;
            }
            if (!std.mem.endsWith(u8, ent.name, manifest_suffix)) continue;
            try names.append(self.alloc, try self.alloc.dupe(u8, ent.name));
        }
        std.mem.sort([]u8, names.items, {}, lessName);
        std.mem.sort([]u8, subdirs.items, {}, lessName);

        for (names.items) |n| {
            const stem = n[0 .. n.len - manifest_suffix.len];
            self.loadOne(dir, stem, n, flat_origin, dir_path) catch |e| {
                self.br.say(broker.level_err, "host", "plugins: {s} not loaded: {s}", .{ stem, @errorName(e) });
            };
        }
        for (subdirs.items) |n| {
            self.loadInstalledOne(dir_path, n) catch |e| {
                self.br.say(broker.level_err, "host", "plugins: {s} not loaded: {s}", .{ n, @errorName(e) });
            };
        }
    }

    const manifest_suffix = ".manifest.json";

    /// One installed plugin: `<root>/<name>/manifest.json` beside its module.
    /// A subdirectory with no manifest is not a plugin and is left alone.
    fn loadInstalledOne(self: *Host, root_path: []const u8, name: []const u8) !void {
        const dir_path = try std.fs.path.join(self.alloc, &.{ root_path, name });
        defer self.alloc.free(dir_path);
        var sub = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
        defer sub.close(io);
        const probe = sub.openFile(io, "manifest.json", .{}) catch return;
        probe.close(io);
        try self.loadOne(sub, "", "manifest.json", .installed, dir_path);
    }

    /// The stamp file scripts/build-plugin-aot.sh writes beside the .aot
    /// files it produced, naming the WAMR build and the wamrc flags they were
    /// compiled under. See `readAot`.
    const aot_stamp_file = "AOT_VERSION";

    /// Whether `<stem>.aot` is loaded in preference to `<stem>.wasm`.
    ///
    /// An AOT module is native code, and wamrc decides which registers that
    /// code may use from the target triple it is handed.
    /// scripts/build-plugin-aot.sh names an architecture and an ABI with no
    /// platform in them, so the code it emits treats x18 as an ordinary
    /// register. Darwin, iOS, Android and Windows on arm64 all reserve x18 for
    /// the platform and overwrite it at any instruction boundary, so a pointer
    /// held there reads back as null and the next load through it faults.
    ///
    /// Naming a full triple does not settle it: wamrc reserves x18 only when
    /// it is given `--cpu` and `--cpu-features=+reserve-x18` together, and a
    /// file built with `--target=aarch64-apple-darwin` alone still uses the
    /// register.
    ///
    /// The AOT format records the architecture but not the ABI or the
    /// platform, so `wasm.aotRefusal` cannot separate a file that is safe here
    /// from one that is not, and this constant is the only gate. Turning it on
    /// requires the build script to reserve the platform's registers on every
    /// target it emits, and the watchdog to be shown terminating a spinning
    /// plugin whose code is native.
    const load_aot_modules = false;

    comptime {
        // The loader stays analyzed while `load_aot_modules` is false.
        _ = &readAot;
    }

    /// `<stem>.aot` for this plugin, when there is one that belongs to this
    /// binary; null to interpret the .wasm instead.
    ///
    /// WHO GETS ONE. The five core plugins, on the platforms the build machine
    /// compiled them for. Nobody else, ever: a .lkplug holds manifest.json and
    /// one .wasm and `unpackToTemp` refuses anything else, so no installed
    /// plugin can bring native code with it. We compile it, or we interpret
    /// it — a third-party .aot would be native code with no sandbox we could
    /// vouch for and no way to tell from the file whether its bounds checks
    /// were even switched on.
    ///
    /// WHY A STALE OR FOREIGN FILE IS REFUSED BY NAME rather than tried. An
    /// .aot is tied to two things at once — the architecture and the exact
    /// WAMR build — and when either has moved the failure the mariner would
    /// otherwise see is "plugin stopped", days after an upgrade, with no way
    /// to connect it to the file left in the plugins directory. So both are
    /// checked here and both are logged with the reason in them, and the
    /// plugin runs interpreted rather than not at all.
    ///
    ///   * the file itself — format version, endianness, word size,
    ///     architecture — in `wasm.aotRefusal`, which reads the header WAMR's
    ///     loader would read.
    ///   * the WAMR build and the wamrc flags — in `wasm.aotStampRefusal`,
    ///     against the AOT_VERSION file the build script wrote beside it.
    ///     This is the half the runtime cannot do: nothing in the AOT format
    ///     records whether the code has bounds checks in it, so a file with no
    ///     stamp is a file we cannot vouch for and is not run.
    fn readAot(self: *Host, dir: std.Io.Dir, stem: []const u8, id: []const u8) !?[]u8 {
        if (!load_aot_modules) return null;
        var name_buf: [160]u8 = undefined;
        const aot_name = std.fmt.bufPrint(&name_buf, "{s}.aot", .{stem}) catch return null;
        const bytes = dir.readFileAlloc(io, aot_name, self.alloc, .limited(max_module_bytes)) catch return null;
        errdefer self.alloc.free(bytes);

        var why_buf: [192]u8 = undefined;
        const stamp = dir.readFileAlloc(io, aot_stamp_file, self.alloc, .limited(1024)) catch "";
        defer if (stamp.len > 0) self.alloc.free(stamp);

        const refusal = wasm.aotStampRefusal(std.mem.trim(u8, stamp, " \t\r\n"), &why_buf) orelse
            wasm.aotRefusal(bytes, &why_buf);
        if (refusal) |why| {
            self.br.say(broker.level_warn, id, "{s} ignored: {s}; running the module interpreted", .{ aot_name, why });
            self.alloc.free(bytes);
            return null;
        }
        self.br.say(broker.level_info, id, "loading the ahead-of-time build ({s})", .{aot_name});
        return bytes;
    }

    /// Read, validate, instantiate and start one plugin. `stem` names the
    /// module file (`<stem>.wasm`); empty means the manifest's id names it,
    /// which is the installed layout. `plugin_dir` is copied into the entry;
    /// the caller keeps its own.
    fn loadOne(self: *Host, dir: std.Io.Dir, stem: []const u8, manifest_name: []const u8, origin: Origin, plugin_dir: []const u8) !void {
        const manifest_text = try dir.readFileAlloc(io, manifest_name, self.alloc, .limited(max_manifest_bytes));
        defer self.alloc.free(manifest_text);
        var manifest = try parseManifest(self.alloc, manifest_text);
        errdefer manifest.deinit(self.alloc);
        if (manifest.api != api_version) return Error.ApiMismatch;

        // Two copies of one id: `Origin.precedence` decides, not scan order.
        // The status the mariner reads says which copy is running, so a
        // developer set beside an installed one is not a mystery.
        //
        // The lesser copy is only unloaded further down, once this one is known
        // to be a plugin at all. A developer directory holding a manifest and
        // no module must not take the bundled plugin off the chart.
        var replacing: ?*Entry = null;
        if (self.entryFor(manifest.id)) |have| {
            if (origin.precedence() <= have.origin.precedence()) {
                self.br.say(
                    broker.level_warn,
                    manifest.id,
                    "already loaded ({s} copy wins); {s} copy skipped",
                    .{ @tagName(have.origin), @tagName(origin) },
                );
                manifest.deinit(self.alloc);
                return;
            }
            replacing = have;
        }

        // Every setting starts at its schema default. A shell that has one
        // saved sends it with `configSet` once the plugin is up.
        const values = try self.alloc.alloc(f64, manifest.settings.len);
        errdefer if (values.len > 0) self.alloc.free(values);
        for (manifest.settings, values) |f, *v| v.* = f.default_value;

        // A list starts empty. The plugin decides what no rows means — the
        // nmea0183 plugin seeds one from LOOKOUT_NMEA — and a shell that has
        // rows saved sends them with `configSet` once the plugin is up.
        const rows = try self.alloc.alloc([]u8, manifest.lists.len);
        var rows_built: usize = 0;
        errdefer freeRows(self.alloc, rows, rows_built);
        while (rows_built < rows.len) : (rows_built += 1) {
            rows[rows_built] = try self.alloc.dupe(u8, "[]");
        }

        // The second and last nmea0183 line in the host, beside the host/port
        // injection in `startJson`: the address the app was started with
        // becomes connection ONE, so the settings window shows the source the
        // mariner is already receiving instead of an empty list. A shell that
        // has rows saved overwrites this the moment it pushes them.
        if (std.mem.endsWith(u8, manifest.id, "nmea0183") and self.opts.nmea_host.len > 0) {
            if (manifest.list("connections")) |li| {
                const seeded = try std.fmt.allocPrint(
                    self.alloc,
                    "[{{\"id\":\"lookout-nmea\",\"name\":\"\",\"host\":\"{s}\",\"port\":{d},\"enabled\":true}}]",
                    .{ self.opts.nmea_host, self.opts.nmea_port },
                );
                self.alloc.free(rows[li]);
                rows[li] = seeded;
            }
        }

        // Flat layout names the module after the file stem; the installed
        // layout names it after the manifest's id, which is authoritative.
        const module_stem = if (stem.len > 0) stem else manifest.id;
        const wasm_name = try std.fmt.allocPrint(self.alloc, "{s}.wasm", .{module_stem});
        defer self.alloc.free(wasm_name);
        // The ahead-of-time build of this plugin, if this platform has one and
        // it belongs to this binary. Absent, stale or foreign, the .wasm below
        // is read instead and the plugin is interpreted, which is what every
        // third-party plugin does always.
        const raw = (try self.readAot(dir, module_stem, manifest.id)) orelse
            try dir.readFileAlloc(io, wasm_name, self.alloc, .limited(max_module_bytes));
        defer self.alloc.free(raw);

        // The grants in force: what the manifest asked for, minus whatever the
        // mariner switched off. The file lives beside the wasm — `grants.json`
        // in an installed plugin's directory, `<id>.grants.json` in a flat one
        // — and its absence means everything the manifest asked for.
        const grants = blk: {
            var name_buf: [160]u8 = undefined;
            const grants_name = if (stem.len > 0)
                std.fmt.bufPrint(&name_buf, "{s}.grants.json", .{manifest.id}) catch break :blk manifest.caps
            else
                grants_file;
            const text = dir.readFileAlloc(io, grants_name, self.alloc, .limited(max_grants_bytes)) catch
                break :blk manifest.caps;
            defer self.alloc.free(text);
            const saved = parseGrants(self.alloc, text) orelse {
                // A permissions file that will not parse grants NOTHING.
                // Failing open is the one wrong answer here.
                self.br.say(broker.level_err, manifest.id, "{s} is unreadable; granting nothing until it is rewritten", .{grants_name});
                break :blk broker.Caps.initEmpty();
            };
            break :blk saved.intersectWith(manifest.caps);
        };

        // WAMR patches the bytecode in place and keeps pointing at it, so the
        // module gets its own aligned, writable copy for the instance's life.
        const bytes = try self.alloc.alignedAlloc(u8, .@"8", raw.len);
        errdefer self.alloc.free(bytes);
        @memcpy(bytes, raw);

        try self.ensureRuntime();

        var err: wasm.ErrBuf = .{};
        var module = wasm.Module.load(bytes, &err) catch |e| {
            self.br.say(broker.level_err, manifest.id, "load failed: {s}", .{err.msg()});
            return e;
        };
        errdefer module.deinit();

        var inst = wasm.Instance.init(module, self.opts.limits, &err) catch |e| {
            self.br.say(broker.level_err, manifest.id, "instantiate failed: {s}", .{err.msg()});
            return e;
        };
        errdefer inst.deinit();

        const state = try self.alloc.create(broker.Plugin);
        errdefer self.alloc.destroy(state);
        state.* = .{
            .broker = self.br,
            .index = @intCast(self.entries.items.len),
            .id = manifest.id,
            .source = self.next_source,
            .caps = grants,
            .http_hosts = manifest.http_hosts,
            .ws_hosts = manifest.ws_hosts,
            .tcp_addrs = manifest.tcp_addrs,
            .udp_ports = manifest.udp_ports,
            .table_keys = manifest.tables,
        };
        inst.setUserData(state);

        const reported = try inst.apiVersion();
        if (reported != api_version) {
            self.br.say(broker.level_err, manifest.id, "lk_abi reported {d}, host speaks {d}", .{ reported, api_version });
            return Error.ApiMismatch;
        }

        // Priority order in the vessel store is registration order, and the
        // source has to exist before the plugin's first publish.
        try self.br.vessels.registerSource(state.source);
        try self.br.registerPlugin(state);
        // Both, in this order: dropPlugin releases what the plugin managed to
        // acquire during lk_start, removePlugin takes the record itself out of
        // the broker's list. Without the second one a plugin that fails here
        // leaves a pointer to freed memory behind, and the NEXT plugin loaded
        // gets its index.
        errdefer {
            self.br.dropPlugin(state.index, broker.wallMs());
            self.br.removePlugin(state);
        }

        // The new copy is a real module that speaks this API, so the id changes
        // hands here — before `lk_start`, so the copy going out takes its
        // overlay objects with it rather than erasing the ones the copy coming
        // in is about to draw. Only the instance goes: nothing on disk is
        // touched, because both copies are somebody's real files.
        if (replacing) |have| {
            self.br.say(
                broker.level_warn,
                manifest.id,
                "{s} copy takes the id from the {s} copy, which is now unloaded",
                .{ @tagName(origin), @tagName(have.origin) },
            );
            self.unload(have);
        }

        const cfg = try self.startJson(&manifest, values, rows);
        defer self.alloc.free(cfg);
        const rc = inst.start(cfg) catch |e| {
            self.reportTrap(&inst, manifest.id, "lk_start");
            return e;
        };
        if (rc != 0) {
            self.br.say(broker.level_err, manifest.id, "lk_start refused with {d}", .{rc});
            return Error.StartRefused;
        }
        // First thing behind `lk_start`: what the mariner has left on. A plugin
        // whose grant was switched off in an earlier run learns it here rather
        // than by having its calls refused one at a time.
        self.pushGrants(state.index, grants);

        const dir_owned: []u8 = if (plugin_dir.len > 0) try self.alloc.dupe(u8, plugin_dir) else &.{};
        errdefer if (dir_owned.len > 0) self.alloc.free(dir_owned);
        const entry = try self.alloc.create(Entry);
        errdefer self.alloc.destroy(entry);
        entry.* = .{
            .manifest = manifest,
            .bytes = bytes,
            .module = module,
            .inst = inst,
            .state = state,
            .values = values,
            .rows = rows,
            .origin = origin,
            .grants = grants,
            .dir = dir_owned,
        };
        // `lk_start` returned cleanly above, so the clean run starts here. This
        // is what `scheduleRestart` measures a first fault against.
        entry.clean_since_ms.store(broker.monoMs(), .release);

        self.next_source += 1;
        {
            self.reg_mu.lock();
            defer self.reg_mu.unlock();
            try self.entries.append(self.alloc, entry);
        }
        self.br.say(broker.level_info, manifest.id, "started ({s}, source {d})", .{ manifest.name, state.source });
        // Loaded hot: the dispatch threads are already running, so this
        // plugin gets its own at once instead of waiting for a start() that
        // already happened.
        if (self.started) self.spawnDispatch(state.index);
    }

    fn ensureRuntime(self: *Host) !void {
        if (self.runtime_held) return;
        try runtimeAcquire();
        self.runtime_held = true;
    }

    /// `{"abi":1,"config":{...}}`. The config is the plugin's settings at
    /// their current values, so a plugin reads one shape at start and at every
    /// CONFIG_CHANGED. nmea0183's host and port ride in the same object: they
    /// are configuration the host owns rather than the mariner.
    fn startJson(self: *Host, manifest: *const Manifest, values: []const f64, rows: []const []u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try out.print(self.alloc, "{{\"abi\":{d},\"config\":{{", .{api_version});
        var first = true;
        if (std.mem.endsWith(u8, manifest.id, "nmea0183")) {
            try out.print(self.alloc, "\"host\":\"{s}\",\"port\":{d}", .{ self.opts.nmea_host, self.opts.nmea_port });
            first = false;
        }
        try writeSettings(&out, self.alloc, manifest, values, rows, first);
        try out.appendSlice(self.alloc, "}}");
        return out.toOwnedSlice(self.alloc);
    }

    // -- settings --------------------------------------------------------------

    fn entryFor(self: *Host, id: []const u8) ?*Entry {
        for (self.entries.items) |e| {
            if (!e.removed and std.mem.eql(u8, e.manifest.id, id)) return e;
        }
        return null;
    }

    /// The plugin's settings object, `{"cpa_limit":926,"cpa_alarm":true,...}`,
    /// appended to `out`. Every field the schema declares is present, whether
    /// or not the mariner has ever touched it.
    pub fn configJson(self: *Host, id: []const u8, out: *std.ArrayList(u8)) !void {
        self.cfg_mu.lock();
        defer self.cfg_mu.unlock();
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        try out.append(self.alloc, '{');
        try writeSettings(out, self.alloc, &e.manifest, e.values, e.rows, true);
        try out.append(self.alloc, '}');
    }

    /// Apply a settings object and tell the plugin. Keys the schema does not
    /// declare are ignored; a number outside its range is clamped rather than
    /// refused, because a shell that sends 10 000 m wants the largest limit
    /// the plugin offers, not an error it will not show anybody.
    ///
    /// The plugin receives the WHOLE config, not the change, so a handler
    /// never has to merge. Delivery goes through the ordinary event queue, so
    /// it lands in order behind whatever the plugin is already handling.
    pub fn configSet(self: *Host, id: []const u8, json: []const u8) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.alloc);
        var index: u32 = 0;
        // Rows the list caps dropped, said out loud after the lock.
        var over: usize = 0;

        {
            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch
                return Error.BadConfig;
            defer parsed.deinit();
            if (parsed.value != .object) return Error.BadConfig;

            self.cfg_mu.lock();
            defer self.cfg_mu.unlock();
            const e = self.entryFor(id) orelse return Error.UnknownPlugin;
            if (e.manifest.settings.len == 0 and e.manifest.lists.len == 0) return Error.BadConfig;
            index = e.state.index;

            var it = parsed.value.object.iterator();
            while (it.next()) |kv| {
                // A list arrives whole: the shell sends every row it wants to
                // keep, so a removed row is simply absent from the array.
                if (e.manifest.list(kv.key_ptr.*)) |li| {
                    const text = try normalizeRows(self.alloc, e.manifest.lists[li], kv.value_ptr.*, &over);
                    self.alloc.free(e.rows[li]);
                    e.rows[li] = text;
                    continue;
                }
                const at = e.manifest.field(kv.key_ptr.*) orelse continue;
                const f = e.manifest.settings[at];
                switch (f.kind) {
                    .number => {
                        const v = jsonNumber(kv.value_ptr.*) orelse return Error.BadConfig;
                        e.values[at] = std.math.clamp(v, f.min, f.max);
                    },
                    .toggle => e.values[at] = switch (kv.value_ptr.*) {
                        .bool => |b| if (b) 1 else 0,
                        else => return Error.BadConfig,
                    },
                    // Only inside a row, and parseManifest refused it here.
                    .text => unreachable,
                }
            }
            try payload.append(self.alloc, '{');
            try writeSettings(&payload, self.alloc, &e.manifest, e.values, e.rows, true);
            try payload.append(self.alloc, '}');
        }

        self.br.push(index, broker.Kind.config_changed, 0, payload.items);
        self.br.say(broker.level_info, id, "config {s}", .{payload.items});
        // The mariner added a row past what the list holds. The plugin will
        // never see it, so the row would sit there looking like every other one
        // and doing nothing; `max_rows` in the registry JSON is how a shell
        // stops offering Add before this happens.
        if (over > 0) self.br.say(
            broker.level_warn,
            id,
            "{d} row{s} past the {d} a list holds {s} dropped and will not be used",
            .{ over, plural(over), max_list_rows, if (over == 1) "was" else "were" },
        );
    }

    // -- files the mariner chose ------------------------------------------------

    /// Hand one plugin one file, and tell it with a FILE_OPENED event carrying
    /// the handle. The plugin may then `file_read` it, or `file_write` it when
    /// `write` is true.
    ///
    /// THIS IS THE WHOLE FILESYSTEM. There is no `file_open` import, so a
    /// plugin cannot name a path: every file it ever sees came through here,
    /// because the mariner opened it or an operator passed `--grant-file`.
    pub fn grantFile(self: *Host, id: []const u8, path: []const u8, write: bool) !i64 {
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        if (!e.manifest.caps.contains(.files)) return Error.NotGranted;
        if (!e.isLive()) return Error.UnknownPlugin;
        return self.br.grantFile(e.state.index, path, write);
    }

    /// Give the plugins a file the mariner opened. True when one took it, false
    /// when no manifest claims that file type — the shell then does with the
    /// file whatever it did before there were plugins.
    ///
    /// THE MARINER OPENS A FILE, NOT A PLUGIN. There is no menu of plugins to
    /// choose from: a manifest claims `.grib2`, the mariner opens a .grib2 the
    /// way they open a chart, and the plugin that claimed it gets read access
    /// and a FILE_OPENED event. The mariner never learns a plugin was involved.
    ///
    /// A CHART IS STILL A CHART. An extension the chart side owns is never
    /// offered to a plugin, so the path a .pmtiles takes is the path it always
    /// took, whatever a manifest says.
    ///
    /// TWO CLAIMS ON ONE TYPE REFUSE BOTH, with one log line naming them. The
    /// alternative is load order deciding which plugin reads the mariner's
    /// weather, silently and differently on each machine. Asking the mariner
    /// which one they meant needs consent chrome that does not exist yet.
    pub fn openFile(self: *Host, path: []const u8) !bool {
        var buf: [max_file_type]u8 = undefined;
        const ext = fileExtension(path, &buf) orelse return false;
        for (chart_extensions) |ce| {
            if (std.mem.eql(u8, ce, ext)) return false;
        }

        var claimant: ?*Entry = null;
        for (self.entries.items) |e| {
            if (e.removed or !e.isLive()) continue;
            if (!e.manifest.claimsFileType(ext)) continue;
            if (claimant) |first| {
                self.br.say(
                    broker.level_err,
                    "host",
                    "{s} is claimed by both {s} and {s}; neither gets {s}",
                    .{ ext, first.manifest.id, e.manifest.id, path },
                );
                return Error.FileTypeConflict;
            }
            claimant = e;
        }
        const e = claimant orelse return false;

        const handle = try self.grantFile(e.manifest.id, path, false);
        self.br.say(broker.level_info, e.manifest.id, "opened {s} (handle {d})", .{ path, handle });
        return true;
    }

    /// Every loaded plugin, its state, its status line, and its settings
    /// schema with the value in force. This is what a shell reads to draw a
    /// settings pane; it never has to know what a plugin is for.
    pub fn registryJson(self: *Host, out: *std.ArrayList(u8)) !void {
        self.cfg_mu.lock();
        defer self.cfg_mu.unlock();
        const alloc = self.alloc;
        try out.appendSlice(alloc, "{\"plugins\":[");
        var written: usize = 0;
        for (self.entries.items) |e| {
            if (e.removed) continue;
            if (written > 0) try out.append(alloc, ',');
            written += 1;
            try out.appendSlice(alloc, "{\"id\":");
            try writeJsonString(out, alloc, e.manifest.id);
            try out.appendSlice(alloc, ",\"name\":");
            try writeJsonString(out, alloc, e.manifest.name);
            try out.appendSlice(alloc, ",\"version\":");
            try writeJsonString(out, alloc, e.manifest.version);
            // Where the plugin came from. The shell reads it two ways: only
            // an "installed" row offers Uninstall, and a "developer" row says
            // "developer copy" beside its status.
            try out.print(alloc, ",\"origin\":\"{s}\"", .{@tagName(e.origin)});
            try out.print(alloc, ",\"live\":{s}", .{if (e.isLive()) "true" else "false"});
            // The status line is a string, not an object: it is text a plugin
            // wrote, and the shell decides what to do with it.
            try out.appendSlice(alloc, ",\"status\":");
            try writeJsonString(out, alloc, e.state.status());
            // Every capability the manifest asked for, its consent sentence,
            // and whether the mariner currently grants it. The wording lives
            // here so every shell shows the same sentence.
            try out.appendSlice(alloc, ",\"capabilities\":[");
            var caps_written: usize = 0;
            for (sentence_order) |cap| {
                if (!e.manifest.caps.contains(cap)) continue;
                if (caps_written > 0) try out.append(alloc, ',');
                caps_written += 1;
                try out.appendSlice(alloc, "{\"cap\":");
                try writeJsonString(out, alloc, cap.name());
                try out.appendSlice(alloc, ",\"sentence\":");
                var sentence: std.ArrayList(u8) = .empty;
                defer sentence.deinit(alloc);
                try writeSentence(&sentence, alloc, cap, &e.manifest);
                try writeJsonString(out, alloc, sentence.items);
                // What the grant carries, so a shell can show the reach
                // beside the sentence: the addresses it may dial, or the
                // ports it may listen on.
                const hosts: []const []u8 = switch (cap) {
                    .net_http => e.manifest.http_hosts,
                    .net_ws => e.manifest.ws_hosts,
                    .net_tcp_client => e.manifest.tcp_addrs,
                    else => &.{},
                };
                if (hosts.len > 0) {
                    try out.appendSlice(alloc, ",\"hosts\":[");
                    for (hosts, 0..) |h, k| {
                        if (k > 0) try out.append(alloc, ',');
                        try writeJsonString(out, alloc, h);
                    }
                    try out.append(alloc, ']');
                }
                if (cap == .net_udp and e.manifest.udp_ports.len > 0) {
                    try out.appendSlice(alloc, ",\"ports\":[");
                    for (e.manifest.udp_ports, 0..) |port, k| {
                        if (k > 0) try out.append(alloc, ',');
                        try out.print(alloc, "{d}", .{port});
                    }
                    try out.append(alloc, ']');
                }
                try out.print(alloc, ",\"granted\":{s}", .{if (e.grants.contains(cap)) "true" else "false"});
                try out.append(alloc, '}');
            }
            try out.append(alloc, ']');
            // The file types this plugin claims, written only when it claims
            // some, so a plugin that opens no files writes the JSON it always
            // wrote. A shell reads these to tell the mariner what its open
            // panel now accepts.
            if (e.manifest.file_types.len > 0) {
                try out.appendSlice(alloc, ",\"file_types\":[");
                for (e.manifest.file_types, 0..) |ft, k| {
                    if (k > 0) try out.append(alloc, ',');
                    try writeJsonString(out, alloc, ft);
                }
                try out.append(alloc, ']');
            }
            try out.appendSlice(alloc, ",\"settings\":[");
            for (e.manifest.settings, e.values, 0..) |f, v, k| {
                if (k > 0) try out.append(alloc, ',');
                try writeFieldJson(out, alloc, f, v);
            }
            try out.append(alloc, ']');
            // The repeating groups: what one row holds, and the rows in force.
            // Written only when the manifest declares one, so a plugin without
            // lists writes the JSON it always wrote.
            if (e.manifest.lists.len > 0) {
                try out.appendSlice(alloc, ",\"lists\":[");
                for (e.manifest.lists, e.rows, 0..) |l, text, k| {
                    if (k > 0) try out.append(alloc, ',');
                    try out.appendSlice(alloc, "{\"key\":");
                    try writeJsonString(out, alloc, l.key);
                    if (l.group.len > 0) {
                        try out.appendSlice(alloc, ",\"group\":");
                        try writeJsonString(out, alloc, l.group);
                    }
                    // The plugin's own wording, written only when it declared
                    // some, so a manifest that says nothing writes the JSON it
                    // always wrote and the application keeps its own default.
                    for ([_][2][]const u8{
                        .{ "footer", l.footer },
                        .{ "empty", l.empty },
                        .{ "add_label", l.add_label },
                        .{ "switch_key", l.switch_key },
                    }) |pair| {
                        if (pair[1].len == 0) continue;
                        try out.append(alloc, ',');
                        try writeJsonString(out, alloc, pair[0]);
                        try out.append(alloc, ':');
                        try writeJsonString(out, alloc, pair[1]);
                    }
                    // HOW MANY ROWS THIS LIST HOLDS. The cap is the host's, not
                    // the manifest's, and `normalizeRows` enforces it by
                    // dropping what is over. A shell that knows the number can
                    // stop offering Add at the cap; one that does not lets the
                    // mariner add a ninth row that quietly never connects.
                    try out.print(alloc, ",\"tab\":\"{s}\",\"max_rows\":{d},\"item_fields\":[", .{ @tagName(l.tab), max_list_rows });
                    for (l.items, 0..) |f, j| {
                        if (j > 0) try out.append(alloc, ',');
                        try out.append(alloc, '{');
                        try writeFieldCore(out, alloc, f);
                        try out.append(alloc, '}');
                    }
                    try out.appendSlice(alloc, "],\"rows\":");
                    try out.appendSlice(alloc, text);
                    try out.append(alloc, '}');
                }
                try out.append(alloc, ']');
            }
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]}");
    }

    // -- install and consent ---------------------------------------------------

    /// The install root in force, created on first use and cached: the
    /// override from `Options`, else install.md's per-platform directory.
    pub fn installRoot(self: *Host) Error![]const u8 {
        if (self.root_cache) |r| return r;
        const root: []u8 = if (self.opts.install_root.len > 0)
            self.alloc.dupe(u8, self.opts.install_root) catch return Error.OutOfMemory
        else
            installRootAlloc(self.alloc) orelse return Error.NoInstallRoot;
        std.Io.Dir.cwd().createDirPath(io, root) catch {};
        self.root_cache = root;
        return root;
    }

    /// The sentence the last refused install left for the mariner. Borrowed;
    /// overwritten by the next install or inspect.
    pub fn installMessage(self: *const Host) [:0]const u8 {
        return self.install_msg[0..self.install_msg_len :0];
    }

    /// The refusal text for `err`, for a shell that got an error the message
    /// buffer does not already describe (an allocation failure, a load error).
    pub fn installErrorText(self: *Host, err: anyerror) [:0]const u8 {
        if (err != Error.PackageRefused) {
            self.setInstallMessage("The install failed: {s}.", .{@errorName(err)});
        }
        return self.installMessage();
    }

    /// Truncation keeps the head of the sentence, which is the part that says
    /// what happened.
    fn setInstallMessage(self: *Host, comptime fmt: []const u8, args: anytype) void {
        const kept = std.fmt.bufPrint(self.install_msg[0..max_install_msg], fmt, args) catch
            self.install_msg[0..max_install_msg];
        self.install_msg_len = kept.len;
        self.install_msg[kept.len] = 0;
    }

    /// Write the mariner's sentence and refuse.
    fn refuse(self: *Host, comptime fmt: []const u8, args: anytype) Error {
        self.setInstallMessage(fmt, args);
        return Error.PackageRefused;
    }

    /// A validated package, unpacked into a temporary directory under the
    /// install root (same volume, so placing it is one rename).
    const Unpacked = struct {
        manifest: Manifest,
        tmp_path: []u8,
    };

    /// Open a .lkplug, check it holds exactly `manifest.json` and the
    /// manifest's `<id>.wasm` — anything else refuses by name — and unpack it.
    /// Every refusal sets `installMessage` to the sentence the shell shows.
    fn unpackToTemp(self: *Host, path: []const u8) !Unpacked {
        const root = try self.installRoot();
        const cwd = std.Io.Dir.cwd();

        var file = cwd.openFile(io, path, .{}) catch |e|
            return self.refuse("Cannot open {s}: {s}.", .{ pkgBaseName(path), @errorName(e) });
        defer file.close(io);
        var rbuf: [4096]u8 = undefined;
        var fr = file.reader(io, &rbuf);

        var it = std.zip.Iterator.init(&fr) catch
            return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)});

        // Pass one, the members by name. The module's name is checked against
        // the manifest's id after the manifest is read.
        var manifest_entry: ?std.zip.Iterator.Entry = null;
        var wasm_entry: ?std.zip.Iterator.Entry = null;
        var wasm_name_buf: [max_zip_name]u8 = undefined;
        var wasm_name: []const u8 = "";
        var name_buf: [max_zip_name]u8 = undefined;
        while (it.next() catch return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)})) |entry| {
            if (entry.filename_len > name_buf.len)
                return self.refuse("The package holds a name longer than any plugin file's.", .{});
            const name = name_buf[0..entry.filename_len];
            fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch
                return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)});
            fr.interface.readSliceAll(name) catch
                return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)});
            if (std.mem.eql(u8, name, "manifest.json")) {
                if (manifest_entry != null) return self.refuse("The package holds manifest.json twice.", .{});
                if (entry.uncompressed_size > max_manifest_bytes)
                    return self.refuse("The manifest is larger than a manifest can be.", .{});
                manifest_entry = entry;
                continue;
            }
            if (std.mem.endsWith(u8, name, ".wasm") and std.mem.indexOfAny(u8, name, "/\\") == null) {
                if (wasm_entry != null)
                    return self.refuse("The package holds two modules: {s} and {s}.", .{ wasm_name, name });
                if (entry.uncompressed_size > max_module_bytes)
                    return self.refuse("The module is larger than a plugin may be.", .{});
                @memcpy(wasm_name_buf[0..name.len], name);
                wasm_name = wasm_name_buf[0..name.len];
                wasm_entry = entry;
                continue;
            }
            // install.md's rule: anything else refuses the install BY NAME.
            return self.refuse("The package holds {s}; a plugin package holds only manifest.json and its module.", .{name});
        }
        const me = manifest_entry orelse return self.refuse("The package holds no manifest.json.", .{});
        const we = wasm_entry orelse return self.refuse("The package holds no wasm module.", .{});

        // Unpack into a scratch directory beside the real ones, so a refusal
        // deletes one directory and a success is one rename. The name only
        // has to dodge a concurrent install of the same second, and the C ABI
        // serializes installs anyway; extraction creates exclusively, so a
        // stale leftover refuses rather than mixes.
        const stamp: u64 = @bitCast(broker.wallMs() *% 1_000 +% broker.monoMs());
        var tmp_name_buf: [40]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".install-{x}", .{stamp}) catch unreachable;
        const tmp_path = try std.fs.path.join(self.alloc, &.{ root, tmp_name });
        errdefer self.alloc.free(tmp_path);
        cwd.createDirPath(io, tmp_path) catch |e|
            return self.refuse("Cannot write to the plugin directory: {s}.", .{@errorName(e)});
        errdefer cwd.deleteTree(io, tmp_path) catch {};
        var tmp_dir = cwd.openDir(io, tmp_path, .{}) catch |e|
            return self.refuse("Cannot write to the plugin directory: {s}.", .{@errorName(e)});
        defer tmp_dir.close(io);

        var scratch: [max_zip_name]u8 = undefined;
        me.extract(&fr, .{}, &scratch, tmp_dir) catch |e|
            return self.refuse("The package would not unpack: {s}.", .{@errorName(e)});
        we.extract(&fr, .{}, &scratch, tmp_dir) catch |e|
            return self.refuse("The package would not unpack: {s}.", .{@errorName(e)});

        const text = tmp_dir.readFileAlloc(io, "manifest.json", self.alloc, .limited(max_manifest_bytes)) catch |e|
            return self.refuse("The manifest would not read back: {s}.", .{@errorName(e)});
        defer self.alloc.free(text);
        var manifest = parseManifest(self.alloc, text) catch
            return self.refuse("The manifest is not one this host can read.", .{});
        errdefer manifest.deinit(self.alloc);
        if (manifest.api != api_version)
            return self.refuse("{s} speaks plugin API {d}; this host speaks {d}.", .{ manifest.id, manifest.api, api_version });
        if (!idSafe(manifest.id))
            return self.refuse("The manifest's id is not a name this host can install.", .{});
        // The manifest is authoritative, so the module must carry its id. A
        // mismatch is a repack error, not something to guess about.
        var want_buf: [max_zip_name]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}.wasm", .{manifest.id}) catch
            return self.refuse("The manifest's id is too long for a module name.", .{});
        if (!std.mem.eql(u8, wasm_name, want))
            return self.refuse("The module is named {s} but the manifest's id wants {s}.", .{ wasm_name, want });

        // The ids of the plugins that ship inside the app are the product's.
        // A package claiming one is refused here, before any consent is asked
        // for, so the sheet shows the reason instead of an Install button and
        // nothing lands on disk to be picked up at the next launch.
        if (self.entryFor(manifest.id)) |have| {
            if (have.origin == .bundled)
                return self.refuse(
                    "{s} is the id of {s}, which comes with Lookout, and an installed plugin may not take it over.",
                    .{ manifest.id, have.manifest.name },
                );
        }

        return .{ .manifest = manifest, .tmp_path = tmp_path };
    }

    /// What the consent sheet shows, as JSON, without installing anything:
    /// `{"id":..,"name":..,"version":..,"sentences":[..]}`. When the id is
    /// already loaded it adds `"installed":{"version":..,"origin":..,
    /// "adds":[..],"drops":[..],"downgrade":bool}` so the sheet can call out
    /// the delta, downgrades included. A refused package answers
    /// `{"error":"…"}` with the sentence the shell shows.
    pub fn inspectPackage(self: *Host, path: []const u8, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        const alloc = self.alloc;
        var up = self.unpackToTemp(path) catch |e| {
            try out.appendSlice(alloc, "{\"error\":");
            try writeJsonString(out, alloc, self.installErrorText(e));
            try out.append(alloc, '}');
            return;
        };
        defer {
            std.Io.Dir.cwd().deleteTree(io, up.tmp_path) catch {};
            alloc.free(up.tmp_path);
            up.manifest.deinit(alloc);
        }
        try out.appendSlice(alloc, "{\"id\":");
        try writeJsonString(out, alloc, up.manifest.id);
        try out.appendSlice(alloc, ",\"name\":");
        try writeJsonString(out, alloc, up.manifest.name);
        try out.appendSlice(alloc, ",\"version\":");
        try writeJsonString(out, alloc, up.manifest.version);
        try out.appendSlice(alloc, ",\"sentences\":[");
        try writeSentences(out, alloc, &up.manifest, null);
        try out.append(alloc, ']');
        if (self.entryFor(up.manifest.id)) |have| {
            try out.appendSlice(alloc, ",\"installed\":{\"version\":");
            try writeJsonString(out, alloc, have.manifest.version);
            try out.print(alloc, ",\"origin\":\"{s}\"", .{@tagName(have.origin)});
            try out.appendSlice(alloc, ",\"adds\":[");
            try writeSentences(out, alloc, &up.manifest, &have.manifest);
            try out.appendSlice(alloc, "],\"drops\":[");
            try writeSentences(out, alloc, &have.manifest, &up.manifest);
            try out.print(alloc, "],\"downgrade\":{s}}}", .{
                if (versionLess(up.manifest.version, have.manifest.version)) "true" else "false",
            });
        }
        try out.append(alloc, '}');
    }

    /// Unpack, validate, place under the install root and load hot. The
    /// consent already happened on the sheet; this is the Install button.
    ///
    /// An id already running is replaced — its instance unloaded, its
    /// directory and grants file overwritten — except a developer copy, which
    /// keeps the id for this run per install.md; the files still land so the
    /// next launch without the override has them. A bundled id is refused
    /// outright by `unpackToTemp`, so nothing here has to defend it.
    pub fn installPackage(self: *Host, path: []const u8) !void {
        var up = try self.unpackToTemp(path);
        var placed = false;
        defer {
            if (!placed) std.Io.Dir.cwd().deleteTree(io, up.tmp_path) catch {};
            self.alloc.free(up.tmp_path);
            up.manifest.deinit(self.alloc);
        }
        const root = try self.installRoot();
        const final = try std.fs.path.join(self.alloc, &.{ root, up.manifest.id });
        defer self.alloc.free(final);
        const cwd = std.Io.Dir.cwd();

        var developer_stays = false;
        if (self.entryFor(up.manifest.id)) |have| {
            if (have.origin == .developer) {
                developer_stays = true;
            } else {
                // Consent was re-asked with the delta on the sheet, so the
                // old instance, its files and its grants file all go.
                self.unload(have);
            }
        }
        cwd.deleteTree(io, final) catch {};
        cwd.rename(up.tmp_path, cwd, final, io) catch |e|
            return self.refuse("Cannot place {s}: {s}.", .{ up.manifest.id, @errorName(e) });
        placed = true;
        if (developer_stays) {
            self.br.say(broker.level_warn, up.manifest.id, "installed; the developer copy stays in force until the override is dropped", .{});
            return;
        }

        self.loadInstalledOne(root, up.manifest.id) catch |e| {
            // Nothing half-installed: a module that will not start leaves no
            // directory behind, and the sentence says which plugin failed.
            cwd.deleteTree(io, final) catch {};
            return self.refuse("{s} did not start: {s}. Nothing was installed.", .{ up.manifest.id, @errorName(e) });
        };
    }

    /// Remove an installed plugin: instance down, broker record gone, overlay
    /// and store contributions erased (the same dropPlugin path a dead plugin
    /// takes), directory deleted, persisted storage deleted. Bundled and
    /// developer copies refuse: only what install wrote can be removed.
    pub fn uninstall(self: *Host, id: []const u8) !void {
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        if (e.origin != .installed) return Error.NotInstalled;
        self.unload(e);
        if (e.dir.len > 0) std.Io.Dir.cwd().deleteTree(io, e.dir) catch {};
        self.deleteStorage(e.manifest.id);
        self.br.say(broker.level_info, id, "uninstalled: its files, storage and overlay are gone", .{});
    }

    /// Take a loaded plugin out of the registry: SHUTDOWN, thread down,
    /// instance gone, broker record gone, slot tombstoned. The files are the
    /// caller's business — installPackage replaces them, uninstall deletes
    /// them, and a developer or bundled set is never written.
    fn unload(self: *Host, e: *Entry) void {
        const index = e.state.index;
        if (e.thread != null) {
            if (e.isLive()) self.br.push(index, broker.Kind.shutdown, 0, "");
            const until = broker.monoMs() + self.opts.shutdown_ms;
            while (e.isLive() and broker.monoMs() < until) broker.sleepMs(2);
            e.stopping.store(true, .release);
            var grace: u32 = 0;
            while (grace < shutdown_grace_ms and e.entered_ms.load(.acquire) != 0) : (grace += 2) broker.sleepMs(2);
            if (e.entered_ms.load(.acquire) != 0) {
                self.br.say(broker.level_warn, e.manifest.id, "still inside the module; terminating", .{});
                e.inst.terminate();
            }
            if (e.thread) |th| {
                th.join();
                e.thread = null;
            }
        } else if (e.isLive()) {
            self.deliverTo(index, broker.Kind.shutdown, 0, "");
        }
        // SHUTDOWN delivery retired it; this is the path where it could not.
        self.retire(index, false, "unloaded");
        self.br.removePlugin(e.state);
        {
            // The watchdog walks the registry on the I/O thread; it must see
            // the tombstone before the instance behind it goes away.
            self.reg_mu.lock();
            e.removed = true;
            self.reg_mu.unlock();
        }
        e.inst.deinit();
        e.module.deinit();
        self.alloc.free(e.bytes);
    }

    /// Switch one capability on or off, live. The broker checks per call, so
    /// the flip is felt on the plugin's next mediated call: a revoked
    /// capability answers -1 and counts denied exactly as if the manifest had
    /// never asked. No restart, no event, no redelivery.
    pub fn grantSet(self: *Host, id: []const u8, cap_name: []const u8, on: bool) !void {
        const cap = broker.Cap.fromName(cap_name) orelse return Error.UnknownCapability;
        var grants: broker.Caps = undefined;
        var index: u32 = 0;
        {
            self.cfg_mu.lock();
            defer self.cfg_mu.unlock();
            const e = self.entryFor(id) orelse return Error.UnknownPlugin;
            index = e.state.index;
            // A grant can never exceed the manifest: switching ON something
            // it never asked for is refused, not stored.
            if (!e.manifest.caps.contains(cap)) return Error.NotGranted;
            if (on) e.grants.insert(cap) else e.grants.remove(cap);
            // The natives read this set unlocked on the dispatch threads. It
            // is one machine word; a call racing the flip lands on one side
            // of it or the other, which is what "live" means.
            e.state.caps = e.grants;
            grants = e.grants;
        }
        // A grant that goes off takes back what it produced. The plugin keeps
        // running, so nothing else clears the overlay objects it drew or the
        // readings it published, and both would sit there unchanging while
        // looking current.
        if (!on) self.br.withdraw(index, cap, broker.wallMs());
        // The plugin is told what it now holds, after the takeback, so it can
        // stop producing what the host would only refuse. Enforcement is
        // unchanged: every call is still checked, and one that arrives before
        // this event is answered -1 like any other.
        self.pushGrants(index, grants);
        self.persistGrants(id, grants) catch |e| {
            self.br.say(broker.level_warn, id, "grant change not saved: {s}", .{@errorName(e)});
        };
        self.br.say(broker.level_info, id, "grant {s} switched {s}", .{ cap.name(), if (on) "on" else "off" });
    }

    /// Hand a plugin the set of capabilities it holds, as
    /// `{"v":1,"granted":[…]}`. Sent once the module has started, and again on
    /// every change, which is the only way a plugin learns what it may do: the
    /// manifest is what it asked for, not what the mariner left on.
    ///
    /// A failure to build the JSON is silent. The event is an optimisation for
    /// the plugin, never the permission itself.
    fn pushGrants(self: *Host, index: u32, caps: broker.Caps) void {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.alloc);
        writeGrantsJson(&json, self.alloc, caps) catch return;
        self.br.push(index, broker.Kind.grants_changed, 0, json.items);
    }

    /// Write the grants file beside the plugin's wasm, atomically. A set that
    /// cannot be written (the app bundle is read-only) keeps the flip for
    /// this run and says so.
    fn persistGrants(self: *Host, id: []const u8, caps: broker.Caps) !void {
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        if (e.dir.len == 0) return;
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.alloc);
        try writeGrantsJson(&json, self.alloc, caps);
        const name = if (e.origin == .installed)
            try self.alloc.dupe(u8, grants_file)
        else
            try std.fmt.allocPrint(self.alloc, "{s}.grants.json", .{id});
        defer self.alloc.free(name);
        const final = try std.fs.path.join(self.alloc, &.{ e.dir, name });
        defer self.alloc.free(final);
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{final});
        defer self.alloc.free(tmp);
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = json.items });
        try cwd.rename(tmp, cwd, final, io);
    }

    /// Take the plugin's persisted storage with it. The broker keeps the file
    /// on a mere disable so a reload finds its settings; an uninstall is the
    /// mariner saying goodbye, and everything the plugin owns goes.
    fn deleteStorage(self: *Host, id: []const u8) void {
        var name_buf: [192]u8 = undefined;
        const name = storageFileName(id, &name_buf);
        var dir_owned: ?[]u8 = null;
        var resolved = false;
        {
            self.br.mu.lock();
            defer self.br.mu.unlock();
            resolved = self.br.storage_dir_resolved;
            if (resolved) {
                if (self.br.storage_dir) |d| dir_owned = self.alloc.dupe(u8, d) catch null;
            }
        }
        // Never resolved this run does not mean no file: an earlier run may
        // have written one in the default place.
        if (!resolved) dir_owned = storageDirDefault(self.alloc);
        const dir = dir_owned orelse return;
        defer self.alloc.free(dir);
        const path = std.fs.path.join(self.alloc, &.{ dir, name }) catch return;
        defer self.alloc.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    // -- the event loop ------------------------------------------------------

    /// Start the broker's I/O thread, arm the watchdog, and give every live
    /// plugin its own dispatch thread. Call after `loadDir`: `lk_start` runs on
    /// the caller's thread, and nothing should be delivering events while it
    /// does. Idempotent, and a repeat call picks up plugins loaded since —
    /// which is what `loadPlugins` leans on when it loads a second directory.
    pub fn start(self: *Host) !void {
        // Armed before the I/O thread exists, so the first tick already has it.
        self.br.setWatchdog(self, watchdogTick);
        try self.br.start();
        self.started = true;
        for (self.entries.items, 0..) |e, i| {
            if (e.removed or !e.isLive() or e.thread != null) continue;
            self.spawnDispatch(@intCast(i));
        }
    }

    /// One plugin's dispatch thread, spawned at `start` or the moment a hot
    /// install appends it.
    fn spawnDispatch(self: *Host, index: u32) void {
        const e = self.entries.items[index];
        e.stopping.store(false, .release);
        e.thread = std.Thread.spawn(
            .{ .stack_size = dispatch_stack_bytes },
            dispatchMain,
            .{ self, index },
        ) catch |err| {
            // No thread means no events, ever. Better a plugin that is
            // visibly gone than one that is silently deaf.
            self.br.say(broker.level_err, e.manifest.id, "no dispatch thread: {s}", .{@errorName(err)});
            self.retire(index, true, "no dispatch thread");
            return;
        };
    }

    /// SHUTDOWN to every live plugin, drained best effort, then every thread
    /// down. Safe to call twice and safe to call without `start`.
    ///
    /// The join at the end is bounded because anything still inside a module
    /// when the grace period runs out is terminated first. A plugin in a loop
    /// must not stop the app from closing, and a thread that never returns
    /// cannot be joined.
    pub fn stop(self: *Host) void {
        if (!self.started) {
            // Never started: deliver SHUTDOWN inline so a plugin that opened a
            // socket in lk_start still gets told.
            for (self.entries.items, 0..) |e, i| {
                if (!e.removed and e.isLive()) self.deliverTo(@intCast(i), broker.Kind.shutdown, 0, "");
            }
            self.br.stop();
            return;
        }

        for (self.entries.items, 0..) |e, i| {
            if (!e.removed and e.isLive()) self.br.push(@intCast(i), broker.Kind.shutdown, 0, "");
        }
        var waited: u32 = 0;
        while (self.br.queued() > 0 and waited < self.opts.shutdown_ms) : (waited += 2) {
            broker.sleepMs(2);
        }

        for (self.entries.items) |e| e.stopping.store(true, .release);
        var grace: u32 = 0;
        while (grace < shutdown_grace_ms and self.anyInModule()) : (grace += 2) broker.sleepMs(2);
        for (self.entries.items) |e| {
            if (e.removed or e.thread == null or e.entered_ms.load(.acquire) == 0) continue;
            self.br.say(broker.level_warn, e.manifest.id, "still inside the module at shutdown; terminating", .{});
            e.inst.terminate();
        }
        for (self.entries.items) |e| {
            if (e.thread) |th| {
                th.join();
                e.thread = null;
            }
        }
        self.started = false;
        self.br.stop();
    }

    fn anyInModule(self: *Host) bool {
        for (self.entries.items) |e| {
            if (e.thread != null and e.entered_ms.load(.acquire) != 0) return true;
        }
        return false;
    }

    /// Deliver everything queued, on the CALLING thread, and return how many
    /// events went. For the replay harness and the tests, where delivery has
    /// to be deterministic rather than concurrent. Never call this while
    /// `start` has dispatch threads running — two threads would enter the same
    /// instance.
    ///
    /// Round robin rather than plugin by plugin, so an event that makes one
    /// plugin publish still reaches the others in something like the order the
    /// old single queue gave them.
    pub fn pump(self: *Host) usize {
        var n: usize = 0;
        var moved = true;
        while (moved) {
            moved = false;
            for (0..self.entries.items.len) |i| {
                const e = self.br.popFor(@intCast(i)) orelse continue;
                defer self.br.freeEvent(e);
                self.deliverTo(@intCast(i), e.kind, e.handle, e.payload);
                n += 1;
                moved = true;
            }
        }
        return n;
    }

    /// One plugin's dispatch thread: its queue, its instance, its restarts,
    /// nobody else's.
    ///
    /// The restart happens HERE, and not on the watchdog's thread or the
    /// shell's, because bringing a plugin back means calling `lk_start` — wasm,
    /// on a thread with a runtime environment, in the one place that is allowed
    /// inside this instance. The thread outlives the fault for exactly as long
    /// as the backoff says, and goes when the schedule runs out or the host
    /// stops.
    fn dispatchMain(self: *Host, index: u32) void {
        const e = self.entries.items[index];
        // WAMR keeps the interpreter's native stack boundary per THREAD, and
        // the load thread got its own from initRuntime. Cheap, and the
        // documented way to enter wasm from a thread the runtime has not seen;
        // without the hardware bound check it is no longer the difference
        // between running and trapping.
        wasm.initThreadEnv() catch {
            self.br.say(broker.level_err, e.manifest.id, "dispatch thread has no wasm runtime env; no events will be delivered", .{});
            return;
        };
        defer wasm.destroyThreadEnv();

        while (true) {
            self.serveEvents(index);
            // A fault leaves a restart time behind; anything else — SHUTDOWN,
            // an unload, the last attempt of the schedule — leaves zero, and
            // this thread is done.
            const at = e.restart_at.swap(0, .acq_rel);
            if (at == 0) break;
            while (!e.stopping.load(.acquire) and broker.monoMs() < at) broker.sleepMs(2);
            if (e.stopping.load(.acquire)) break;
            _ = self.restart(index);
        }
        // Anything still queued belongs to nobody now.
        self.br.clearQueue(index);
    }

    /// Deliver this plugin's events until it stops, faults or is told to stop.
    fn serveEvents(self: *Host, index: u32) void {
        const e = self.entries.items[index];
        // Polled rather than waited on a condition variable, for the same
        // reason raster.zig's worker is: Zig 0.16 has no std.Thread.Condition
        // outside an Io. The backoff keeps an idle plugin off the CPU; the
        // broker's fanout tick lands every 100 ms anyway.
        var idle_ms: u32 = 1;
        while (!e.stopping.load(.acquire) and e.isLive()) {
            // The watchdog may have terminated this instance while the thread
            // was between events, or just after a call returned. Either way the
            // plugin overran and is finished.
            if (e.killed_ms.load(.acquire) != 0) {
                self.disableStuck(index);
                return;
            }
            // A queue that overflowed was filled by the I/O thread; the note
            // is written here, where the status line has one writer.
            e.state.drainQueueBudget();
            const ev = self.br.popFor(index) orelse {
                broker.sleepMs(idle_ms);
                if (idle_ms < 8) idle_ms *= 2;
                continue;
            };
            idle_ms = 1;
            defer self.br.freeEvent(ev);
            self.deliverTo(index, ev.kind, ev.handle, ev.payload);
        }
    }

    /// Bring a faulted plugin back, on its own dispatch thread. True when it is
    /// running again.
    ///
    /// WHAT IT GETS BACK. Its settings and its connection rows, exactly as they
    /// stand — including anything the mariner changed while it was down — and
    /// nothing else. The instance is NEW, so its globals are gone; the scene is
    /// empty, because `retire` erased everything it had drawn and published;
    /// the queue is empty, because what arrived while it was dead went with it.
    /// Its persisted storage is untouched on disk and it may read it back.
    ///
    /// A restart that cannot instantiate, or whose `lk_start` traps or refuses,
    /// is one more failed attempt: the schedule decides whether there is
    /// another.
    fn restart(self: *Host, index: u32) bool {
        const e = self.entries.items[index];
        e.restarts += 1;
        // The clean run is over the moment an attempt begins. Without this a
        // plugin that ran for hours and then could not come up at all would
        // have its allowance handed back after every failed attempt, which is
        // the restart loop the schedule exists to prevent.
        e.clean_since_ms.store(0, .release);

        var err: wasm.ErrBuf = .{};
        var fresh = wasm.Instance.init(e.module, self.opts.limits, &err) catch |ie| {
            self.br.say(broker.level_err, e.manifest.id, "restart {d}: instantiate failed: {s}", .{ e.restarts, err.msg() });
            self.giveUp(index, @errorName(ie));
            return false;
        };
        fresh.setUserData(e.state);
        {
            // The watchdog reads this instance on the I/O thread while it walks
            // the registry, so the swap happens under the registry lock. The
            // plugin is not live either side of it, so nothing is inside.
            self.reg_mu.lock();
            defer self.reg_mu.unlock();
            e.inst.deinit();
            e.inst = fresh;
        }

        const cfg = blk: {
            self.cfg_mu.lock();
            defer self.cfg_mu.unlock();
            break :blk self.startJson(&e.manifest, e.values, e.rows) catch |ce| {
                self.giveUp(index, @errorName(ce));
                return false;
            };
        };
        defer self.alloc.free(cfg);

        // Live again BEFORE the call: `lk_start` subscribes, dials, draws and
        // posts a status, and every one of those goes through the broker record
        // this flips back on. The stamp goes with it, so a plugin that hangs in
        // lk_start is the watchdog's business like any other call.
        e.killed_ms.store(0, .release);
        e.retired.store(false, .release);
        {
            self.br.mu.lock();
            defer self.br.mu.unlock();
            e.state.enabled = true;
        }
        e.live.store(true, .release);
        e.entered_ms.store(broker.monoMs(), .release);
        const rc = e.inst.start(cfg) catch |se| {
            e.entered_ms.store(0, .release);
            var tbuf: [max_reason]u8 = undefined;
            const text = e.inst.exception() orelse @errorName(se);
            const kept = tbuf[0..@min(text.len, tbuf.len)];
            @memcpy(kept, text[0..kept.len]);
            e.inst.clearException();
            self.br.say(broker.level_err, e.manifest.id, "restart {d}: lk_start trapped: {s}", .{ e.restarts, kept });
            self.retire(index, true, kept);
            self.scheduleRestart(index, kept);
            return false;
        };
        e.entered_ms.store(0, .release);
        if (rc != 0) {
            var buf: [max_reason]u8 = undefined;
            const why = std.fmt.bufPrint(&buf, "lk_start refused with {d}", .{rc}) catch "lk_start refused";
            self.br.say(broker.level_err, e.manifest.id, "restart {d}: {s}", .{ e.restarts, why });
            self.retire(index, true, why);
            self.scheduleRestart(index, why);
            return false;
        }
        e.clean_since_ms.store(broker.monoMs(), .release);
        // A fresh instance knows nothing, including what it is allowed to do.
        self.pushGrants(e.state.index, e.grants);
        self.br.say(
            broker.level_info,
            e.manifest.id,
            "restarted (attempt {d} of {d}); settings and connections restored, scene empty",
            .{ e.restarts, self.opts.restart_backoff_ms.len },
        );
        return true;
    }

    /// Arrange for a faulted plugin's own dispatch thread to bring it back, or
    /// say on its status line that this was the last time.
    ///
    /// Called from that thread, right after `retire`, so a plugin with no
    /// thread to serve the restart is never promised one.
    fn scheduleRestart(self: *Host, index: u32, reason: []const u8) void {
        const e = self.entries.items[index];
        const schedule = self.opts.restart_backoff_ms;
        // Nothing to promise: the schedule is switched off, the host is
        // stopping, or this plugin has had every attempt it is going to get.
        if (schedule.len == 0 or e.stopping.load(.acquire)) return;
        self.decayRestarts(e);
        if (e.restarts >= schedule.len) {
            self.giveUp(index, reason);
            return;
        }
        const wait_ms = schedule[e.restarts];
        e.restart_at.store(broker.monoMs() + wait_ms, .release);
        self.br.say(
            broker.level_warn,
            e.manifest.id,
            "restarting in {d} ms (attempt {d} of {d})",
            .{ wait_ms, e.restarts + 1, schedule.len },
        );
        setFaultStatus(e, "{s}; restarting (attempt {d} of {d})", .{ reason, e.restarts + 1, schedule.len });
    }

    /// Give a plugin its attempts back when it earned them: a stretch of clean
    /// running since it last came up says the fault behind it was the data, not
    /// the plugin, and a plugin that meets one bad sentence an hour must not go
    /// dark partway through a passage.
    ///
    /// Called on the plugin's own dispatch thread at the moment of the NEXT
    /// fault, so there is no timer and nothing to cancel: the question is only
    /// ever asked when the answer matters.
    fn decayRestarts(self: *Host, e: *Entry) void {
        const since = e.clean_since_ms.load(.acquire);
        const now = broker.monoMs();
        if (!allowanceWhole(e.restarts, since, now, self.opts.restart_clean_ms)) return;
        const ran_ms = now - since;
        self.br.say(
            broker.level_info,
            e.manifest.id,
            "ran clean for {d} s after {d} restart{s}; the restart allowance is whole again",
            .{ @divTrunc(ran_ms, 1000), e.restarts, plural(e.restarts) },
        );
        e.restarts = 0;
    }

    /// The end of the line: this plugin is not coming back, and the status line
    /// the mariner reads says why in as many words. Nothing is restarted after
    /// this without a relaunch.
    fn giveUp(self: *Host, index: u32, reason: []const u8) void {
        const e = self.entries.items[index];
        e.restart_at.store(0, .release);
        self.br.say(
            broker.level_err,
            e.manifest.id,
            "stopped after {d} failed restart{s}: {s}",
            .{ e.restarts, plural(e.restarts), reason },
        );
        setFaultStatus(e, "stopped after {d} failed restart{s}: {s}", .{ e.restarts, plural(e.restarts), reason });
    }

    fn deliverTo(self: *Host, index: u32, kind: u32, handle: u64, payload: []const u8) void {
        if (index >= self.entries.items.len) return;
        const e = self.entries.items[index];
        if (e.removed or !e.isLive()) return;
        // SHUTDOWN is the last thing a plugin ever sees, whatever it returns.
        if (kind == broker.Kind.shutdown) e.live.store(false, .release);

        // The stamp the watchdog reads. Set before the call and cleared after
        // it however it ends, so a plugin is only ever judged on time it is
        // actually spending inside the module.
        e.entered_ms.store(broker.monoMs(), .release);
        const rc = e.inst.eventWith(kind, handle, payload) catch |err| {
            e.entered_ms.store(0, .release);
            if (e.killed_ms.load(.acquire) != 0) {
                self.disableStuck(index);
                return;
            }
            // An ordinary trap keeps its OWN text. WAMR's message says what the
            // module did wrong ("unreachable", "out of bounds memory access"),
            // which is the only useful thing anybody has; the error name is the
            // fallback for a failure with no exception behind it, such as
            // lk_alloc answering zero.
            var tbuf: [max_reason]u8 = undefined;
            const text = e.inst.exception() orelse @errorName(err);
            const kept = tbuf[0..@min(text.len, tbuf.len)];
            @memcpy(kept, text[0..kept.len]);
            e.inst.clearException();
            self.br.say(broker.level_err, e.manifest.id, "lk_event trapped: {s}", .{kept});
            self.retire(index, true, kept);
            // One malformed sentence should not cost the mariner the plugin
            // for the rest of the passage. A plugin that traps on its way out
            // is on its way out, though, and is not brought back.
            if (kind != broker.Kind.shutdown) self.scheduleRestart(index, kept);
            return;
        };
        e.entered_ms.store(0, .release);

        // A non-zero return is the plugin's own complaint, not a fault: it
        // stays running and the line says which event it disliked.
        if (rc != 0) self.br.say(broker.level_warn, e.manifest.id, "event {d} returned {d}", .{ kind, rc });
        if (kind == broker.Kind.shutdown) self.retire(index, false, "shutdown");
    }

    fn reportTrap(self: *Host, inst: *wasm.Instance, id: []const u8, what: []const u8) void {
        const text = inst.exception() orelse "(no exception text)";
        self.br.say(broker.level_err, id, "{s} trapped: {s}", .{ what, text });
        inst.clearException();
    }

    /// The disable path for a plugin the watchdog terminated. WAMR's own text
    /// for this trap is "terminated by user", which says who did it and nothing
    /// about why, so it is dropped in favour of the budget it blew. Every other
    /// trap keeps its original exception text.
    fn disableStuck(self: *Host, index: u32) void {
        const e = self.entries.items[index];
        e.inst.clearException();
        var buf: [max_reason]u8 = undefined;
        const reason = std.fmt.bufPrint(
            &buf,
            "stuck in lk_event (terminated after {d} ms)",
            .{e.killed_ms.load(.acquire)},
        ) catch "stuck in lk_event";
        self.retire(index, true, reason);
        // A plugin that overran is restarted like one that trapped: the event
        // it choked on is gone with its queue, and the next start may well be
        // the plugin working again.
        self.scheduleRestart(index, reason);
    }

    /// Take a plugin out of service and erase everything it contributed:
    /// overlay objects, published values, AIS targets, sockets, timers and
    /// whatever was still queued. `fault` distinguishes a plugin that broke —
    /// logged as an error, status line replaced with the reason — from one that
    /// was shut down, which keeps whatever it last said about itself.
    fn retire(self: *Host, index: u32, fault: bool, reason: []const u8) void {
        const e = self.entries.items[index];
        e.live.store(false, .release);
        if (e.retired.swap(true, .acq_rel)) return;
        if (fault) {
            setFaultStatus(e, "{s}", .{reason});
            self.br.say(broker.level_err, e.manifest.id, "disabled: {s}; overlays and published values cleared", .{reason});
        }
        self.br.dropPlugin(index, broker.wallMs());
    }

    // -- the watchdog --------------------------------------------------------

    /// Called from the broker's 100 ms tick, on the I/O thread, with no lock
    /// held. Terminates any plugin that has been inside a module call for
    /// longer than the budget, and returns at once: it never joins the stuck
    /// thread, never waits for it, and does not touch anything the stuck thread
    /// owns. The plugin's own dispatch thread does the clean-up when the
    /// terminated call unwinds.
    fn watchdogTick(ctx: ?*anyopaque, mono_ms: i64) void {
        const self: *Host = @ptrCast(@alignCast(ctx orelse return));
        // Under the registry lock: an install appends to this list from the
        // API thread while the tick walks it here on the I/O thread.
        self.reg_mu.lock();
        defer self.reg_mu.unlock();
        for (self.entries.items) |e| {
            if (e.removed or !e.isLive()) continue;
            const entered = e.entered_ms.load(.acquire);
            if (entered == 0) continue;
            const elapsed = mono_ms - entered;
            if (elapsed < self.opts.event_budget_ms) continue;
            // Claim the kill. A second tick over the same stuck call must not
            // terminate it twice, and must not overwrite the elapsed time the
            // disable line will report.
            if (e.killed_ms.cmpxchgStrong(0, elapsed, .acq_rel, .acquire) != null) continue;
            self.br.say(
                broker.level_err,
                e.manifest.id,
                "over the {d} ms event budget ({d} ms inside the module); terminating",
                .{ self.opts.event_budget_ms, elapsed },
            );
            e.inst.terminate();
        }
    }
};

fn lessName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// THE DECAY RULE, with every input an argument: how many attempts are spent,
/// when the plugin last came up, what time it is, and how long a clean run has
/// to be. True when the attempts are given back.
///
/// A free function so the rule can be checked without a clock, a thread or a
/// wasm module. `decayRestarts` is the only caller in the host, and it does
/// nothing but read the entry, ask this, and log.
///
/// `clean_since_ms` of 0 means an attempt is in flight, which is no clean run
/// at all whatever the clock says: that is what keeps a plugin that cannot come
/// up from being restarted for ever. `clean_ms` of 0 switches the rule off.
fn allowanceWhole(restarts: usize, clean_since_ms: i64, now_ms: i64, clean_ms: i64) bool {
    if (restarts == 0 or clean_ms <= 0 or clean_since_ms == 0) return false;
    return now_ms - clean_since_ms >= clean_ms;
}

/// Replace a plugin's status line with one the HOST wrote, in the one case
/// where nobody is left inside the module to say what happened.
///
/// Part of the detail is text WAMR wrote, so quotes, backslashes and control
/// bytes are folded to spaces rather than escaped: this is a one-line status,
/// not a document, and it must not be able to break the shape.
fn setFaultStatus(e: *Entry, comptime fmt: []const u8, args: anytype) void {
    var detail: [max_reason]u8 = undefined;
    const written = std.fmt.bufPrint(&detail, fmt, args) catch detail[0..];
    for (written) |*ch| ch.* = switch (ch.*) {
        '"', '\\', 0...31, 127 => ' ',
        else => ch.*,
    };
    var buf: [broker.max_status]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{{\"state\":\"disabled\",\"detail\":\"{s}\"}}",
        .{written},
    ) catch "{\"state\":\"disabled\"}";
    _ = e.state.setStatus(line);
}

// ---- tests -------------------------------------------------------------------

const t = std.testing;
const ais_settings_manifest = testing.ais_settings_manifest;

test "the start payload carries the api version, and NMEA config only for nmea0183" {
    var vessels = try store.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(t.allocator);
    defer ais.deinit();
    var br = broker.Broker.init(t.allocator, &vessels, &ais, .{});
    defer br.deinit();
    var h = Host.init(t.allocator, &br, .{ .nmea_host = "10.0.0.4", .nmea_port = 2000 });
    defer h.deinit();

    var nm = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.nmea0183\",\"api\":1}");
    defer nm.deinit(t.allocator);
    const nmea = try h.startJson(&nm, &.{}, &.{});
    defer t.allocator.free(nmea);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"host\":\"10.0.0.4\",\"port\":2000}}", nmea);

    var om = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.ownship\",\"api\":1}");
    defer om.deinit(t.allocator);
    const other = try h.startJson(&om, &.{}, &.{});
    defer t.allocator.free(other);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{}}", other);

    // A plugin with a schema starts on its defaults, in the same shape
    // CONFIG_CHANGED later carries.
    var am = try parseManifest(t.allocator, ais_settings_manifest);
    defer am.deinit(t.allocator);
    const with = try h.startJson(&am, &.{ 926, 1 }, &.{});
    defer t.allocator.free(with);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"cpa_limit\":926,\"cpa_alarm\":true}}", with);
}

test "an id two directories both offer goes by origin, not by scan order" {
    // Developer over bundled over installed. The shell scans them in that order
    // today; the rule is what keeps the answer the same when something does
    // not — a shell that loads the installed set late, the way
    // `lookout_plugins_load_installed` does, still runs the developer copy.
    // Equal precedence is not a win, which is what makes loading one directory
    // twice a no-op; test/host_restart.zig drives all three end to end.
    try t.expect(Origin.developer.precedence() > Origin.bundled.precedence());
    try t.expect(Origin.bundled.precedence() > Origin.installed.precedence());
    try t.expect(Origin.developer.precedence() > Origin.installed.precedence());
}

test "the restart schedule is a second, then five, then thirty, then no more" {
    try t.expectEqualSlices(i64, &.{ 1_000, 5_000, 30_000 }, &default_restart_backoff_ms);
    // A host built with the default Options restarts on it. A schedule of no
    // entries is the old behaviour — disabled for good — and stays reachable
    // for a shell that wants it.
    const shipped = Options{};
    try t.expectEqualSlices(i64, &default_restart_backoff_ms, shipped.restart_backoff_ms);
    // ...and it is spent per bout of trouble, not per run of the app.
    try t.expectEqual(@as(i64, 5 * 60 * 1000), shipped.restart_clean_ms);
    // Five minutes is an order of magnitude past the longest wait in the
    // schedule, which is what makes it a threshold and not a coin toss.
    try t.expect(default_restart_clean_ms >= 10 * default_restart_backoff_ms[default_restart_backoff_ms.len - 1]);
}

// THE DECAY RULE ITSELF, on arithmetic alone: no clock, no threads, no module,
// so the answer is the same on an idle machine and on one running five builds.
test "the restart allowance comes back only after a clean run past the window" {
    const window: i64 = 5 * 60 * 1000;
    const now: i64 = 1_000_000;

    // Attempts spent, and up for twice the window: the fault in front of it is
    // a new bout of trouble and the plugin starts again from one.
    try t.expect(allowanceWhole(1, now - 2 * window, now, window));
    try t.expect(allowanceWhole(3, now - window, now, window));

    // A moment short of the window is the same bout of trouble.
    try t.expect(!allowanceWhole(2, now - window + 1, now, window));
    try t.expect(!allowanceWhole(2, now - 250, now, window));

    // Nothing spent, nothing to give back.
    try t.expect(!allowanceWhole(0, now - 2 * window, now, window));

    // An attempt in flight has no clean run behind it, whatever the clock
    // says. This is what stops a plugin that cannot come up at all from being
    // restarted for ever.
    try t.expect(!allowanceWhole(2, 0, now, window));

    // Switched off: the host does what it did before the counter decayed.
    try t.expect(!allowanceWhole(2, now - 2 * window, now, 0));
}
