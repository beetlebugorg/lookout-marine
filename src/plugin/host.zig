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
//! A TRAPPED PLUGIN IS DISABLED, not retried. WAMR's exception text is logged,
//! the instance is left instantiated but never entered again, and everything
//! the plugin contributed — overlay objects, vessel paths, AIS targets,
//! sockets, timers, queued events — is dropped. A chartplotter that keeps
//! drawing the last position a crashed plugin published is worse than one that
//! draws nothing.

const std = @import("std");

pub const wasm = @import("wasm.zig");
pub const store = @import("store.zig");
pub const aisstore = @import("aisstore.zig");
pub const broker = @import("broker.zig");

const io = std.Io.Threaded.global_single_threaded.io();

/// The ABI version this host speaks. A module reporting anything else is not
/// loaded — the exports may have the same names and a different meaning.
pub const abi_version: u32 = 1;

/// Largest plugin module accepted. The prototype's plugins are tens of KiB;
/// the cap is here so a stray file in the plugin directory cannot be read into
/// memory whole.
pub const max_module_bytes: usize = 8 * 1024 * 1024;
pub const max_manifest_bytes: usize = 64 * 1024;

pub const Error = error{
    BadManifest,
    AbiMismatch,
    StartRefused,
    /// A plugin cannot be loaded once the dispatch threads are running: they
    /// hold pointers into the registry, which growing it would invalidate.
    AlreadyStarted,
    /// `configSet` named an id no plugin here answers to.
    UnknownPlugin,
    /// The config JSON is not an object, or a field it names does not match
    /// the kind the schema declares.
    BadConfig,
    OutOfMemory,
};

/// One settings field a manifest declares. A shell renders these; the plugin
/// receives their values and nothing else.
///
/// A number field is clamped to `min`..`max` on the way in, so a plugin never
/// has to defend against a setting outside the range it published.
pub const Field = struct {
    key: []u8,
    /// What the shell shows beside the control. Defaults to the key.
    label: []u8,
    /// The unit of a number field, for display only: values cross the ABI in
    /// the unit the schema names.
    unit: []u8,
    kind: Kind,
    min: f64 = 0,
    max: f64 = 0,
    /// A toggle's default is 0 or 1.
    default_value: f64 = 0,

    pub const Kind = enum { number, toggle };
};

/// Longest settings schema a manifest may declare. A pane a mariner has to
/// scroll past is a pane nobody reads at sea.
pub const max_fields = 16;

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

/// A plugin's manifest.json:
/// `{"id":"org.beetlebug.ais","name":"AIS","abi":1,"capabilities":[...],
///   "settings":[{"key":"cpa_limit","kind":"number","unit":"m","min":93,
///                "max":9260,"default":926}]}`.
pub const Manifest = struct {
    id: []u8,
    name: []u8,
    abi: u32,
    caps: broker.Caps,
    /// The settings schema, empty when the manifest declares none.
    settings: []Field = &.{},

    pub fn deinit(self: *Manifest, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        freeFields(alloc, self.settings, self.settings.len);
        self.* = undefined;
    }

    pub fn field(self: *const Manifest, key: []const u8) ?usize {
        for (self.settings, 0..) |f, i| {
            if (std.mem.eql(u8, f.key, key)) return i;
        }
        return null;
    }
};

