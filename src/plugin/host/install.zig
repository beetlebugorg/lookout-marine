//! Install: the package, the grants, the consent sentences.
//!
//! Where an installed plugin goes on each platform, the `grants.json` beside it
//! that records which of its capabilities are still on, and the sentence the
//! consent sheet shows for each one. `Host` drives all of it; this file holds
//! the wording and the rules.

const std = @import("std");
const builtin = @import("builtin");

const broker = @import("../broker.zig");
const manifest = @import("manifest.zig");
const settings_json = @import("settings_json.zig");

const Manifest = manifest.Manifest;
const writeJsonString = settings_json.writeJsonString;

/// Longest refusal sentence kept for the shell to show.
pub const max_install_msg = 240;

/// Longest member name read out of a package. An id is 128 bytes at most and
/// the module name adds five; anything longer is not a plugin file.
pub const max_zip_name = 160;

/// Longest grants.json read back. A full grant list is under 200 bytes.
pub const max_grants_bytes: usize = 4096;

/// The revocation file beside an installed plugin's wasm. A flat directory
/// uses `<id>.grants.json` instead, because its plugins share the directory.
pub const grants_file = "grants.json";

/// The consent table's order (install.md). The sheet and the settings rows
/// list sentences in this order whatever order the manifest declared.
pub const sentence_order = [_]broker.Cap{
    .vessel_read,
    .ais_read,
    .vessel_publish,
    .ais_publish,
    .overlay_draw,
    .alerts_raise,
    .net_tcp_client,
    .net_udp,
    .net_http,
    .net_ws,
    .storage,
    .files,
};

/// One capability's consent sentence, worded exactly as install.md's table.
/// Host lists print inline; the `local` token prints as the boat's own
/// network, because "local" is jargon and that is what it grants.
pub fn writeSentence(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cap: broker.Cap, m: *const Manifest) !void {
    switch (cap) {
        .vessel_read => try out.appendSlice(alloc, "Read your instruments: position, heading, depth, wind."),
        .ais_read => try out.appendSlice(alloc, "Read AIS traffic."),
        .vessel_publish => try out.appendSlice(alloc, "Provide instrument readings to the chart."),
        .ais_publish => try out.appendSlice(alloc, "Provide AIS targets to the chart."),
        .overlay_draw => try out.appendSlice(alloc, "Draw on the chart."),
        .alerts_raise => try out.appendSlice(alloc, "Raise alarms."),
        .net_tcp_client => {
            try out.appendSlice(alloc, "Connect to instruments on: ");
            try writeHostList(out, alloc, m.tcp_addrs);
            try out.append(alloc, '.');
        },
        .net_udp => {
            try out.appendSlice(alloc, "Listen for broadcasts on ");
            try out.appendSlice(alloc, if (m.udp_ports.len == 1) "port " else "ports ");
            for (m.udp_ports, 0..) |port, i| {
                if (i > 0) try out.appendSlice(alloc, if (i + 1 == m.udp_ports.len) " and " else ", ");
                try out.print(alloc, "{d}", .{port});
            }
            try out.append(alloc, '.');
        },
        .net_http => {
            try out.appendSlice(alloc, "Fetch data from: ");
            try writeHostList(out, alloc, m.http_hosts);
            try out.append(alloc, '.');
        },
        .net_ws => {
            try out.appendSlice(alloc, "Stream data from: ");
            try writeHostList(out, alloc, m.ws_hosts);
            try out.append(alloc, '.');
        },
        .storage => try out.appendSlice(alloc, "Keep its own settings and data."),
        .files => {
            try out.appendSlice(alloc, "Open ");
            for (m.file_types, 0..) |ft, i| {
                if (i > 0) try out.appendSlice(alloc, if (i + 1 == m.file_types.len) " and " else ", ");
                try out.appendSlice(alloc, ft);
            }
            if (m.file_types.len > 0) try out.append(alloc, ' ');
            try out.appendSlice(alloc, "files you choose.");
        },
    }
}

fn writeHostList(out: *std.ArrayList(u8), alloc: std.mem.Allocator, hosts: []const []u8) !void {
    for (hosts, 0..) |h, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, if (std.mem.eql(u8, h, broker.local_token)) "your own network" else h);
    }
}

/// The sentences of `of`'s capabilities as a comma-separated run of JSON
/// strings, skipping any whose sentence `unless` would print identically.
/// With `unless` null that is simply all of them; with it, the run is the
/// consent delta — a changed host list changes the sentence, so it shows.
pub fn writeSentences(out: *std.ArrayList(u8), alloc: std.mem.Allocator, of: *const Manifest, unless: ?*const Manifest) error{OutOfMemory}!void {
    var first = true;
    for (sentence_order) |cap| {
        if (!of.caps.contains(cap)) continue;
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(alloc);
        try writeSentence(&s, alloc, cap, of);
        if (unless) |other| {
            if (other.caps.contains(cap)) {
                var o: std.ArrayList(u8) = .empty;
                defer o.deinit(alloc);
                try writeSentence(&o, alloc, cap, other);
                if (std.mem.eql(u8, s.items, o.items)) continue;
            }
        }
        if (!first) try out.append(alloc, ',');
        first = false;
        try writeJsonString(out, alloc, s.items);
    }
}

