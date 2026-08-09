---
id: publishing
title: Publishing data
---

# Publishing data

**Capabilities:** `vessel.publish`, and `ais.publish` for targets.

A plugin that reads an instrument publishes what it hears, and every plugin
can then read it as an input. The position `nmea0183` publishes is the
position `ownship` draws.

```zig
var p = lk.Publish.begin();
p.number("navigation.speedOverGround", mps);
p.position("navigation.position", .{ .lat = lat, .lon = lon });
p.clear("environment.wind.speedTrue");   // held by this source, no value right now
_ = p.send();

var u = lk.Upsert.begin();
u.target(.{ .mmsi = 899000101, .at = at, .sog_mps = mps, .cog_deg = cog });
_ = u.send();
```

Both batches are stamped with Lookout's wall clock, which is what the store
ages against. `send` answers the number of values Lookout took, or -1 when
the manifest did not ask for the capability; an empty batch is not sent and
answers 0.

`clear` is for an instrument that reports having no value, which is
different from one that went quiet. A depth sounder that loses the bottom
says so: if your plugin simply stops publishing, the last depth stays on the
chart until it ages out, five seconds of a number you know is wrong. `clear`
drops it at once, and when another source holds the path, the store elects
that one. It withdraws only your own value; no source can hold a path
against another. The Signal K plugin does this when a server sends an
explicit null.

Everything crossing the boundary is SI: metres and metres per second,
whatever the wire format reported. Bearings are degrees true. Convert for
display only, in the text a mariner reads.

Everything one plugin publishes lands in one source, whatever connection it
came off. Two sources carrying the same path are arbitrated by the store's
election: the chart uses one of them and falls back to the other when the
first goes quiet for five seconds.

## The limits

A `Publish` batch serializes into 4096 bytes and an `Upsert` batch into
8192. An overflow drops the whole batch and logs it. A target's name is cut
at 32 bytes.
