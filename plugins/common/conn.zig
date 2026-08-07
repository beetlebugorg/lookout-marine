//! Connections the mariner keeps, owned by the library.
//!
//! A source plugin declares the list once:
//!
//!   pub const Connections = lk.connections(.{
//!       .key = "servers",
//!       .group = "Signal K servers",
//!       .add_label = "Add Server",
//!       .status_empty = "no servers",
//!       .columns = .{ .port = .{ .label = "Port", .desc = "…", .min = 1, .max = 65535, .default = 8375 } },
//!       .State = struct { framer: Framer = .{} },
//!   });
//!
//!   pub fn onData(conn: *Connections.Connection, bytes: []const u8) void { … }
//!
//! and the library owns everything else: the settings list schema, one socket
//! per connection, the reconnect clock, the failure count behind
//! "unreachable", the pause switch, the per-row status item and the plugin's
//! own status line.
//!
//! CONNECTIONS ARE MATCHED BY ID. Editing one connection never disturbs
//! another: only an address change, a pause or a delete closes a socket.
//!
//! The plugin may declare, on its root:
//!
//!   onData(conn, bytes)     required: the bytes off the wire
//!   onOpen(conn)            a stream opened; send a subscription here
//!   onClose(conn)           a stream ended
//!   connectionNote(conn)    a phrase to add after the connection's rate
//!   endpoint(conn)          where to dial, when it is not the connection's
//!                           host and port: a websocket URL, say
//!
//! This file imports the raw shim and the schema, and nothing above them.

const std = @import("std");
const raw = @import("lk.zig");
const schema = @import("schema.zig");

/// Where one connection is dialled.
pub const Endpoint = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    /// A websocket URL. The manifest must grant `net.ws` for its host.
    ws: []const u8,
    /// This connection cannot be dialled, and the text says why. The library
    /// stops retrying and shows the reason on the connection's line.
    refused: []const u8,
};

/// How one connection list behaves.
pub const Opts = struct {
    /// The config key the connection array arrives under.
    key: []const u8,
    /// The section heading in the settings window.
    group: []const u8,
    tab: schema.Tab = .connections,
    footer: []const u8 = "",
    empty: []const u8 = "",
    add_label: []const u8 = "",
    /// The wording of the four standard columns, and the port's range.
    columns: schema.RowColumns = .{},
    /// Columns beyond the four, as a struct shaped like a settings group.
    Extra: type = struct {},
    /// Per-connection state the plugin keeps: a framer, a parser, an
    /// identity.
    State: type = struct {},

    /// Delay before a dropped connection is retried.
    reconnect_ms: i64 = 2_000,
    /// Failed connects in a row before a connection reads as unreachable
    /// rather than reconnecting. Three tries is six seconds of silence.
    unreachable_after: u32 = 3,
    /// How often the status is rebuilt, and the window a rate is averaged
    /// over.
    status_ms: i64 = 2_000,
    /// What `conn.count` counts, for the status: "42 msg/s".
    rate_noun: []const u8 = "msg",
    /// The plugin's status detail when the mariner has added no connections.
    status_empty: []const u8 = "nothing configured",
    /// What a connection says once it has read as unreachable.
    no_answer_detail: []const u8 = "check the address",
    /// What a connection says when the host would not dial it at all. That only
    /// happens when the manifest's grant does not cover the address, and only
    /// the plugin knows which grant it asked for.
    refused_detail: []const u8 = "the host refused this address",
};

/// What one connection is doing, in the words the shell shows.
pub const RowState = enum {
    connected,
    reconnecting,
    /// Dialled and dialled and nothing answered.
    no_answer,
    paused,
    /// The connection has no address, or a port nothing can dial.
    no_address,
    /// The endpoint refused the connection outright: a grant that does not
    /// cover it.
    refused,

    fn text(self: RowState) []const u8 {
        return switch (self) {
            .connected => "connected",
            .reconnecting => "reconnecting",
            .no_answer => "unreachable",
            .paused => "paused",
            .no_address => "no_address",
            .refused => "refused",
        };
    }
};

