//! Two NMEA sources at once: the real nmea0183 .wasm, the real host, the real
//! broker sockets, and two loopback servers standing in for two gateways.
//!
//! What it proves, which nothing else does:
//!   - one plugin holds several connections, and both feed the same chart;
//!   - switching a row off closes THAT socket and leaves the other alone;
//!   - the status carries one item per row, keyed by the row id the shell
//!     assigned, so the settings window can put each line beside its row.
//!
//! The name test carries an AIS VESSEL NAME the whole way: armored sentences
//! on a socket, the nmea0183 module's reassembly and decode, the AIS store's
//! merge onto a target that was created by an earlier position report, the
//! snapshot the broker fans out, and the ais module's own choice between the
//! name and the MMSI. What it reads at the end is the row the targets dialog
//! puts on screen, so nothing about the name path is taken on trust.
//!
//! The instrument test does the same for the sentences whose fields are a list
//! rather than a fixed layout, and checks the units they land in.
//!
//! The plugins arrive as anonymous imports, like plugins/echo does for
//! host_smoke: importing host.zig must never drag a plugin binary into the
//! core.

const std = @import("std");
const host = @import("host");

const broker = host.broker;
const vstore = host.store;
const aisstore = host.aisstore;

const nmea_wasm = @embedFile("nmea_plugin_wasm");
const nmea_manifest = @embedFile("nmea_manifest");
const nmea_id = "org.beetlebug.nmea0183";
const ais_wasm = @embedFile("ais_plugin_wasm");
const ais_manifest = @embedFile("ais_manifest");
const ais_id = "org.beetlebug.ais";
const io = std.Io.Threaded.global_single_threaded.io();

/// How long a wait-for gives up after. Generous: a loaded machine still has to
/// resolve a name, connect, and get a line through the interpreter.
const deadline_ms: i64 = 8_000;

// ---------------------------------------------------------------------------
// a loopback gateway
// ---------------------------------------------------------------------------

