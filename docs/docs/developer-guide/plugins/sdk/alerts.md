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

You never request a capability to log or to read the clocks. Anything that must outlive an
event is a global: a plugin is single-threaded by contract, and
`lk.scratch()` is gone as soon as you return.

Severity is `alarm`, `warning`, `notice` or `caution`. Raise one when the
mariner must act now and would not otherwise know; everything else is a
status line. An alarm that fires when nothing is wrong gets switched off, and
then the real one is not heard.
