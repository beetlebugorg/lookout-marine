//! AIS traffic over the internet, from an aiscast relay.
//!
//! Most boats have no AIS receiver. The relay aggregates open government
//! feeds, volunteer receivers and other aggregators, and streams AIS by
//! bounding box over a websocket: send one subscribe frame, get one JSON
//! event per deduplicated message. This plugin subscribes for the chart view
//! and upserts what arrives, so the symbols, the target table, CPA and the
//! collision alarm all work with nothing on the boat but an internet
//! connection.
//!
//! Every upsert is marked `net`: internet traffic can be stale or patchy, and
//! the target list says "Internet" so the mariner can tell it from a receiver.
//! Targets are stamped with each message's own time rather than receipt time,
//! which is what lets the store's freshest-report arbitration weigh this feed
//! against a live receiver.
//!
//! THE SUBSCRIPTION FOLLOWS THE VIEW with hysteresis: the subscribed box is
//! the view inflated by a margin, and a new subscribe frame goes out only
//! when the view centre leaves the middle of THAT BOX or the zoom changes
//! materially — a pan does not thrash the relay. The relay's welcome frame
//! advertises the connection's area cap, so a zoomed-out view degrades to a
//! capped box around the view's centre, and the centre rule is what still
//! resubscribes on a short pan at those scales.

const std = @import("std");
const lk = @import("lk2");
const cfg = @import("config.zig");

comptime {
    lk.plugin(@This());
}

pub const Connections = cfg.Connections;
const Connection = Connections.Connection;

const knot_mps = 1852.0 / 3600.0;

/// The box is the view inflated by this much on each side, so traffic is
/// already flowing when a small pan lands.
const pad = 0.30;
/// The area cap assumed until the welcome frame names the real one: the
/// anonymous tier's 100 square degrees with the margin applied.
const max_area_sqdeg = 100.0 * area_margin;
/// Subscribed just under the advertised cap, so float rounding in the box
/// arithmetic can never trip the relay's refusal.
const area_margin = 0.96;
/// Resubscribe when the view centre drifts past this fraction of the
/// SUBSCRIBED box's span, or the view span changes by more than this ratio.
const resub_center = 0.25;
const resub_ratio = 1.4;
/// The relay allows about one subscription change a second; half that leaves
/// margin and still tracks a pan closely.
const min_sub_interval_ms = 2_000;
/// A report's stamp is clamped into [now - this, now]. The lower bound caps
/// what a skewed upstream clock can do — the store would otherwise evict an
/// honestly-old-looking target at once — while ages up to five minutes stay
/// truthful in the target list.
const max_report_age_ms = 300_000;

var url_buf: [640]u8 = undefined;
var sub_buf: [320]u8 = undefined;

/// The chart view as the host last reported it.
var view: ?lk.ViewBox = null;

/// One-shot armed when a resubscribe is due but rate-limited; -1 when none.
/// One timer for the plugin: the interval is per connection, but re-checking
/// every connection on fire costs nothing and needs no per-row bookkeeping.
var retry_timer: i64 = -1;

/// The relay identity, one per plugin however many rows share it: a bearer
/// token any socket may present. Loaded from storage at start, registered
/// in-band when sharing first needs it.
///
/// A token is `ak1.<claims>.<signature>`, so its length follows the claims it
/// carries: a personal one measures a little over 300 bytes, and one carrying
/// bbox or cidr claims is longer. Sized well past that, because a token that
/// does not fit is a token silently thrown away.
var token_buf: [512]u8 = undefined;
var token_len: usize = 0;

fn token() []const u8 {
    return token_buf[0..token_len];
}

pub fn onStart(_: lk.raw.Start) !void {
    var buf: [token_buf.len + 64]u8 = undefined;
    const val = lk.raw.storageGet("identity", &buf) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, lk.scratch(), val, .{}) catch return;
    if (root != .object) return;
    const tok = jstr(root.object.get("token")) orelse return;
    if (tok.len == 0 or tok.len > token_buf.len) return;
    @memcpy(token_buf[0..tok.len], tok);
    token_len = tok.len;
}

