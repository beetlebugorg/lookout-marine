//! Serve a recorded NMEA 0183 log over TCP, the way a boat's gateway does.
//!
//!   zig run -lc tools/nmea_replay.zig -- [--port 10110] [--rate 1] [--once] [LOG]
//!
//! The log defaults to test/annapolis.nmea and the port to 10110, which is what
//! the nmea0183 plugin dials unless the mariner says otherwise. Point a
//! connection at 127.0.0.1:10110 and the app sees a boat under way, wind, depth
//! and the scene's AIS targets.
//!
//! Sentences are grouped the way the log is written, from one RMC to the next,
//! and a group goes out every second divided by `--rate`. The log restarts when
//! it runs out and every client gets it from the top, so what a client sees
//! does not depend on when it connected.
//!
//! This serves a RECORDED log and nothing else. It is never pointed at a live
//! feed: a frame or a fixture built from one carries other people's vessel
//! names, MMSIs and positions.
//!
//! POSIX only. It is a development tool for the machines the shells are built
//! on, so it talks to libc rather than carrying the host's Windows layer.

const std = @import("std");

const max_log_bytes = 8 * 1024 * 1024;

/// The host's own sleep, stated the same way broker.zig states it.
const posix = struct {
    extern "c" fn usleep(usec: u32) c_int;
};

const Args = struct {
    path: []const u8 = "test/annapolis.nmea",
    port: u16 = 10110,
    rate: f64 = 1.0,
    once: bool = false,
};

/// One second of the log: every sentence from one RMC up to the next.
const Group = struct { start: usize, end: usize };

const Scene = struct {
    text: []const u8,
    groups: []const Group,
    period_us: u32,
    once: bool,
};

fn isRmc(line: []const u8) bool {
    return line.len > 6 and line[0] == '$' and std.mem.indexOf(u8, line[0..9], "RMC") != null;
}

/// Split the log at each RMC. A leading run with no RMC is its own group, so
/// nothing is dropped.
fn split(alloc: std.mem.Allocator, text: []const u8) ![]Group {
    var out: std.ArrayList(Group) = .empty;
    errdefer out.deinit(alloc);
    var start: usize = 0;
    var i: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
        if (isRmc(trimmed) and i > start) {
            try out.append(alloc, .{ .start = start, .end = i });
            start = i;
        }
        i += line.len + 1;
    }
    if (start < text.len) try out.append(alloc, .{ .start = start, .end = text.len });
    return out.toOwnedSlice(alloc);
}

fn send(fd: std.c.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn feed(scene: *const Scene, fd: std.c.fd_t) void {
    defer _ = std.c.close(fd);
    while (true) {
        for (scene.groups) |g| {
            if (!send(fd, scene.text[g.start..g.end])) return;
            _ = posix.usleep(scene.period_us);
        }
        if (scene.once) return;
    }
}

fn parseArgs(argv: []const []const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--once")) {
            a.once = true;
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < argv.len) {
            i += 1;
            a.port = try std.fmt.parseInt(u16, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--rate") and i + 1 < argv.len) {
            i += 1;
            a.rate = try std.fmt.parseFloat(f64, argv[i]);
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            a.path = arg;
        }
    }
    return a;
}

/// Bind 127.0.0.1 only. A replay feed is for this machine, and a log served to
/// the network is a boat's instruments impersonated on somebody else's screen.
fn listenLoopback(port: u16) !std.c.fd_t {
    const s = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (s < 0) return error.SocketFailed;
    errdefer _ = std.c.close(s);
    var yes: c_int = 1;
    _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
    var addr = std.c.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    if (std.c.bind(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    if (std.c.listen(s, 4) != 0) return error.ListenFailed;
    return s;
}

/// The port actually bound. Port 0 asks the system for a free one, which is
/// what a script wants when a fixed port may already be taken.
fn boundPort(s: std.c.fd_t) u16 {
    var addr = std.c.sockaddr.in{ .port = 0, .addr = 0 };
    var len: std.c.socklen_t = @sizeOf(@TypeOf(addr));
    if (std.c.getsockname(s, @ptrCast(&addr), &len) != 0) return 0;
    return std.mem.bigToNative(u16, addr.port);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const a = try parseArgs(argv);

    const text = std.Io.Dir.cwd().readFileAlloc(init.io, a.path, alloc, .limited(max_log_bytes)) catch {
        var eb: [512]u8 = undefined;
        var err = std.Io.File.stderr().writer(init.io, &eb);
        try err.interface.print(
            "no log at {s}. Generate one: zig run tools/nmea_gen.zig -- {s}\n",
            .{ a.path, a.path },
        );
        try err.interface.flush();
        return error.NoLog;
    };
    defer alloc.free(text);

    const groups = try split(alloc, text);
    defer alloc.free(groups);

    const scene: Scene = .{
        .text = text,
        .groups = groups,
        .period_us = if (a.rate > 0)
            @intFromFloat(1_000_000.0 / a.rate)
        else
            0,
        .once = a.once,
    };

    const srv = try listenLoopback(a.port);
    defer _ = std.c.close(srv);

    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    try out.interface.print(
        "serving {s}, {d} group(s) at {d}x on 127.0.0.1:{d}. Ctrl-C to stop.\n",
        .{ a.path, groups.len, a.rate, boundPort(srv) },
    );
    try out.interface.flush();

    while (true) {
        const peer = std.c.accept(srv, null, null);
        if (peer < 0) continue;
        const t = std.Thread.spawn(.{}, feed, .{ &scene, peer }) catch {
            _ = std.c.close(peer);
            continue;
        };
        t.detach();
    }
}