/// One settings field out of a manifest. Everything the shell needs to draw a
/// control, and everything `configSet` needs to police one.
fn parseField(alloc: std.mem.Allocator, v: std.json.Value) !Field {
    if (v != .object) return Error.BadManifest;
    const o = v.object;
    const key = switch (o.get("key") orelse return Error.BadManifest) {
        .string => |s| s,
        else => return Error.BadManifest,
    };
    if (key.len == 0 or key.len > 32) return Error.BadManifest;
    const kind_text = switch (o.get("kind") orelse return Error.BadManifest) {
        .string => |s| s,
        else => return Error.BadManifest,
    };
    const kind = std.meta.stringToEnum(Field.Kind, kind_text) orelse return Error.BadManifest;
    const label = switch (o.get("label") orelse std.json.Value{ .string = key }) {
        .string => |s| s,
        else => key,
    };
    const unit = switch (o.get("unit") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };

    var f = Field{
        .key = try alloc.dupe(u8, key),
        .label = undefined,
        .unit = undefined,
        .kind = kind,
    };
    errdefer alloc.free(f.key);
    f.label = try alloc.dupe(u8, label);
    errdefer alloc.free(f.label);
    f.unit = try alloc.dupe(u8, unit);
    errdefer alloc.free(f.unit);

    switch (kind) {
        .number => {
            f.min = jsonNumber(o.get("min")) orelse return Error.BadManifest;
            f.max = jsonNumber(o.get("max")) orelse return Error.BadManifest;
            if (!(f.max > f.min)) return Error.BadManifest;
            const d = jsonNumber(o.get("default")) orelse return Error.BadManifest;
            f.default_value = std.math.clamp(d, f.min, f.max);
        },
        .toggle => {
            f.max = 1;
            f.default_value = switch (o.get("default") orelse return Error.BadManifest) {
                .bool => |b| if (b) 1 else 0,
                else => return Error.BadManifest,
            };
        },
    }
    return f;
}

fn jsonNumber(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |x| if (std.math.isFinite(x)) x else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Parse a manifest. Unknown capability names are refused rather than ignored:
/// a typo in a grant is a plugin that silently loses a permission at sea.
pub fn parseManifest(alloc: std.mem.Allocator, json: []const u8) !Manifest {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return Error.BadManifest;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.BadManifest;
    const o = parsed.value.object;

    const id = switch (o.get("id") orelse return Error.BadManifest) {
        .string => |s| s,
        else => return Error.BadManifest,
    };
    if (id.len == 0 or id.len > 128) return Error.BadManifest;
    const name = switch (o.get("name") orelse std.json.Value{ .string = id }) {
        .string => |s| s,
        else => id,
    };
    const abi: u32 = switch (o.get("abi") orelse return Error.BadManifest) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return Error.BadManifest,
        else => return Error.BadManifest,
    };

    var caps = broker.Caps.initEmpty();
    if (o.get("capabilities")) |c| {
        if (c != .array) return Error.BadManifest;
        for (c.array.items) |item| {
            const text = switch (item) {
                .string => |s| s,
                else => return Error.BadManifest,
            };
            caps.insert(broker.Cap.fromName(text) orelse return Error.BadManifest);
        }
    }

    const id_owned = try alloc.dupe(u8, id);
    errdefer alloc.free(id_owned);
    const name_owned = try alloc.dupe(u8, name);
    errdefer alloc.free(name_owned);

    // `built` counts the fields already allocated, so a malformed field
    // halfway down the schema frees exactly the ones before it.
    var fields: []Field = &.{};
    var built: usize = 0;
    errdefer freeFields(alloc, fields, built);
    if (o.get("settings")) |sv| {
        if (sv != .array) return Error.BadManifest;
        if (sv.array.items.len > max_fields) return Error.BadManifest;
        fields = try alloc.alloc(Field, sv.array.items.len);
        for (sv.array.items) |item| {
            fields[built] = try parseField(alloc, item);
            built += 1;
            // Two fields with one key would give the shell two controls over
            // the same value.
            for (fields[0 .. built - 1]) |g| {
                if (std.mem.eql(u8, g.key, fields[built - 1].key)) return Error.BadManifest;
            }
        }
    }
    return .{
        .id = id_owned,
        .name = name_owned,
        .abi = abi,
        .caps = caps,
        .settings = fields,
    };
}

fn freeFields(alloc: std.mem.Allocator, fields: []Field, built: usize) void {
    for (fields[0..built]) |f| {
        alloc.free(f.key);
        alloc.free(f.label);
        alloc.free(f.unit);
    }
    if (fields.len > 0) alloc.free(fields);
}

/// One loaded plugin, and the thread that runs it.
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
    /// clean-up runs exactly once whichever path reaches it.
    retired: std.atomic.Value(bool) = .init(false),

    pub fn isLive(self: *const Entry) bool {
        return self.live.load(.acquire);
    }
};

