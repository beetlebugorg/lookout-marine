---
id: canvas
title: Drawing with a canvas
---

# Drawing with a canvas

**Capabilities:** `overlay.draw`.

A canvas is an overlay object you draw yourself: paths, curves, arcs, fills,
strokes, gradients, text, any color. Use one when the chart objects on
[Drawing on the chart](drawing.md) are not enough, which is how you build a
custom instrument: a dial, a gauge, a scale, a rose.

You record commands into the canvas inside your `draw` function, and Lookout
renders the recording. A canvas is one object in your scene with an id like
any other: redraw it and only the difference crosses to the chart, leave it
out of a call and it comes off the chart.

```zig
pub fn draw(c: *lk.Chart) void {
    const at = inputs.boat.get();
    var cv = c.canvas("ring", .{ .at = at, .anchor = .ownship, .space = .geo });

    cv.strokeStyle(.{ .token = .warning });
    cv.lineWidth(1.5);
    cv.beginPath();
    cv.arc(0, 0, lk.nm(1), 0, 360, false);
    cv.stroke();

    cv.done();
}
```

That is a one-mile guard ring riding own ship. `done()` seals the recording;
a canvas you never seal is not posted.

## The two spaces

Every canvas is anchored at a position (`at`, and `.anchor = .ownship` rides
own ship's display position like any anchored object). The `space` says what
your coordinates mean from there:

| Space | Units | Holds its |
|---|---|---|
| `.points` | screen points, x east, y down | size on screen, at every zoom |
| `.geo` | metres east and north of the anchor | size on the ground, at every zoom |

An instrument is `.points`: a dial that stays 64 points wide however far the
mariner zooms out. A range ring or a sector is `.geo`: `arc(0, 0, 1852, …)`
is one nautical mile on the water at any zoom. Stroke widths and text sizes
are screen points in both spaces.

## The commands

The recorder is the canvas model you already know:

| Group | Calls |
|---|---|
| Paths | `beginPath`, `moveTo`, `lineTo`, `quadTo`, `bezierTo`, `arc(cx, cy, r, from_deg, to_deg, ccw)`, `closePath` |
| Painting | `fill()`, `stroke()`, `clip()` |
| Style | `fillStyle`, `strokeStyle`, `lineWidth`, `lineCap`, `lineJoin` |
| Text | `font(size_pt, .regular/.bold)`, `textAlign`, `fillText(text, x, y)` |
| Transform | `translate`, `rotate(deg)`, `scale`, `save`, `restore` |

A style is a token, a free color, or a gradient:

```zig
cv.fillStyle(.{ .token = .ownship });                       // the palette, per scheme
cv.fillStyle(.{ .rgba = .{ 0.97, 0.98, 1.0, 0.72 } });      // your own color
cv.fillStyle(.{ .radial = .{ .center = .{ 0, 0 }, .radius = 64, .stops = &.{
    .{ .t = 0, .color = .{ .rgba = .{ 1, 1, 1, 0.7 } } },
    .{ .t = 1, .color = .{ .token = .warning } },
} } });                                                     // radial or .linear
```

**Night is your job.** A free RGBA color does not dim itself for the night
palette. Use tokens where you can, because Lookout re-resolves them per
scheme; where you use your own colors, choose ones that survive a dark
wheelhouse.

## A worked instrument

The shipped `plugins/canvasdemo/` draws a wind dial at own ship: a
radial-gradient face, ticks every 10 and 30 degrees, bold cardinal letters,
and a needle on the recorded rotation. The needle is the part worth copying:

```zig
cv.save();
cv.rotate(twd);
cv.beginPath();
cv.moveTo(0, -(R - 8));
cv.lineTo(5.5, 16);
cv.lineTo(-5.5, 16);
cv.closePath();
cv.fill();
cv.restore();
```

Draw the shape pointing north in its own frame, `rotate` to the live
bearing, and `restore` so the rotation ends with the needle. The whole dial
re-records every `draw` call, and Lookout sends only what changed: with a
steady wind, nothing.

## The limits

A canvas holds 2048 commands; the SDK drops the rest with one log line. A
text run is cut at 256 bytes, a gradient at 8 stops.

The recording counts against your scene's 64 KiB like every other object. A
canvas is not hit-testable: a pick payload needs a symbol.

Text on the chart reads from about 10 pt regular or 9 pt bold at 1x. Below
that the stems fall under a pixel and the glyphs read as ghosts, worst over
a busy chart.
