//! lookout-plugin-dev — run the wasm plugins against a recorded NMEA log and
//! a real chart, without a window.
//!
//!   lookout-plugin-dev --chart US5MD1MC.pmtiles --plugins zig-out/plugins \
//!       --replay test/annapolis.nmea --rate 20 --until 420 --png out.png \
//!       --view -76.4767,38.9763,15
//!
//! WHAT IT IS. The chart core opened offscreen, the plugin host running inside
//! it exactly as it does in the app, and a loopback TCP listener standing in
//! for the boat's NMEA multiplexer. The log is served at `rate` times real
//! time, frames are rendered so the overlay a plugin posts actually lands, and
//! at `--until` replay seconds the frame is written to a PNG.
//!
//! HOW THE PLUGINS FIND IT. The listener binds an ephemeral port, then
//! LOOKOUT_NMEA and LOOKOUT_PLUGINS are set BEFORE the core is created:
//! root.zig reads both while opening the chart, which is where the plugin
//! layer is built and started. Nothing else configures the plugins.
//!
//! WHAT IT PRINTS. `--print` selects one stream:
//!   all      everything below, plus every plugin log line
//!   deltas   vessel paths and AIS targets as they change in the stores
//!   overlay  overlay objects appearing and disappearing
//!   alert    alerts plugins raise
//!   status   chrome status transitions
//! Errors, grant refusals and traps print whatever the filter is: a harness
//! that hides a trap because it was asked for `--print overlay` is a harness
//! that lies. Lines the plugin layer emits BEFORE the chart is open (module
//! load, lk_start) go to stderr through the broker's default sink; everything
//! after that comes here, on stdout.
//!
//! EXIT CODE. 0 only when at least one frame rendered and no plugin trapped.
//! 1 for a trap or no frame, 2 for a bad invocation or a chart that will not
//! open.