pub const Options = struct {
    /// `LOOKOUT_NMEA=host:port`, passed to the nmea0183 plugin's config.
    nmea_host: []const u8 = "127.0.0.1",
    nmea_port: u16 = 10110,
    limits: wasm.Limits = .{},
    /// How long `stop` waits for SHUTDOWN to reach every plugin before the
    /// dispatch threads are torn down anyway. Best effort by contract: a plugin
    /// stuck in a loop must not stop the app from closing.
    shutdown_ms: u32 = 500,
    /// The watchdog's budget for one module call. See
    /// `default_event_budget_ms`.
    event_budget_ms: i64 = default_event_budget_ms,
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
    }
    runtime_refs += 1;
}

fn runtimeRelease() void {
    runtime_mu.lock();
    defer runtime_mu.unlock();
    if (runtime_refs == 0) return;
    runtime_refs -= 1;
    if (runtime_refs != 0) return;
    broker.unregisterNatives();
    wasm.deinitRuntime();
}

pub const Host = struct {
    alloc: std.mem.Allocator,
    br: *broker.Broker,
    opts: Options,
    entries: std.ArrayList(Entry) = .empty,
    /// True between `start` and `stop`, while the dispatch threads exist.
    started: bool = false,
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
        for (self.entries.items) |*e| {
            e.inst.deinit();
            e.module.deinit();
            self.alloc.free(e.bytes);
            if (e.values.len > 0) self.alloc.free(e.values);
            e.manifest.deinit(self.alloc);
            self.alloc.destroy(e.state);
        }
        self.entries.deinit(self.alloc);
        if (self.runtime_held) {
            runtimeRelease();
            self.runtime_held = false;
        }
        self.* = undefined;
    }

    pub fn count(self: *const Host) usize {
        return self.entries.items.len;
    }

    /// The plugin state by manifest id, for the harness and the tests.
    pub fn find(self: *Host, id: []const u8) ?*broker.Plugin {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.manifest.id, id)) return e.state;
        }
        return null;
    }

    // -- loading -------------------------------------------------------------

    /// Load every plugin in `dir`: each is a `<id>.manifest.json` and the
    /// `<id>.wasm` beside it, which is what `zig build plugins` installs. A
    /// plugin that fails to load is logged and skipped — one bad module must
    /// not take the others down with it.
    ///
    /// Load order is the sorted file order, and load order IS source priority
    /// in the vessel store, so it is deterministic across machines.
    pub fn loadDir(self: *Host, dir_path: []const u8) !void {
        // The dispatch threads hold pointers into `entries`; appending to it
        // now could move them. Load first, then start.
        if (self.started) return Error.AlreadyStarted;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
            self.br.say(broker.level_warn, "host", "plugins: cannot open {s}: {s}", .{ dir_path, @errorName(e) });
            return e;
        };
        defer dir.close(io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (try it.next(io)) |ent| {
            if (ent.kind == .directory) continue;
            if (!std.mem.endsWith(u8, ent.name, manifest_suffix)) continue;
            try names.append(self.alloc, try self.alloc.dupe(u8, ent.name));
        }
        std.mem.sort([]u8, names.items, {}, lessName);

        for (names.items) |n| {
            const stem = n[0 .. n.len - manifest_suffix.len];
            self.loadOne(dir, dir_path, stem, n) catch |e| {
                self.br.say(broker.level_err, "host", "plugins: {s} not loaded: {s}", .{ stem, @errorName(e) });
            };
        }
    }

    const manifest_suffix = ".manifest.json";

    fn loadOne(self: *Host, dir: std.Io.Dir, dir_path: []const u8, stem: []const u8, manifest_name: []const u8) !void {
        const manifest_text = try dir.readFileAlloc(io, manifest_name, self.alloc, .limited(max_manifest_bytes));
        defer self.alloc.free(manifest_text);
        var manifest = try parseManifest(self.alloc, manifest_text);
        errdefer manifest.deinit(self.alloc);
        if (manifest.abi != abi_version) return Error.AbiMismatch;

        // Every setting starts at its schema default. A shell that has one
        // saved sends it with `configSet` once the plugin is up.
        const values = try self.alloc.alloc(f64, manifest.settings.len);
        errdefer if (values.len > 0) self.alloc.free(values);
        for (manifest.settings, values) |f, *v| v.* = f.default_value;

        const wasm_name = try std.fmt.allocPrint(self.alloc, "{s}.wasm", .{stem});
        defer self.alloc.free(wasm_name);
        const raw = try dir.readFileAlloc(io, wasm_name, self.alloc, .limited(max_module_bytes));
        defer self.alloc.free(raw);

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
            .caps = manifest.caps,
        };
        inst.setUserData(state);

        const reported = try inst.abiVersion();
        if (reported != abi_version) {
            self.br.say(broker.level_err, manifest.id, "lk_abi reported {d}, host speaks {d}", .{ reported, abi_version });
            return Error.AbiMismatch;
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

        const cfg = try self.startJson(&manifest, values);
        defer self.alloc.free(cfg);
        const rc = inst.start(cfg) catch |e| {
            self.reportTrap(&inst, manifest.id, "lk_start");
            return e;
        };
        if (rc != 0) {
            self.br.say(broker.level_err, manifest.id, "lk_start refused with {d}", .{rc});
            return Error.StartRefused;
        }

        self.next_source += 1;
        try self.entries.append(self.alloc, .{
            .manifest = manifest,
            .bytes = bytes,
            .module = module,
            .inst = inst,
            .state = state,
            .values = values,
        });
        self.br.say(broker.level_info, manifest.id, "started ({s}, source {d})", .{ manifest.name, state.source });
        _ = dir_path;
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
    fn startJson(self: *Host, manifest: *const Manifest, values: []const f64) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try out.print(self.alloc, "{{\"abi\":{d},\"config\":{{", .{abi_version});
        var first = true;
        if (std.mem.endsWith(u8, manifest.id, "nmea0183")) {
            try out.print(self.alloc, "\"host\":\"{s}\",\"port\":{d}", .{ self.opts.nmea_host, self.opts.nmea_port });
            first = false;
        }
        try writeSettings(&out, self.alloc, manifest.settings, values, first);
        try out.appendSlice(self.alloc, "}}");
        return out.toOwnedSlice(self.alloc);
    }

    // -- settings --------------------------------------------------------------

    fn entryFor(self: *Host, id: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.manifest.id, id)) return e;
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
        try writeSettings(out, self.alloc, e.manifest.settings, e.values, true);
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

        {
            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch
                return Error.BadConfig;
            defer parsed.deinit();
            if (parsed.value != .object) return Error.BadConfig;

            self.cfg_mu.lock();
            defer self.cfg_mu.unlock();
            const e = self.entryFor(id) orelse return Error.UnknownPlugin;
            if (e.manifest.settings.len == 0) return Error.BadConfig;
            index = e.state.index;

            var it = parsed.value.object.iterator();
            while (it.next()) |kv| {
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
                }
            }
            try payload.append(self.alloc, '{');
            try writeSettings(&payload, self.alloc, e.manifest.settings, e.values, true);
            try payload.append(self.alloc, '}');
        }

        self.br.push(index, broker.Kind.config_changed, 0, payload.items);
        self.br.say(broker.level_info, id, "config {s}", .{payload.items});
    }

    /// Every loaded plugin, its state, its status line, and its settings
    /// schema with the value in force. This is what a shell reads to draw a
    /// settings pane; it never has to know what a plugin is for.
    pub fn registryJson(self: *Host, out: *std.ArrayList(u8)) !void {
        self.cfg_mu.lock();
        defer self.cfg_mu.unlock();
        const alloc = self.alloc;
        try out.appendSlice(alloc, "{\"plugins\":[");
        for (self.entries.items, 0..) |*e, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"id\":");
            try writeJsonString(out, alloc, e.manifest.id);
            try out.appendSlice(alloc, ",\"name\":");
            try writeJsonString(out, alloc, e.manifest.name);
            try out.print(alloc, ",\"live\":{s}", .{if (e.isLive()) "true" else "false"});
            // The status line is a string, not an object: it is text a plugin
            // wrote, and the shell decides what to do with it.
            try out.appendSlice(alloc, ",\"status\":");
            try writeJsonString(out, alloc, e.state.status());
            try out.appendSlice(alloc, ",\"settings\":[");
            for (e.manifest.settings, e.values, 0..) |f, v, k| {
                if (k > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, "{\"key\":");
                try writeJsonString(out, alloc, f.key);
                try out.appendSlice(alloc, ",\"label\":");
                try writeJsonString(out, alloc, f.label);
                try out.print(alloc, ",\"kind\":\"{s}\"", .{@tagName(f.kind)});
                if (f.unit.len > 0) {
                    try out.appendSlice(alloc, ",\"unit\":");
                    try writeJsonString(out, alloc, f.unit);
                }
                switch (f.kind) {
                    .number => try out.print(alloc, ",\"min\":{d},\"max\":{d},\"default\":{d},\"value\":{d}", .{
                        f.min, f.max, f.default_value, v,
                    }),
                    .toggle => try out.print(alloc, ",\"default\":{s},\"value\":{s}", .{
                        boolText(f.default_value), boolText(v),
                    }),
                }
                try out.append(alloc, '}');
            }
            try out.appendSlice(alloc, "]}");
        }
        try out.appendSlice(alloc, "]}");
    }

    // -- the event loop ------------------------------------------------------

    /// Start the broker's I/O thread, arm the watchdog, and give every live
    /// plugin its own dispatch thread. Call after `loadDir`: `lk_start` runs on
    /// the caller's thread, and nothing should be delivering events while it
    /// does.
    pub fn start(self: *Host) !void {
        if (self.started) return;
        // Armed before the I/O thread exists, so the first tick already has it.
        self.br.setWatchdog(self, watchdogTick);
        try self.br.start();
        self.started = true;
        for (self.entries.items, 0..) |*e, i| {
            if (!e.isLive()) continue;
            e.stopping.store(false, .release);
            e.thread = std.Thread.spawn(
                .{ .stack_size = dispatch_stack_bytes },
                dispatchMain,
                .{ self, @as(u32, @intCast(i)) },
            ) catch |err| {
                // No thread means no events, ever. Better a plugin that is
                // visibly gone than one that is silently deaf.
                self.br.say(broker.level_err, e.manifest.id, "no dispatch thread: {s}", .{@errorName(err)});
                self.retire(@intCast(i), true, "no dispatch thread");
                continue;
            };
        }
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
            for (self.entries.items, 0..) |*e, i| {
                if (e.isLive()) self.deliverTo(@intCast(i), broker.Kind.shutdown, 0, "");
            }
            self.br.stop();
            return;
        }

        for (self.entries.items, 0..) |*e, i| {
            if (e.isLive()) self.br.push(@intCast(i), broker.Kind.shutdown, 0, "");
        }
        var waited: u32 = 0;
        while (self.br.queued() > 0 and waited < self.opts.shutdown_ms) : (waited += 2) {
            broker.sleepMs(2);
        }

        for (self.entries.items) |*e| e.stopping.store(true, .release);
        var grace: u32 = 0;
        while (grace < shutdown_grace_ms and self.anyInModule()) : (grace += 2) broker.sleepMs(2);
        for (self.entries.items) |*e| {
            if (e.thread == null or e.entered_ms.load(.acquire) == 0) continue;
            self.br.say(broker.level_warn, e.manifest.id, "still inside the module at shutdown; terminating", .{});
            e.inst.terminate();
        }
        for (self.entries.items) |*e| {
            if (e.thread) |th| {
                th.join();
                e.thread = null;
            }
        }
        self.started = false;
        self.br.stop();
    }

    fn anyInModule(self: *Host) bool {
        for (self.entries.items) |*e| {
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

    /// One plugin's dispatch thread: its queue, its instance, nobody else's.
    fn dispatchMain(self: *Host, index: u32) void {
        const e = &self.entries.items[index];
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
                break;
            }
            const ev = self.br.popFor(index) orelse {
                broker.sleepMs(idle_ms);
                if (idle_ms < 8) idle_ms *= 2;
                continue;
            };
            idle_ms = 1;
            defer self.br.freeEvent(ev);
            self.deliverTo(index, ev.kind, ev.handle, ev.payload);
        }
        // Anything still queued belongs to nobody now.
        self.br.clearQueue(index);
    }

    fn deliverTo(self: *Host, index: u32, kind: u32, handle: u64, payload: []const u8) void {
        if (index >= self.entries.items.len) return;
        const e = &self.entries.items[index];
        if (!e.isLive()) return;
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
        const e = &self.entries.items[index];
        e.inst.clearException();
        var buf: [max_reason]u8 = undefined;
        const reason = std.fmt.bufPrint(
            &buf,
            "stuck in lk_event (terminated after {d} ms)",
            .{e.killed_ms.load(.acquire)},
        ) catch "stuck in lk_event";
        self.retire(index, true, reason);
    }

    /// Take a plugin out of service and erase everything it contributed:
    /// overlay objects, published values, AIS targets, sockets, timers and
    /// whatever was still queued. `fault` distinguishes a plugin that broke —
    /// logged as an error, status line replaced with the reason — from one that
    /// was shut down, which keeps whatever it last said about itself.
    fn retire(self: *Host, index: u32, fault: bool, reason: []const u8) void {
        const e = &self.entries.items[index];
        e.live.store(false, .release);
        if (e.retired.swap(true, .acq_rel)) return;
        if (fault) {
            // The reason goes into a JSON status line, and part of it is text
            // WAMR wrote, so quotes, backslashes and control bytes are folded
            // to spaces rather than escaped: this is a one-line status, not a
            // document, and it must not be able to break the shape.
            var safe: [max_reason]u8 = undefined;
            const n = @min(reason.len, safe.len);
            for (reason[0..n], 0..) |ch, i| safe[i] = switch (ch) {
                '"', '\\', 0...31, 127 => ' ',
                else => ch,
            };
            var buf: [broker.max_status]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{{\"state\":\"disabled\",\"detail\":\"{s}\"}}", .{safe[0..n]}) catch "{\"state\":\"disabled\"}";
            _ = e.state.setStatus(line);
            self.br.say(broker.level_err, e.manifest.id, "disabled: {s}; overlays and published values cleared", .{safe[0..n]});
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
        for (self.entries.items) |*e| {
            if (!e.isLive()) continue;
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

fn boolText(v: f64) []const u8 {
    return if (v != 0) "true" else "false";
}

/// `"key":value` for each field, comma-separated. `first` says whether the
/// object it is going into is still empty.
fn writeSettings(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    fields: []const Field,
    values: []const f64,
    first: bool,
) !void {
    var lead = first;
    for (fields, values) |f, v| {
        if (!lead) try out.append(alloc, ',');
        lead = false;
        try writeJsonString(out, alloc, f.key);
        switch (f.kind) {
            .number => try out.print(alloc, ":{d}", .{v}),
            .toggle => try out.print(alloc, ":{s}", .{boolText(v)}),
        }
    }
}

/// A quoted, escaped JSON string. A manifest is a file on disk and a status
/// line is text a plugin wrote; neither may break the shape of what it lands
/// in.
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

// ---- tests -------------------------------------------------------------------

const t = std.testing;

test "a manifest parses id, name, abi and the granted capabilities" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.ais","name":"AIS targets","abi":1,
        \\ "capabilities":["ais.read","overlay.draw","alerts.raise"]}
    );
    defer m.deinit(a);
    try t.expectEqualStrings("org.beetlebug.ais", m.id);
    try t.expectEqualStrings("AIS targets", m.name);
    try t.expectEqual(@as(u32, 1), m.abi);
    try t.expect(m.caps.contains(.ais_read));
    try t.expect(m.caps.contains(.overlay_draw));
    try t.expect(m.caps.contains(.alerts_raise));
    try t.expect(!m.caps.contains(.vessel_publish));
    try t.expect(!m.caps.contains(.net_tcp_client));
}

test "a manifest with no capabilities grants nothing, and name defaults to id" {
    const a = t.allocator;
    var m = try parseManifest(a, "{\"id\":\"org.beetlebug.quiet\",\"abi\":1}");
    defer m.deinit(a);
    try t.expectEqualStrings("org.beetlebug.quiet", m.name);
    try t.expectEqual(@as(usize, 0), m.caps.count());
}

test "a manifest is refused rather than half-read" {
    const a = t.allocator;
    try t.expectError(Error.BadManifest, parseManifest(a, "not json"));
    try t.expectError(Error.BadManifest, parseManifest(a, "[]"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"abi\":1}"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\"}"));
    // An unknown capability is a typo in a grant, so the plugin does not load.
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"net.udp\"]}"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"abi\":1,\"capabilities\":\"vessel.read\"}"));
}

