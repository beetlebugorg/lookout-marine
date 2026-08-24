//! One inbound FIFO per plugin, and the caps that keep a plugin which stops
//! consuming from growing its queue without bound.

const std = @import("std");

const broker = @import("../broker.zig");
const caps = @import("caps.zig");
const testing = @import("testing.zig");

const vstore = @import("../store.zig");
const ais_store = @import("../aisstore.zig");
const net = @import("../net.zig");

const Broker = broker.Broker;
const Kind = caps.Kind;

pub const Event = struct {
    /// Registry index of the plugin this is for.
    plugin: u32,
    kind: u32,
    handle: u64,
    /// Owned by the broker; the dispatch thread frees it after delivery.
    payload: []u8,
};

/// ONE FIFO PER PLUGIN, this deep. Over this the prototype's four plugins
/// never queue more than a few dozen events; the cap exists so a plugin that
/// stops consuming cannot grow its queue without bound — and because the
/// queues are separate, the plugin that stops consuming is the only one that
/// loses events.
pub const max_queued = 1024;

/// Above this depth the I/O thread stops READING that plugin's sockets, which
/// pushes the backlog into the kernel's receive buffer and then onto the peer
/// as TCP window pressure. Three quarters leaves room for the events a paused
/// plugin still gets — timers and fanout, which have nowhere to push back to.
pub const pause_reads_at = max_queued * 3 / 4;

/// Highest plugin index a queue is kept for. Indices come from the host's
/// registry, so this is a sanity bound on the array a stray push could grow,
/// not a product decision about how many plugins may run.
pub const max_plugins = 64;

/// One plugin's inbound FIFO.
pub const Queue = struct {
    items: std.ArrayList(Event) = .empty,
    /// Read cursor. The queue compacts when the cursor has passed half of it,
    /// so a steady stream neither shifts every pop nor grows without bound.
    head: usize = 0,
    /// Events discarded because this queue was full.
    dropped: u64 = 0,
    /// True while this plugin's sockets are not being read.
    paused: bool = false,
    /// The plugin's dispatch thread parks on [0]; a push writes a byte to
    /// [1]. Made with the queue; invalid when the host had no descriptors to
    /// spare, in which case parking degrades to a bounded poll.
    wake: [2]net.Socket = .{ net.invalid, net.invalid },

    pub fn depth(self: *const Queue) usize {
        return self.items.items.len - self.head;
    }
};

const t = std.testing;
const silentLog = testing.silentLog;

test "each plugin's queue is its own FIFO and compacts as it drains" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();

    for (0..300) |i| b.push(@intCast(i % 3), Kind.timer, i, "x");
    try t.expectEqual(@as(usize, 300), b.queued());
    try t.expectEqual(@as(usize, 100), b.queuedFor(1));

    // Each plugin sees its own events, in the order they were pushed, and none
    // of anybody else's.
    for (0..3) |p| {
        for (0..100) |n| {
            const e = b.popFor(@intCast(p)).?;
            defer b.freeEvent(e);
            try t.expectEqual(@as(u64, n * 3 + p), e.handle);
            try t.expectEqual(@as(u32, @intCast(p)), e.plugin);
        }
        try t.expect(b.popFor(@intCast(p)) == null);
    }
    try t.expectEqual(@as(usize, 0), b.queued());
}

test "a plugin that stops consuming loses its own events and nobody else's" {
    var vessels = try vstore.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = ais_store.AisStore.init(t.allocator);
    defer ais.deinit();
    var b = Broker.init(t.allocator, &vessels, &ais, .{});
    defer b.deinit();
    b.setLog(null, silentLog);

    for (0..max_queued + 50) |i| b.push(0, Kind.timer, i, "");
    b.push(1, Kind.timer, 7, "");

    try t.expectEqual(@as(usize, max_queued), b.queuedFor(0));
    try t.expectEqual(@as(u64, 50), b.droppedFor(0));
    // The neighbour is untouched: separate queues, separate caps.
    try t.expectEqual(@as(usize, 1), b.queuedFor(1));
    try t.expectEqual(@as(u64, 0), b.droppedFor(1));
    // The FIFO keeps the OLDEST events; the overflow is at the tail.
    const first = b.popFor(0).?;
    defer b.freeEvent(first);
    try t.expectEqual(@as(u64, 0), first.handle);

    // SHUTDOWN ignores the cap: a plugin in trouble is exactly the one that
    // has to hear it.
    b.push(0, Kind.shutdown, 0, "");
    try t.expectEqual(@as(usize, max_queued), b.queuedFor(0));
    try t.expectEqual(@as(u64, 50), b.droppedFor(0));
}