pub fn endpoint(conn: *Connection) lk.Endpoint {
    // TLS on 443, which is the relay; any other port is a dev or loopback
    // instance speaking plain ws. The identity rides on every dial, sharing
    // on or off: it is not the toggle, and presenting it costs nothing. A
    // token the mariner pasted on the row outranks the minted one.
    const scheme = if (conn.port == 443) "wss" else "ws";
    const key = rowKey(conn);
    const url = if (key.len > 0)
        std.fmt.bufPrint(&url_buf, "{s}://{s}:{d}/v1/stream?key={s}", .{ scheme, conn.host.text(), conn.port, key }) catch
            return .{ .refused = "the address is too long for a websocket URL" }
    else
        std.fmt.bufPrint(&url_buf, "{s}://{s}:{d}/v1/stream", .{ scheme, conn.host.text(), conn.port }) catch
            return .{ .refused = "the address is too long for a websocket URL" };
    return .{ .ws = url };
}

/// The credential this row dials with: its own pasted token, or the minted
/// identity every row shares.
fn rowKey(conn: *Connection) []const u8 {
    const own = conn.cols.token.text();
    return if (own.len > 0) own else token();
}

pub fn onView(v: lk.ViewBox) void {
    view = v;
    for (Connections.all()) |conn| maybeResubscribe(conn);
}

pub fn onOpen(conn: *Connection) void {
    // A fresh socket has no subscription, whatever the last one carried.
    // The relay sends nothing until the first subscribe frame and sets no
    // deadline for it, so with no view yet this simply waits for onView.
    conn.state = .{};
    maybeResubscribe(conn);
    maybeRegister(conn);
}

pub fn onClose(conn: *Connection) void {
    conn.state = .{};
}

/// A row's line says "sharing" only once the relay has actually taken
/// something from it; anything earlier would be a hope, not a report.
pub fn connectionNote(conn: *Connection) []const u8 {
    return if (conn.state.acked) "sharing" else "";
}

/// The rate-limit and flush one-shots arrive here; the library claims
/// everything else first.
pub fn onEvent(e: lk.raw.Event) !void {
    switch (e) {
        .timer => |id| if (id == retry_timer) {
            retry_timer = -1;
            for (Connections.all()) |conn| maybeResubscribe(conn);
        } else if (id == share_timer) {
            share_timer = -1;
            flushShare();
        },
        else => {},
    }
}

fn maybeResubscribe(conn: *Connection) void {
    const v = view orelse return;
    if (!conn.connected()) return;
    const s = &conn.state;
    if (s.sub_view) |sv| if (s.sub_box) |sb| if (!drifted(v, sv, sb)) return;
    const mono = lk.monoMs();
    if (s.last_sub_ms != 0 and mono - s.last_sub_ms < min_sub_interval_ms) {
        if (retry_timer < 0) retry_timer = lk.raw.timerSet(min_sub_interval_ms - (mono - s.last_sub_ms), false);
        return;
    }
    subscribe(conn, v, mono);
}

/// True when the view has left the subscription: the centre out of the middle
/// half of the box actually subscribed — which the area cap can make far
/// smaller than the view — or the view span changed past the ratio.
fn drifted(v: lk.ViewBox, sub_view: lk.ViewBox, sub_box: lk.ViewBox) bool {
    const dlat = @abs((v.min_lat + v.max_lat) - (sub_box.min_lat + sub_box.max_lat)) / 2.0;
    const dlon = @abs(lk.wrapLon(((v.min_lon + v.max_lon) - (sub_box.min_lon + sub_box.max_lon)) / 2.0));
    if (dlat > resub_center * (sub_box.max_lat - sub_box.min_lat)) return true;
    if (dlon > resub_center * (sub_box.max_lon - sub_box.min_lon)) return true;
    const vlat = v.max_lat - v.min_lat;
    const vlon = v.max_lon - v.min_lon;
    const slat = sub_view.max_lat - sub_view.min_lat;
    const slon = sub_view.max_lon - sub_view.min_lon;
    if (vlat > slat * resub_ratio or vlat * resub_ratio < slat) return true;
    if (vlon > slon * resub_ratio or vlon * resub_ratio < slon) return true;
    return false;
}