/// One pretend NMEA gateway: it accepts a client and writes its sentence over
/// and over, with a value that goes up every time, so a test can tell a feed
/// that is still arriving from one that stopped.
const Feed = struct {
    fd: std.c.fd_t = -1,
    port: u16 = 0,
    /// "$SDDBT,,f,{d}.0,M,,F" and the like, formatted with the tick. Ignored
    /// when `lines` is set.
    fmt: []const u8 = "",
    /// Whole sentences, checksums and all, written in order once per pass. A
    /// sentence whose checksum is part of what is under test cannot be
    /// rebuilt by `sentence` below.
    lines: ?[]const []const u8 = null,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Clients accepted so far. A reconnect shows up here.
    accepted: std.atomic.Value(u32) = .init(0),

    fn open(self: *Feed) !void {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);
        var yes: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.c.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f00_0001) };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
        if (std.c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        self.fd = fd;
        self.port = std.mem.bigToNative(u16, addr.port);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn close(self: *Feed) void {
        self.stop.store(true, .release);
        if (self.thread) |th| th.join();
        self.thread = null;
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }

    fn run(self: *Feed) void {
        var tick: u32 = 0;
        while (!self.stop.load(.acquire)) {
            const peer = self.acceptOne() orelse continue;
            defer _ = std.c.close(peer);
            // macOS raises SIGPIPE on a write to a socket the plugin closed;
            // the error return is enough.
            if (@hasDecl(std.c.SO, "NOSIGPIPE")) {
                var yes: c_int = 1;
                _ = std.c.setsockopt(peer, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &yes, @sizeOf(c_int));
            }
            _ = self.accepted.fetchAdd(1, .monotonic);
            while (!self.stop.load(.acquire)) {
                if (self.lines) |set| {
                    if (!self.writeLines(peer, set)) break;
                    broker.sleepMs(100);
                    continue;
                }
                tick = (tick % 90) + 1;
                var line: [96]u8 = undefined;
                const text = sentence(&line, self.fmt, tick) catch return;
                if (!writeAll(peer, text)) break;
                broker.sleepMs(20);
            }
        }
    }

    fn writeLines(self: *Feed, peer: std.c.fd_t, set: []const []const u8) bool {
        var buf: [128]u8 = undefined;
        for (set) |line| {
            if (self.stop.load(.acquire)) return false;
            const text = std.fmt.bufPrint(&buf, "{s}\r\n", .{line}) catch return false;
            if (!writeAll(peer, text)) return false;
        }
        return true;
    }

    fn acceptOne(self: *Feed) ?std.c.fd_t {
        var fds = [_]std.c.pollfd{.{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, 50) catch return null;
        if (n <= 0) return null;
        const peer = std.c.accept(self.fd, null, null);
        return if (peer < 0) null else peer;
    }
};

/// One sentence with its checksum, built at run time so the value can move.
fn sentence(buf: []u8, comptime_fmt: []const u8, tick: u32) ![]const u8 {
    var body: [80]u8 = undefined;
    const b = try std.fmt.bufPrint(&body, "{s}", .{comptime_fmt});
    // The one substitution: "%" stands for the tick.
    var filled: [80]u8 = undefined;
    var n: usize = 0;
    for (b) |c| {
        if (c == '%') {
            n += (try std.fmt.bufPrint(filled[n..], "{d}", .{tick})).len;
        } else {
            filled[n] = c;
            n += 1;
        }
    }
    var sum: u8 = 0;
    for (filled[0..n]) |c| sum ^= c;
    return std.fmt.bufPrint(buf, "${s}*{X:0>2}\r\n", .{ filled[0..n], sum });
}

fn writeAll(fd: std.c.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

// ---------------------------------------------------------------------------
// waiting
// ---------------------------------------------------------------------------

/// An assertion that says which one it was. `expect` alone reports
/// "TestUnexpectedResult" and nothing else, which is no use in a test with
/// this many moving parts.
fn must(cond: bool, comptime what: []const u8) !void {
    if (cond) return;
    std.debug.print("\nFAILED: {s}\n", .{what});
    return error.TestUnexpectedResult;
}

fn waitFor(ctx: anytype, ready: fn (@TypeOf(ctx)) bool) !void {
    const until = broker.monoMs() + deadline_ms;
    while (broker.monoMs() < until) {
        if (ready(ctx)) return;
        broker.sleepMs(20);
    }
    return error.TimedOut;
}

fn reading(vessels: *vstore.Store, path: []const u8) ?vstore.Reading {
    return vessels.readElected(path, broker.wallMs());
}

fn number(vessels: *vstore.Store, path: []const u8) ?f64 {
    const r = reading(vessels, path) orelse return null;
    return switch (r.value) {
        .number => |v| v,
        else => null,
    };
}

const depth_path = "environment.depth.belowTransducer";
const heading_path = "navigation.headingTrue";

fn haveBoth(v: *vstore.Store) bool {
    return number(v, depth_path) != null and number(v, heading_path) != null;
}

/// Keeps every broker log line, so the test can prove the plugin never
/// trapped and nothing was refused a grant.
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
};

// ---------------------------------------------------------------------------
// the test
// ---------------------------------------------------------------------------

test "two connections feed one chart, and pausing one leaves the other running" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".wasm", .data = nmea_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".manifest.json", .data = nmea_manifest });
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dir_path);

    // Two gateways: one sends depth, the other heading, so the store shows
    // which of them is still arriving.
    var depth = Feed{ .fmt = "SDDBT,,f,%.0,M,,F" };
    try depth.open();
    defer depth.close();
    var heading = Feed{ .fmt = "HEHDT,%.0,T" };
    try heading.open();
    defer heading.close();

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var br = broker.Broker.init(alloc, &vessels, &ais, .{});
    defer br.deinit();
    // The default sink prints through std.debug, which under `zig build test`
    // shares a stream with the build runner's protocol. Keep the lines here
    // instead, and assert on them at the end.
    var log = LogSink{ .alloc = alloc };
    defer log.text.deinit(alloc);
    br.setLog(&log, LogSink.write);

    // No seed address: this test owns the connection list, and a seeded row
    // would dial whatever happens to listen on the default port.
    var h = host.Host.init(alloc, &br, .{ .nmea_host = "" });
    defer h.deinit();
    try h.loadDir(dir_path);
    try std.testing.expectEqual(@as(usize, 1), h.count());
    try h.start();
    defer h.stop();

    // The mariner adds two connections.
    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try cfg.print(
        alloc,
        "{{\"connections\":[" ++
            "{{\"id\":\"c-depth\",\"name\":\"Sounder\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}," ++
            "{{\"id\":\"c-heading\",\"name\":\"Compass\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}]}}",
        .{ depth.port, heading.port },
    );
    try h.configSet(nmea_id, cfg.items);

    // Both sockets come up and both feeds reach the store.
    try waitFor(&vessels, haveBoth);
    try must(depth.accepted.load(.monotonic) >= 1, "the sounder was dialled");
    try must(heading.accepted.load(.monotonic) >= 1, "the compass was dialled");

    // The status carries one item per row, under the ids the shell chose.
    const plugin = h.find(nmea_id) orelse return error.PluginNotLoaded;
    try waitFor(plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "\"c-depth\"") != null and
                std.mem.indexOf(u8, p.status(), "\"c-heading\"") != null;
        }
    }.ready);
    try must(std.mem.indexOf(u8, plugin.status(), "\"state\":\"connected\"") != null, "a row reads connected");
    try must(std.mem.indexOf(u8, plugin.status(), "2 of 2 connected") != null, "both rows connected");

    // The mariner switches the compass off. Its row stays in the list.
    cfg.clearRetainingCapacity();
    try cfg.print(
        alloc,
        "{{\"connections\":[" ++
            "{{\"id\":\"c-depth\",\"name\":\"Sounder\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}," ++
            "{{\"id\":\"c-heading\",\"name\":\"Compass\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":false}}]}}",
        .{ depth.port, heading.port },
    );
    try h.configSet(nmea_id, cfg.items);

    try waitFor(plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "\"paused\"") != null;
        }
    }.ready);

    // The paused row publishes nothing more; the other one keeps going.
    //
    // The socket closes the moment the row is switched off, but bytes already
    // read into the queue are still delivered, so the baseline is taken after
    // a short drain — otherwise a late line makes the paused row look alive.
    broker.sleepMs(400);
    const heading_at_pause = reading(&vessels, heading_path).?.ts_ms;
    const depth_at_pause = reading(&vessels, depth_path).?.ts_ms;
    broker.sleepMs(700);
    try must(reading(&vessels, heading_path).?.ts_ms == heading_at_pause, "the paused row published nothing more");
    try must(reading(&vessels, depth_path).?.ts_ms >= depth_at_pause, "the other row kept publishing");

    // The status says which row is which: one connected, one switched off,
    // and the plugin itself is still running.
    try must(std.mem.indexOf(u8, plugin.status(), "1 of 2 connected") != null, "one of two rows is connected");
    try must(std.mem.indexOf(u8, plugin.status(), "\"state\":\"paused\"") != null, "the switched-off row says paused");

    // Switching it back on reconnects it, and the gateway sees a second client.
    cfg.clearRetainingCapacity();
    try cfg.print(
        alloc,
        "{{\"connections\":[" ++
            "{{\"id\":\"c-depth\",\"name\":\"Sounder\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}," ++
            "{{\"id\":\"c-heading\",\"name\":\"Compass\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}]}}",
        .{ depth.port, heading.port },
    );
    try h.configSet(nmea_id, cfg.items);
    try waitFor(&heading, struct {
        fn ready(f: *Feed) bool {
            return f.accepted.load(.monotonic) >= 2;
        }
    }.ready);

    // A row the mariner deletes takes its socket with it, and the row that
    // stays is not disturbed: the sounder is never re-accepted.
    const sounder_clients = depth.accepted.load(.monotonic);
    cfg.clearRetainingCapacity();
    try cfg.print(
        alloc,
        "{{\"connections\":[{{\"id\":\"c-depth\",\"name\":\"Sounder\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}]}}",
        .{depth.port},
    );
    try h.configSet(nmea_id, cfg.items);
    try waitFor(plugin, struct {
        fn ready(p: *broker.Plugin) bool {
            return std.mem.indexOf(u8, p.status(), "1 of 1 connected") != null;
        }
    }.ready);
    try must(std.mem.indexOf(u8, plugin.status(), "\"c-heading\"") == null, "the deleted row is gone from the status");
    try must(sounder_clients == depth.accepted.load(.monotonic), "the row that stayed was not re-dialled");

    // Through all of that the plugin stayed up and asked for nothing it was
    // not granted.
    try must(!log.has("trapped"), "nothing trapped");
    try must(!log.has("denied"), "no grant was refused");
    try std.testing.expectEqual(@as(u32, 0), plugin.denied);
}

