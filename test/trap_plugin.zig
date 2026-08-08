//! A plugin that breaks on cue. It behaves like any other — logs, draws an
//! overlay symbol, posts a status, answers every event — until it is handed the
//! trigger, and then it traps.
//!
//! It breaks in the two places a plugin in the field breaks. Inside `lk_event`,
//! which is one malformed sentence off the wire; and inside `lk_start`, which
//! is a plugin that cannot come up at all — that one is a setting, so a test can
//! switch it on while the plugin is running and watch every restart fail.
//!
//! Its start line reports what it was handed: the `mark` setting, how many
//! connection rows arrived, and how many events the last instance had counted.
//! That last number is always zero on a restart, which is what proves a
//! restarted plugin does NOT get its globals back.
//!
//! It is the subject of test/host_restart.zig. Nothing else runs it, and `zig
//! build plugins` does not install it — like test/spin_plugin.zig it is a test
//! fixture, not a plugin anybody would sail with.

const std = @import("std");
const lk = @import("lk");

comptime {
    lk.registerPlugin(@This());
}

/// The timer id that means "trap now": the wasm `unreachable` opcode, which is
/// what a plugin that indexes past the end of an array gives the host. Timer
/// ids the host hands out start at 1 and count up, so this one can only have
/// come from a test pushing a TIMER event by hand.
pub const trap_timer_id: i64 = 515151;

/// Where the symbol goes: Annapolis harbour, north of the other fixtures'.
const lon: f64 = -76.4750;
const lat: f64 = 38.9850;

/// Events THIS INSTANCE has seen. A restart is a new instance with new linear
/// memory, so the count starts again at zero.
var events: u32 = 0;

/// Set by the setting of the same name, at start and at every settings change:
/// the plugin has to be holding it when SHUTDOWN arrives.
var trap_at_shutdown = false;

pub fn start(s: lk.Start) !void {
    lk.logf(.info, "trap fixture start: mark {d}, {d} connection(s), {d} event(s) remembered", .{
        lk.cfgInt(s.config, "mark", 0),
        rowCount(s.config, "connections"),
        events,
    });
    trap_at_shutdown = flag(s.config, "trap_at_shutdown");
    if (flag(s.config, "trap_at_start")) {
        lk.logf(.warn, "trapping on purpose inside lk_start", .{});
        @trap();
    }
    draw();
    lk.status("running", "started", .{});
}

pub fn onEvent(e: lk.Event) !void {
    events += 1;
    switch (e) {
        .timer => |id| {
            if (id == trap_timer_id) {
                lk.logf(.warn, "trapping on purpose from timer {d}", .{id});
                @trap();
            }
            lk.status("running", "{d} events", .{events});
        },
        .config_changed => |json| {
            // The whole settings object, which is what the host sends. Read
            // back so a test can arm the shutdown trap while the plugin runs.
            if (std.json.parseFromSliceLeaky(std.json.Value, lk.scratch(), json, .{})) |root| {
                trap_at_shutdown = flag(root, "trap_at_shutdown");
            } else |_| {}
            lk.status("running", "{d} events, new settings", .{events});
        },
        .store_changed => {
            draw();
            lk.status("running", "{d} events", .{events});
        },
        .shutdown => {
            if (trap_at_shutdown) {
                lk.logf(.warn, "trapping on purpose inside SHUTDOWN", .{});
                @trap();
            }
            lk.status("stopped", "shut down after {d} events", .{events});
        },
        else => {},
    }
}

fn draw() void {
    var buf: [512]u8 = undefined;
    var ov = lk.Overlay.init(&buf);
    ov.symbol("trap", .target, lon, lat, 0, .target, 1.0);
    _ = ov.send();
}

/// A toggle arrives as a JSON bool, which is neither of the two readers the
/// shim offers.
fn flag(config: std.json.Value, key: []const u8) bool {
    if (config != .object) return false;
    return switch (config.object.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

fn rowCount(config: std.json.Value, key: []const u8) usize {
    if (config != .object) return 0;
    return switch (config.object.get(key) orelse return 0) {
        .array => |a| a.items.len,
        else => 0,
    };
}