/// The relay's first frame on every accepted socket, and again after an
/// in-band register: the limits actually in effect for this connection.
/// `limits.publish` appears only when the socket may publish, which is what
/// makes `keyed` the relay's word rather than a guess; `limits.area` is the
/// subscribed area it will accept, absent meaning unlimited. A cap that
/// changes what the open subscription covers forces a resubscribe — the tier
/// only ever changes on connect or register, so this is rare and cheap.
fn welcome(conn: *Connection, o: std.json.ObjectMap) void {
    const s = &conn.state;
    s.keyed = false;
    s.area_cap = null;
    if (o.get("limits")) |l| if (l == .object) {
        s.keyed = jbool(l.object.get("publish")) orelse false;
        if (jnum(l.object.get("area"))) |a| {
            // Negative means MMSI-only, which a chart subscription cannot
            // use; keep the default and let the relay's error frames say so.
            if (a > 0) s.area_cap = a * area_margin;
        } else {
            s.area_cap = std.math.inf(f64);
        }
    };
    const sv = s.sub_view orelse return;
    const ob = s.sub_box orelse return;
    const nb = computeBox(sv, s.area_cap orelse max_area_sqdeg);
    if (nb.min_lat != ob.min_lat or nb.min_lon != ob.min_lon or
        nb.max_lat != ob.max_lat or nb.max_lon != ob.max_lon)
    {
        s.sub_view = null;
        s.sub_box = null;
        maybeResubscribe(conn);
    }
}

fn subscribe(conn: *Connection, v: lk.ViewBox, mono: i64) void {
    const box = computeBox(v, conn.state.area_cap orelse max_area_sqdeg);
    var w = std.Io.Writer.fixed(&sub_buf);
    writeSubscribe(&w, box) catch return;
    if (conn.send(w.buffered()) < 0) {
        // A full send queue right after a reconnect. The relay sets no
        // deadline but also sends nothing until asked, so a static view
        // would otherwise stay silent forever.
        if (retry_timer < 0) retry_timer = lk.raw.timerSet(min_sub_interval_ms, false);
        return;
    }
    conn.state.sub_view = v;
    conn.state.sub_box = box;
    conn.state.last_sub_ms = mono;
}

/// The box to subscribe: the view padded, capped to the connection's area
/// with the aspect kept, centre wrapped to ±180. Longitude stays a continuous
/// span; the writer splits it at the antimeridian.
fn computeBox(v: lk.ViewBox, cap: f64) lk.ViewBox {
    var span_lat = (v.max_lat - v.min_lat) * (1.0 + 2.0 * pad);
    var span_lon = @min((v.max_lon - v.min_lon) * (1.0 + 2.0 * pad), 360.0);
    const area = span_lat * span_lon;
    if (area > cap) {
        const k = @sqrt(cap / area);
        span_lat *= k;
        span_lon *= k;
    }
    const clat = (v.min_lat + v.max_lat) / 2.0;
    const clon = lk.wrapLon((v.min_lon + v.max_lon) / 2.0);
    return .{
        .min_lat = @max(-90.0, clat - span_lat / 2.0),
        .min_lon = clon - span_lon / 2.0,
        .max_lat = @min(90.0, clat + span_lat / 2.0),
        .max_lon = clon + span_lon / 2.0,
    };
}

/// `{"type":"subscribe","snapshot":true,"bbox":[…]}`, split in two across
/// the antimeridian (the relay ORs the boxes). `snapshot` replays the box's
/// current vessels at once, so the chart fills without waiting minutes for
/// each anchored ship to transmit again; the replays carry their original
/// times, which the stamp clamp and the store's freshest-wins rule already
/// weigh honestly.
fn writeSubscribe(w: *std.Io.Writer, b: lk.ViewBox) !void {
    try w.writeAll("{\"type\":\"subscribe\",\"snapshot\":true,\"bbox\":[");
    if (b.min_lon < -180.0) {
        try oneBox(w, b.min_lat, b.min_lon + 360.0, b.max_lat, 180.0);
        try w.writeByte(',');
        try oneBox(w, b.min_lat, -180.0, b.max_lat, b.max_lon);
    } else if (b.max_lon > 180.0) {
        try oneBox(w, b.min_lat, b.min_lon, b.max_lat, 180.0);
        try w.writeByte(',');
        try oneBox(w, b.min_lat, -180.0, b.max_lat, b.max_lon - 360.0);
    } else {
        try oneBox(w, b.min_lat, b.min_lon, b.max_lat, b.max_lon);
    }
    try w.writeAll("]}");
}

fn oneBox(w: *std.Io.Writer, min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64) !void {
    try w.print("[{d:.4},{d:.4},{d:.4},{d:.4}]", .{ min_lat, min_lon, max_lat, max_lon });
}

// ---------------------------------------------------------------------------
// The stream
// ---------------------------------------------------------------------------

const jstr = lk.raw.jstrOpt;
const jnum = lk.raw.jnumOpt;
const jint = lk.raw.jintOpt;
const jbool = lk.raw.jboolOpt;

