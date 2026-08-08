//! The fixtures the parts of the broker share in their tests: the stores every
//! test needs, a log sink that keeps what was said, and the waits.
//!
//! Every mediated-I/O test built on these runs a real server on loopback rather
//! than a mock, so what is proved is the wire and not a stub: a datagram through
//! the kernel, an HTTP head parsed off a socket, an RFC 6455 handshake with its
//! accept hash, a file on disk. None of them reaches the network.
//!
//! There are no tests here. Each part carries its own.

const std = @import("std");

const broker = @import("../broker.zig");
const queue = @import("queue.zig");

const vstore = @import("../store.zig");
const ais_store = @import("../aisstore.zig");

const Broker = broker.Broker;
const Event = queue.Event;
const monoMs = broker.monoMs;
const sleepMs = broker.sleepMs;
const io = std.Io.Threaded.global_single_threaded.io();

/// 36 bytes, so a range is easy to read by eye in a failure.
pub const test_body = "0123456789abcdefghijklmnopqrstuvwxyz";

pub fn silentLog(_: ?*anyopaque, _: u32, _: []const u8, _: []const u8) void {}

/// Everything the broker said during a test, concatenated. A refusal that is
/// not reported is a refusal the mariner never learns about, so the tests
/// assert on the words and not only on the return value.
pub const Log = struct {
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,
    lines: usize = 0,

    pub fn write(ctx: ?*anyopaque, _: u32, _: []const u8, msg: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ctx orelse return));
        const n = @min(msg.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], msg[0..n]);
        self.len += n;
        self.lines += 1;
    }

    pub fn has(self: *const Log, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.buf[0..self.len], needle) != null;
    }

    pub fn count(self: *const Log) usize {
        return self.lines;
    }
};

/// The four stores every broker test needs, in one place.
pub const Fixture = struct {
    vessels: vstore.Store,
    ais: ais_store.AisStore,
    br: Broker,
    sink: Log = .{},

    pub fn init(alloc: std.mem.Allocator) !*Fixture {
        const self = try alloc.create(Fixture);
        self.* = .{
            .vessels = try vstore.Store.init(alloc),
            .ais = ais_store.AisStore.init(alloc),
            .br = undefined,
        };
        self.br = Broker.init(alloc, &self.vessels, &self.ais, .{});
        self.br.setLog(&self.sink, Log.write);
        return self;
    }

    pub fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        self.br.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        alloc.destroy(self);
    }
};

/// The next event for one plugin, or an error. The caller frees the payload.
pub fn nextEvent(b: *Broker, plugin: u32, timeout_ms: u32) !Event {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (b.popFor(plugin)) |e| return e;
        sleepMs(5);
    }
    return error.NoEvent;
}

/// A directory of this test's own under the system temporary directory, removed
/// on the way out.
pub fn scratchDir(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const base = if (std.c.getenv("TMPDIR")) |x| std.mem.span(x) else "/tmp";
    const trimmed = if (base.len > 1 and base[base.len - 1] == '/') base[0 .. base.len - 1] else base;
    const path = try std.fmt.allocPrint(alloc, "{s}/lookout-plugin-test-{s}-{d}", .{ trimmed, name, monoMs() });
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

pub fn removeScratch(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}
