//! What a plugin's alert becomes once the host has it: a severity, the words,
//! and the acknowledgement the mariner owes it.
//!
//! The Broker owns the list and applies the raises; this file is the shape they
//! take, the wire they arrive on, and the order a shell reads them back in.
//!
//! An alarm is audible and a warning is visible, so the severity is the whole
//! difference between the two. It rides in on the payload, and a payload that
//! does not say reads as an alarm.

const std = @import("std");

const broker = @import("../broker.zig");
const pl = @import("plugins");
const caps = @import("caps.zig");
const testing = @import("testing.zig");

const vstore = @import("../store.zig");
const ais_store = @import("../aisstore.zig");

const Broker = broker.Broker;
const Plugin = broker.Plugin;
const Caps = caps.Caps;

/// Live alerts one plugin may hold. Over the cap a raise gives way to the
/// oldest alert the mariner has already acknowledged; when every one of them
/// is unacknowledged the raise is refused and logged.
pub const max_alerts_per_plugin = 32;

/// Longest title and body kept. Longer is cut rather than refused, because
/// half a sentence still names the danger and a silent alarm names nothing.
pub const max_alert_title = 96;
pub const max_alert_body = 240;

/// Longest dedup key kept. A key is an identity a plugin makes up, so it needs
/// room for a name and a number and not for a sentence.
pub const max_alert_key = 64;

/// An ACKNOWLEDGED alert clears once this long has passed with nothing
/// happening to it. The condition returning after that raises a fresh alert
/// and sounds again, so a mariner who silenced one close pass still hears the
/// next.
///
/// An unacknowledged alert never clears on its own. An alarm ends when the
/// mariner ends it, not when it gets old.
pub const alert_clear_ms: i64 = 120_000;

/// How loud an alert is. The order is the loudness: a louder restatement of a
/// live alert takes back its acknowledgement.
pub const Severity = enum {
    notice,
    warning,
    alarm,

    pub fn name(self: Severity) []const u8 {
        return @tagName(self);
    }

    pub fn louderThan(self: Severity, other: Severity) bool {
        return @intFromEnum(self) > @intFromEnum(other);
    }
};

/// One alert the host is holding.
pub const Alert = struct {
    /// Registry index of the plugin that raised it. What `dropPlugin` matches.
    plugin: u32,
    /// Manifest id, borrowed from the plugin record like `Table.plugin_id`.
    plugin_id: []const u8,
    /// What an acknowledgement names. Never reused.
    id: u64,
    severity: Severity,
    /// What the plugin calls this alert, or empty when it named nothing. Not
    /// on the wire: the shell acknowledges an id, and this is the host's
    /// answer to which alert a raise is about.
    key: []u8,
    title: []u8,
    body: []u8,
    /// Wall clock, for the shell to show.
    raised_ms: i64,
    /// Monotonic, moved by every restatement and by the acknowledgement. The
    /// clear window above is measured on it.
    last_ms: i64,
    acknowledged: bool = false,

    /// True when `r` restates this alert rather than raising another one.
    ///
    /// A KEY IS AN IDENTITY, and a plugin that supplies one owns what counts
    /// as the same alert. The words are then free to move under it: a vessel
    /// whose name arrives after its first position report is the same danger
    /// under a new wording. With no key the words are all the host has, so the
    /// title and the body are the identity, and a body carrying a figure that
    /// moves raises a new alert every time it moves.
    pub fn restatedBy(self: Alert, r: Raised) bool {
        if (self.key.len > 0 or r.key.len > 0) return std.mem.eql(u8, self.key, r.key);
        return std.mem.eql(u8, self.title, r.title) and std.mem.eql(u8, self.body, r.body);
    }
};

pub fn freeAlert(alloc: std.mem.Allocator, a: Alert) void {
    alloc.free(a.key);
    alloc.free(a.title);
    alloc.free(a.body);
}

/// The order a shell reads them in: what is still unanswered first, then the
/// loudest, then the oldest. A mariner reads down from the thing that needs
/// doing now, and an alert already on screen does not move when another
/// arrives beneath it.
pub const Order = struct {
    alerts: []const Alert,

    pub fn less(self: Order, a: u32, b: u32) bool {
        const x = self.alerts[a];
        const y = self.alerts[b];
        if (x.acknowledged != y.acknowledged) return y.acknowledged;
        if (x.severity != y.severity) return x.severity.louderThan(y.severity);
        return x.id < y.id;
    }
};