// ---------------------------------------------------------------------------
// the name path
// ---------------------------------------------------------------------------

/// The AIS a gateway repeats, in the order a receiver hears it: the position
/// reports first and the static reports minutes later, which is the order that
/// makes the store merge a name onto a target it already has.
///
///   * a class A position report and the two-fragment type 5 that names her.
///     The pair is the one in the parser's fixtures, framed the way a B&G Zeus
///     frames one: its two fragments carry DIFFERENT sequential message ids and
///     an empty channel, which is what the assembler has to tolerate for a
///     class A ship to be anything but a number on the chart.
///   * a class B position report and the single-sentence type 24 part A that
///     names her, from the generated Annapolis log.
///
/// Both vessels are invented, like everything else the tests here send.
const ais_lines = [_][]const u8{
    "!AIVDM,1,1,,,15NtpTh00lJQtlpFCD83IRht0000,0*47",
    "!AIVDM,1,1,,B,B52LbuP0?6`O6V5TjPmDI3P4h000,0*29",
    "!AIVDM,2,1,4,,55NtpTh00001LASO3C8M85V0PE8tp000000000163064440008hCSPD3k2Dh,0*55",
    "!AIVDM,2,2,5,,00000000000,2*60",
    "!AIVDM,1,1,,B,H52LbuQ<D61=18U@D00000000000,0*4A",
};

