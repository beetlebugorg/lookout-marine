//! What one plugin may take, and the record the host keeps of it.
//!
//! `Plugin` is the state a native reaches through the calling instance's user
//! data: its grants, its chrome status, and the meters below.

const std = @import("std");

const broker = @import("../broker.zig");
const caps = @import("caps.zig");
const queue = @import("queue.zig");
const testing = @import("testing.zig");

const vstore = @import("../store.zig");

const Broker = broker.Broker;
const Caps = caps.Caps;
const Kind = caps.Kind;
const SourceId = vstore.SourceId;
const level_err = caps.level_err;
const level_warn = caps.level_warn;
const max_queued = queue.max_queued;
const monoMs = broker.monoMs;

// ---- per-plugin state ------------------------------------------------------

/// Longest chrome status text kept per plugin. Anything longer is truncated
/// rather than allocated per update.
///
/// One line needs a fraction of this. The room is for a status that carries an
/// `items` array — one entry per row of a settings LIST, which is how the
/// nmea0183 plugin reports each connection separately. Eight connections of
/// `{"id":…,"state":…,"detail":…}` fit with the envelope.
pub const max_status = 768;

// ---- the budgets -----------------------------------------------------------
//
// The watchdog catches a plugin that spins. These catch the other three ways a
// plugin can take more than its share without ever looping: allocating without
// bound, flooding the wire, and drowning the log. Each is metered per plugin,
// so a badly behaved plugin costs its neighbours nothing.
//
// EVERY BREACH IS VISIBLE. It is said out loud, and it is named on the
// plugin's own status line until the plugin is reloaded. A plugin that cannot
// tell it is being throttled gets reported as slow rather than fixed.

/// Sustained bytes per second one plugin may hand the host to put on the wire.
///
/// The allowance is a bucket that refills at this rate and holds one second's
/// worth: a plugin that sends a 300 KB batch and then goes quiet is not
/// flooding, and one that sends 300 KB every 100 ms is. It counts what the
/// plugin ASKS to send. Bytes arriving are not metered — a plugin does not
/// choose how fast its gateway talks.
pub const default_wire_bytes_per_s: i64 = 1024 * 1024;

/// Sustained log lines per second one plugin may write. A plugin logging every
/// sentence at 20 Hz is a plugin whose log nobody can read, and the lines it
/// drops are counted and reported.
pub const default_log_lines_per_s: i64 = 10;

/// How often a breach that keeps happening is said again. The first one is
/// said at once; after that, once a minute, so a plugin being throttled for
/// flooding the log cannot flood the log with the news.
pub const budget_say_ms: i64 = 60_000;

/// The metered ceilings, per plugin. The shipped numbers are the defaults and
/// nothing in the app moves them.
///
/// They are settable because a HARNESS drives a plugin harder than any mariner
/// would: the host tests that count a fixture's log lines as proof its handler
/// ran to the end need a fixture that may log once per event, which is fifty a
/// second. The budgets themselves are proved by the tests that are about them.
pub const Budgets = struct {
    wire_bytes_per_s: i64 = default_wire_bytes_per_s,
    log_lines_per_s: i64 = default_log_lines_per_s,

    /// What may go out in one go. One second's worth of wire, and two of log
    /// lines so a plugin's start-up chatter is not clipped.
    pub fn wireBurst(self: Budgets) i64 {
        return self.wire_bytes_per_s;
    }

    pub fn logBurst(self: Budgets) i64 {
        return 2 * self.log_lines_per_s;
    }
};

/// Which budget a plugin last ran into. It rides on the status line so the
/// mariner reads "throttled" rather than guessing at "slow".
pub const Budget = enum {
    none,
    /// Linear memory: a `memory.grow` refused at the per-plugin ceiling.
    memory,
    /// The wire allowance: a send refused, answered -1.
    wire,
    /// The log allowance: lines dropped.
    logs,
    /// The event queue: events dropped because the plugin stopped consuming.
    events,

    pub fn name(self: Budget) []const u8 {
        return switch (self) {
            .none => "",
            .memory => "memory",
            .wire => "wire",
            .logs => "logs",
            .events => "events",
        };
    }
};