const ais_settings_manifest =
    \\{"id":"org.beetlebug.ais","name":"AIS targets","abi":1,
    \\ "capabilities":["ais.read"],
    \\ "settings":[
    \\  {"key":"cpa_limit","label":"CPA limit","kind":"number","unit":"m","min":93,"max":9260,"default":926},
    \\  {"key":"cpa_alarm","label":"Collision alarm","kind":"toggle","default":true}]}
;

test "the start payload carries the ABI, and NMEA config only for nmea0183" {
    var vessels = try store.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(t.allocator);
    defer ais.deinit();
    var br = broker.Broker.init(t.allocator, &vessels, &ais, .{});
    defer br.deinit();
    var h = Host.init(t.allocator, &br, .{ .nmea_host = "10.0.0.4", .nmea_port = 2000 });
    defer h.deinit();

    var nm = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.nmea0183\",\"abi\":1}");
    defer nm.deinit(t.allocator);
    const nmea = try h.startJson(&nm, &.{});
    defer t.allocator.free(nmea);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"host\":\"10.0.0.4\",\"port\":2000}}", nmea);

    var om = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.ownship\",\"abi\":1}");
    defer om.deinit(t.allocator);
    const other = try h.startJson(&om, &.{});
    defer t.allocator.free(other);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{}}", other);

    // A plugin with a schema starts on its defaults, in the same shape
    // CONFIG_CHANGED later carries.
    var am = try parseManifest(t.allocator, ais_settings_manifest);
    defer am.deinit(t.allocator);
    const with = try h.startJson(&am, &.{ 926, 1 });
    defer t.allocator.free(with);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"cpa_limit\":926,\"cpa_alarm\":true}}", with);
}

