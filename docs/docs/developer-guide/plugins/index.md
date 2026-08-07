---
id: index
title: Plugins
sidebar_position: 1
---

# Plugins

A plugin is a WebAssembly module and a small JSON manifest. You write the module
and compile it to `wasm32-freestanding`. The manifest says who the plugin is and
what it is allowed to do. Lookout loads the pair, runs the module in a sandbox,
and lends it a fixed set of calls into the app.

You write one to get something off your boat and onto the chart. In practice that
means Zig today, or any toolchain that can emit a freestanding wasm module —
there is no WASI yet, so the Go and Rust standard libraries will not boot.

The shortest path in is [Build your first plugin](build-your-first.md): a
manifest, one Zig file, and a dashed line drawn on a real chart.

## What you can build

There are two jobs. Most plugins do one of them; some do both.

**Publish.** Turn a data source into values the whole app can use. Your plugin
opens a TCP connection to the multiplexer on the boat's network, parses what
comes back, and writes readings into the **vessel store** — Lookout's single
table of current boat data, keyed by path: `navigation.position`,
`environment.depth.belowTransducer`, and so on. It can write AIS contacts into
the **AIS store** the same way, keyed by MMSI. Position, heading, course and
speed in the vessel store are what put the boat on the chart and drive follow
mode and course-up, so a publishing plugin is how Lookout learns where you are.

**Draw.** Put your own geometry on the chart. Your plugin posts objects —
symbols, lines and filled areas, in longitude and latitude — to the **overlay**,
a retained layer the core draws along with the chart. Retained means you post an
object once and it stays until you replace it or delete it. Laylines, a guard
ring, a route, an anchor-watch circle, a tide arrow, the track you have sailed.

What a plugin does not do is touch the machine. Inside the module there is no
socket, no file, no thread and no frame. You ask the host, Lookout's plugin
runtime. If your manifest asked for the permission, the host does it.

```
        the boat's network              the mariner's settings
                │                                │
                ▼                                ▼
   ┌───────────────────────────────────────────────────────┐
   │  your plugin:  <id>.wasm  +  <id>.manifest.json       │
   │  wasm32-freestanding · no WASI · single-threaded      │
   └──────────────┬────────────────────────────────────────┘
                  │  five exports out, fifteen imports in,
                  │  every import checked against your manifest
                  ▼
   ┌───────────────────────────────────────────────────────┐
   │  the host   sockets, timers, events, one thread for   │
   │             your plugin and nobody else's             │
   │             the vessel store · the AIS store          │
   │             the overlay                               │
   └──────────────┬────────────────────────────────────────┘
                  ▼
          the core renders the frame
```

## Where your plugin shows up

Your manifest can declare settings — numbers and toggles. They appear in the
app's settings window as ordinary chart settings, filed under the topic they
belong to: a collision-alarm limit sits under Alarms beside every other alarm.
No pane names your plugin, and the word "plugin" does not appear anywhere in the
app.

Write your labels to match. The person reading them is at the helm configuring a
boat, not administering software.

## What runs today

The plugin layer is a prototype. Four plugins ship with it and are the worked examples: `nmea0183` publishes, and
`ownship`, `ais` and `laylines` draw.

Where you can run a plugin:

| Platform | Plugin host | Overlay rendering |
|---|---|---|
| macOS | Runs. The reference. | Metal, seen on screen |
| iOS, iPadOS | Runs on the simulator | Metal, seen on screen |
| Linux | Compiles and links; no socket has carried a byte | Vulkan, run offscreen through MoltenVK, never on a Linux driver |
| Windows | Compiles and links; never run | Direct3D 12, compiled, never rendered |
| Android | No WAMR archive, and the app does not start the host yet | The Vulkan pass is in the APK; the plugin host is not |

Develop on macOS. It is the only platform where the whole loop has been run.

Your module is executed by [WAMR]'s fast interpreter, built by
`scripts/build-wamr.sh`. There is no JIT and no AOT compilation, which is what
makes iOS possible: the host never asks the operating system for executable
pages. It also means your code runs well short of native speed, so keep event
handlers small. On macOS and iOS the host turns on whenever the WAMR archive is
present; elsewhere it needs `-Dplugins=true`.

Built and usable today:

- The five exports, the fifteen `lookout` imports, and the seven capabilities.
- The vessel store, with an election between competing sources and one 5 s
  staleness window, and the AIS store, MMSI-keyed and aged.
- The retained overlay: symbols, polylines, polygons, colour tokens, pick
  payloads for hover and tap, and an own-ship anchor the core moves for you every
  frame.
- Settings: number, toggle and text fields declared in your manifest, grouped
  into the app's own settings tabs, applied hot without a restart.
- Lists: a group the mariner adds rows to, delivered as a JSON array with a
  stable id per row. The `nmea0183` plugin uses one to hold several TCP
  connections at once, each with its own socket and its own pause switch.
- Per-row status: a status may carry an `items` array, one entry per row, so an
  app can show "connected, 44 msg/s" beside one connection and "paused" beside
  another.
- One dispatch thread per plugin, a 1 s watchdog, a per-plugin event queue with
  backpressure, and a fault path that erases everything a dead plugin drew.
- `lookout-plugin-dev`, a harness that runs your plugin against a recorded log
  and renders the result to a PNG.

## The ABI is version 0 and unstable

Your module exports `lk_abi`, it returns 1, and the host refuses any module that
reports another number. That number is a handshake, not a promise.

Everything on [the ABI page](abi.md) can change: event kinds, JSON shapes,
capability names, the manifest schema. There is no deprecation period and no
compatibility shim, and the version number is not raised for every change — so a
plugin built against an older Lookout may still load and then misread what it is
handed. What that means for you:

- Pin the Lookout commit you built and tested against, and treat moving to a
  newer one as work.
- Re-run your plugin in [the dev harness](dev-harness.md) after every move. It
  prints the store, the overlay and the denied calls, which is where a silent
  ABI change shows up first.
- Expect the four plugins in `plugins/` to change with the core. They are built
  in the same tree, the ABI is shaped by what they need, and it is changed when
  they need something different. Nobody is holding it still for an out-of-tree
  plugin yet.

## Where to go next

| Page | What it is |
|---|---|
| [Build your first plugin](build-your-first.md) | The walkthrough in Zig: a directory, a manifest, a module, the harness, the app |
| [The ABI](abi.md) | The reference: exports, imports, event kinds, JSON shapes, the manifest |
| [The rules](rules.md) | The contract that bites, and the reason behind each rule |
| [The dev harness](dev-harness.md) | `lookout-plugin-dev`: the replay log, what it prints, and golden tests |

## The code worth reading

The plugins that ship with Lookout are worked examples of everything on these
pages. Read them in this order; each one adds something.

```
plugins/common/lk.zig      the plugin-side library: the externs, a scratch arena, JSON helpers
plugins/laylines/          two close-hauled lines from the true wind — the simplest one
plugins/ownship/           the boat: symbol, heading line, course vector, track
plugins/nmea0183/          TCP clients, NMEA 0183 and AIVDM parsing, publishing, a settings list
plugins/ais/               targets, CPA/TCPA, the collision alarm, aids to navigation
src/plugin/                the host: the imports, the grants, the stores, the watchdog
```

Read `src/plugin/` when this documentation and Lookout disagree with each other.
The code is the one that is right.

[WAMR]: https://github.com/bytecodealliance/wasm-micro-runtime