/// Room for the host's `,"budget":"memory"` note on top of what the plugin
/// wrote for itself.
pub const max_budget_note = 24;

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
    /// This plugin's provenance in the vessel and AIS stores, and the first id
    /// of the block the host reserved for it.
    source: SourceId,
    /// Ids in that block, `source` included. A plugin that declares a
    /// connection list gets one more for every row the list holds, so two
    /// gateways on one plugin are two sources the store arbitrates between
    /// instead of one slot they overwrite in turn.
    source_span: u32 = 1,
    caps: Caps,
    /// The hostnames `http_fetch` may reach, from the manifest's `net.http`
    /// grant. Borrowed from the host's manifest, like `id`. Empty means the
    /// plugin may reach nothing, which is what an ungranted plugin has.
    http_hosts: []const []const u8 = &.{},
    /// The same for `ws_connect`, from the `net.ws` grant.
    ws_hosts: []const []const u8 = &.{},
    /// The addresses `tcp_connect` may dial, from the `net.tcp-client` grant.
    /// The `local` token stands for the boat's own network; see `isLocalHost`.
    tcp_addrs: []const []const u8 = &.{},
    /// The ports `udp_open` may bind, from the `net.udp` grant.
    udp_ports: []const u16 = &.{},
    /// The bus topics this plugin may publish and read, from the `bus.publish`
    /// and `bus.read` grants. The read list IS the subscription: fanout
    /// consults it directly, so there is no subscribe call and a revoked
    /// grant stops delivery by itself.
    pub_topics: []const []const u8 = &.{},
    sub_topics: []const []const u8 = &.{},
    /// The table keys the manifest declared, borrowed from the host like `id`.
    /// `declareTable` refuses anything else: a table the mariner never saw on
    /// the consent sheet does not appear in a menu because the module asked
    /// for it at run time.
    table_keys: []const []const u8 = &.{},
    /// False once the plugin has trapped or been shut down: natives from an
    /// in-flight call still work, but nothing new is delivered.
    enabled: bool = true,
    /// Its vessel-store subscription, once it has called `subscribe`.
    sub: ?vstore.SubId = null,
    ais_sub: bool = false,
    view_sub: bool = false,
    /// True while this plugin is owed a VIEW_CHANGED whatever the dedupe says:
    /// it just subscribed, or its last one was dropped on a full queue.
    view_pending: bool = false,
    /// What the plugin last said about itself, through `chrome_status`.
    status_buf: [max_status]u8 = @splat(0),
    status_len: usize = 0,
    /// What a reader is shown: the same words with any budget note folded in.
    /// Kept alongside rather than composed on demand so `status()` stays a
    /// slice every caller can hold.
    line_buf: [max_status + max_budget_note]u8 = @splat(0),
    line_len: usize = 0,
    /// Calls refused for want of a capability. The smoke test asserts on this.
    denied: u32 = 0,

    // -- the budgets ---------------------------------------------------------
    // Written from the plugin's own dispatch thread, which is the only thread
    // inside its module. The one breach that is noticed elsewhere is the event
    // queue, filled by the I/O thread: that one raises `queue_over` and the
    // dispatch thread turns it into a note, so the status line has a single
    // writer.

    /// The budget this plugin last ran into, and the ones it has already been
    /// told about, so a breach that keeps happening is not said every time.
    budget: Budget = .none,
    budgets_seen: std.EnumSet(Budget) = std.EnumSet(Budget).initEmpty(),
    budget_said_ms: i64 = 0,
    /// Bytes left in the wire allowance, and when it was last topped up. A
    /// zero clock means untouched, and the first charge fills the bucket.
    wire_tokens: i64 = 0,
    wire_ms: i64 = 0,
    /// Sends refused over the wire allowance.
    wire_throttled: u64 = 0,
    /// The same for the log allowance, in lines.
    log_tokens: i64 = 0,
    log_ms: i64 = 0,
    logs_dropped: u64 = 0,
    /// Raised by the I/O thread when this plugin's event queue drops an event.
    queue_over: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Events lost to a full queue, written by the I/O thread under the
    /// broker's lock and read when the note above is drained.
    dropped_events: u64 = 0,

    pub fn status(self: *const Plugin) []const u8 {
        return self.line_buf[0..self.line_len];
    }

    /// The store source one published batch belongs to. `place` is a
    /// connection's place in the mariner's list, counting from one; zero is
    /// the plugin publishing as itself.
    ///
    /// The block is consecutive and the store elects in registration order, so
    /// a lower place outranks a higher one: the gateway at the top of the
    /// Connections list holds a path while its values are fresh, and the next
    /// one down takes over when they go stale. A place past the block is out
    /// of range and answers with the plugin's own id, so a numbering fault
    /// loses the provenance while the value still lands.
    pub fn sourceAt(self: *const Plugin, place: u32) SourceId {
        return if (place == 0 or place >= self.source_span) self.source else self.source + place;
    }

    /// Replace the chrome status. Normally the plugin's own words, through
    /// `chrome_status`; the host also writes here when it disables a plugin,
    /// which is the one case where nobody is left inside the module to say
    /// what happened. Returns true when the line a reader sees changed.
    pub fn setStatus(self: *Plugin, text: []const u8) bool {
        const n = @min(text.len, max_status);
        @memcpy(self.status_buf[0..n], text[0..n]);
        self.status_len = n;
        return self.composeLine();
    }

    /// Fold the budget note into the plugin's own words. The status is JSON
    /// the plugin wrote, so the note goes in as one more member of it; a
    /// plugin that has said nothing yet, or said something that is not an
    /// object, still gets a line that names the budget.
    ///
    /// Returns true when the composed line changed.
    fn composeLine(self: *Plugin) bool {
        var buf: [max_status + max_budget_note]u8 = undefined;
        const raw = self.status_buf[0..self.status_len];
        const line = if (self.budget == .none)
            raw
        else if (raw.len >= 2 and raw[0] == '{' and raw[raw.len - 1] == '}')
            std.fmt.bufPrint(&buf, "{{{s}{s}\"budget\":\"{s}\"}}", .{
                raw[1 .. raw.len - 1],
                if (raw.len > 2) "," else "",
                self.budget.name(),
            }) catch raw
        else if (raw.len == 0)
            std.fmt.bufPrint(&buf, "{{\"budget\":\"{s}\"}}", .{self.budget.name()}) catch raw
        else
            std.fmt.bufPrint(&buf, "{s} [budget: {s}]", .{ raw, self.budget.name() }) catch raw;

        const changed = line.len != self.line_len or !std.mem.eql(u8, self.line_buf[0..line.len], line);
        @memcpy(self.line_buf[0..line.len], line);
        self.line_len = line.len;
        return changed;
    }

    /// Record a budget breach: name it on the status line, and say it out
    /// loud. The first breach of a budget goes out at error level so no log
    /// filter can hide it; after that, once a minute.
    pub fn noteBudget(self: *Plugin, which: Budget, comptime fmt: []const u8, args: anytype) void {
        const first = !self.budgets_seen.contains(which);
        if (self.budget != which) {
            self.budget = which;
            _ = self.composeLine();
        }
        const now = monoMs();
        if (!first and now - self.budget_said_ms < budget_say_ms) return;
        self.budgets_seen.insert(which);
        self.budget_said_ms = now;
        self.broker.say(if (first) level_err else level_warn, self.id, fmt, args);
    }

    /// Charge `n` bytes to the wire allowance. False when it is spent, and the
    /// caller answers -1: this is the only place a send is refused for pace
    /// rather than for a grant, so it does not count as a denied call.
    pub fn chargeWire(self: *Plugin, call: []const u8, n: usize) bool {
        const b = self.broker.budgets;
        refill(&self.wire_tokens, &self.wire_ms, monoMs(), b.wire_bytes_per_s, b.wireBurst());
        const want: i64 = @intCast(n);
        if (want <= self.wire_tokens) {
            self.wire_tokens -= want;
            return true;
        }
        self.wire_throttled += 1;
        self.noteBudget(
            .wire,
            "throttled: {s} of {d} bytes is over the {d} KiB/s wire budget ({d} call{s} throttled)",
            .{ call, n, @divTrunc(b.wire_bytes_per_s, 1024), self.wire_throttled, plural(self.wire_throttled) },
        );
        return false;
    }

    /// Charge one line to the log allowance. False when it is spent and the
    /// line is dropped.
    pub fn chargeLog(self: *Plugin) bool {
        const b = self.broker.budgets;
        refill(&self.log_tokens, &self.log_ms, monoMs(), b.log_lines_per_s, b.logBurst());
        if (self.log_tokens >= 1) {
            self.log_tokens -= 1;
            return true;
        }
        self.logs_dropped += 1;
        self.noteBudget(
            .logs,
            "throttled: {d} log line{s} dropped over the {d}/s log budget",
            .{ self.logs_dropped, plural(self.logs_dropped), b.log_lines_per_s },
        );
        return false;
    }

    /// Turn a queue overflow raised by the I/O thread into a note, on this
    /// plugin's own dispatch thread. Called between events, so the status line
    /// has one writer and the count is read where it is safe to read.
    pub fn drainQueueBudget(self: *Plugin) void {
        if (!self.queue_over.load(.monotonic)) return;
        self.queue_over.store(false, .monotonic);
        self.noteBudget(
            .events,
            "throttled: {d} event{s} dropped over the {d}-event queue budget",
            .{ self.dropped_events, plural(self.dropped_events), max_queued },
        );
    }
};

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