const class_a_mmsi: u32 = 367999123;
const class_a_name = "GRAY HERON";
const class_b_mmsi: u32 = 338111222;
const class_b_name = "SEA SPRITE";

fn named(store: *aisstore.AisStore, mmsi: u32, want: []const u8) bool {
    const t = store.get(mmsi) orelse return false;
    const n = t.name() orelse return false;
    return std.mem.eql(u8, n, want) and t.hasPosition();
}

fn bothNamed(store: *aisstore.AisStore) bool {
    return named(store, class_a_mmsi, class_a_name) and named(store, class_b_mmsi, class_b_name);
}

test "an AIS name reaches the row the targets dialog draws, not the MMSI" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".wasm", .data = nmea_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".manifest.json", .data = nmea_manifest });
    try tmp.dir.writeFile(io, .{ .sub_path = ais_id ++ ".wasm", .data = ais_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = ais_id ++ ".manifest.json", .data = ais_manifest });
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dir_path);

    var gateway = Feed{ .lines = &ais_lines };
    try gateway.open();
    defer gateway.close();

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var br = broker.Broker.init(alloc, &vessels, &ais, .{});
    defer br.deinit();
    var log = LogSink{ .alloc = alloc };
    defer log.text.deinit(alloc);
    br.setLog(&log, LogSink.write);

    var h = host.Host.init(alloc, &br, .{ .nmea_host = "" });
    defer h.deinit();
    try h.loadDir(dir_path);
    try std.testing.expectEqual(@as(usize, 2), h.count());
    try h.start();
    defer h.stop();

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try cfg.print(
        alloc,
        "{{\"connections\":[{{\"id\":\"c-ais\",\"name\":\"AIS\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}]}}",
        .{gateway.port},
    );
    try h.configSet(nmea_id, cfg.items);

    // Both targets reach the host's store with a position AND the name their
    // static report carried. The class A name only gets here if the
    // mismatched message ids were tolerated.
    try waitFor(&ais, bothNamed);

    // The mariner opens the targets dialog. Rows exist only while it is open,
    // and what it holds is what the shell puts on screen.
    try must(br.setTableOpen(ais_id, "targets", true), "the ais plugin declares a targets table");

    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(alloc);
    const Rows = struct {
        br: *broker.Broker,
        out: *std.ArrayList(u8),

        fn ready(self: @This()) bool {
            self.out.clearRetainingCapacity();
            _ = self.br.tableRowsJson(ais_id, "targets", "name", true, self.out) catch return false;
            return std.mem.indexOf(u8, self.out.items, class_a_name) != null and
                std.mem.indexOf(u8, self.out.items, class_b_name) != null;
        }
    };
    try waitFor(Rows{ .br = &br, .out = &rows }, Rows.ready);

    // The name column is the first cell, the MMSI the second. A target that
    // reported a name shows it there; the number beside it is the identifier,
    // not the label, and the two are never the same string.
    try must(
        std.mem.indexOf(u8, rows.items, "\"cells\":[\"" ++ class_a_name ++ "\",\"367999123\"") != null,
        "the class A row leads with her name",
    );
    try must(
        std.mem.indexOf(u8, rows.items, "\"cells\":[\"" ++ class_b_name ++ "\",\"338111222\"") != null,
        "the class B row leads with her name",
    );

    try must(!log.has("trapped"), "nothing trapped");
    try must(!log.has("denied"), "no grant was refused");
}