const position_types = [_][]const u8{
    "PositionReport",
    "StandardClassBPositionReport",
    "ExtendedClassBPositionReport",
    "LongRangeAisBroadcastMessage",
};

pub fn onData(conn: *Connection, data: []const u8) void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, lk.scratch(), data, .{}) catch return;
    if (root != .object) return;
    const o = root.object;
    const typ = jstr(o.get("type")) orelse return;
    if (std.mem.eql(u8, typ, "error")) {
        lk.log(.warn, "relay: {s}", .{jstr(o.get("error")) orelse "unnamed error"});
        return;
    }
    if (std.mem.eql(u8, typ, "welcome")) {
        welcome(conn, o);
        return;
    }
    if (std.mem.eql(u8, typ, "key")) {
        // Trusted only on the socket whose register asked for it. The relay
        // upgrades this connection in place and confirms with a fresh
        // welcome, which is what flips `keyed`.
        if (!conn.state.registered) return;
        const tok = jstr(o.get("token")) orelse return;
        if (tok.len == 0 or tok.len > token_buf.len) return;
        @memcpy(token_buf[0..tok.len], tok);
        token_len = tok.len;
        storeIdentity();
        lk.log(.info, "sharing identity minted", .{});
        return;
    }
    if (std.mem.eql(u8, typ, "ack")) {
        conn.state.acked = true;
        return;
    }
    if (!std.mem.eql(u8, typ, "event")) return;
    conn.count(1);

    const mmsi = jint(o.get("mmsi")) orelse return;
    if (mmsi <= 0 or mmsi > 0xffff_ffff) return;
    var tgt = lk.Target{ .mmsi = @intCast(mmsi) };

    // The relay carries the vessel's last known position on every event, so a
    // static message places its target too. Absent until one has been heard.
    if (jnum(o.get("lat"))) |la| if (jnum(o.get("lon"))) |lo| {
        if (@abs(la) <= 90.0 and @abs(lo) <= 180.0) tgt.at = .{ .lat = la, .lon = lo };
    };
    // The message's own time, so the store's freshest-report arbitration is
    // honest. Unparseable → null → the library stamps receipt time.
    if (isoMs(jstr(o.get("time")))) |t_ms| {
        const now = lk.nowMs();
        tgt.ts_ms = std.math.clamp(t_ms, now - max_report_age_ms, now);
    }

    const msg_type = jstr(o.get("msg_type")) orelse "";
    const msg: ?std.json.ObjectMap = if (o.get("message")) |m|
        (if (m == .object) m.object else null)
    else
        null;

    if (eqlAny(msg_type, &position_types)) {
        if (msg) |m| {
            // go-ais keeps the wire's "not available" sentinels: Sog 102.3
            // knots (type 27 encodes 6-bit knots, sentinel 63), Cog 360,
            // TrueHeading 511. Absent beats a lie.
            const sog_na: f64 = if (std.mem.eql(u8, msg_type, "LongRangeAisBroadcastMessage")) 63.0 else 102.2;
            if (jnum(m.get("Sog"))) |kn| {
                if (kn >= 0 and kn < sog_na) tgt.sog_mps = kn * knot_mps;
            }
            if (jnum(m.get("Cog"))) |c| {
                if (c >= 0 and c < 360.0) tgt.cog_deg = c;
            }
            if (jnum(m.get("TrueHeading"))) |h| {
                if (h >= 0 and h < 360.0) tgt.heading_deg = h;
            }
        }
    } else if (std.mem.eql(u8, msg_type, "ShipStaticData")) {
        if (msg) |m| setName(&tgt, m.get("Name"));
    } else if (std.mem.eql(u8, msg_type, "StaticDataReport")) {
        // Type 24 part A carries the name one level down.
        if (msg) |m| if (m.get("ReportA")) |a| if (a == .object) setName(&tgt, a.object.get("Name"));
    } else if (std.mem.eql(u8, msg_type, "AidsToNavigationReport")) {
        tgt.aton = true;
        if (msg) |m| {
            setName(&tgt, m.get("Name"));
            if (jint(m.get("Type"))) |ty| {
                if (ty >= 0 and ty <= 31) tgt.aton_type = @intCast(ty);
            }
            if (jbool(m.get("OffPosition"))) |b| tgt.off_position = b;
            if (jbool(m.get("VirtualAtoN")) orelse jbool(m.get("VirtualAton"))) |b| tgt.virtual_aton = b;
        }
    }
    // Anything else — a base station, a binary broadcast — still refreshes
    // the target's position and age, and says nothing more.

    if (tgt.at == null and tgt.name_str.len == 0 and !tgt.aton) return;
    var u = lk.Upsert.fromNet(conn);
    u.target(tgt);
    _ = u.send();
}