pub fn pkgBaseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[cut + 1 ..];
}

/// install.md's per-platform table. Null when the platform names no place —
/// Android's files directory has no path in the environment, so a shell there
/// sets `Options.install_root` instead.
pub fn installRootAlloc(alloc: std.mem.Allocator) ?[]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const appdata = std.c.getenv("APPDATA") orelse return null;
            const s = std.mem.span(appdata);
            if (s.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}\\Lookout Marine\\Plugins", .{s}) catch null;
        },
        .macos => {
            const home = std.mem.span(std.c.getenv("HOME") orelse return null);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/Lookout Marine/Plugins", .{home}) catch null;
        },
        .linux => {
            if (std.c.getenv("XDG_DATA_HOME")) |x| {
                const s = std.mem.span(x);
                if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout-marine/plugins", .{s}) catch null;
            }
            const home = std.mem.span(std.c.getenv("HOME") orelse return null);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/.local/share/lookout-marine/plugins", .{home}) catch null;
        },
        else => return null,
    }
}

/// True when the id can be a directory name under the install root:
/// reverse-DNS characters only, no separators, no leading dot. An id that
/// fails this is refused at install and never touches the disk.
pub fn idSafe(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    if (id[0] == '.') return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// `{"v":1,"granted":["ais.read",…]}` — the capabilities the mariner has left
/// on. The manifest stays the asked-for set; this file is the subset in force.
pub fn writeGrantsJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, caps: broker.Caps) !void {
    try out.appendSlice(alloc, "{\"v\":1,\"granted\":[");
    var first = true;
    for (sentence_order) |cap| {
        if (!caps.contains(cap)) continue;
        if (!first) try out.append(alloc, ',');
        first = false;
        try writeJsonString(out, alloc, cap.name());
    }
    try out.appendSlice(alloc, "]}");
}

/// Null when the text is not a grants file at all. The caller treats that as
/// nothing granted, never as everything: this is a permissions file. A cap
/// name a newer host wrote and this one does not know grants nothing and
/// refuses nothing.
pub fn parseGrants(alloc: std.mem.Allocator, text: []const u8) ?broker.Caps {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const list = parsed.value.object.get("granted") orelse return null;
    if (list != .array) return null;
    var caps = broker.Caps.initEmpty();
    for (list.array.items) |item| switch (item) {
        .string => |s| if (broker.Cap.fromName(s)) |cap| caps.insert(cap),
        else => return null,
    };
    return caps;
}

/// True when `a` reads as an older version than `b`. Dotted segments compare
/// numerically when both are numbers, lexically otherwise; a missing segment
/// is zero. This only ever decides whether the consent sheet says
/// "downgrade", so a tie or an unparseable pair is simply not one.
pub fn versionLess(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const sa = ia.next();
        const sb = ib.next();
        if (sa == null and sb == null) return false;
        const ta = sa orelse "0";
        const tb = sb orelse "0";
        const na = std.fmt.parseInt(u64, ta, 10) catch null;
        const nb = std.fmt.parseInt(u64, tb, 10) catch null;
        if (na != null and nb != null) {
            if (na.? != nb.?) return na.? < nb.?;
        } else switch (std.mem.order(u8, ta, tb)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
}

/// The name broker.zig's KvStore saves a plugin's storage under, replicated
/// here so `uninstall` can take the file with the plugin. Kept in step with
/// KvStore.fileName by the comment on both.
pub fn storageFileName(id: []const u8, buf: []u8) []const u8 {
    const n = @min(id.len, buf.len - 5);
    for (id[0..n], 0..) |c, i| buf[i] = switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => c,
        else => '_',
    };
    @memcpy(buf[n .. n + 5], ".json");
    return buf[0 .. n + 5];
}