/// What one alert payload says.
///
/// The optional `key` is the identity: two raises from one plugin under the
/// same key are one alert. Without it the title and the body are the identity,
/// the title naming the condition and the body naming the instance of it. See
/// `Alert.restatedBy` and `Broker.raiseAlert`.
pub const Raised = struct {
    severity: Severity,
    key: []const u8,
    title: []const u8,
    body: []const u8,

    /// Null for a payload with nothing in it. Anything else yields an alert: a
    /// payload with no title takes its body as one, and a payload with neither
    /// is shown as it arrived. A plugin that reached for an alarm is not
    /// silenced because its JSON was written by hand.
    pub fn parse(json: []const u8) ?Raised {
        const text = std.mem.trim(u8, json, " \t\r\n");
        if (text.len == 0) return null;
        var title = jsonStringField(text, "title") orelse "";
        var body = jsonStringField(text, "body") orelse "";
        if (title.len == 0) {
            title = body;
            body = "";
        }
        if (title.len == 0) title = text;
        return .{
            .severity = severityOf(text),
            .key = clip(jsonStringField(text, "key") orelse "", max_alert_key),
            .title = clip(title, max_alert_title),
            .body = clip(body, max_alert_body),
        };
    }
};

/// The severity a payload carries. Anything unrecognised, including a payload
/// with no severity at all, is an alarm: an unreadable severity is not a reason
/// to be quiet. `caution` is the other name the SDK offers for `notice`.
pub fn severityOf(json: []const u8) Severity {
    const sev = jsonStringField(json, "severity") orelse return .alarm;
    if (std.mem.eql(u8, sev, "notice") or std.mem.eql(u8, sev, "caution")) return .notice;
    if (std.mem.eql(u8, sev, "warning")) return .warning;
    return .alarm;
}

/// The string value of a top-level-ish `"key":"value"` pair, by scan rather
/// than by parse: this runs on every alert and the payload is the plugin's own
/// one-line JSON, not a document.
pub fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
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

