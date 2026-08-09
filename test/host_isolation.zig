//! TIME ISOLATION, end to end: two real .wasm plugins, the real WAMR embedding,
//! the real broker and the real registry, one of which stops answering.
//!
//! What this proves, in one run: while test/spin_plugin.zig sits in an endless
//! loop inside `lk_event`, plugins/echo keeps receiving and finishing events;
//! the watchdog terminates the spinner within its budget and not before; the
//! spinner's overlay objects go and echo's stay; echo goes on working after the
//! kill; and no ordinary event of echo's ever trips the watchdog.
//!
//! Kept out of src/plugin/ for the same reason test/host_smoke.zig is: the
//! .wasm modules arrive as anonymous imports only a test root declares.

const std = @import("std");
const host = @import("host");
const overlay = @import("overlay");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const echo_wasm = @embedFile("echo_plugin_wasm");
const echo_manifest = @embedFile("echo_manifest");
const spin_wasm = @embedFile("spin_plugin_wasm");

const echo_id = "org.beetlebug.echo";
const spin_id = "org.beetlebug.spin";

/// The spinner asks for nothing but the overlay: `log`, `chrome_status` and
/// timers are ungated, so this is every grant it needs to draw one symbol.
const spin_manifest =
    \\{"id":"org.beetlebug.spin","name":"Spinner","api":1,"capabilities":["overlay.draw"]}
;

/// The timer ids test/spin_plugin.zig treats as "stop returning", "trap now"
/// and "allocate until the host refuses".
const trigger_timer_id: u64 = 424242;
const trap_timer_id: u64 = 424243;
const hog_timer_id: u64 = 424244;

/// One synthetic STORE_CHANGED, the shape the fanout tick builds. Echo answers
/// each one with a log line naming the path's age, which is how this test
/// counts events that ran to the END of the handler rather than merely arrived.
const position_event =
    \\{"values":[{"path":"navigation.position","value":{"lat":38.98,"lon":-76.47},"ts":1000,"age_ms":120}]}
;
const echo_handled = "navigation.position age";

const io = std.Io.Threaded.global_single_threaded.io();

const LogSink = struct {
    text: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,
    mu: vstore.Lock = .{},

    fn write(ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void {
        const self: *LogSink = @ptrCast(@alignCast(ctx.?));
        self.mu.lock();
        defer self.mu.unlock();
        self.text.print(self.alloc, "{d}|{s}|{s}\n", .{ level, plugin, msg }) catch {};
    }

    fn has(self: *LogSink, needle: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return std.mem.indexOf(u8, self.text.items, needle) != null;
    }

    fn count(self: *LogSink, needle: []const u8) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var n: usize = 0;
        var rest: []const u8 = self.text.items;
        while (std.mem.indexOf(u8, rest, needle)) |i| {
            n += 1;
            rest = rest[i + needle.len ..];
        }
        return n;
    }
};

const OvSink = struct {
    fn apply(ctx: ?*anyopaque, source: []const u8, json: []const u8) anyerror!void {
        const s: *overlay.Store = @ptrCast(@alignCast(ctx.?));
        return s.applyBatch(source, json);
    }
    fn remove(ctx: ?*anyopaque, source: []const u8) void {
        const s: *overlay.Store = @ptrCast(@alignCast(ctx.?));
        s.removeSource(source);
    }
};

/// The overlay store's own lock, because the dispatch threads write it while
/// the test reads it.
fn hasObject(ov: *overlay.Store, id: []const u8) bool {
    ov.mu.lock();
    defer ov.mu.unlock();
    return ov.objs.contains(id);
}

/// The pairs `zig build plugins` installs, for both plugins, in a scratch
/// directory. Load order is sorted file order, so echo is index 0 and the
/// spinner index 1.
fn stage(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = echo_id ++ ".wasm", .data = echo_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = echo_id ++ ".manifest.json", .data = echo_manifest });
    try tmp.dir.writeFile(io, .{ .sub_path = spin_id ++ ".wasm", .data = spin_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = spin_id ++ ".manifest.json", .data = spin_manifest });
    return std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