const std = @import("std");
const lk = @import("root.zig");
const ov = @import("overlay.zig");
const phost = @import("plugin/host.zig");
const broker = phost.broker;
const replay = @import("plugin_dev_replay.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const USAGE =
    \\lookout-plugin-dev — replay a NMEA log into the wasm plugins over a chart
    \\
    \\usage: lookout-plugin-dev --chart <pmtiles|dir> [options]
    \\
    \\  --chart PATH      a baked .pmtiles archive, or a directory of them.
    \\                    Repeatable; several charts compose.
    \\  --plugins DIR     plugin directory (<id>.wasm + <id>.manifest.json)
    \\  --replay FILE     NMEA 0183 log to serve on the loopback listener
    \\  --rate X          replay speed, x real time (default 1; 0 = as fast as
    \\                    the socket takes it)
    \\  --until S         stop after S replay SECONDS (default: the whole log)
    \\  --png PATH        snapshot written at --until (default plugin-dev.png)
    \\  --view lon,lat,zoom   explicit view (default: fit the chart)
    \\  --width W --height H  render size (default 1600x1200)
    \\  --scheme day|dusk|night   palette (default day)
    \\  --print WHAT      all | deltas | overlay | alert | status (default all)
    \\  --set-config ID JSON  change a plugin's settings mid-replay, e.g.
    \\                    --set-config 200@org.beetlebug.ais '{"cpa_limit":100}'
    \\                    The SECONDS@ prefix is the replay second to do it at;
    \\                    without one it happens before the replay starts.
    \\                    Repeatable, applied in the order given.
    \\  --grant-file ID PATH  give a plugin one file to read, as the mariner's
    \\                    open panel would, e.g.
    \\                    --grant-file 30@org.beetlebug.grib gfs.grib2
    \\                    The plugin gets FILE_OPENED with the handle. Same
    \\                    SECONDS@ prefix, repeatable.
    \\  -h, --help        this help
    \\
;

// ---------------------------------------------------------------------------
// what gets printed
// ---------------------------------------------------------------------------

const Print = enum { all, deltas, overlay, alert, status };

/// One line to stdout in one write, so lines from the dispatch thread, the
/// I/O thread and the harness never interleave mid-line. Truncated at 2 KiB.
fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    const s = w.buffered();
    if (s.len == 0) return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn levelName(level: u32) []const u8 {
    return switch (level) {
        0 => "debug",
        1 => "info",
        2 => "warn",
        else => "error",
    };
}

/// Everything the threads share. The counters are atomics because the feeder
/// writes them and the main loop reads them.
const State = struct {
    print: Print = .all,
    /// Replay position: the second of the last group written to the socket.
    replay_ms: std.atomic.Value(i64) = .init(0),
    lines: std.atomic.Value(u64) = .init(0),
    groups: std.atomic.Value(u64) = .init(0),
    conns: std.atomic.Value(u32) = .init(0),
    /// The feeder reached the end of the log.
    eof: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    /// A plugin trapped or was disabled — seen in the log stream.
    trapped: std.atomic.Value(bool) = .init(false),
    alerts: std.atomic.Value(u32) = .init(0),

    fn replaySeconds(self: *State) f64 {
        return @as(f64, @floatFromInt(self.replay_ms.load(.monotonic))) / 1000.0;
    }
};

var state: State = .{};

/// The broker's log sink. Every plugin log line, grant refusal, status
/// transition, alert and trap report arrives here.
fn logSink(ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void {
    const st: *State = @ptrCast(@alignCast(ctx.?));

    const is_alert = std.mem.startsWith(u8, msg, "ALERT ");
    const is_status = std.mem.startsWith(u8, msg, "status ");
    if (is_alert) _ = st.alerts.fetchAdd(1, .monotonic);
    if (std.mem.indexOf(u8, msg, "trapped") != null or
        std.mem.startsWith(u8, msg, "disabled:")) st.trapped.store(true, .monotonic);

    // A trap, a refused grant or a rejected batch is a diagnostic, not a data
    // stream: it prints under EVERY filter. Without this a plugin that died
    // during --print status looks like a plugin that said nothing.
    const show = level >= broker.level_err or switch (st.print) {
        .all => true,
        .alert => is_alert,
        .status => is_status,
        .deltas, .overlay => false,
    };
    if (!show) return;
    emit("t={d:>7.1}s [{s}] {s}: {s}\n", .{ st.replaySeconds(), levelName(level), plugin, msg });
}

fn wants(st: *State, what: Print) bool {
    return st.print == .all or st.print == what;
}

// ---------------------------------------------------------------------------
// the loopback NMEA server
// ---------------------------------------------------------------------------

const Listener = struct {
    fd: std.c.fd_t,
    port: u16,

    /// Bind 127.0.0.1 on a port the kernel picks, so several harnesses (and
    /// the app) can run at once.
    fn open() !Listener {
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
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn close(self: *Listener) void {
        _ = std.c.close(self.fd);
    }
};

const Feeder = struct {
    st: *State,
    listen_fd: std.c.fd_t,
    text: []const u8,
    rate: f64,
    /// Last replay second to serve, so the snapshot is taken at exactly the
    /// second `--until` names rather than however far the next poll got.
    until_s: ?f64 = null,

    fn run(self: *Feeder) void {
        while (!self.st.stop.load(.acquire)) {
            const peer = self.acceptOne() orelse continue;
            defer _ = std.c.close(peer);
            // macOS raises SIGPIPE on a write to a socket the plugin closed
            // (a reconnect, a disabled plugin); the error return is enough.
            if (@hasDecl(std.c.SO, "NOSIGPIPE")) {
                var yes: c_int = 1;
                _ = std.c.setsockopt(peer, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &yes, @sizeOf(c_int));
            }
            const n = self.st.conns.fetchAdd(1, .monotonic) + 1;
            if (wants(self.st, .all)) emit("t={d:>7.1}s [info] harness: nmea client connected (#{d})\n", .{ self.st.replaySeconds(), n });
            self.serve(peer);
        }
    }

    /// Accept with a timeout so `stop` is noticed while nothing connects.
    fn acceptOne(self: *Feeder) ?std.c.fd_t {
        var fds = [_]std.c.pollfd{.{ .fd = self.listen_fd, .events = std.c.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, 100) catch return null;
        if (n <= 0) return null;
        const peer = std.c.accept(self.listen_fd, null, null);
        return if (peer < 0) null else peer;
    }

    /// Serve the log once, paced by its own RMC clock, then hold the socket
    /// open: an EOF would send the nmea plugin into its reconnect backoff and
    /// the harness would replay the log from the start.
    fn serve(self: *Feeder, peer: std.c.fd_t) void {
        var sp = replay.Splitter.init(self.text);
        const t0 = broker.monoMs();
        while (!self.st.stop.load(.acquire)) {
            const g = sp.next() orelse break;
            if (self.until_s) |u| {
                if (@as(f64, @floatFromInt(g.second)) > u) break;
            }
            if (!self.waitUntil(t0 + replay.dueMs(g.second, self.rate))) return;
            if (!writeAll(peer, g.text)) {
                if (wants(self.st, .all)) emit("t={d:>7.1}s [warn] harness: nmea client went away\n", .{self.st.replaySeconds()});
                return;
            }
            self.st.replay_ms.store(@as(i64, g.second) * 1000, .monotonic);
            _ = self.st.groups.fetchAdd(1, .monotonic);
            _ = self.st.lines.fetchAdd(std.mem.count(u8, g.text, "\n"), .monotonic);
        }
        self.st.eof.store(true, .release);
        while (!self.st.stop.load(.acquire)) broker.sleepMs(20);
    }

    /// Sleep until `due` (monotonic ms). False when the harness stopped first.
    fn waitUntil(self: *Feeder, due: i64) bool {
        while (!self.st.stop.load(.acquire)) {
            const left = due - broker.monoMs();
            if (left <= 0) return true;
            broker.sleepMs(@intCast(@min(left, 20)));
        }
        return false;
    }
};

fn writeAll(fd: std.c.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        const e = std.c.errno(n);
        if (e == .INTR or e == .AGAIN) {
            broker.sleepMs(1);
            continue;
        }
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// what the stores hold, printed as it changes
// ---------------------------------------------------------------------------

const max_watch = 48;
const max_text = 128;

/// The last printed rendering of a thing, so only changes print. Keyed by
/// name (a vessel path, an MMSI, an overlay object id) in a fixed table: the
/// prototype's plugins publish a handful of each, and a poller that allocates
/// per tick would be measuring itself.
const Watch = struct {
    const Row = struct {
        key: [64]u8 = undefined,
        key_len: usize = 0,
        text: [max_text]u8 = undefined,
        text_len: usize = 0,
        /// Set by `update`, cleared by `beginSweep`: whether this key was in
        /// the store on THIS pass. Distinct from holding a recorded value,
        /// which every row in the table does.
        present: bool = false,
    };
    /// What this table watches, for the one line it prints if it fills up.
    what: []const u8,
    rows: [max_watch]Row = @splat(.{}),
    n: usize = 0,
    /// Set when a key was dropped for want of space, so the warning that the
    /// stream is now incomplete prints exactly once.
    overflowed: bool = false,

    fn find(self: *Watch, key: []const u8) ?*Row {
        for (self.rows[0..self.n]) |*r| {
            if (std.mem.eql(u8, r.key[0..r.key_len], key)) return r;
        }
        return null;
    }

    /// Record `key` = `text`. Returns true when that is a change worth
    /// printing: a key never seen, or one whose text moved. `text` must NOT
    /// carry an age or any other value that changes on its own, or every pass
    /// looks like a change.
    fn update(self: *Watch, key: []const u8, text: []const u8) bool {
        var fresh = false;
        const row = self.find(key) orelse blk: {
            if (self.n == max_watch or key.len > 64) {
                if (!self.overflowed) emit("harness: more than {d} {s} to watch; the rest are not in this stream\n", .{ max_watch, self.what });
                self.overflowed = true;
                return false;
            }
            const r = &self.rows[self.n];
            self.n += 1;
            @memcpy(r.key[0..key.len], key);
            r.key_len = key.len;
            fresh = true;
            break :blk r;
        };
        const n = @min(text.len, max_text);
        const same = !fresh and row.text_len == n and std.mem.eql(u8, row.text[0..n], text[0..n]);
        @memcpy(row.text[0..n], text[0..n]);
        row.text_len = n;
        row.present = true;
        return !same;
    }

    /// Start a pass that also detects disappearance.
    fn beginSweep(self: *Watch) void {
        for (self.rows[0..self.n]) |*r| r.present = false;
    }

    /// The key of the next row this pass did not see, removed from the table.
    /// `buf` takes the key, which the row no longer holds after the call.
    fn nextGone(self: *Watch, buf: []u8) ?[]const u8 {
        for (self.rows[0..self.n], 0..) |*r, i| {
            if (r.present) continue;
            const len = @min(r.key_len, buf.len);
            @memcpy(buf[0..len], r.key[0..len]);
            self.rows[i] = self.rows[self.n - 1];
            self.n -= 1;
            return buf[0..len];
        }
        return null;
    }
};

/// Polls the three stores the plugins write and prints what moved. Reading
/// the stores rather than the log is deliberate: the broker logs failures,
/// not successful publishes, so this is the only place a publish becomes
/// visible without touching broker.zig.
const Watcher = struct {
    st: *State,
    ps: PluginsRef,
    paths: Watch = .{ .what = "vessel paths" },
    ais: Watch = .{ .what = "AIS targets" },
    objs: Watch = .{ .what = "overlay objects" },

    fn poll(self: *Watcher, now_ms: i64, alloc: std.mem.Allocator) void {
        if (wants(self.st, .deltas)) {
            self.pollPaths(now_ms);
            self.pollAis(now_ms, alloc);
        }
        if (wants(self.st, .overlay)) self.pollOverlay();
    }

    /// The vessel store's own path list, then the elected reading for each.
    /// The list is copied under the store's lock and read back through the
    /// public `readElected`, so nothing here holds a lock across a print.
    fn pollPaths(self: *Watcher, now_ms: i64) void {
        var names: [max_watch][64]u8 = undefined;
        var lens: [max_watch]usize = undefined;
        var n: usize = 0;
        {
            const vs = self.ps.vessels;
            vs.mu.lock();
            defer vs.mu.unlock();
            for (vs.entries.items) |e| {
                if (n == max_watch or e.path.len > 64) continue;
                @memcpy(names[n][0..e.path.len], e.path);
                lens[n] = e.path.len;
                n += 1;
            }
        }

        self.paths.beginSweep();
        for (0..n) |i| {
            const path = names[i][0..lens[i]];
            const r = self.ps.vessels.readElected(path, now_ms) orelse continue;
            var vbuf: [96]u8 = undefined;
            const value = r.value.toJson(&vbuf) catch continue;
            // Age is printed but not compared: it moves every pass on its own,
            // and a value that never changes would print forever.
            var line: [max_text]u8 = undefined;
            var w = std.Io.Writer.fixed(&line);
            w.print("{s} src {d}{s}", .{ value, r.source, if (r.stale) " STALE" else "" }) catch {};
            if (!self.paths.update(path, w.buffered())) continue;
            emit("t={d:>7.1}s publish {s} = {s} (age {d} ms)\n", .{ self.st.replaySeconds(), path, w.buffered(), r.age_ms });
        }
        var gone: [64]u8 = undefined;
        while (self.paths.nextGone(&gone)) |k| {
            emit("t={d:>7.1}s publish {s} gone\n", .{ self.st.replaySeconds(), k });
        }
    }

    fn pollAis(self: *Watcher, now_ms: i64, alloc: std.mem.Allocator) void {
        const targets = self.ps.ais.snapshot(alloc) catch return;
        defer alloc.free(targets);
        self.ais.beginSweep();
        for (targets) |tg| {
            var key: [64]u8 = undefined;
            const k = std.fmt.bufPrint(&key, "{d}", .{tg.mmsi}) catch continue;
            var line: [max_text]u8 = undefined;
            var w = std.Io.Writer.fixed(&line);
            if (tg.aton) {
                w.print("{d:.5},{d:.5} AtoN type {d}{s}{s} {s}", .{
                    tg.lat orelse 0,
                    tg.lon orelse 0,
                    tg.aton_type orelse 0,
                    if (tg.virtual_aton) " VIRTUAL" else " physical",
                    if (tg.off_position orelse false) " OFF POSITION" else "",
                    tg.name() orelse "",
                }) catch {};
            } else w.print("{d:.5},{d:.5} sog {d:.1} m/s cog {d:.0} hdg {d:.0} {s}", .{
                tg.lat orelse 0,
                tg.lon orelse 0,
                tg.sog orelse 0,
                tg.cog orelse -1,
                tg.heading orelse -1,
                tg.name() orelse "",
            }) catch {};
            if (!self.ais.update(k, w.buffered())) continue;
            emit("t={d:>7.1}s ais {s} {s} (age {d} ms)\n", .{ self.st.replaySeconds(), k, w.buffered(), tg.ageMs(now_ms) });
        }
        // Anything not in the snapshot was evicted or cleared.
        var gone: [64]u8 = undefined;
        while (self.ais.nextGone(&gone)) |k| {
            emit("t={d:>7.1}s ais {s} gone\n", .{ self.st.replaySeconds(), k });
        }
    }

    /// Overlay objects appearing and disappearing. Their geometry moves every
    /// second and printing that would drown the stream; the inventory at the
    /// end says what is on the chart.
    fn pollOverlay(self: *Watcher) void {
        var keys: [max_watch][64]u8 = undefined;
        var lens: [max_watch]usize = undefined;
        var desc: [max_watch][64]u8 = undefined;
        var desc_len: [max_watch]usize = undefined;
        var n: usize = 0;
        {
            const store = self.ps.overlay;
            store.mu.lock();
            defer store.mu.unlock();
            for (store.objs.keys(), store.objs.values()) |k, o| {
                if (n == max_watch or k.len > 64) continue;
                @memcpy(keys[n][0..k.len], k);
                lens[n] = k.len;
                var w = std.Io.Writer.fixed(&desc[n]);
                w.print("{s} {s}", .{ @tagName(o.kind), @tagName(o.token) }) catch {};
                if (o.pts.len > 0) w.print(" {d} pts", .{o.pts.len}) catch {};
                desc_len[n] = w.buffered().len;
                n += 1;
            }
        }

        self.objs.beginSweep();
        for (0..n) |i| {
            const key = keys[i][0..lens[i]];
            const text = desc[i][0..desc_len[i]];
            if (!self.objs.update(key, text)) continue;
            emit("t={d:>7.1}s overlay + {s} ({s})\n", .{ self.st.replaySeconds(), key, text });
        }
        var gone: [64]u8 = undefined;
        while (self.objs.nextGone(&gone)) |k| {
            emit("t={d:>7.1}s overlay - {s}\n", .{ self.st.replaySeconds(), k });
        }
    }

    /// What the plugins have on the chart at the end of the run.
    fn inventory(self: *Watcher) void {
        const store = self.ps.overlay;
        store.mu.lock();
        defer store.mu.unlock();
        emit("overlay: {d} object(s)\n", .{store.objs.count()});
        for (store.objs.keys(), store.objs.values()) |k, o| {
            switch (o.kind) {
                .symbol => emit("  {s}: {s} {s} at {d:.5},{d:.5} rot {d:.0}\n", .{ k, @tagName(o.sym), @tagName(o.token), o.at[0], o.at[1], o.rot_deg }),
                .polyline => emit("  {s}: polyline {s} {d} pts{s}\n", .{ k, @tagName(o.token), o.pts.len, if (o.dash) " dashed" else "" }),
                .polygon => emit("  {s}: polygon {s} {d} pts\n", .{ k, @tagName(o.token), o.pts.len }),
            }
        }
    }
};

/// The plugin layer's four pieces, borrowed out of the core. root.zig keeps
/// them in one heap allocation whose type it does not export; these are the
/// pointers the harness needs from it.
const PluginsRef = struct {
    vessels: *phost.store.Store,
    ais: *phost.aisstore.AisStore,
    overlay: *ov.Store,
    br: *broker.Broker,
    host: *phost.Host,
};

fn pluginsRef(l: *lk.Lookout) ?PluginsRef {
    const ps = l.plugins orelse return null;
    return .{
        .vessels = &ps.vessels,
        .ais = &ps.ais,
        .overlay = &ps.overlay,
        .br = &ps.br,
        .host = &ps.host,
    };
}

// ---------------------------------------------------------------------------
// charts
// ---------------------------------------------------------------------------

const io = std.Io.Threaded.global_single_threaded.io();

fn isDir(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// Every baked archive under a directory, the way src/main.zig finds them.
fn scanPmtiles(alloc: std.mem.Allocator, dir: []const u8, out: *std.ArrayList([:0]const u8)) !void {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var w = try d.walk(alloc);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (e.kind == .directory or !std.mem.endsWith(u8, e.basename, ".pmtiles")) continue;
        try out.append(alloc, try std.fs.path.joinZ(alloc, &.{ dir, e.path }));
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

/// One thing to do TO a plugin at a replay second: a settings change, or a
/// file the mariner would have chosen.
///
/// Proving a setting is applied HOT means changing it while the log is playing
/// and watching the behaviour move, which is what the second is for. A grant is
/// timed for the same reason: a plugin that reads a file must go on serving the
/// stream while it does.
const Action = struct {
    at_s: f64 = 0,
    kind: Kind,
    id: [:0]const u8,
    /// The settings object for `.config`, the file path for `.grant`.
    arg: [:0]const u8,
    done: bool = false,

    const Kind = enum { config, grant };
};

/// `[SECONDS@]ID`. `flag` names the option in the error, so a bad second says
/// which argument it came from.
fn parseActionTarget(flag: []const u8, text: [:0]const u8) struct { at_s: f64, id: [:0]const u8 } {
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return .{ .at_s = 0, .id = text };
    const secs = std.fmt.parseFloat(f64, text[0..at]) catch
        fail("{s}: {s} is not a replay second", .{ flag, text[0..at] });
    return .{ .at_s = secs, .id = text[at + 1 .. :0] };
}

const Args = struct {
    charts: std.ArrayList([:0]const u8) = .empty,
    actions: std.ArrayList(Action) = .empty,
    plugins_dir: ?[:0]const u8 = null,
    replay_path: ?[]const u8 = null,
    rate: f64 = 1,
    until_s: ?f64 = null,
    png: []const u8 = "plugin-dev.png",
    view: ?lk.View = null,
    width: u32 = 1600,
    height: u32 = 1200,
    scheme: lk.Scheme = @import("c.zig").c.TILE57_SCHEME_DAY,
    print: Print = .all,
};

/// `lon,lat,zoom[,rotation_deg]`. The rotation is there because overlay
/// geometry under a turned camera is only verifiable by rendering one.
fn parseView(text: []const u8) ?lk.View {
    var it = std.mem.splitScalar(u8, text, ',');
    const lon = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const lat = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const zoom = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    var rot: f64 = 0;
    if (it.next()) |r| rot = std.fmt.parseFloat(f64, r) catch return null;
    if (it.next() != null) return null;
    return .{ .lon = lon, .lat = lat, .zoom = zoom, .rotation_deg = rot };
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lookout-plugin-dev: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// How often a frame is rendered while the log plays. Frequent enough that an
/// overlay posted mid-replay is on screen well before the snapshot, cheap
/// enough that the render does not become the replay's clock.
const frame_interval_ms: i64 = 250;
/// How often the stores are read for the delta stream.
const poll_interval_ms: i64 = 100;
/// Time given to the last second of the log to reach the overlay: the socket,
/// the parse, the publish, the broker's 100 ms fanout tick and the plugin's
/// draw all happen after the harness stops feeding.
const settle_ms: u32 = 400;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const cc = @import("c.zig").c;

    var a = Args{};
    defer a.charts.deinit(alloc);
    defer a.actions.deinit(alloc);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const next: ?[:0]const u8 = if (i + 1 < argv.len) argv[i + 1][0.. :0] else null;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{USAGE});
            return;
        } else if (std.mem.eql(u8, arg, "--chart")) {
            try a.charts.append(alloc, next orelse fail("--chart needs a path", .{}));
            i += 1;
        } else if (std.mem.eql(u8, arg, "--plugins")) {
            a.plugins_dir = next orelse fail("--plugins needs a directory", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            a.replay_path = next orelse fail("--replay needs a file", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--rate")) {
            a.rate = std.fmt.parseFloat(f64, next orelse "") catch fail("--rate wants a number", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--until")) {
            a.until_s = std.fmt.parseFloat(f64, next orelse "") catch fail("--until wants replay seconds", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--png")) {
            a.png = next orelse fail("--png needs a path", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--view")) {
            a.view = parseView(next orelse "") orelse fail("--view wants lon,lat,zoom[,rotation_deg]", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--width")) {
            a.width = std.fmt.parseInt(u32, next orelse "", 10) catch fail("--width wants pixels", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--height")) {
            a.height = std.fmt.parseInt(u32, next orelse "", 10) catch fail("--height wants pixels", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--scheme")) {
            const s = next orelse "";
            a.scheme = if (std.mem.eql(u8, s, "day"))
                cc.TILE57_SCHEME_DAY
            else if (std.mem.eql(u8, s, "dusk"))
                cc.TILE57_SCHEME_DUSK
            else if (std.mem.eql(u8, s, "night"))
                cc.TILE57_SCHEME_NIGHT
            else
                fail("--scheme wants day, dusk or night", .{});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--set-config")) {
            const target = parseActionTarget(arg, next orelse fail("--set-config needs a plugin id", .{}));
            if (i + 2 >= argv.len) fail("--set-config needs an id and a JSON object", .{});
            try a.actions.append(alloc, .{
                .at_s = target.at_s,
                .kind = .config,
                .id = target.id,
                .arg = argv[i + 2][0.. :0],
            });
            i += 2;
        } else if (std.mem.eql(u8, arg, "--grant-file")) {
            const target = parseActionTarget(arg, next orelse fail("--grant-file needs a plugin id", .{}));
            if (i + 2 >= argv.len) fail("--grant-file needs an id and a file path", .{});
            try a.actions.append(alloc, .{
                .at_s = target.at_s,
                .kind = .grant,
                .id = target.id,
                .arg = argv[i + 2][0.. :0],
            });
            i += 2;
        } else if (std.mem.eql(u8, arg, "--print")) {
            a.print = std.meta.stringToEnum(Print, next orelse "") orelse
                fail("--print wants all, deltas, overlay, alert or status", .{});
            i += 1;
        } else if (arg.len > 0 and arg[0] != '-') {
            try a.charts.append(alloc, argv[i][0.. :0]);
        } else {
            fail("unknown option {s}\n\n{s}", .{ arg, USAGE });
        }
    }
    if (a.charts.items.len == 0) fail("no --chart given.\n\n{s}", .{USAGE});
    state.print = a.print;

    // Expand chart directories the way the demo does: one --chart may name a
    // whole ENC_ROOT.
    var chart_paths: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (chart_paths.items) |p| alloc.free(p);
        chart_paths.deinit(alloc);
    }
    for (a.charts.items) |p| {
        if (isDir(p)) {
            scanPmtiles(alloc, p, &chart_paths) catch fail("cannot scan {s}", .{p});
        } else {
            try chart_paths.append(alloc, try alloc.dupeZ(u8, p));
        }
    }
    if (chart_paths.items.len == 0) fail("no .pmtiles found in the --chart path(s)", .{});

    // The replay log, whole: 600 s of 1 Hz NMEA is ~100 KiB.
    var log_text: []const u8 = "";
    if (a.replay_path) |path| {
        log_text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch
            fail("cannot read the replay log {s}", .{path});
    }
    defer if (log_text.len > 0) alloc.free(log_text);

    // The listener must exist before the core does: root.zig reads
    // LOOKOUT_NMEA while it opens the chart, and the plugin dials at once.
    var listener = Listener.open() catch fail("cannot bind a loopback listener", .{});
    defer listener.close();
    var nmea_env: [64]u8 = undefined;
    const nmea = std.fmt.bufPrintZ(&nmea_env, "127.0.0.1:{d}", .{listener.port}) catch unreachable;
    _ = setenv("LOOKOUT_NMEA", nmea.ptr, 1);
    if (a.plugins_dir) |dir| {
        _ = setenv("LOOKOUT_PLUGINS", dir.ptr, 1);
    } else {
        emit("harness: no --plugins, running the chart alone\n", .{});
    }
    emit("harness: nmea listener on {s}\n", .{nmea});

    const l = lk.Lookout.openCharts(alloc, chart_paths.items, .{
        .want_window = false,
        .width = a.width,
        .height = a.height,
    }) catch fail("cannot open the chart(s)", .{});
    defer l.close();

    const ps = pluginsRef(l);
    if (ps) |p| {
        p.br.setLog(&state, logSink);
        // The directory can also arrive as LOOKOUT_PLUGINS from the caller's
        // environment, which is why this does not assume --plugins was given.
        emit("harness: {d} plugin(s) loaded from {s}\n", .{ p.host.count(), a.plugins_dir orelse "$LOOKOUT_PLUGINS" });
    } else if (a.plugins_dir != null) {
        emit("harness: LOOKOUT_PLUGINS was set but no plugin layer came up\n", .{});
    }

    const v = a.view orelse l.fitChart();
    l.setView(v);
    var m = l.getMariner();
    m.scheme = a.scheme;
    l.setMariner(m);
    emit("harness: view lon={d:.5} lat={d:.5} zoom={d:.2}, {d}x{d}\n", .{ v.lon, v.lat, v.zoom, a.width, a.height });

    // First frame before the replay starts: the chart's own build is seconds
    // of work on a cold cache and must not eat into the replay clock.
    const px = try alloc.alloc(u8, @as(usize, a.width) * a.height * 4);
    defer alloc.free(px);
    var frames: u64 = 0;
    if (l.snapshotRgba(px)) |_| {
        frames += 1;
    } else |e| emit("harness: first frame failed: {s}\n", .{@errorName(e)});

    var feeder = Feeder{ .st = &state, .listen_fd = listener.fd, .text = log_text, .rate = a.rate, .until_s = a.until_s };
    var feeder_thread: ?std.Thread = null;
    if (log_text.len > 0) {
        feeder_thread = std.Thread.spawn(.{}, Feeder.run, .{&feeder}) catch |e|
            fail("cannot start the replay thread: {s}", .{@errorName(e)});
    }

    var watcher: ?Watcher = if (ps) |p| .{ .st = &state, .ps = p } else null;

    // The loop: serve, watch, render, until the replay reaches --until (or
    // runs out). Rendering is what makes an overlay posted from the dispatch
    // thread reach the GPU, so it happens throughout, not only at the end.
    const start_mono = broker.monoMs();
    var next_frame = start_mono;
    var next_poll = start_mono;
    var warned_silent = false;
    const wall_cap_ms: i64 = if (a.until_s) |u|
        @intFromFloat(@max(u * 1000.0 / @max(a.rate, 0.001) * 3.0, 30_000.0))
    else
        600_000;

    while (true) {
        const now = broker.monoMs();
        if (a.until_s) |u| {
            if (state.replaySeconds() >= u) break;
        }
        if (state.eof.load(.acquire) and state.replay_ms.load(.monotonic) > 0) break;
        if (log_text.len == 0 and now - start_mono > 1000) break;
        if (now - start_mono > wall_cap_ms) {
            emit("harness: giving up after {d} s of wall clock\n", .{@divTrunc(now - start_mono, 1000)});
            break;
        }
        // Nothing dialled the listener: no plugin holds net.tcp-client, or the
        // one that does never connected. The replay clock cannot advance, so
        // say so rather than sit here until the wall cap.
        if (!warned_silent and log_text.len > 0 and state.conns.load(.monotonic) == 0 and now - start_mono > 5_000) {
            warned_silent = true;
            emit("harness: nothing has connected to {s} after 5 s; the log is not being read\n", .{nmea});
        }
        for (a.actions.items) |*c| {
            if (c.done or state.replaySeconds() < c.at_s) continue;
            c.done = true;
            switch (c.kind) {
                .config => if (l.setPluginConfig(std.mem.span(c.id.ptr), std.mem.span(c.arg.ptr))) |_| {
                    emit("t={d:>7.1}s set-config {s} {s}\n", .{ state.replaySeconds(), c.id, c.arg });
                } else |e| {
                    emit("t={d:>7.1}s set-config {s} REFUSED: {s}\n", .{ state.replaySeconds(), c.id, @errorName(e) });
                },
                // The grant a mariner's open panel makes, driven from the
                // command line. The handle printed is the one FILE_OPENED
                // carries, so a plugin's own log lines can be read against it.
                .grant => {
                    const p = ps orelse fail("--grant-file needs a plugin layer; pass --plugins", .{});
                    if (p.host.grantFile(std.mem.span(c.id.ptr), std.mem.span(c.arg.ptr), false)) |handle| {
                        emit("t={d:>7.1}s grant-file {s} {s} FILE_OPENED handle {d}\n", .{ state.replaySeconds(), c.id, c.arg, handle });
                    } else |e| {
                        emit("t={d:>7.1}s grant-file {s} {s} REFUSED: {s}\n", .{ state.replaySeconds(), c.id, c.arg, @errorName(e) });
                    }
                },
            }
        }
        if (now >= next_poll) {
            next_poll = now + poll_interval_ms;
            if (watcher) |*w| w.poll(broker.wallMs(), alloc);
        }
        if (now >= next_frame) {
            next_frame = now + frame_interval_ms;
            if (l.snapshotRgba(px)) |_| {
                frames += 1;
            } else |e| emit("harness: frame failed: {s}\n", .{@errorName(e)});
        }
        broker.sleepMs(10);
    }

    // The last group is still in flight when the loop breaks: it has to cross
    // the socket, be parsed, published, fanned out on the broker's 100 ms tick
    // and drawn before the snapshot can show it.
    var settle: u32 = 0;
    while (settle < settle_ms) : (settle += 50) {
        broker.sleepMs(50);
        if (watcher) |*w| w.poll(broker.wallMs(), alloc);
    }
    var png_ok = false;
    if (l.snapshotPng(a.png)) |_| {
        frames += 1;
        png_ok = true;
        emit("harness: wrote {s}\n", .{a.png});
    } else |e| emit("harness: snapshot failed: {s}\n", .{@errorName(e)});

    // Stop the feeder before the core closes: l.close() takes the plugins
    // down, and a socket still being written to is a plugin still being fed.
    state.stop.store(true, .release);
    if (feeder_thread) |th| th.join();

    if (watcher) |*w| w.inventory();

    var trapped = state.trapped.load(.monotonic);
    if (ps) |p| {
        for (p.host.entries.items) |*e| {
            if (!e.isLive()) trapped = true;
            emit("plugin {s}: {s}, {d} denied call(s), status {s}\n", .{
                e.manifest.id,
                if (e.isLive()) "live" else "STOPPED",
                e.state.denied,
                if (e.state.status().len > 0) e.state.status() else "(none)",
            });
        }
    }
    emit("replay: {d} group(s), {d} line(s), {d:.1} s at {d}x, {d} connection(s)\n", .{
        state.groups.load(.monotonic),
        state.lines.load(.monotonic),
        state.replaySeconds(),
        a.rate,
        state.conns.load(.monotonic),
    });
    emit("frames: {d} rendered, {d} alert(s) raised\n", .{ frames, state.alerts.load(.monotonic) });
    emit("harness: stopping the plugins\n", .{});

    if (trapped) {
        emit("FAIL: a plugin trapped or stopped\n", .{});
        l.close();
        std.process.exit(1);
    }
    if (frames == 0 or !png_ok) {
        emit("FAIL: no frame rendered\n", .{});
        l.close();
        std.process.exit(1);
    }
}