/// A token bucket: `tokens` tops up at `per_s` a second, capped at `burst`.
/// A zero clock is a bucket nobody has drawn on yet, and it starts full.
///
/// `since` moves only by the time actually turned into tokens, never simply to
/// `now`. A caller arriving every few milliseconds would otherwise convert an
/// elapsed span too short to be worth a whole token, keep the remainder of
/// nothing, and never refill at all.
fn refill(tokens: *i64, since: *i64, now: i64, per_s: i64, burst: i64) void {
    if (since.* == 0) {
        since.* = now;
        tokens.* = burst;
        return;
    }
    const elapsed = now - since.*;
    if (elapsed <= 0) return;
    const gained = @divTrunc(elapsed * per_s, 1000);
    if (gained <= 0) return;
    tokens.* = @min(burst, tokens.* + gained);
    since.* += @divTrunc(gained * 1000, per_s);
}

const t = std.testing;
const Fixture = testing.Fixture;

test "the wire budget throttles at its ceiling and says so on the status line" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    var p = Plugin{ .broker = b, .index = 0, .id = "org.example.firehose", .source = 1, .caps = Caps.initEmpty() };
    _ = p.setStatus("{\"state\":\"connected\",\"detail\":\"2 sources\"}");
    try t.expectEqualStrings("{\"state\":\"connected\",\"detail\":\"2 sources\"}", p.status());

    // One second's worth goes out in a burst; the byte after it does not. The
    // bucket's clock is pinned AHEAD of now, so no elapsed time exists to
    // refill from and what is measured is the ceiling and not the wall clock.
    const frozen = monoMs() + 60_000;
    p.wire_ms = frozen;
    p.wire_tokens = b.budgets.wireBurst();
    const chunk: usize = 64 * 1024;
    const burst: usize = @intCast(b.budgets.wireBurst());
    var sent: usize = 0;
    while (sent < burst) : (sent += chunk) {
        try t.expect(p.chargeWire("tcp_send", chunk));
    }
    try t.expect(!p.chargeWire("tcp_send", chunk));
    try t.expectEqual(@as(u64, 1), p.wire_throttled);

    // The plugin's own words, with the budget it hit folded in: a plugin that
    // cannot tell it is being throttled is reported as slow rather than fixed.
    try t.expectEqualStrings(
        "{\"state\":\"connected\",\"detail\":\"2 sources\",\"budget\":\"wire\"}",
        p.status(),
    );
    try t.expect(fx.sink.has("over the 1024 KiB/s wire budget"));
    // It is a pace refusal, not a grant refusal, so it does not count denied.
    try t.expectEqual(@as(u32, 0), p.denied);

    // The note survives the plugin posting a new status of its own.
    _ = p.setStatus("{\"state\":\"connected\",\"detail\":\"3 sources\"}");
    try t.expectEqualStrings(
        "{\"state\":\"connected\",\"detail\":\"3 sources\",\"budget\":\"wire\"}",
        p.status(),
    );

    // A second of quiet buys the allowance back.
    p.wire_ms = monoMs() - 1000;
    try t.expect(p.chargeWire("tcp_send", chunk));
}