/// Where broker.zig keeps plugin storage when nobody called setStorageDir,
/// replicated from its defaultStorageDir for the same reason as the name.
pub fn storageDirDefault(alloc: std.mem.Allocator) ?[]u8 {
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

// ---- tests -------------------------------------------------------------------

const t = std.testing;
const parseManifest = manifest.parseManifest;

test "the consent sentences read exactly as install.md words them" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.example.everything","api":1,"capabilities":[
        \\ "vessel.read","ais.read","vessel.publish","ais.publish",
        \\ "overlay.draw","alerts.raise",
        \\ {"net.tcp-client":["local"]},
        \\ {"net.udp":[10110,4001]},
        \\ {"net.http":["nomads.ncep.noaa.gov"]},
        \\ {"net.ws":["demo.signalk.org","local"]},
        \\ "storage","files"],
        \\ "file_types":[".grib2",".grb"]}
    );
    defer m.deinit(a);

    const expect = [_][]const u8{
        "Read your instruments: position, heading, depth, wind.",
        "Read AIS traffic.",
        "Provide instrument readings to the chart.",
        "Provide AIS targets to the chart.",
        "Draw on the chart.",
        "Raise alarms.",
        "Connect to instruments on: your own network.",
        "Listen for broadcasts on ports 10110 and 4001.",
        "Fetch data from: nomads.ncep.noaa.gov.",
        "Stream data from: demo.signalk.org, your own network.",
        "Keep its own settings and data.",
        "Open .grib2 and .grb files you choose.",
    };
    for (sentence_order, expect) |cap, want| {
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(a);
        try writeSentence(&s, a, cap, &m);
        try t.expectEqualStrings(want, s.items);
    }

    // The delta writer: everything against nothing is everything, and a
    // manifest against itself is silence.
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(a);
    try writeSentences(&all, a, &m, null);
    try t.expectEqual(@as(usize, expect.len), std.mem.count(u8, all.items, "\"") / 2);
    var none: std.ArrayList(u8) = .empty;
    defer none.deinit(a);
    try writeSentences(&none, a, &m, &m);
    try t.expectEqualStrings("", none.items);

    // A changed host list changes the sentence, so it shows in the delta.
    var other = try parseManifest(a,
        \\{"id":"org.example.everything","api":1,"capabilities":[{"net.http":["tiles.example.org"]}]}
    );
    defer other.deinit(a);
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(a);
    try writeSentences(&delta, a, &other, &m);
    try t.expectEqualStrings("\"Fetch data from: tiles.example.org.\"", delta.items);

    // One address, and one port, read in the singular.
    var one = try parseManifest(a,
        \\{"id":"org.example.one","api":1,"capabilities":[
        \\ {"net.tcp-client":["gateway.example.com"]},{"net.udp":[10110]}]}
    );
    defer one.deinit(a);
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(a);
    try writeSentence(&s, a, .net_tcp_client, &one);
    try t.expectEqualStrings("Connect to instruments on: gateway.example.com.", s.items);
    s.clearRetainingCapacity();
    try writeSentence(&s, a, .net_udp, &one);
    try t.expectEqualStrings("Listen for broadcasts on port 10110.", s.items);
}

test "grants.json round-trips, and a malformed one grants nothing" {
    const a = t.allocator;
    var caps = broker.Caps.initEmpty();
    caps.insert(.ais_read);
    caps.insert(.overlay_draw);
    caps.insert(.net_http);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try writeGrantsJson(&json, a, caps);
    try t.expectEqualStrings("{\"v\":1,\"granted\":[\"ais.read\",\"overlay.draw\",\"net.http\"]}", json.items);

    const back = parseGrants(a, json.items).?;
    try t.expect(back.eql(caps));

    // An empty grant list is a valid file that grants nothing.
    const empty = parseGrants(a, "{\"v\":1,\"granted\":[]}").?;
    try t.expectEqual(@as(usize, 0), empty.count());

    // A name a newer host knows grants nothing here and refuses nothing.
    const newer = parseGrants(a, "{\"v\":1,\"granted\":[\"ais.read\",\"net.quic\"]}").?;
    try t.expectEqual(@as(usize, 1), newer.count());

    // Not a grants file at all: null, which the loader reads as NOTHING
    // granted, never as everything.
    try t.expect(parseGrants(a, "not json") == null);
    try t.expect(parseGrants(a, "[]") == null);
    try t.expect(parseGrants(a, "{\"v\":1}") == null);
    try t.expect(parseGrants(a, "{\"v\":1,\"granted\":[1]}") == null);
}

test "version order decides only the downgrade sentence" {
    try t.expect(versionLess("1.2", "1.10"));
    try t.expect(!versionLess("1.10", "1.2"));
    try t.expect(versionLess("1.2", "1.2.1"));
    try t.expect(!versionLess("1.2", "1.2"));
    try t.expect(!versionLess("", ""));
    try t.expect(versionLess("", "0.1"));
    // Unparseable segments fall back to text order rather than lying.
    try t.expect(versionLess("1.0-beta", "1.0-rc"));
}

test "an id that could leave the install root is refused" {
    try t.expect(idSafe("org.example.downwind"));
    try t.expect(idSafe("a-b_c.9"));
    try t.expect(!idSafe(""));
    try t.expect(!idSafe(".hidden"));
    try t.expect(!idSafe("../escape"));
    try t.expect(!idSafe("a/b"));
    try t.expect(!idSafe("a\\b"));
    try t.expect(!idSafe("a b"));
}