/// The values of the plugin's extra columns: `f64` for a `Num`, `bool` for a
/// `Flag`, a fixed string for a `Text`.
fn ColumnValues(comptime Extra: type) type {
    const in = @typeInfo(Extra).@"struct".fields;
    comptime var names: [in.len][:0]const u8 = undefined;
    comptime var types: [in.len]type = undefined;
    comptime var attrs: [in.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (in, 0..) |f, i| {
        const meta = schema.spec(f);
        names[i] = f.name;
        switch (f.type) {
            schema.Num => {
                types[i] = f64;
                const d: f64 = meta.default;
                attrs[i] = .{ .default_value_ptr = &d };
            },
            schema.Flag => {
                types[i] = bool;
                const d: bool = meta.default;
                attrs[i] = .{ .default_value_ptr = &d };
            },
            schema.Text => {
                types[i] = schema.Str(schema.max_text_bytes);
                const d: schema.Str(schema.max_text_bytes) = .{};
                attrs[i] = .{ .default_value_ptr = &d };
            },
            else => @compileError("column '" ++ f.name ++ "' must be lk.Num, lk.Flag or lk.Text"),
        }
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn Connections(comptime opts: Opts) type {
    return struct {
        const Self = @This();

        /// What the manifest must declare for this list. `lk.settingsJson`
        /// renders it; the plugin's own test checks the manifest against it.
        pub const lk_list = .{
            schema.ListSpec{
                .key = opts.key,
                .group = opts.group,
                .tab = opts.tab,
                .footer = opts.footer,
                .empty = opts.empty,
                .add_label = opts.add_label,
            },
            opts.columns,
            opts.Extra,
        };

        /// One connection: the row the mariner filled in, the plugin's own
        /// state for it, and the socket the library holds.
        pub const Connection = struct {
            /// The shell's id for this row. It survives an edit, and it is
            /// what a status item points at.
            id: schema.Str(32) = .{},
            /// What the mariner calls it. May be empty.
            name: schema.Str(48) = .{},
            host: schema.Str(schema.max_text_bytes) = .{},
            port: u16 = 0,
            /// False means PAUSED: the stream closes and nothing reconnects.
            enabled: bool = true,
            /// The plugin's own columns.
            cols: ColumnValues(opts.Extra) = .{},
            /// The plugin's own state for this connection.
            state: opts.State = .{},

            used: bool = false,
            seen: bool = false,
            /// Where the row sits in the mariner's list, so the status items
            /// come back in the order the settings window shows.
            order: usize = 0,

            sock: i64 = -1,
            ws: bool = false,
            retry_timer: i64 = -1,
            failures: u32 = 0,
            conn: RowState = .reconnecting,

            /// What the plugin has counted since it started, and the rate over
            /// the last status window.
            counted: u64 = 0,
            last_counted: u64 = 0,
            rate: u64 = 0,
            detail: schema.Str(64) = .{},

            /// What to call this connection: the mariner's name, or the
            /// address.
            pub fn label(self: *const Connection) []const u8 {
                return if (self.name.len > 0) self.name.text() else self.host.text();
            }

            /// True while the stream is up.
            pub fn connected(self: *const Connection) bool {
                return self.conn == .connected;
            }

            /// Write to this connection's stream. Returns the bytes queued,
            /// or -1.
            pub fn send(self: *Connection, bytes: []const u8) i32 {
                if (self.sock < 0) return -1;
                return if (self.ws) raw.wsSend(self.sock, bytes) else raw.tcpSend(self.sock, bytes);
            }

            /// Count `n` of whatever this connection carries. The library
            /// turns it into the rate on the connection's status line and in
            /// the plugin's.
            pub fn count(self: *Connection, n: u64) void {
                self.counted += n;
            }

            /// Add a phrase to this connection's status line, after the
            /// state. Say nothing that only repeats the state.
            pub fn setDetail(self: *Connection, comptime fmt: []const u8, args: anytype) void {
                var buf: [64]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                w.print(fmt, args) catch {};
                self.detail.set(w.buffered());
            }

            /// A connection with no address cannot be dialled.
            fn usable(self: *const Connection) bool {
                return self.host.len > 0 and self.port > 0;
            }

            fn closeSocket(self: *Connection) void {
                if (self.sock >= 0) {
                    if (self.ws) raw.wsClose(self.sock) else raw.tcpClose(self.sock);
                }
                self.sock = -1;
                if (self.retry_timer >= 0) raw.timerCancel(self.retry_timer);
                self.retry_timer = -1;
                self.rate = 0;
            }

            fn scheduleRetry(self: *Connection) void {
                if (self.retry_timer >= 0) return;
                if (!self.enabled or !self.usable()) return;
                const id = raw.timerSet(opts.reconnect_ms, false);
                if (id >= 0) self.retry_timer = id;
            }

            fn noteFailure(self: *Connection) void {
                if (self.failures < opts.unreachable_after) self.failures += 1;
                if (self.failures >= opts.unreachable_after) {
                    self.conn = .no_answer;
                    self.detail.set(opts.no_answer_detail);
                } else {
                    self.conn = .reconnecting;
                    self.detail.set("");
                }
            }
        };

        var conns: [schema.max_rows]Connection = @splat(.{});
        var status_timer: i64 = -1;
        var last_status: schema.Str(768) = .{};

        /// The used connections, in the order the settings window shows.
        fn ordered(buf: *[schema.max_rows]*Connection) []*Connection {
            var n: usize = 0;
            for (&conns) |*r| {
                if (!r.used) continue;
                buf[n] = r;
                n += 1;
            }
            // A `for (1..n)` would be a REVERSED range when n is 0, which is
            // undefined with safety off, so this is a while.
            var i: usize = 1;
            while (i < n) : (i += 1) {
                var j = i;
                while (j > 0 and buf[j - 1].order > buf[j].order) : (j -= 1) {
                    const tmp = buf[j - 1];
                    buf[j - 1] = buf[j];
                    buf[j] = tmp;
                }
            }
            return buf[0..n];
        }

        /// Every connection the mariner has, in the order the settings window
        /// shows. The slice is rebuilt on each call.
        pub fn all() []*Connection {
            const S = struct {
                var buf: [schema.max_rows]*Connection = undefined;
            };
            return ordered(&S.buf);
        }

        /// The connection with this id, or null.
        pub fn byId(id: []const u8) ?*Connection {
            for (&conns) |*r| {
                if (r.used and r.id.eql(id)) return r;
            }
            return null;
        }

        // ---- what lk2 calls ------------------------------------------------

        pub fn lkStart(comptime P: type, config: std.json.Value) void {
            reconcile(P, config);
            status_timer = raw.timerSet(opts.status_ms, true);
            postStatus(P);
        }

        pub fn lkConfig(comptime P: type, config: std.json.Value) void {
            reconcile(P, config);
            postStatus(P);
        }

        /// True when the timer was the library's.
        pub fn lkTimer(comptime P: type, id: i64) bool {
            if (id == status_timer) {
                postStatus(P);
                return true;
            }
            for (&conns) |*r| {
                if (!r.used or r.retry_timer != id) continue;
                r.retry_timer = -1;
                open(P, r);
                return true;
            }
            return false;
        }

        /// True when the event belonged to one of these connections.
        pub fn lkEvent(comptime P: type, e: raw.Event) bool {
            switch (e) {
                .tcp_connected => |id| {
                    const r = bySocket(id, false) orelse return false;
                    opened(P, r);
                },
                .ws_open => |w| {
                    const r = bySocket(w.conn, true) orelse return false;
                    opened(P, r);
                },
                .tcp_data => |d| {
                    const r = bySocket(d.conn, false) orelse return false;
                    P.onData(r, d.bytes);
                },
                .ws_data => |w| {
                    const r = bySocket(w.conn, true) orelse return false;
                    P.onData(r, w.text);
                },
                .tcp_closed => |id| {
                    const r = bySocket(id, false) orelse return false;
                    ended(P, r);
                },
                .ws_closed => |w| {
                    const r = bySocket(w.conn, true) orelse return false;
                    ended(P, r);
                },
                else => return false,
            }
            return true;
        }

        pub fn lkShutdown() void {
            for (&conns) |*r| {
                if (!r.used) continue;
                r.closeSocket();
                r.used = false;
            }
            if (status_timer >= 0) raw.timerCancel(status_timer);
            status_timer = -1;
        }

        // ---- the connection itself ------------------------------------------

        fn bySocket(id: i64, ws: bool) ?*Connection {
            for (&conns) |*r| {
                if (r.used and r.sock == id and r.ws == ws) return r;
            }
            return null;
        }

        fn where(comptime P: type, r: *Connection) Endpoint {
            if (@hasDecl(P, "endpoint")) return P.endpoint(r);
            return .{ .tcp = .{ .host = r.host.text(), .port = r.port } };
        }

        /// Ask for a connection. The result arrives later as an open or a
        /// close event, so only an outright refusal is visible here.
        fn open(comptime P: type, r: *Connection) void {
            if (!r.enabled) {
                r.conn = .paused;
                return;
            }
            if (!r.usable()) {
                r.conn = .no_address;
                return;
            }
            switch (where(P, r)) {
                .tcp => |a| {
                    r.ws = false;
                    r.sock = raw.tcpConnect(a.host, a.port);
                },
                .ws => |url| {
                    r.ws = true;
                    r.sock = raw.wsConnect(url, &.{});
                },
                .refused => |why| {
                    r.conn = .refused;
                    r.detail.set(why);
                    return;
                },
            }
            if (r.sock < 0) {
                r.sock = -1;
                // The host would not make the call at all, and the only reason
                // it does that is the grant. Retrying is a refusal every two
                // seconds for ever, so the connection stops and says what is
                // wrong.
                if (r.ws) {
                    r.conn = .refused;
                    r.detail.set(opts.refused_detail);
                    return;
                }
                r.noteFailure();
                r.scheduleRetry();
            }
        }

        fn opened(comptime P: type, r: *Connection) void {
            r.conn = .connected;
            r.failures = 0;
            r.last_counted = r.counted;
            r.rate = 0;
            r.detail.set("");
            if (@hasDecl(P, "onOpen")) P.onOpen(r);
            postStatus(P);
        }

        fn ended(comptime P: type, r: *Connection) void {
            r.sock = -1;
            if (@hasDecl(P, "onClose")) P.onClose(r);
            // The close of a connection the mariner just switched off is not
            // a failure, and must not read as one.
            if (r.enabled and r.usable()) {
                r.noteFailure();
                r.scheduleRetry();
            }
            postStatus(P);
        }

        /// Take the mariner's list and make the streams match it.
        fn reconcile(comptime P: type, config: std.json.Value) void {
            for (&conns) |*r| r.seen = false;

            const list = listOf(config);
            for (list, 0..) |item, order| {
                if (item != .object) continue;
                const o = item.object;
                const id = str(o.get("id")) orelse continue;
                if (id.len == 0) continue;

                const r = byId(id) orelse freeSlot() orelse continue;
                const fresh = !r.used;
                const was_enabled = !fresh and r.enabled;
                const old_host = r.host;
                const old_port = r.port;
                const old_cols = r.cols;

                r.used = true;
                r.seen = true;
                r.order = order;
                r.id.set(id);
                r.name.set(str(o.get("name")) orelse "");
                r.host.set(str(o.get("host")) orelse "");
                const p = int(o.get("port")) orelse @as(i64, @intFromFloat(opts.columns.port.default));
                r.port = if (p >= 1 and p <= 65535) @intCast(p) else 0;
                r.enabled = switch (o.get("enabled") orelse std.json.Value{ .bool = true }) {
                    .bool => |b| b,
                    else => true,
                };
                readColumns(&r.cols, o);

                // A column of the plugin's own may pick the transport, so a
                // change to one is a change of address.
                const moved = fresh or !old_host.eql(r.host.text()) or old_port != r.port or
                    !std.meta.eql(old_cols, r.cols);

                if (!r.enabled) {
                    r.closeSocket();
                    r.conn = .paused;
                    r.failures = 0;
                } else if (!r.usable()) {
                    r.closeSocket();
                    r.conn = .no_address;
                } else if (moved or !was_enabled) {
                    // A new address, or a connection just switched back on:
                    // start over, including the count behind "unreachable".
                    r.closeSocket();
                    r.failures = 0;
                    r.conn = .reconnecting;
                    r.state = .{};
                    open(P, r);
                } else if (r.sock < 0 and r.retry_timer < 0) {
                    open(P, r);
                }
            }

            // A connection the mariner deleted takes its stream with it.
            for (&conns) |*r| {
                if (!r.used or r.seen) continue;
                r.closeSocket();
                r.* = .{};
            }
        }

        fn listOf(config: std.json.Value) []const std.json.Value {
            if (config != .object) return &.{};
            const v = config.object.get(opts.key) orelse return &.{};
            return switch (v) {
                .array => |a| a.items,
                else => &.{},
            };
        }

        fn freeSlot() ?*Connection {
            for (&conns) |*r| {
                if (!r.used) return r;
            }
            return null;
        }

        fn readColumns(out: *ColumnValues(opts.Extra), o: std.json.ObjectMap) void {
            inline for (@typeInfo(opts.Extra).@"struct".fields) |f| {
                if (o.get(f.name)) |v| switch (f.type) {
                    schema.Num => {
                        const meta = comptime schema.spec(f);
                        if (num(v)) |x| @field(out, f.name) = std.math.clamp(x, meta.min, meta.max);
                    },
                    schema.Flag => if (v == .bool) {
                        @field(out, f.name) = v.bool;
                    },
                    schema.Text => if (v == .string) {
                        @field(out, f.name).set(v.string);
                    },
                    else => {},
                };
            }
        }

        // ---- the status line ---------------------------------------------

        /// The plugin's line, and one item per row for the settings window.
        /// The item ids are the row ids the shell assigned, which is how each
        /// row's line finds its way back to the right row.
        fn postStatus(comptime P: type) void {
            var order_buf: [schema.max_rows]*Connection = undefined;
            const order = ordered(&order_buf);

            var live: usize = 0;
            var total: u64 = 0;
            for (order) |r| {
                sampleRate(r);
                if (r.connected()) {
                    live += 1;
                    total += r.rate;
                }
            }

            var buf: [768]u8 = undefined;
            var b = raw.Buf.init(&buf);
            b.raw("{\"state\":");
            b.str(if (live > 0) "running" else "degraded");
            b.raw(",\"detail\":");
            var detail: [120]u8 = undefined;
            var d = raw.Buf.init(&detail);
            if (order.len == 0) {
                d.raw(opts.status_empty);
            } else if (live > 0) {
                d.print("{d} of {d} connected, {d} {s}/s", .{ live, order.len, total, opts.rate_noun });
            } else {
                d.print("0 of {d} connected", .{order.len});
            }
            b.str(d.bytes());

            b.raw(",\"items\":[");
            for (order, 0..) |r, k| {
                if (k > 0) b.raw(",");
                b.raw("{\"id\":");
                b.str(r.id.text());
                b.raw(",\"state\":");
                b.str(r.conn.text());
                b.raw(",\"detail\":");
                var line: [96]u8 = undefined;
                var lw = raw.Buf.init(&line);
                if (r.connected()) {
                    lw.print("{d} {s}/s", .{ r.rate, opts.rate_noun });
                    if (@hasDecl(P, "connectionNote")) {
                        const note = P.connectionNote(r);
                        if (note.len > 0) lw.print(", {s}", .{note});
                    }
                } else lw.raw(r.detail.text());
                b.str(lw.bytes());
                b.raw("}");
            }
            b.raw("]}");
            if (b.overflowed) {
                // Too many connections to describe at once: the line still
                // goes out, so the chrome never falls silent.
                raw.status(if (live > 0) "running" else "degraded", "{d} of {d} connected", .{ live, order.len });
                return;
            }
            // The host logs a status text it has not seen, so a 2 s repeat of
            // the same line would be a log line every 2 s.
            if (last_status.eql(b.bytes())) return;
            last_status.set(b.bytes());
            raw.statusJson(b.bytes());
        }

        fn sampleRate(r: *Connection) void {
            const diff = r.counted - r.last_counted;
            r.last_counted = r.counted;
            if (!r.connected()) {
                r.rate = 0;
                return;
            }
            r.rate = (diff * 1000 + @as(u64, @intCast(opts.status_ms)) / 2) /
                @as(u64, @intCast(opts.status_ms));
        }
    };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn int(v: ?std.json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn num(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