/// The first `limit` bytes, backed off to a codepoint boundary. A cut inside a
/// multi-byte character would put invalid UTF-8 on the wire, and the shell
/// parses that wire as JSON.
fn clip(s: []const u8, limit: usize) []const u8 {
    if (s.len <= limit) return s;
    var n = limit;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

const t = std.testing;
const silentLog = testing.silentLog;

/// A broker with one plugin record, for the alert tests. The record is the
/// host's in the real thing; here it is a local the fixture lends out.
const AlertFixture = struct {
    vessels: *vstore.Store,
    ais: *ais_store.AisStore,
    broker: Broker,
    plugin: Plugin = undefined,

    fn init() !*AlertFixture {
        const a = t.allocator;
        const self = try a.create(AlertFixture);
        self.vessels = try a.create(vstore.Store);
        self.vessels.* = try vstore.Store.init(a);
        self.ais = try a.create(ais_store.AisStore);
        self.ais.* = ais_store.AisStore.init(a);
        self.broker = Broker.init(a, self.vessels, self.ais, .{});
        self.broker.setLog(null, silentLog);
        self.plugin = .{
            .broker = &self.broker,
            .index = 0,
            .id = "org.example.alarm",
            .source = 1,
            .caps = Caps.initEmpty(),
        };
        try self.broker.registerPlugin(&self.plugin);
        return self;
    }

    fn deinit(self: *AlertFixture) void {
        const a = t.allocator;
        self.broker.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        a.destroy(self.ais);
        a.destroy(self.vessels);
        a.destroy(self);
    }

    fn raise(self: *AlertFixture, json: []const u8) void {
        self.broker.raiseAlert(&self.plugin, json);
    }

    fn read(self: *AlertFixture, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        try self.broker.alertsJson(out);
    }

    fn count(self: *AlertFixture) usize {
        self.broker.mu.lock();
        defer self.broker.mu.unlock();
        return self.broker.alerts.items.len;
    }

    /// The id of the one alert held, for an acknowledgement.
    fn onlyId(self: *AlertFixture) u64 {
        self.broker.mu.lock();
        defer self.broker.mu.unlock();
        return self.broker.alerts.items[0].id;
    }

    fn seq(self: *AlertFixture) u64 {
        self.broker.mu.lock();
        defer self.broker.mu.unlock();
        return self.broker.alerts_seq;
    }

    /// Age every alert past the clear window. The window is a wall-clock rule
    /// and a test is not going to wait two minutes for it.
    fn age(self: *AlertFixture) void {
        self.broker.mu.lock();
        defer self.broker.mu.unlock();
        for (self.broker.alerts.items) |*a| a.last_ms -= alert_clear_ms;
    }
};

const cpa_alarm = "{\"severity\":\"alarm\",\"title\":\"AIS CPA alarm\",\"body\":\"ANNE: CPA 124 m in 585 s\"}";
const cpa_alarm_other = "{\"severity\":\"alarm\",\"title\":\"AIS CPA alarm\",\"body\":\"BRAVO: CPA 90 m in 200 s\"}";

/// One vessel under its own key, said twice. The second says it a second
/// later, with figures that have moved and the name the target had not sent
/// when it was first heard.
const keyed_first = "{\"severity\":\"alarm\",\"key\":\"cpa:899000101\"," ++
    "\"title\":\"AIS CPA alarm\",\"body\":\"899000101: CPA 171 m in 600 s\"}";
const keyed_again = "{\"severity\":\"alarm\",\"key\":\"cpa:899000101\"," ++
    "\"title\":\"AIS CPA alarm\",\"body\":\"ANNE: CPA 170 m in 599 s\"}";
const keyed_other = "{\"severity\":\"alarm\",\"key\":\"cpa:899000102\"," ++
    "\"title\":\"AIS CPA alarm\",\"body\":\"BRAVO: CPA 90 m in 200 s\"}";

test "an alert reaches the shell, and the same condition restated does not stack" {
    const a = t.allocator;
    const f = try AlertFixture.init();
    defer f.deinit();

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.read(&json);
    try t.expectEqualStrings("{\"seq\":0,\"alerts\":[]}", json.items);

    f.raise(cpa_alarm);
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"plugin\":\"org.example.alarm\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"severity\":\"alarm\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"title\":\"AIS CPA alarm\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"body\":\"ANNE: CPA 124 m in 585 s\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"acknowledged\":false") != null);

    // The same vessel, said again: one alert, and the sequence does not move,
    // so a shell polling it does not redraw.
    const before = f.seq();
    f.raise(cpa_alarm);
    f.raise(cpa_alarm);
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expectEqual(before, f.seq());

    // Another vessel is another alarm. Two dangers are two decisions.
    f.raise(cpa_alarm_other);
    try t.expectEqual(@as(usize, 2), f.count());
    try t.expect(f.seq() > before);
}

test "acknowledging silences one alert and leaves the rest sounding" {
    const a = t.allocator;
    const f = try AlertFixture.init();
    defer f.deinit();
    f.raise(cpa_alarm);
    const first = f.onlyId();
    f.raise(cpa_alarm_other);

    try t.expect(f.broker.ackAlert(first));
    // An id nobody holds is not an acknowledgement.
    try t.expect(!f.broker.ackAlert(first + 1000));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.read(&json);
    // Both are still listed, and the one still unanswered is read first.
    try t.expectEqual(@as(usize, 2), f.count());
    const unacked = std.mem.indexOf(u8, json.items, "\"acknowledged\":false").?;
    const acked = std.mem.indexOf(u8, json.items, "\"acknowledged\":true").?;
    try t.expect(unacked < acked);
    try t.expect(std.mem.indexOf(u8, json.items, "BRAVO").? < std.mem.indexOf(u8, json.items, "ANNE").?);
}

// AN ALARM THE MARINER CANNOT SILENCE IS THE WORST BUG THIS FILE CAN HAVE.
// The words move while the danger stands still, and each new wording used to
// be a fresh alert with nobody's answer on it.
test "a keyed alert restated in different words keeps its acknowledgement" {
    const a = t.allocator;
    const f = try AlertFixture.init();
    defer f.deinit();

    f.raise(keyed_first);
    const first = f.onlyId();
    try t.expect(f.broker.ackAlert(first));

    // The same vessel a second later. One alert, and it is the one the
    // mariner already answered, so nothing sounds.
    f.raise(keyed_again);
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expectEqual(first, f.onlyId());

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"acknowledged\":true") != null);
    // What the mariner reads is the last thing the plugin said.
    try t.expect(std.mem.indexOf(u8, json.items, "ANNE: CPA 170 m in 599 s") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "CPA 171 m") == null);
}

