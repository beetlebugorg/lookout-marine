---
id: drawing
title: Drawing on the chart
---

# Drawing on the chart

**Capabilities:** `overlay.draw`.

Lookout calls your `draw` function once a second. Declare
`pub const draw_rate_ms: i64 = 250;` to change that. A plugin that draws
nothing does not declare `draw`, and gets no timer.

The timer runs while there is somewhere for a scene to land. Switch
`overlay.draw` off and Lookout takes what your plugin drew off the chart,
stops calling your `draw` function, and posts the reason on the plugin's
status line; switch it back on and the timer returns with the whole scene
described again. Nothing about enforcement moves: every host call is still
checked on its own, and one made without the grant still answers -1 and counts
as denied. There is simply no call left to make.

While the timer is down, Lookout leaves the status line alone, so a plugin that
posts its own line from the update hook is still heard. The rest of the plugin
runs as it always did: readings arrive, the update hook runs, and a dialog the
plugin declared keeps filling. A table is data and costs no capability. See
[Subscribing to data](subscribing.md#filling-a-dialog).

Your plugin should draw its entire view on each `draw` call. Lookout compares
that scene with the last one: an object with the same id and the same content
is left alone, a changed one is replaced, and one you did not draw is taken
off the chart. There is no delete call, no batch and no buffer.

```zig
pub fn draw(c: *lk.Chart) void {
    const boat = inputs.boat.get();

    c.line("ahead", &.{ boat, boat.destination(90, lk.nm(1)) }, .{
        .color = .ownship,
        .width_pt = 2,
    });
    c.symbol("mark", .target, boat.destination(45, lk.nm(0.5)), .{
        .color = .target,
        .rot_deg = 45,
    });

    // 72 points is a ring with no visible corners at harbour zoom.
    var ring: [72]lk.Point = undefined;
    for (&ring, 0..) |*p, i| p.* = boat.destination(@as(f64, @floatFromInt(i)) * 5.0, lk.nm(1));
    c.area("guard", &ring, .{ .color = .warning, .alpha = 0.12 });
}
```

`c.line` takes at least two points. `c.area` takes at least three and closes
the ring for you. Each takes a style struct:

| `lk.Chart.Line` | Default | What it is |
|---|---|---|
| `color` | required | a palette token |
| `width_pt` | `1.5` | screen points, converted at the live zoom |
| `dash` | `false` | |
| `anchor` | `.fixed` | |

| `lk.Chart.Symbol` | Default | What it is |
|---|---|---|
| `color` | required | a palette token |
| `rot_deg` | `0` | a true bearing, clockwise from north |
| `scale` | `1` | |
| `anchor` | `.fixed` | |
| `pick` | `null` | what the shell shows on hover or tap |

| `lk.Chart.Area` | Default | What it is |
|---|---|---|
| `color` | required | a palette token |
| `alpha` | `1` | multiplies the token's own alpha |

**Colours are tokens, never RGB.** The tokens are `ownship`, `target`,
`target_danger`, `track`, `layline_port`, `layline_stbd` and `warning`.
Lookout resolves each one for the day, dusk and night schemes.

**The symbols are** `ownship`, `target`, `aton` and `aton_virtual`. For a
shape of your own, a dial or a ring or a rose, draw it with
[a canvas](canvas.md).

**`.anchor = .ownship`** rides own ship's display position, which Lookout
carries forward between fixes, so the object stays still on screen instead of
stepping once a second. Own ship's heading line uses it.

**A pick payload** is
`.{ .title = …, .rows = &.{ .{ "MMSI", "899000101" } } }`, and only a symbol
carries one: a line and an area have no single point to measure a tap
against. The values are strings the plugin has already formatted, because
only the plugin knows the unit.

## Working with positions

Every point you hand to `c.line`, `c.symbol` and `c.area` is an `lk.Point`,
latitude first. The overlay's wire format puts longitude first, and this type
is what keeps that out of your code. It carries helper methods for the
geometry a chart plugin needs, and the SDK adds a few unit helpers beside it:

| Helper | Answers |
|---|---|
| `p.destination(bearing_deg, dist_m)` | where you get to, over a sphere |
| `p.bearingTo(other)` | the initial great-circle bearing, degrees true |
| `p.distanceTo(other)` | metres |
| `p.valid()` | false for a position off the earth or carrying a NaN |
| `lk.nm(n)` | metres from nautical miles |
| `lk.knots(mps)` | knots from metres per second |
| `lk.normalizeDeg(d)`, `lk.wrapLon(d)` | a bearing folded into 0–360, a longitude into ±180 |

## The limits

The limits have names, so a plugin can size its own buffers against them. A
scene holds `lk.max_objects` (512) objects and serializes into
`lk.scene_bytes` (64 KiB). An object id is at most `lk.max_object_id`
(48) bytes. An overflow drops the whole batch and logs it, and the next call
rebuilds the scene from nothing.

## Posting the status line

```zig
c.status("TWD {d:.0} deg", .{twd});          // working, and what it is doing
c.degraded("the chart is out of date", .{}); // short of something, and which
```

Lookout logs every status text it has not seen before, and nothing is sent
while the text is unchanged. Round anything live before you print it, or the
text changes every tick and every tick becomes a log line.

Say nothing in `draw` and the plugin reads `running`. A missing input already
produces the degraded line, so `c.degraded` is for what Lookout cannot see.
Outside `draw`, `lk.say(.running, fmt, args)` posts the same line; the states
are `starting`, `running`, `degraded` and `stopped`. The text is cut at 160
bytes.

The status line belongs to your `draw` function while the chart grant is on:
the text comes off the chart your plugin was handed, and Lookout posts it after
each frame. With the grant off there is no frame, so Lookout posts one line
naming the reason and then writes nothing more. Say what you like from the
update hook after that.