/// Wait for `pred` up to `timeout_ms`, polling every 5 ms. Returns how long it
/// took, or an error if it never came true.
fn waitFor(timeout_ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !u32 {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (pred(ctx)) return waited;
        broker.sleepMs(5);
    }
    return error.TimedOut;
}

test "a plugin stuck in a loop is terminated, and only that plugin stops" {
    const alloc = std.testing.allocator;
    const test_started = broker.monoMs();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);
    // Echo is fed an event every 20 ms below and logs one line for each, so
    // the count of those lines is the proof its dispatch thread kept running
    // while its neighbour was wedged. Fifty lines a second is far over the
    // shipped log budget, which would drop most of them and read here as a
    // plugin that stopped, so this test lifts the ceiling. The log budget is
    // proved where it belongs, in broker.zig's own tests.
    br.budgets.log_lines_per_s = 1_000_000;

    // The shipped watchdog budget, not a shortened one: what this test proves
    // is what the host does by default.
    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();
    const budget = h.opts.event_budget_ms;
    try std.testing.expectEqual(host.default_event_budget_ms, budget);

    try h.loadDir(dir_path);
    try std.testing.expectEqual(@as(usize, 2), h.count());
    const echo = h.find(echo_id) orelse return error.EchoNotLoaded;
    const spin = h.find(spin_id) orelse return error.SpinNotLoaded;
    try std.testing.expectEqual(@as(u32, 0), echo.index);
    try std.testing.expectEqual(@as(u32, 1), spin.index);

    try h.start();

    // (a) Both plugins are enabled and both are processing events. Each has its
    //     own thread and its own queue, so the two runs of events interleave.
    for (0..5) |_| {
        br.push(echo.index, broker.Kind.store_changed, 0, position_event);
        br.push(spin.index, broker.Kind.store_changed, 0, position_event);
    }
    _ = try waitFor(2_000, &sink, struct {
        fn f(s: *LogSink) bool {
            return s.count(echo_handled) >= 5 and s.count("spin saw 1 value(s)") >= 5;
        }
    }.f);
    try std.testing.expect(echo.enabled);
    try std.testing.expect(spin.enabled);
    // Both have drawn: the spinner's symbol is what has to disappear later.
    try std.testing.expect(hasObject(&ov, echo_id ++ "/echo"));
    try std.testing.expect(hasObject(&ov, spin_id ++ "/spin"));

    // (b) The spinner is triggered and never returns from lk_event again.
    const echo_at_trigger = sink.count(echo_handled);
    const triggered_ms = broker.monoMs();
    br.push(spin.index, broker.Kind.timer, trigger_timer_id, "");
    _ = try waitFor(2_000, &sink, struct {
        fn f(s: *LogSink) bool {
            return s.has("spinning forever from timer");
        }
    }.f);

    // (c) While it is stuck, echo keeps receiving AND finishing events. They
    //     are pushed from here every 20 ms, so what is being measured is the
    //     other plugin's dispatch thread running while this one is wedged. The
    //     loop ends the moment the spinner's overlay object goes, which is the
    //     last step of the disable path.
    const half_budget: u32 = @intCast(@divTrunc(budget, 2));
    var stuck_ms: u32 = 0;
    while (hasObject(&ov, spin_id ++ "/spin") and stuck_ms < 5_000) : (stuck_ms += 20) {
        br.push(echo.index, broker.Kind.store_changed, 0, position_event);
        // Halfway to the budget the watchdog must NOT have fired yet: a plugin
        // is allowed all of its budget before anybody touches it.
        if (stuck_ms == half_budget) try std.testing.expect(spin.enabled);
        broker.sleepMs(20);
    }
    const disabled_ms = broker.monoMs() - triggered_ms;
    const echo_during = sink.count(echo_handled) - echo_at_trigger;
    try std.testing.expect(echo_during >= 10);
    try std.testing.expect(echo.enabled);

    // (d) The watchdog waited its budget, then killed inside two ticks of the
    //     I/O loop — the tick is what sets the precision — and said why.
    try std.testing.expect(disabled_ms >= budget);
    // The 200 ms on top is scheduling slack: the kill is at a tick boundary,
    // and this thread has to be scheduled to see it. Measured: about 1.1 s.
    try std.testing.expect(disabled_ms <= budget + 2 * broker.tick_ms + 200);
    try std.testing.expect(!spin.enabled);
    try std.testing.expect(sink.has("stuck in lk_event (terminated after "));
    // The reason reaches the status line, which is what chrome would show.
    try std.testing.expect(std.mem.indexOf(u8, spin.status(), "disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, spin.status(), "stuck in lk_event") != null);
    // ...and everything it drew is gone, while echo's is untouched.
    try std.testing.expect(!hasObject(&ov, spin_id ++ "/spin"));
    try std.testing.expect(hasObject(&ov, echo_id ++ "/echo"));

    // (e) Echo still works after the kill.
    const echo_after_kill = sink.count(echo_handled);
    for (0..5) |_| br.push(echo.index, broker.Kind.store_changed, 0, position_event);
    var waited: u32 = 0;
    while (sink.count(echo_handled) < echo_after_kill + 5 and waited < 2_000) : (waited += 5) {
        broker.sleepMs(5);
    }
    try std.testing.expect(sink.count(echo_handled) >= echo_after_kill + 5);
    try std.testing.expect(echo.enabled);

    // The watchdog is not a timeout on being busy: echo ran hundreds of events,
    // including a periodic timer, and was never once accused of overrunning.
    try std.testing.expect(!sink.has("|" ++ echo_id ++ "|over the "));
    try std.testing.expect(!sink.has("|" ++ echo_id ++ "|disabled"));
    try std.testing.expect(!sink.has("|" ++ echo_id ++ "|lk_event trapped"));

    h.stop();
    // The whole scenario, well inside the ten seconds the phase gate allows.
    try std.testing.expect(broker.monoMs() - test_started < 10_000);
}

// Closing the app while a plugin is wedged. `stop` joins every dispatch
// thread, and a thread inside an endless loop cannot be joined, so it
// terminates whatever is still in the module first. Without that this test does
// not fail — it hangs, which is exactly what a mariner closing the chart would
// see.
test "shutdown does not wait on a plugin that is still spinning" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);

    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();
    try h.loadDir(dir_path);
    const spin = h.find(spin_id) orelse return error.SpinNotLoaded;
    try h.start();

    br.push(spin.index, broker.Kind.timer, trigger_timer_id, "");
    _ = try waitFor(2_000, &sink, struct {
        fn f(s: *LogSink) bool {
            return s.has("spinning forever from timer");
        }
    }.f);

    // Straight into shutdown, before the watchdog's budget is anywhere near up.
    const stopping_at = broker.monoMs();
    h.stop();
    const took = broker.monoMs() - stopping_at;
    // shutdown_ms of draining, then the grace period, then the join.
    try std.testing.expect(took < 3_000);
    try std.testing.expect(!hasObject(&ov, spin_id ++ "/spin"));
}