test "two keys are two alarms, and a key is not inferred for an unkeyed raise" {
    const a = t.allocator;
    const f = try AlertFixture.init();
    defer f.deinit();

    f.raise(keyed_first);
    try t.expect(f.broker.ackAlert(f.onlyId()));

    // Another vessel closing is another decision. Its key is its own, so the
    // answer given to the first is not given to it.
    f.raise(keyed_other);
    try t.expectEqual(@as(usize, 2), f.count());
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"acknowledged\":false") != null);

    // The same words with no key are a third alert. An identity a plugin gave
    // one alert is never guessed for another.
    f.raise("{\"severity\":\"alarm\",\"title\":\"AIS CPA alarm\"," ++
        "\"body\":\"899000101: CPA 171 m in 600 s\"}");
    try t.expectEqual(@as(usize, 3), f.count());
}

test "an acknowledged alert clears, and the condition returning sounds again" {
    const f = try AlertFixture.init();
    defer f.deinit();
    f.raise(cpa_alarm);
    const first = f.onlyId();
    try t.expect(f.broker.ackAlert(first));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);

    // Still held while it is fresh: the mariner can see what they silenced.
    try f.read(&json);
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expect(std.mem.indexOf(u8, json.items, "\"acknowledged\":true") != null);

    // Past the window it is gone, and the same words come back as a new alert
    // that nobody has answered.
    f.age();
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"alerts\":[]") != null);

    f.raise(cpa_alarm);
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expect(f.onlyId() != first);
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"acknowledged\":false") != null);

    // An unacknowledged alarm never clears on its own.
    f.age();
    try f.read(&json);
    try t.expectEqual(@as(usize, 1), f.count());
}

test "a louder restatement takes back the acknowledgement" {
    const f = try AlertFixture.init();
    defer f.deinit();
    const words = "\"title\":\"Depth\",\"body\":\"3.1 m under the keel\"";
    f.raise("{\"severity\":\"warning\"," ++ words ++ "}");
    try t.expect(f.broker.ackAlert(f.onlyId()));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);

    // The same words at the same level are the same condition, still answered.
    f.raise("{\"severity\":\"warning\"," ++ words ++ "}");
    try f.read(&json);
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expect(std.mem.indexOf(u8, json.items, "\"acknowledged\":true") != null);

    // Louder is news: one alert still, sounding again.
    f.raise("{\"severity\":\"alarm\"," ++ words ++ "}");
    try f.read(&json);
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expect(std.mem.indexOf(u8, json.items, "\"severity\":\"alarm\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"acknowledged\":false") != null);
}

test "a payload the host cannot read still raises something" {
    const f = try AlertFixture.init();
    defer f.deinit();
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);

    // No severity is an alarm, and a body with no title is the title.
    f.raise("{\"body\":\"steering gear failure\"}");
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"severity\":\"alarm\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"title\":\"steering gear failure\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"body\":\"\"") != null);

    // Not JSON at all is shown as it arrived rather than dropped.
    f.raise("engine room fire");
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"title\":\"engine room fire\"") != null);

    // Nothing at all is nothing.
    f.raise("   ");
    try t.expectEqual(@as(usize, 2), f.count());
}

test "a long alert is cut on a character, and the wire stays parseable" {
    const a = t.allocator;
    const f = try AlertFixture.init();
    defer f.deinit();

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    try payload.appendSlice(a, "{\"severity\":\"warning\",\"title\":\"");
    // Three bytes each, so a cut at the byte budget lands mid-character
    // unless it is backed off.
    for (0..max_alert_title) |_| try payload.appendSlice(a, "\u{00e5}");
    try payload.appendSlice(a, "\",\"body\":\"x\"}");
    f.raise(payload.items);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.read(&json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json.items, .{});
    defer parsed.deinit();
    const title = parsed.value.object.get("alerts").?.array.items[0].object.get("title").?.string;
    try t.expect(title.len <= max_alert_title);
    try t.expect(std.unicode.utf8ValidateSlice(title));
}

