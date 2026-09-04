//! The import table a plugin calls: every function in module `lookout`, the
//! grant checked on each one, and the allowlist that says how far a granted
//! call may reach.
//!
//! A call the manifest did not ask for returns -1 (void imports return nothing)
//! and is counted. It never traps.

const std = @import("std");

const broker = @import("../broker.zig");
const alerts = @import("alerts.zig");
const budgets = @import("budgets.zig");
// `caps` names a local in the grant tests below, so this one is suffixed.
const caps_mod = @import("caps.zig");
const http = @import("http.zig");
const registry_json = @import("registry_json.zig");
const storage = @import("storage.zig");
const testing = @import("testing.zig");

const wasm = @import("../wasm.zig");
const webio = @import("../webio.zig");
const ais_store = @import("../aisstore.zig");

const Cap = caps_mod.Cap;
const Caps = caps_mod.Caps;
const FetchRequest = http.FetchRequest;
const Plugin = budgets.Plugin;
const level_err = caps_mod.level_err;
const level_info = caps_mod.level_info;
const level_warn = caps_mod.level_warn;
const monoMs = broker.monoMs;
const wallMs = broker.wallMs;
const atonType = registry_json.atonType;
const jsonBool = registry_json.jsonBool;
const jsonInt = registry_json.jsonInt;
const jsonNum = registry_json.jsonNum;
const writeJsonValue = registry_json.writeJsonValue;
const file_read_max = storage.file_read_max;

/// Longest `http_fetch` or `ws_connect` request JSON accepted.
const request_json_max = 8 * 1024;

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
    // Which refusal this is decides where the reader goes looking: a manifest
    // to edit, or a switch to turn back on. Saying "the manifest does not
    // request it" about a capability the manifest DOES request sends them to
    // the wrong file.
    if (p.asked.contains(cap)) {
        p.broker.say(level_err, p.id, "denied {s}: capability {s} is switched off for this plugin", .{ call, cap.name() });
    } else {
        p.broker.say(level_err, p.id, "denied {s}: manifest does not request capability {s}", .{ call, cap.name() });
    }
    return false;
}

fn hostLog(env: wasm.c.wasm_exec_env_t, level: u32, ptr: [*c]const u8, len: u32) callconv(.c) void {
    const p = caller(env) orelse return;
    if (!p.chargeLog()) return;
    p.broker.log_fn(p.broker.log_ctx, @min(level, level_err), p.id, bytes(ptr, len));
}

fn hostNowMs(env: wasm.c.wasm_exec_env_t) callconv(.c) i64 {
    _ = env;
    return wallMs();
}