// ---------------------------------------------------------------------------
// Sharing: received sentences off the bus, back to the relay
// ---------------------------------------------------------------------------

/// Pending raw VDM lines (TAG blocks included), newest-wins on overflow: for
/// a live relay, dropping the stale backlog beats dropping what just arrived.
var share_buf: [4096]u8 = undefined;
var share_len: usize = 0;
/// One-shot for the next flush; -1 when none is armed.
var share_timer: i64 = -1;
/// When the last publish frame went out, monotonic. One frame per interval
/// keeps a busy receiver far under the relay's publish caps.
var last_pub_ms: i64 = 0;
const pub_interval_ms = 2_000;

/// Raw sentences from the nmea0183 topic, forwarded under the one Share AIS
/// consent: other boats' reports and this boat's own transponder reports
/// alike — the toggle's wording says so, and a transponder is already
/// broadcasting the boat to every receiver in range.
pub fn onBus(topic: []const u8, from: []const u8, frame: []const u8) void {
    _ = from;
    if (!std.mem.eql(u8, topic, "nmea0183")) return;
    if (!anyShareEnabled()) return;
    var lines = std.mem.splitSequence(u8, frame, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // The sentence starts after the TAG block's closing backslash.
        const start = if (std.mem.lastIndexOfScalar(u8, line, '\\')) |at| at + 1 else 0;
        const sentence = line[start..];
        if (sentence.len < 7 or sentence[0] != '!') continue;
        if (!std.mem.eql(u8, sentence[3..6], "VDM") and !std.mem.eql(u8, sentence[3..6], "VDO")) continue;
        appendShare(line);
    }
    flushShare();
}

fn appendShare(line: []const u8) void {
    if (share_len + line.len + 2 > share_buf.len) {
        share_len = 0;
    }
    if (line.len + 2 > share_buf.len) return;
    @memcpy(share_buf[share_len..][0..line.len], line);
    share_buf[share_len + line.len] = '\r';
    share_buf[share_len + line.len + 1] = '\n';
    share_len += line.len + 2;
}

/// The socket sharing publishes on: the first connected, keyed row with the
/// share toggle on. One socket however many rows, so the relay sees one
/// station and multipart groups stay on one stream.
fn shareConn() ?*Connection {
    for (Connections.all()) |conn| {
        if (conn.cols.share and conn.connected() and conn.state.keyed) return conn;
    }
    return null;
}

fn anyShareEnabled() bool {
    for (Connections.all()) |conn| {
        if (conn.cols.share) return true;
    }
    return false;
}

/// Send the pending lines as one `{"type":"publish","nmea":[…]}` frame, at
/// most one per interval; due-but-early arms the one-shot. The flush is
/// frame-atomic: a refused send drops the batch whole rather than tearing a
/// multipart group.
fn flushShare() void {
    if (share_len == 0) return;
    const conn = shareConn() orelse return;
    const mono = lk.monoMs();
    if (last_pub_ms != 0 and mono - last_pub_ms < pub_interval_ms) {
        if (share_timer < 0) share_timer = lk.raw.timerSet(pub_interval_ms - (mono - last_pub_ms), false);
        return;
    }
    var out_buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    writePublish(&w, share_buf[0..share_len]) catch {
        share_len = 0;
        return;
    };
    _ = conn.send(w.buffered());
    share_len = 0;
    last_pub_ms = mono;
}

/// The publish frame from CRLF-joined lines. TAG blocks carry backslashes,
/// which JSON strings must escape.
fn writePublish(w: *std.Io.Writer, pending: []const u8) !void {
    try w.writeAll("{\"type\":\"publish\",\"nmea\":[");
    var first = true;
    var lines = std.mem.splitSequence(u8, pending, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        // The library escaper: the TAG blocks carry backslashes, and a stray
        // control byte must not produce invalid JSON.
        try std.json.Stringify.value(line, .{}, w);
    }
    try w.writeAll("]}");
}