// ---------------------------------------------------------------------------
// the transducer, temperature and log sentences
// ---------------------------------------------------------------------------

/// A boat's own instruments: a transducer list with two of its five readings
/// empty, the water temperature, and the log. The XDR is the shape that matters
/// here, because it is the only sentence the plugin reads whose fields are a
/// list rather than a fixed layout.
const instrument_lines = [_][]const u8{
    "$IIXDR,C,,C,AIRTEMP,A,3.4,D,HEEL,A,1.9,D,TRIM,P,,B,BARO,A,-2.2,D,RUDDER*0B",
    "$IIMTW,17.9,C*1C",
    "$VWVLW,1234.5,N,12.3,N*4D",
};

const roll_path = "navigation.attitude.roll";
const pitch_path = "navigation.attitude.pitch";
const rudder_path = "steering.rudderAngle";
const water_temp_path = "environment.water.temperature";
const log_path = "navigation.log";
const trip_path = "navigation.trip.log";

fn haveInstruments(v: *vstore.Store) bool {
    for ([_][]const u8{ roll_path, pitch_path, rudder_path, water_temp_path, log_path, trip_path }) |p| {
        if (number(v, p) == null) return false;
    }
    return true;
}

test "XDR, MTW and VLW reach the store in SI" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".wasm", .data = nmea_wasm });
    try tmp.dir.writeFile(io, .{ .sub_path = nmea_id ++ ".manifest.json", .data = nmea_manifest });
    const dir_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(dir_path);

    var instruments = Feed{ .lines = &instrument_lines };
    try instruments.open();
    defer instruments.close();

    var vessels = try vstore.Store.init(alloc);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(alloc);
    defer ais.deinit();
    var br = broker.Broker.init(alloc, &vessels, &ais, .{});
    defer br.deinit();
    var log = LogSink{ .alloc = alloc };
    defer log.text.deinit(alloc);
    br.setLog(&log, LogSink.write);

    var h = host.Host.init(alloc, &br, .{ .nmea_host = "" });
    defer h.deinit();
    try h.loadDir(dir_path);
    try h.start();
    defer h.stop();

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try cfg.print(
        alloc,
        "{{\"connections\":[{{\"id\":\"c-inst\",\"name\":\"Instruments\",\"host\":\"127.0.0.1\",\"port\":{d},\"enabled\":true}}]}}",
        .{instruments.port},
    );
    try h.configSet(nmea_id, cfg.items);

    try waitFor(&vessels, haveInstruments);

    // Degrees for the angles, kelvin for the temperature, metres for the log:
    // the units the store's table names, not the sentence's.
    try must(@abs(number(&vessels, roll_path).? - 3.4) < 1e-9, "heel is degrees");
    try must(@abs(number(&vessels, pitch_path).? - 1.9) < 1e-9, "trim is degrees");
    try must(@abs(number(&vessels, rudder_path).? + 2.2) < 1e-9, "rudder is degrees, signed");
    try must(@abs(number(&vessels, water_temp_path).? - (17.9 + 273.15)) < 1e-9, "water temperature is kelvin");
    try must(@abs(number(&vessels, log_path).? - 1234.5 * 1852.0) < 1e-6, "the log is metres");
    try must(@abs(number(&vessels, trip_path).? - 12.3 * 1852.0) < 1e-6, "the trip is metres");

    try must(!log.has("trapped"), "nothing trapped");
    try must(!log.has("denied"), "no grant was refused");
}