/// Fill the caller's buffer with cryptographically secure random bytes.
/// Capability-free like the clocks: the sandbox has no entropy of its own,
/// and a plugin minting an identity key needs some.
fn hostRandBytes(env: wasm.c.wasm_exec_env_t, ptr: [*c]u8, cap: u32) callconv(.c) i32 {
    _ = caller(env) orelse return -1;
    if (ptr == null or cap == 0) return 0;
    // The same CSPRNG the TLS layer draws from (webio.zig).
    std.Io.Threaded.global_single_threaded.io().random(ptr[0..cap]);
    return @intCast(cap);
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

/// Which of the plugin's sources a batch was published under. `"source"`
/// carries a connection's place in the mariner's list, counting from one; a
/// batch without it is the plugin publishing as itself.
///
/// A place the plugin does not own is a fault in the module, not a grant
/// violation, so it is said once per batch and the values still land.
fn batchSource(p: *Plugin, o: std.json.ObjectMap, call: []const u8) broker.SourceId {
    const place = jsonInt(o.get("source")) orelse return p.source;
    if (place <= 0) return p.source;
    if (place >= p.source_span) {
        p.broker.say(level_warn, p.id, "{s}: no connection {d}; published as the plugin", .{ call, place });
        return p.source;
    }
    return p.sourceAt(@intCast(place));
}

/// `{"updates":[{"path":..,"value":..,"ts":..}]}`, with an optional `"source"`
/// naming the connection it came from. A bad update is skipped and counted; a
/// batch that is not an object at all fails. The return is the number of
/// updates applied, so a plugin can see its own typos.
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
    const source = batchSource(p, parsed.value.object, "publish");

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
        p.broker.vessels.set(path, text.items, ts, source) catch |e| {
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
    return applyAisUpsert(p, bytes(ptr, len));
}

/// `{"targets":[...]}`, with an optional `"source"` naming the connection that
/// heard them. A bad target is skipped; the return is the number applied.
fn applyAisUpsert(p: *Plugin, json: []const u8) i32 {
    const alloc = p.broker.alloc;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch {
        p.broker.say(level_warn, p.id, "ais_upsert: malformed JSON", .{});
        return -1;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return -1;
    const targets = parsed.value.object.get("targets") orelse return -1;
    if (targets != .array) return -1;
    const source = batchSource(p, parsed.value.object, "ais_upsert");
    // Display provenance only; the store arbitrates by ts.
    const net = jsonBool(parsed.value.object.get("net")) orelse false;

    // Clamped because the store reads no wall clock: a future `ts` would
    // outrank every live report and never evict; an ancient one would evict
    // on the next tick while churning the change counter.
    const now = wallMs();
    const ts_floor = now - ais_store.default_evict_ms;
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
            // A target's own key overrides the batch, so a bridge re-publishing
            // a mixed set keeps each target's provenance.
            .net = jsonBool(o.get("net")) orelse net,
            .ts_ms = std.math.clamp(jsonInt(o.get("ts")) orelse now, ts_floor, now),
        };
        const landed = p.broker.ais.upsert(upd, source) catch |e| {
            p.broker.say(level_warn, p.id, "ais_upsert {d}: {s}", .{ mmsi, @errorName(e) });
            continue;
        };
        // An outranked update is not an error, but it did not land, and the
        // return is the number applied.
        if (landed) applied += 1;
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
/// warning at warn, notice at info.
///
/// The line has to carry the difference between "you may want to know" and
/// "act now": an alarm at info is an alarm nobody sees, and a notice at error
/// is an operator who learns to ignore red. `alerts.severityOf` decides which
/// tier the payload named.
fn alertLevel(json: []const u8) u32 {
    return switch (alerts.severityOf(json)) {
        .notice => level_info,
        .warning => level_warn,
        .alarm => level_err,
    };
}

/// Raise an alert: the host holds it for the shell to show and to sound, and
/// says it in the log. -1 for a payload with nothing in it, matching the SDK,
/// where -1 means the grant is missing or the payload did not fit.
fn hostAlert(env: wasm.c.wasm_exec_env_t, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .alerts_raise, "alert")) return -1;
    const text = bytes(ptr, len);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return -1;
    p.broker.raiseAlert(p, text);
    p.broker.say(alertLevel(text), p.id, "ALERT {s}", .{text});
    return 0;
}

fn hostTcpConnect(env: wasm.c.wasm_exec_env_t, host_ptr: [*c]const u8, host_len: u32, port: u32) callconv(.c) i64 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_tcp_client, "tcp_connect")) return -1;
    if (port == 0 or port > 65535) return -1;
    const addr = bytes(host_ptr, host_len);
    if (!allowAddress(p, "tcp_connect", addr)) return -1;
    return p.broker.openConn(p.index, addr, @intCast(port));
}

fn hostTcpSend(env: wasm.c.wasm_exec_env_t, id: i64, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_tcp_client, "tcp_send")) return -1;
    const data = bytes(ptr, len);
    if (!p.chargeWire("tcp_send", data.len)) return -1;
    return p.broker.sendConn(p.index, id, data);
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
    // Clamped both ways: see max_timer_delay_ms.
    const delay = std.math.clamp(delay_ms, 1, broker.max_timer_delay_ms);
    b.mu.lock();
    defer b.mu.unlock();
    var held: usize = 0;
    for (b.timers.items) |tm| {
        if (tm.plugin == p.index) held += 1;
    }
    if (held >= broker.max_timers_per_plugin) return -1;
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

/// Largest bus frame: enough for a read's worth of NMEA sentences or a JSON
/// event. Larger data belongs in storage, announced with a small frame here.
pub const bus_frame_max = 64 * 1024;