// MEMORY ISOLATION, the budget rather than the watchdog. A plugin that
// allocates without bound is not stuck and does not trap, so nothing above
// catches it: what stops it is the per-plugin ceiling on linear memory. The
// allocation fails, the plugin is told, it keeps running, and the refusal is
// on its status line — a plugin that cannot tell it hit a budget is reported
// as slow rather than fixed.
test "a plugin that allocates without bound is refused at the memory budget" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);

    // The shipped ceiling, not a shortened one.
    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();
    try std.testing.expectEqual(broker.max_memory_pages, h.opts.limits.max_memory_pages);
    try std.testing.expectEqual(@as(i64, 64 * 1024 * 1024), broker.max_memory_bytes);

    try h.loadDir(dir_path);
    const echo = h.find(echo_id) orelse return error.EchoNotLoaded;
    const spin = h.find(spin_id) orelse return error.SpinNotLoaded;
    try h.start();

    br.push(spin.index, broker.Kind.timer, hog_timer_id, "");
    _ = try waitFor(5_000, &sink, struct {
        fn f(s: *LogSink) bool {
            return s.has("out of memory after ");
        }
    }.f);

    // The host said which budget it was, with the ceiling in it.
    try std.testing.expect(sink.has("refused at the 64 MiB linear-memory budget"));
    // The plugin saw the failure itself: it got some memory and then an error,
    // rather than a trap or a silent zero.
    try std.testing.expect(!sink.has("out of memory after 0 MiB"));
    // It is still running. A budget is not a kill.
    try std.testing.expect(spin.enabled);
    try std.testing.expect(!sink.has("lk_event trapped"));
    try std.testing.expect(!sink.has("stuck in lk_event"));
    // ...and its own status line names the budget beside its own words.
    try std.testing.expect(std.mem.indexOf(u8, spin.status(), "\"budget\":\"memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spin.status(), "out of memory after ") != null);

    // The neighbour never noticed.
    br.push(echo.index, broker.Kind.store_changed, 0, position_event);
    _ = try waitFor(2_000, &sink, struct {
        fn f(s: *LogSink) bool {
            return s.count(echo_handled) >= 1;
        }
    }.f);
    try std.testing.expect(echo.enabled);
    try std.testing.expect(std.mem.indexOf(u8, echo.status(), "budget") == null);

    h.stop();
}

// The watchdog message must not swallow the ordinary one. A plugin that traps
// on its own — the case the host has handled since Phase 2 — has to keep WAMR's
// text for what it actually did, or every fault in the field reads as "stuck".
test "a plugin that traps on its own is disabled with its own exception text" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try stage(alloc, &tmp);
    defer alloc.free(dir_path);

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var ov = overlay.Store.init(alloc);
    defer ov.deinit();
    var sink = LogSink{ .alloc = alloc };
    defer sink.text.deinit(alloc);

    var br = broker.Broker.init(alloc, &vessels, &ais, .{
        .ctx = &ov,
        .applyFn = OvSink.apply,
        .removeFn = OvSink.remove,
    });
    defer br.deinit();
    br.setLog(&sink, LogSink.write);

    var h = host.Host.init(alloc, &br, .{});
    defer h.deinit();
    try h.loadDir(dir_path);
    const echo = h.find(echo_id) orelse return error.EchoNotLoaded;
    const spin = h.find(spin_id) orelse return error.SpinNotLoaded;
    try h.start();

    const trapped_at = broker.monoMs();
    br.push(spin.index, broker.Kind.timer, trap_timer_id, "");
    var waited: u32 = 0;
    while (hasObject(&ov, spin_id ++ "/spin") and waited < 2_000) : (waited += 5) broker.sleepMs(5);

    // Straight away — no budget to wait out, because nothing overran.
    try std.testing.expect(broker.monoMs() - trapped_at < 1_000);
    try std.testing.expect(!spin.enabled);
    try std.testing.expect(sink.has("lk_event trapped: "));
    try std.testing.expect(sink.has("unreachable"));
    // The watchdog was not involved, and does not get the credit.
    try std.testing.expect(!sink.has("stuck in lk_event"));
    try std.testing.expect(!sink.has("over the "));
    try std.testing.expect(std.mem.indexOf(u8, spin.status(), "unreachable") != null);

    // Echo is untouched, as it was for the watchdog kill.
    br.push(echo.index, broker.Kind.store_changed, 0, position_event);
    _ = try waitFor(2_000, &sink, struct {
        fn f(s: *LogSink) bool {
            return s.count(echo_handled) >= 1;
        }
    }.f);
    try std.testing.expect(echo.enabled);
    try std.testing.expect(hasObject(&ov, echo_id ++ "/echo"));

    h.stop();
}