/// Register the plugin's identity, once, through the designated row: the
/// lowest place among share-enabled connected rows, only when no identity is
/// stored and none is in flight on this socket. The relay answers with a
/// `key` frame and a fresh welcome, upgrading this connection in place; its
/// refusals are non-fatal error frames, and the session then simply does not
/// share.
fn maybeRegister(conn: *Connection) void {
    // A row with its own token needs no identity of ours.
    if (conn.cols.token.len > 0) return;
    if (!conn.cols.share or token_len > 0 or conn.state.registered) return;
    for (Connections.all()) |other| {
        if (other != conn and other.cols.share and other.connected() and other.place() < conn.place()) return;
    }
    var seed: [32]u8 = undefined;
    if (lk.raw.randBytes(&seed) < 0) return;
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return;
    var b64_buf: [43]u8 = undefined;
    const pub_b64 = std.base64.url_safe_no_pad.Encoder.encode(&b64_buf, &kp.public_key.toBytes());
    var frame_buf: [96]u8 = undefined;
    const frame = std.fmt.bufPrint(&frame_buf, "{{\"type\":\"register\",\"pubkey\":\"{s}\"}}", .{pub_b64}) catch return;
    if (conn.send(frame) < 0) return;
    conn.state.registered = true;
}

/// The token is the whole identity: a bearer the relay never challenges, so
/// nothing else is worth keeping. Losing it just mints a fresh one.
fn storeIdentity() void {
    var buf: [token_buf.len + 64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"token\":\"{s}\"}}", .{token()}) catch return;
    if (lk.raw.storagePut("identity", json) < 0) lk.log(.warn, "identity not stored; sharing lasts this session", .{});
}

fn setName(tgt: *lk.Target, v: ?std.json.Value) void {
    const n = jstr(v) orelse return;
    // The wire pads names with spaces or '@'.
    const trimmed = std.mem.trim(u8, n, " @");
    if (trimmed.len > 0) tgt.name_str.set(trimmed);
}