fn hostBusPublish(env: wasm.c.wasm_exec_env_t, topic_ptr: [*c]const u8, topic_len: u32, ptr: [*c]const u8, len: u32) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .bus_publish, "bus_publish")) return -1;
    const topic = bytes(topic_ptr, topic_len);
    if (!topicListed(p.pub_topics, topic)) {
        p.denied += 1;
        p.broker.denied += 1;
        p.broker.say(level_err, p.id, "denied bus_publish: {s} is not in the manifest's bus.publish topic list", .{topic});
        return -1;
    }
    const data = bytes(ptr, len);
    if (data.len > bus_frame_max) {
        p.broker.say(level_warn, p.id, "bus_publish {s}: frame over {d} bytes dropped", .{ topic, bus_frame_max });
        return -1;
    }
    return p.broker.busPublish(p, topic, data);
}

const topicListed = caps_mod.topicListed;

fn hostViewSubscribe(env: wasm.c.wasm_exec_env_t) callconv(.c) i32 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .view_read, "view_subscribe")) return -1;
    const b = p.broker;
    b.mu.lock();
    defer b.mu.unlock();
    p.view_sub = true;
    // Deliver the current view to THIS plugin on the next tick rather than
    // waiting for a pan; nobody else hears a duplicate.
    p.view_pending = true;
    return 0;
}

// -- UDP ----------------------------------------------------------------------

fn hostUdpOpen(env: wasm.c.wasm_exec_env_t, port: u32) callconv(.c) i64 {
    const p = caller(env) orelse return -1;
    if (!allow(p, .net_udp, "udp_open")) return -1;
    if (port > 65535) return -1;
    if (!allowPort(p, "udp_open", @intCast(port))) return -1;
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
    const data = bytes(ptr, len);
    if (!p.chargeWire("udp_send", data.len)) return -1;
    return p.broker.sendUdp(p.index, id, data, bytes(host_ptr, host_len), @intCast(port));
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

/// Whether one address is covered by a grant's list. `local` matches anything
/// on the boat's own network; everything else is an exact, case-insensitive
/// hostname match. There are no wildcards: a plugin that needs two servers
/// names two servers, and nobody has to reason about what `*.noaa.gov` covers
/// at three in the morning.
fn addressListed(list: []const []const u8, addr: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, local_token)) {
            if (isLocalHost(addr)) return true;
            continue;
        }
        if (webio.sameHost(entry, addr)) return true;
    }
    return false;
}

/// Whether this plugin's `net.tcp-client` grant covers the address it is
/// dialling. Checked HERE, at the call, the way the http and ws host lists
/// are: a refused dial is a denied call that answers -1, never a trap.
///
/// The plugin holds the capability by this point, so the refusal is about
/// reach: a gateway plugin granted `local` cannot dial the internet however
/// its connection rows are filled in.
fn allowAddress(p: *Plugin, call: []const u8, addr: []const u8) bool {
    if (addressListed(p.tcp_addrs, addr)) return true;
    p.denied += 1;
    p.broker.denied += 1;
    p.broker.say(level_err, p.id, "denied {s}: {s} is not in the manifest's net.tcp-client address list", .{ call, addr });
    return false;
}

/// Whether this plugin's `net.udp` grant covers the port it is binding. Port 0
/// asks the system for whatever is free, which is not a port the mariner was
/// shown, so it is refused like any other unlisted one.
fn allowPort(p: *Plugin, call: []const u8, port: u16) bool {
    for (p.udp_ports) |granted| {
        if (granted == port) return true;
    }
    p.denied += 1;
    p.broker.denied += 1;
    p.broker.say(level_err, p.id, "denied {s}: port {d} is not in the manifest's net.udp port list", .{ call, port });
    return false;
}

