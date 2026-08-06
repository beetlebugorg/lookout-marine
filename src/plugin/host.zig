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
    OutOfMemory,
};

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
/// `{"id":"org.beetlebug.ais","name":"AIS","abi":1,"capabilities":[...]}`.
pub const Manifest = struct {
    id: []u8,
    name: []u8,
    abi: u32,
    caps: broker.Caps,

    pub fn deinit(self: *Manifest, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.* = undefined;
    }
};

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
    return .{ .id = id_owned, .name = name_owned, .abi = abi, .caps = caps };
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

        const cfg = try self.startJson(manifest.id);
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
        });
        self.br.say(broker.level_info, manifest.id, "started ({s}, source {d})", .{ manifest.name, state.source });
        _ = dir_path;
    }

    fn ensureRuntime(self: *Host) !void {
        if (self.runtime_held) return;
        try runtimeAcquire();
        self.runtime_held = true;
    }

    /// `{"abi":1,"config":{...}}`. Only nmea0183 takes configuration in the
    /// prototype; everything else starts with an empty object, which is what a
    /// plugin with nothing to configure must accept.
    fn startJson(self: *Host, id: []const u8) ![]u8 {
        if (std.mem.endsWith(u8, id, "nmea0183")) {
            return std.fmt.allocPrint(
                self.alloc,
                "{{\"abi\":{d},\"config\":{{\"host\":\"{s}\",\"port\":{d}}}}}",
                .{ abi_version, self.opts.nmea_host, self.opts.nmea_port },
            );
        }
        return std.fmt.allocPrint(self.alloc, "{{\"abi\":{d},\"config\":{{}}}}", .{abi_version});
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

test "the start payload carries the ABI, and NMEA config only for nmea0183" {
    var vessels = try store.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(t.allocator);
    defer ais.deinit();
    var br = broker.Broker.init(t.allocator, &vessels, &ais, .{});
    defer br.deinit();
    var h = Host.init(t.allocator, &br, .{ .nmea_host = "10.0.0.4", .nmea_port = 2000 });
    defer h.deinit();

    const nmea = try h.startJson("org.beetlebug.nmea0183");
    defer t.allocator.free(nmea);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"host\":\"10.0.0.4\",\"port\":2000}}", nmea);

    const other = try h.startJson("org.beetlebug.ownship");
    defer t.allocator.free(other);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{}}", other);
}
