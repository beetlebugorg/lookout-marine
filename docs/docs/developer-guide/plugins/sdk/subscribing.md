---
id: subscribing
title: Subscribing to data
---

# Subscribing to data

**Capabilities:** `vessel.read`, and `ais.read` for the AIS targets.

Your plugin subscribes by declaring inputs. When your plugin starts, Lookout
reads your `inputs` declaration and delivers each path's values from then
on.

```zig
pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
    pub const depth = lk.subscribeNumber("environment.depth.belowTransducer", .{
        .max_age_ms = 10_000,
        .optional = true,
    });
    pub const traffic = lk.subscribeAis(.{});
};
```

| Declaration | What it holds |
|---|---|
| `lk.subscribeNumber(path, opts)` | an `f64` off the vessel store |
| `lk.subscribePosition(path, opts)` | an `lk.Point` off the vessel store |
| `lk.subscribeAis(.{ .max = 128 })` | the AIS target set |

Every value carries its age: the time since it arrived, measured on the
monotonic clock. A reading is **fresh** while its age is under the input's
`max_age_ms`, 5 seconds unless the declaration says otherwise. Past that it
is **stale**.

`opts` is an `lk.InputOpts`:

| Field | Default | What it does |
|---|---|---|
| `label` | the last segment of the path | what the status line calls this reading when it is missing |
| `max_age_ms` | `5_000` | how old the value may be and still count as fresh |
| `optional` | `false` | takes the input out of the freshness gate and out of the status line |

The paths are the vessel store's own: `navigation.position`,
`navigation.speedOverGround`, `environment.wind.directionTrue`,
`environment.depth.belowTransducer` and the rest.
[Capabilities and store data](glossary.md) lists every path the shipped
plugins fill, by plugin.

## Reading an input

Which call you use follows from the declaration. A required input is read
with `get()`. Lookout does not call your `draw` function until every required
input is fresh, so inside it the value is always current. An optional input is read with
`fresh()`, which returns null when the value is missing or older than its
window. Either kind answers `ageMs()` with the value's age, or null when
nothing has arrived yet.

An optional input has no `get`, and calling it is a compile error. The error
names both ways out: read it with `fresh()` and handle the null, or drop
`.optional = true` and let Lookout wait for the value before it calls your
`draw` function.

Lookout calls your `onData` function when bytes arrive, not on the draw
timer, so the freshness gate has not run there. Read inputs with `fresh()`
inside `onData`.

## When a reading goes stale

A reading goes stale when its age passes `max_age_ms`. When a required
reading goes stale, Lookout clears everything your plugin drew, skips the
call to your `draw` function, and posts one degraded line naming every
missing input at once: `no wind, no
position`. Naming all of them matters: a line that says only "no wind" while
the GPS is also out sends the mariner to the wrong instrument. The word in
that list is the input's `label`.

An empty AIS set never stops Lookout calling your `draw` function. No
targets in range is a normal condition, not a missing instrument.

## Reading AIS targets

Declaring `lk.subscribeAis(.{})` subscribes the plugin to the AIS target set: one
entry for every vessel and aid to navigation Lookout has heard. Inside
`draw`, `inputs.traffic.targets()` returns the whole set and
`inputs.traffic.find(mmsi)` returns one target or null.

Each target carries the fields below. A field the vessel has not broadcast is
null: never heard and heard as zero are different readings.

| Field | Type | Note |
|---|---|---|
| `mmsi` | `u32` | |
| `at` | `?lk.Point` | |
| `sog_mps` | `?f64` | metres per second |
| `cog_deg`, `heading_deg` | `?f64` | degrees true |
| `aton`, `virtual_aton` | `bool` | an aid to navigation, and one that exists only as a broadcast |
| `aton_type` | `?u8` | |
| `off_position` | `?bool` | |
| `age_ms` | `i64` | |
| `name()` | `[]const u8` | cut at 32 bytes |

A target that stops being heard drops out of the set. Draw from the set each
call and Lookout takes the symbol off the chart for you.