test "the log budget drops lines at its ceiling, counts them and reports once a minute" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    var p = Plugin{ .broker = b, .index = 0, .id = "org.example.chatty", .source = 1, .caps = Caps.initEmpty() };
    const frozen = monoMs() + 60_000;
    p.log_ms = frozen;
    p.log_tokens = b.budgets.logBurst();
    var i: i64 = 0;
    while (i < b.budgets.logBurst()) : (i += 1) try t.expect(p.chargeLog());
    try t.expect(!p.chargeLog());
    try t.expectEqual(@as(u64, 1), p.logs_dropped);
    try t.expectEqualStrings("{\"budget\":\"logs\"}", p.status());
    try t.expect(fx.sink.has("1 log line dropped over the 10/s log budget"));

    // The next thousand drops are counted and stay quiet: the news about a
    // plugin flooding the log must not itself flood the log.
    const said = fx.sink.count();
    var n: usize = 0;
    while (n < 1000) : (n += 1) try t.expect(!p.chargeLog());
    try t.expectEqual(@as(u64, 1001), p.logs_dropped);
    try t.expectEqual(said, fx.sink.count());

    // A minute on, it is said again with the running count.
    p.budget_said_ms = monoMs() - budget_say_ms;
    try t.expect(!p.chargeLog());
    try t.expect(fx.sink.has("1002 log lines dropped over the 10/s log budget"));

    // A second of quiet buys ten lines back, and no more.
    p.log_ms = monoMs() - 1000;
    p.log_tokens = 0;
    i = 0;
    while (i < b.budgets.log_lines_per_s) : (i += 1) try t.expect(p.chargeLog());
    p.log_ms = monoMs() + 60_000;
    try t.expect(!p.chargeLog());
}