test "a plugin cannot hold more live alerts than its budget" {
    const a = t.allocator;
    const f = try AlertFixture.init();
    defer f.deinit();

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    for (0..max_alerts_per_plugin) |i| {
        payload.clearRetainingCapacity();
        try payload.print(a, "{{\"severity\":\"alarm\",\"title\":\"CPA\",\"body\":\"{d}\"}}", .{i});
        f.raise(payload.items);
    }
    try t.expectEqual(@as(usize, max_alerts_per_plugin), f.count());

    // One more, with every one of them unanswered: refused, and the alerts
    // already up are untouched.
    f.raise("{\"severity\":\"alarm\",\"title\":\"CPA\",\"body\":\"over\"}");
    try t.expectEqual(@as(usize, max_alerts_per_plugin), f.count());
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"body\":\"over\"") == null);

    // An acknowledgement makes room: the oldest answered alert gives way to
    // the danger nobody has seen yet.
    var first: u64 = 0;
    {
        f.broker.mu.lock();
        first = f.broker.alerts.items[0].id;
        f.broker.mu.unlock();
    }
    try t.expect(f.broker.ackAlert(first));
    f.raise("{\"severity\":\"alarm\",\"title\":\"CPA\",\"body\":\"over\"}");
    try t.expectEqual(@as(usize, max_alerts_per_plugin), f.count());
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"body\":\"over\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"body\":\"0\"") == null);
}

// AN ORPHANED ALARM IS A LIE. Whatever raised it is no longer watching the
// condition, so it can never say the condition has passed.
test "a plugin that goes takes its alerts with it" {
    const f = try AlertFixture.init();
    defer f.deinit();
    f.raise(cpa_alarm);
    f.broker.dropPlugin(0, 1000);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);
    try f.read(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"alerts\":[]") != null);
}

test "revoking alerts.raise takes back what it raised" {
    const f = try AlertFixture.init();
    defer f.deinit();
    f.raise(cpa_alarm);
    try t.expectEqual(@as(usize, 1), f.count());

    // A capability the plugin still holds leaves the alert where it is.
    f.broker.withdraw(0, .overlay_draw, 1000);
    try t.expectEqual(@as(usize, 1), f.count());

    f.broker.withdraw(0, .alerts_raise, 1000);
    try t.expectEqual(@as(usize, 0), f.count());
}

test "the typed alerts say what the JSON says" {
    const a = t.allocator;
    const fx = try AlertFixture.init();
    defer fx.deinit();

    fx.raise(
        \\{"severity":"alarm","title":"AIS CPA alarm","body":"ANNE: CPA 124 m in 585 s"}
    );
    fx.raise(
        \\{"severity":"warning","title":"Depth","body":"3.1 m under the keel"}
    );

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try fx.read(&text);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text.items, .{});

    const read = try pl.Alerts.init(a);
    defer read.free();
    try fx.broker.alertsRead(read);

    try t.expectEqual(@as(u64, @intCast(doc.object.get("seq").?.integer)), read.seq);
    const list = doc.object.get("alerts").?.array;
    try t.expectEqual(list.items.len, read.rows.len);
    for (list.items, read.rows) |item, got| {
        const o = item.object;
        try t.expectEqual(@as(u64, @intCast(o.get("id").?.integer)), got.id);
        try t.expectEqualStrings(o.get("plugin").?.string, std.mem.span(got.plugin));
        try t.expectEqualStrings(o.get("title").?.string, std.mem.span(got.title));
        try t.expectEqualStrings(o.get("body").?.string, std.mem.span(got.body));
        try t.expectEqualStrings(o.get("severity").?.string, @tagName(got.severity));
        try t.expectEqual(o.get("acknowledged").?.bool, got.acknowledged != 0);
        try t.expectEqual(o.get("raised").?.integer, got.raised);
    }
}

test "the typed alerts keep the order the shell draws" {
    const a = t.allocator;
    const fx = try AlertFixture.init();
    defer fx.deinit();

    fx.raise(
        \\{"severity":"notice","title":"A","body":"a"}
    );
    fx.raise(
        \\{"severity":"alarm","title":"B","body":"b"}
    );
    fx.raise(
        \\{"severity":"warning","title":"C","body":"c"}
    );

    const read = try pl.Alerts.init(a);
    defer read.free();
    try fx.broker.alertsRead(read);

    // The loudest first among what nobody has answered.
    try t.expectEqual(@as(usize, 3), read.rows.len);
    try t.expectEqualStrings("B", std.mem.span(read.rows[0].title));
    try t.expectEqualStrings("C", std.mem.span(read.rows[1].title));
    try t.expectEqualStrings("A", std.mem.span(read.rows[2].title));
}