test "a settings schema parses, and a malformed field refuses the manifest" {
    const a = t.allocator;
    var m = try parseManifest(a, ais_settings_manifest);
    defer m.deinit(a);
    try t.expectEqual(@as(usize, 2), m.settings.len);
    try t.expectEqualStrings("cpa_limit", m.settings[0].key);
    try t.expectEqualStrings("CPA limit", m.settings[0].label);
    try t.expectEqualStrings("m", m.settings[0].unit);
    try t.expectEqual(Field.Kind.number, m.settings[0].kind);
    try t.expectEqual(@as(f64, 93), m.settings[0].min);
    try t.expectEqual(@as(f64, 9260), m.settings[0].max);
    try t.expectEqual(@as(f64, 926), m.settings[0].default_value);
    try t.expectEqual(Field.Kind.toggle, m.settings[1].kind);
    try t.expectEqual(@as(f64, 1), m.settings[1].default_value);
    try t.expectEqual(@as(usize, 1), m.field("cpa_alarm").?);
    try t.expect(m.field("nothing") == null);

    // A field with no kind, an unknown kind, a range that is not one, a
    // toggle whose default is a number, and two fields sharing a key.
    const bad = [_][]const u8{
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\"}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"slider\",\"default\":1}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"number\",\"min\":5,\"max\":5,\"default\":5}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"number\",\"min\":0,\"max\":5}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"toggle\",\"default\":1}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"toggle\",\"default\":true}," ++
            "{\"key\":\"a\",\"kind\":\"toggle\",\"default\":false}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":{}}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));

    // A default outside the range it declares is clamped, not refused.
    var clamped = try parseManifest(a,
        \\{"id":"x","abi":1,"settings":[{"key":"a","kind":"number","min":1,"max":10,"default":99}]}
    );
    defer clamped.deinit(a);
    try t.expectEqual(@as(f64, 10), clamped.settings[0].default_value);
}