fn eqlAny(s: []const u8, of: []const []const u8) bool {
    for (of) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// "2026-08-20T15:25:54.342871Z" → epoch milliseconds. UTC only: an offset
/// suffix is rejected rather than misread as Z, and the caller then falls
/// back to receipt time. Fractional seconds past the millisecond are dropped.
fn isoMs(s: ?[]const u8) ?i64 {
    const txt = s orelse return null;
    if (txt.len < 20) return null;
    if (txt[4] != '-' or txt[7] != '-' or txt[10] != 'T' or txt[13] != ':' or txt[16] != ':') return null;
    const y = std.fmt.parseInt(u16, txt[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, txt[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, txt[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(u8, txt[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(u8, txt[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(u8, txt[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or hh > 23 or mi > 59 or ss > 60) return null;
    var frac_ms: i64 = 0;
    var at: usize = 19;
    if (txt[at] == '.') {
        var scale: i64 = 100;
        at += 1;
        while (at < txt.len and txt[at] >= '0' and txt[at] <= '9') : (at += 1) {
            if (scale > 0) {
                frac_ms += scale * (txt[at] - '0');
                scale = @divTrunc(scale, 10);
            }
        }
    }
    if (at >= txt.len or txt[at] != 'Z') return null;
    const days = lk.daysFromCivil(y, mo, d);
    return ((days * 24 + hh) * 60 + mi) * 60_000 + @as(i64, ss) * 1_000 + frac_ms;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "ISO time round-trips against known instants, UTC only" {
    try t.expectEqual(@as(i64, 1755703554_342), isoMs("2025-08-20T15:25:54.342871Z").?);
    try t.expectEqual(@as(i64, 0), isoMs("1970-01-01T00:00:00Z").?);
    try t.expectEqual(@as(i64, 86_400_000), isoMs("1970-01-02T00:00:00Z").?);
    // An offset is not Z: misreading it as UTC would stamp hours of error.
    try t.expect(isoMs("2025-08-20T15:25:54-05:00") == null);
    try t.expect(isoMs("2025-08-20 15:25:54.794168 +0000 UTC") == null);
    try t.expect(isoMs("not a time") == null);
    try t.expect(isoMs(null) == null);
}

test "the subscribe frame pads the view and splits the antimeridian" {
    var w = std.Io.Writer.fixed(&sub_buf);
    try writeSubscribe(&w, computeBox(.{ .min_lat = 59.0, .min_lon = 10.0, .max_lat = 60.0, .max_lon = 11.0 }, max_area_sqdeg));
    // 1°×1° view → 1.6°×1.6° box centred on 59.5, 10.5.
    try t.expectEqualStrings("{\"type\":\"subscribe\",\"snapshot\":true,\"bbox\":[[58.7000,9.7000,60.3000,11.3000]]}", w.buffered());

    // A view across the antimeridian goes out as two boxes.
    w = std.Io.Writer.fixed(&sub_buf);
    try writeSubscribe(&w, computeBox(.{ .min_lat = -18.0, .min_lon = 179.0, .max_lat = -17.0, .max_lon = 181.0 }, max_area_sqdeg));
    const two = w.buffered();
    try t.expect(std.mem.count(u8, two, "[") == 3);
    try t.expect(std.mem.indexOf(u8, two, "180") != null);

    // A whole-world view is capped to the tier's area, not refused.
    const world = computeBox(.{ .min_lat = -80.0, .min_lon = -180.0, .max_lat = 80.0, .max_lon = 180.0 }, max_area_sqdeg);
    const area = (world.max_lat - world.min_lat) * (world.max_lon - world.min_lon);
    try t.expect(area <= max_area_sqdeg + 0.1);
}

test "hysteresis lets a small pan through and catches a big one" {
    const sub = lk.ViewBox{ .min_lat = 59.0, .min_lon = 10.0, .max_lat = 60.0, .max_lon = 11.0 };
    const sb = computeBox(sub, max_area_sqdeg);
    // A nudge inside the middle half of the subscribed box.
    try t.expect(!drifted(.{ .min_lat = 59.1, .min_lon = 10.1, .max_lat = 60.1, .max_lon = 11.1 }, sub, sb));
    // The centre out past a quarter of the subscribed span.
    try t.expect(drifted(.{ .min_lat = 59.6, .min_lon = 10.6, .max_lat = 60.6, .max_lon = 11.6 }, sub, sb));
    // Zoom out past the ratio.
    try t.expect(drifted(.{ .min_lat = 58.5, .min_lon = 9.5, .max_lat = 60.5, .max_lon = 11.5 }, sub, sb));
    // Same view exactly.
    try t.expect(!drifted(sub, sub, sb));
}

test "a publish frame escapes the TAG block backslashes and joins the lines" {
    share_len = 0;
    appendShare("\\s:lk1*7F\\!AIVDM,1,1,,A,13HOI:0P0000VOHLCnHQKwvL05Ip,0*23");
    appendShare("\\s:lk1*7F\\!AIVDM,2,1,3,B,55P5TL01VIaAL@7WKO@mBplU@<PDhh,0*1C");
    var out: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try writePublish(&w, share_buf[0..share_len]);
    try t.expect(std.mem.startsWith(u8, w.buffered(), "{\"type\":\"publish\",\"nmea\":[\"\\\\s:lk1*7F\\\\!AIVDM,1,"));
    try t.expect(std.mem.indexOf(u8, w.buffered(), "\",\"\\\\s:lk1*7F\\\\!AIVDM,2,") != null);
    try t.expect(std.mem.endsWith(u8, w.buffered(), "\"]}"));
    share_len = 0;
}

test "an overflowing share buffer keeps the newest lines, whole" {
    share_len = 0;
    var line_buf: [80]u8 = undefined;
    @memset(&line_buf, 'x');
    line_buf[0] = '!';
    var appended: usize = 0;
    while (appended < 100) : (appended += 1) appendShare(&line_buf);
    // Every kept line is intact and the newest append always landed.
    try t.expect(share_len <= share_buf.len);
    try t.expect(share_len % (line_buf.len + 2) == 0);
    try t.expect(share_len > 0);
    share_len = 0;
}

test "past the area cap, hysteresis follows the capped box, not the view" {
    // A 40°×40° passage-planning view subscribes only ~10°×10°; a pan the
    // view would shrug off has already left the subscribed box.
    const wide = lk.ViewBox{ .min_lat = 20.0, .min_lon = -60.0, .max_lat = 60.0, .max_lon = -20.0 };
    const wb = computeBox(wide, max_area_sqdeg);
    try t.expect((wb.max_lat - wb.min_lat) < 11.0);
    const panned = lk.ViewBox{ .min_lat = 29.0, .min_lon = -60.0, .max_lat = 69.0, .max_lon = -20.0 };
    try t.expect(drifted(panned, wide, wb));
    try t.expect(!drifted(wide, wide, wb));
}