/// Whether this plugin's manifest named the host in `url`.
///
/// The grant is per HOST, not per capability: `net.http` on its own grants
/// nothing, and the allowlist is what the mariner consented to.
fn allowUrl(p: *Plugin, cap: Cap, call: []const u8, url_text: []const u8) bool {
    if (!allow(p, cap, call)) return false;
    const url = webio.Url.parse(url_text) catch {
        p.broker.say(level_warn, p.id, "{s}: {s} is not a URL this host can fetch", .{ call, url_text });
        return false;
    };
    const hosts = if (cap == .net_http) p.http_hosts else p.ws_hosts;
    if (addressListed(hosts, url.host)) return true;
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
    const data = bytes(ptr, len);
    if (!p.chargeWire("ws_send", data.len)) return -1;
    return p.broker.sendWs(p.index, id, data);
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
    .{ .name = "rand_bytes", .func = @ptrCast(&hostRandBytes), .signature = "(*~)i" },
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
    .{ .name = "view_subscribe", .func = @ptrCast(&hostViewSubscribe), .signature = "()i" },
    .{ .name = "bus_publish", .func = @ptrCast(&hostBusPublish), .signature = "(*~*~)i" },
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
    wasm.c.wasm_runtime_set_enlarge_mem_error_callback(&memoryRefused, null);
}

pub fn unregisterNatives() void {
    wasm.c.wasm_runtime_set_enlarge_mem_error_callback(null, null);
    wasm.unregisterNatives("lookout", &natives);
}

/// A `memory.grow` the runtime refused, which is the linear-memory budget
/// biting. WAMR has already answered the module -1, so the plugin sees its own
/// allocation fail and decides what to do; this only makes the refusal
/// visible, on the plugin's own dispatch thread.
///
/// MAX_SIZE_REACHED is the ceiling. Anything else is the host itself out of
/// memory, which is not the plugin's budget and is not named as one.
fn memoryRefused(
    inc_pages: u32,
    current_bytes: u64,
    memory_index: u32,
    reason: wasm.c.enlarge_memory_error_reason_t,
    inst: wasm.c.wasm_module_inst_t,
    env: wasm.c.wasm_exec_env_t,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = memory_index;
    _ = user_data;
    // The exec env is the interpreter's and is set for the whole call, but the
    // instance carries the same pointer for the paths where it is not.
    const raw = (if (env != null) wasm.callerUserData(env) else null) orelse
        wasm.c.wasm_runtime_get_custom_data(inst) orelse return;
    const p: *Plugin = @ptrCast(@alignCast(raw));
    if (reason != @as(@TypeOf(reason), @intCast(wasm.c.MAX_SIZE_REACHED))) {
        p.broker.say(level_err, p.id, "memory.grow of {d} page(s) failed inside the host", .{inc_pages});
        return;
    }
    p.noteBudget(
        .memory,
        "throttled: memory.grow of {d} page(s) refused at the {d} MiB linear-memory budget ({d} MiB in use)",
        .{ inc_pages, @divTrunc(max_memory_bytes, 1024 * 1024), @divTrunc(current_bytes, 1024 * 1024) },
    );
}

/// Linear memory one plugin may hold. Kept here beside the other budgets; the
/// host turns it into the page count it instantiates with.
pub const max_memory_bytes: i64 = 64 * 1024 * 1024;
pub const wasm_page_bytes: u32 = 64 * 1024;
pub const max_memory_pages: u32 = @intCast(@divTrunc(max_memory_bytes, wasm_page_bytes));

const t = std.testing;
const Fixture = testing.Fixture;

// -- publishing ------------------------------------------------------------------------

/// A plugin with a connection list, as the host builds one: its own source id
/// and one for each of the eight rows a list holds, registered in ascending
/// order so a row's place is its rank. The eight is the host's cap, which this
/// layer sits below and cannot import.
fn withConnections(fx: *Fixture, id: []const u8, base: broker.SourceId) !Plugin {
    const p = Plugin{
        .broker = &fx.br,
        .index = 0,
        .id = id,
        .source = base,
        .source_span = 1 + 8,
        .caps = Caps.initEmpty(),
    };
    for (0..p.source_span) |k| {
        try fx.vessels.registerSource(base + @as(broker.SourceId, @intCast(k)));
    }
    return p;
}

/// `{"source":n,"updates":[{"path":..,"value":{lat,lon},"ts":..}]}`.
fn positionBatch(buf: []u8, place: u32, lat: f64, ts_ms: i64) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"source\":{d},\"updates\":[{{\"path\":\"navigation.position\"," ++
            "\"value\":{{\"lat\":{d},\"lon\":-76.48}},\"ts\":{d}}}]}}",
        .{ place, lat, ts_ms },
    );
}