test "a full event queue names the events budget on the status line" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    var p = Plugin{ .broker = b, .index = 0, .id = "org.example.deaf", .source = 1, .caps = Caps.initEmpty() };
    try b.registerPlugin(&p);
    defer b.removePlugin(&p);
    _ = p.setStatus("{\"state\":\"running\"}");

    // Fill the queue past its cap without ever draining it.
    var i: usize = 0;
    while (i < max_queued + 4) : (i += 1) b.push(0, Kind.timer, 0, "");
    defer b.clearQueue(0);
    try t.expect(b.droppedFor(0) >= 4);

    // The I/O thread only raises the flag; the note is written where the
    // status line has one writer, which is the dispatch thread.
    try t.expectEqualStrings("{\"state\":\"running\"}", p.status());
    p.drainQueueBudget();
    try t.expectEqualStrings("{\"state\":\"running\",\"budget\":\"events\"}", p.status());
    try t.expect(fx.sink.has("over the 1024-event queue budget"));
}

test "a budget note lands on a status line whatever shape the plugin gave it" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);

    var p = Plugin{ .broker = &fx.br, .index = 0, .id = "org.example.quiet", .source = 1, .caps = Caps.initEmpty() };
    // A plugin that has said nothing yet still reads as throttled.
    p.noteBudget(.memory, "out of memory", .{});
    try t.expectEqualStrings("{\"budget\":\"memory\"}", p.status());
    // An empty object, and text that is not JSON at all.
    _ = p.setStatus("{}");
    try t.expectEqualStrings("{\"budget\":\"memory\"}", p.status());
    _ = p.setStatus("running");
    try t.expectEqualStrings("running [budget: memory]", p.status());
    // A status longer than the buffer is truncated, not overflowed.
    const long = "x" ** (max_status + 64);
    _ = p.setStatus(long);
    try t.expect(p.status().len <= max_status + max_budget_note);
}
