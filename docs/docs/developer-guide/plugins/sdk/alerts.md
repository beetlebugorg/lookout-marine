---
id: alerts
title: Logging, clocks and alerts
---

# Logging, clocks and alerts

| Call | What it does |
|---|---|
| `lk.log(.info, fmt, args)` | one log line, cut at 512 bytes. Levels `debug`, `info`, `warn`, `err` |
| `lk.nowMs()` | wall clock, milliseconds since the epoch |
| `lk.monoMs()` | monotonic milliseconds. Measure intervals with this |
| `lk.scratch()` | an allocator reset the moment your function returns |
| `lk.alert(.alarm, title, body)` | raise an alert. Needs `alerts.raise` |
| `lk.alertKeyed(key, .alarm, title, body)` | raise an alert under a key of your own |

You never request a capability to log or to read the clocks. Anything that must outlive an
event is a global: a plugin is single-threaded by contract, and
`lk.scratch()` is gone as soon as you return.

Severity is `alarm`, `warning`, `notice` or `caution`. Raise one when the
mariner must act now and would not otherwise know; everything else is a
status line. An alarm that fires when nothing is wrong gets switched off, and
then the real one is not heard.

## Keying an alert on the thing in danger

Lookout holds one alert for each key you use. A raise under a key it already
holds updates the alert on screen instead of adding one. The mariner's
acknowledgement survives that update, so an alarm they silenced stays silent.

Give the key the identity of the thing, not the words you are about to show.
A vessel's MMSI is a key. The path of a depth sensor is a key.

```zig
var key: [24]u8 = undefined;
_ = lk.alertKeyed(
    std.fmt.bufPrint(&key, "cpa:{d}", .{target.mmsi}) catch return,
    .alarm,
    "AIS CPA alarm",
    "GALLEON is closing inside your CPA limit",
);
```

Go and Rust take the same four arguments, as `lk.AlertKeyed(key, sev, title,
body)` and `lk::alert_keyed(key, sev, title, body)`. Lookout cuts a key at 64
bytes. An empty key is no key.

## Keeping a moving figure out of the body

Without a key, Lookout can only tell your alerts apart by their title and their
body. A body carrying a figure that moves is a new alert every time it moves.
The mariner cannot silence it: the alert they answered is not the one now
sounding.

Draw the moving figure on the chart, or put it in a table. The body should name
the thing and say what is wrong with it.
