//! A throwaway plugin that exercises every part of the host it can reach
//! without doing anything useful: it subscribes to a path, sets a periodic
//! timer, echoes TCP bytes into the log, draws one overlay symbol, takes two
//! settings, and tries to raise an alert it was deliberately NOT granted.
//!
//! It exists so plugins/common/lk.zig, src/plugin/broker.zig and
//! src/plugin/host.zig can be tested end to end before the four real plugins
//! are written. test/host_smoke.zig drives it. Delete it when the prototype's
//! own plugins cover the same ground.

const std = @import("std");
const lk = @import("lk");

comptime {
    lk.registerPlugin(@This());
}

/// Where the symbol goes when the store has not given us a position yet:
/// Annapolis harbour, the prototype's test ground.
const default_lon: f64 = -76.4767;
const default_lat: f64 = 38.9763;

var ticks: u32 = 0;
var values_seen: u32 = 0;
var lon: f64 = default_lon;
var lat: f64 = default_lat;

/// The two settings the manifest declares, applied hot. `draw` off deletes the
/// symbol; `scale` resizes it on the next draw.
var draw_on: bool = true;
var scale: f64 = 1.0;

pub fn start(s: lk.Start) !void {
    lk.logf(.info, "echo start, api {d}", .{s.api});
    applyConfig(s.config);

    const n = lk.subscribePaths(&.{"navigation.position"});
    if (n < 0) return error.SubscribeRefused;

    // A periodic timer, which is also how the smoke test sees the I/O thread
    // is running.
    _ = lk.timerSet(250, true);

    // The manifest does not ask for alerts.raise, so this MUST come back -1
    // with a refusal in the host log. Trying it is the point: a grant that is
    // only checked when it is present is not checked at all.
    const rc = lk.raiseAlert(.caution, "echo", "this alert should be refused");
    lk.logf(.info, "alert without the grant returned {d}", .{rc});

    lk.status("running", "waiting for position", .{});
}

pub fn onEvent(e: lk.Event) !void {
    switch (e) {
        .config_changed => |payload| {
            const root = std.json.parseFromSliceLeaky(std.json.Value, lk.scratch(), payload, .{}) catch {
                lk.logf(.warn, "config is not JSON", .{});
                return;
            };
            applyConfig(root);
            lk.logf(.info, "config draw {} scale {d}", .{ draw_on, scale });
            draw();
        },
        .store_changed => |payload| {
            for (lk.pathValues(payload)) |r| {
                values_seen += 1;
                if (r.removed()) {
                    lk.logf(.info, "{s} removed", .{r.path});
                    continue;
                }
                if (r.position()) |p| {
                    lat = p[0];
                    lon = p[1];
                }
                lk.logf(.info, "{s} age {d} ms", .{ r.path, r.age_ms });
            }
            draw();
        },
        .timer => |id| {
            ticks += 1;
            lk.status("running", "timer {d}, {d} ticks, {d} values", .{ id, ticks, values_seen });
        },
        .ais_changed => |payload| lk.logf(.info, "{d} ais targets", .{lk.targets(payload).len}),
        .tcp_connected => |id| lk.logf(.info, "connected {d}", .{id}),
        .tcp_data => |d| lk.logf(.info, "echo {d}: {s}", .{ d.conn, d.bytes }),
        .tcp_closed => |id| lk.logf(.info, "closed {d}", .{id}),
        .shutdown => {
            lk.logf(.info, "shutdown after {d} ticks", .{ticks});
            lk.status("stopped", "shut down", .{});
        },
        // An event kind this fixture asks for nothing about. The API says an
        // unknown kind is ignored, and a switch with no else arm is a plugin
        // that stops compiling every time the host grows one.
        else => {},
    }
}

/// The settings object the host sends at start and on every change. Both
/// fields are always present, so a missing one means the host sent something
/// this plugin does not understand and the current value stands.
fn applyConfig(cfg: std.json.Value) void {
    if (cfg != .object) return;
    if (cfg.object.get("draw")) |v| {
        if (lk.jbool(v)) |b| draw_on = b;
    }
    if (cfg.object.get("scale")) |v| {
        if (lk.jnum(v)) |n| scale = n;
    }
}

fn draw() void {
    var buf: [512]u8 = undefined;
    var ov = lk.Overlay.init(&buf);
    if (draw_on) {
        ov.symbol("echo", .target, lon, lat, 0, .target, scale);
    } else {
        ov.del("echo");
    }
    _ = ov.send();
}