test "two connections of one plugin publish as two sources" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);

    var p = try withConnections(fx, "org.beetlebug.nmea0183", 1);
    try fx.br.registerPlugin(&p);

    // Two gateways on one plugin, both carrying position, both fresh, writing
    // in turn the way two sockets do. The first row is off Annapolis; the
    // second reads thirty miles north of it.
    var buf: [192]u8 = undefined;
    var ts: i64 = 1_000;
    while (ts <= 4_000) : (ts += 1_000) {
        try t.expectEqual(@as(i32, 1), applyPublish(&p, try positionBatch(&buf, 1, 38.98, ts)));
        try t.expectEqual(@as(i32, 1), applyPublish(&p, try positionBatch(&buf, 2, 39.5, ts)));

        // The election holds the first row for as long as its fixes are fresh,
        // so own ship stays where the first gateway puts it instead of walking
        // north and back with every sentence.
        const r = fx.vessels.readElected("navigation.position", ts).?;
        try t.expectEqual(p.sourceAt(1), r.source);
        try t.expectApproxEqAbs(@as(f64, 38.98), r.value.position.lat, 1e-9);
    }

    // The first gateway goes quiet. Past its staleness window the second row
    // holds own ship on its own, and it is not flagged stale: it never stopped.
    _ = applyPublish(&p, try positionBatch(&buf, 2, 39.5, 10_000));
    const over = fx.vessels.readElected("navigation.position", 10_000).?;
    try t.expectEqual(p.sourceAt(2), over.source);
    try t.expect(!over.stale);
    try t.expectApproxEqAbs(@as(f64, 39.5), over.value.position.lat, 1e-9);

    // The first gateway speaks again and takes own ship back.
    _ = applyPublish(&p, try positionBatch(&buf, 1, 38.98, 10_100));
    try t.expectEqual(p.sourceAt(1), fx.vessels.readElected("navigation.position", 10_100).?.source);
}

test "a batch names its connection, and a place the plugin does not own is said out loud" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);

    var p = try withConnections(fx, "org.beetlebug.nmea0183", 1);
    try fx.br.registerPlugin(&p);

    // No `source` is the plugin publishing as itself, which is what a plugin
    // with no connection list does and what every older module sends.
    _ = applyPublish(&p, "{\"updates\":[{\"path\":\"navigation.headingTrue\",\"value\":271,\"ts\":0}]}");
    try t.expectEqual(p.source, fx.vessels.readElected("navigation.headingTrue", 0).?.source);

    // A place past the block is a fault in the module. The value still lands,
    // under the plugin, because losing a fix to a numbering bug is worse than
    // losing the provenance of one.
    _ = applyPublish(&p, "{\"source\":99,\"updates\":[{\"path\":\"navigation.magneticVariation\",\"value\":-11,\"ts\":0}]}");
    try t.expectEqual(p.source, fx.vessels.readElected("navigation.magneticVariation", 0).?.source);
    try t.expect(fx.sink.has("no connection 99"));
}

test "AIS targets carry the connection that heard them" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);

    var p = try withConnections(fx, "org.beetlebug.nmea0183", 1);
    try fx.br.registerPlugin(&p);

    const first = "{\"source\":1,\"targets\":[{\"mmsi\":899000111,\"lat\":38.98,\"lon\":-76.48,\"ts\":0}]}";
    const second = "{\"source\":2,\"targets\":[{\"mmsi\":899000222,\"lat\":39.5,\"lon\":-76.48,\"ts\":0}]}";
    try t.expectEqual(@as(i32, 1), applyAisUpsert(&p, first));
    try t.expectEqual(@as(i32, 1), applyAisUpsert(&p, second));
    try t.expectEqual(p.sourceAt(1), fx.ais.get(899000111).?.source);
    try t.expectEqual(p.sourceAt(2), fx.ais.get(899000222).?.source);

    // One receiver switched off takes its own targets and leaves the other's.
    try t.expectEqual(@as(usize, 1), try fx.ais.clearSource(p.sourceAt(1)));
    try t.expectEqual(@as(usize, 1), fx.ais.count());
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

    // Nothing above was in the manifest, so every refusal said so.
    try t.expect(fx.sink.has("denied net.udp: manifest does not request capability net.udp"));

    // A capability the manifest DOES ask for, switched off by the mariner,
    // reads differently: the reader has a switch to find, not a manifest to
    // edit.
    var asked = Caps.initEmpty();
    asked.insert(.alerts_raise);
    var q = Plugin{
        .broker = b,
        .index = 1,
        .id = "org.beetlebug.revoked",
        .source = 2,
        .caps = Caps.initEmpty(),
        .asked = asked,
    };
    try t.expect(!allow(&q, .alerts_raise, "alert"));
    try t.expect(fx.sink.has("denied alert: capability alerts.raise is switched off for this plugin"));
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

