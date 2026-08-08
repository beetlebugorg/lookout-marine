//! A plugin that stops coming back. It behaves like any other — logs, draws an
//! overlay symbol, posts a status, answers every event — until it is handed the
//! trigger, and then it never returns from `lk_event` again.
//!
//! It is the subject of test/host_isolation.zig: the proof that one plugin in
//! an endless loop neither stops the other plugins nor stops the host, and that
//! the watchdog takes it out inside its budget. Nothing else runs it, and
//! `zig build plugins` does not install it — like test/smoke_plugin.zig it is a
//! test fixture, not a plugin anybody would sail with.

const lk = @import("lk");

comptime {
    lk.registerPlugin(@This());
}

/// The timer id that means "stop returning". Timer ids the host hands out start
/// at 1 and count up, so this one can only have come from a test pushing a
/// TIMER event by hand.
pub const trigger_timer_id: i64 = 424242;

/// The timer id that means "trap now": an ordinary wasm trap, the kind the host
/// has always handled, so the test can tell the two disable paths apart.
pub const trap_timer_id: i64 = 424243;

/// The timer id that means "allocate until the host refuses": the
/// linear-memory budget, seen from inside the module. Unlike the two above
/// this one is survivable — the allocation fails, the plugin is told, and it
/// carries on — which is the whole point of a budget rather than a kill.
pub const hog_timer_id: i64 = 424244;

/// How much the hog asks for at a time. Big enough that the ceiling is reached
/// in a handful of grows, so the test never comes near the watchdog's budget.
const hog_chunk = 4 * 1024 * 1024;

/// Where the symbol goes: Annapolis harbour, a little east of the echo
/// plugin's, so the two objects are distinguishable.
const lon: f64 = -76.4700;
const lat: f64 = 38.9800;

var events: u32 = 0;

/// Written by the loop below. An atomic read-modify-write, not a plain store:
/// a loop with no observable effect is one the optimiser may delete, and this
/// loop's whole job is to still be running when the watchdog arrives. 32-bit
/// because wasm32 without the threads proposal has no 64-bit atomic.
var spins: u32 = 0;

pub fn start(s: lk.Start) !void {
    lk.logf(.info, "spin start, api {d}", .{s.api});
    draw();
    lk.status("running", "not spinning yet", .{});
}

pub fn onEvent(e: lk.Event) !void {
    events += 1;
    switch (e) {
        .timer => |id| {
            if (id == trigger_timer_id) {
                lk.logf(.warn, "spinning forever from timer {d}", .{id});
                lk.status("running", "spinning", .{});
                while (true) _ = @atomicRmw(u32, &spins, .Add, 1, .monotonic);
            }
            if (id == trap_timer_id) {
                lk.logf(.warn, "trapping on purpose from timer {d}", .{id});
                // The wasm `unreachable` opcode. WAMR reports it by that name,
                // which is the text the host must keep.
                @trap();
            }
            if (id == hog_timer_id) {
                const a = lk.scratch();
                var held: usize = 0;
                while (true) {
                    const mem = a.alloc(u8, hog_chunk) catch break;
                    // Touched at both ends: an allocation nothing reads is one
                    // the optimiser may delete, and the pages have to be real.
                    mem[0] = 1;
                    mem[mem.len - 1] = 1;
                    held += hog_chunk;
                }
                const mib = held / (1024 * 1024);
                lk.logf(.warn, "out of memory after {d} MiB", .{mib});
                lk.status("running", "out of memory after {d} MiB", .{mib});
                return;
            }
            lk.status("running", "{d} events", .{events});
        },
        .store_changed => |payload| {
            lk.logf(.info, "spin saw {d} reading(s)", .{lk.readings(payload).len});
            draw();
        },
        .ais_changed => |payload| lk.logf(.info, "spin saw {d} ais targets", .{lk.targets(payload).len}),
        .shutdown => lk.status("stopped", "shut down after {d} events", .{events}),
        else => {},
    }
}

fn draw() void {
    var buf: [512]u8 = undefined;
    var ov = lk.Overlay.init(&buf);
    ov.symbol("spin", .target, lon, lat, 0, .target, 1.0);
    _ = ov.send();
}