test "a plugin granted local dials the boat's network and nothing beyond it" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    var caps = Caps.initEmpty();
    caps.insert(.net_tcp_client);
    var p = Plugin{
        .broker = b,
        .index = 0,
        .id = "org.beetlebug.nmea0183",
        .source = 1,
        .caps = caps,
        .tcp_addrs = &.{local_token},
    };

    // The boat's own network: loopback, the three private ranges, link-local,
    // IPv6 unique-local, and the names mDNS serves. This is every address a
    // mariner's gateway can actually be at.
    for ([_][]const u8{
        "127.0.0.1",     "localhost",   "10.0.1.7",
        "172.16.4.1",    "192.168.1.1", "169.254.3.9",
        "gateway.local", "fd00::1",     "::1",
    }) |addr| {
        try t.expect(allowAddress(&p, "tcp_connect", addr));
    }
    try t.expectEqual(@as(u32, 0), p.denied);

    // The internet, however the address is written. A gateway plugin that is
    // handed a public address in its connection rows does not dial it.
    for ([_][]const u8{
        "example.com", "8.8.8.8", "172.32.0.1", "11.0.0.1", "192.169.1.1", "2606:4700::1",
    }) |addr| {
        try t.expect(!allowAddress(&p, "tcp_connect", addr));
    }
    try t.expectEqual(@as(u32, 6), p.denied);
    try t.expectEqual(@as(u32, 6), b.denied);
    try t.expect(fx.sink.has("denied tcp_connect: example.com is not in the manifest's net.tcp-client address list"));

    // A named address is exact and case-insensitive, and grants nothing else.
    var named = Plugin{
        .broker = b,
        .index = 0,
        .id = "org.example.cloud",
        .source = 1,
        .caps = caps,
        .tcp_addrs = &.{"tiles.example.org"},
    };
    try t.expect(allowAddress(&named, "tcp_connect", "TILES.example.ORG"));
    try t.expect(!allowAddress(&named, "tcp_connect", "a.tiles.example.org"));
    try t.expect(!allowAddress(&named, "tcp_connect", "127.0.0.1"));

    // The capability with no addresses reaches nothing, which is what an
    // ungranted plugin looks like from here.
    var nowhere = Plugin{ .broker = b, .index = 0, .id = "org.example.bare", .source = 1, .caps = caps };
    try t.expect(!allowAddress(&nowhere, "tcp_connect", "127.0.0.1"));
}

test "a udp grant binds the ports it named and no others" {
    const a = t.allocator;
    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    var caps = Caps.initEmpty();
    caps.insert(.net_udp);
    var p = Plugin{
        .broker = b,
        .index = 0,
        .id = "org.example.listener",
        .source = 1,
        .caps = caps,
        .udp_ports = &.{ 10110, 4001 },
    };
    try t.expect(allowPort(&p, "udp_open", 10110));
    try t.expect(allowPort(&p, "udp_open", 4001));
    try t.expectEqual(@as(u32, 0), p.denied);

    // A neighbouring port, and the ephemeral bind: neither is a port the
    // mariner was shown.
    try t.expect(!allowPort(&p, "udp_open", 10111));
    try t.expect(!allowPort(&p, "udp_open", 0));
    try t.expectEqual(@as(u32, 2), p.denied);
    try t.expect(fx.sink.has("denied udp_open: port 10111 is not in the manifest's net.udp port list"));
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
