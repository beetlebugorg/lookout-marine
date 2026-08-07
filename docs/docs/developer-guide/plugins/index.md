---
id: index
title: Plugins
sidebar_position: 1
---

# Plugins

A plugin is one WebAssembly module and one manifest. The module speaks a small C
ABI. The manifest says who it is and what it is allowed to do. Nothing else is a
plugin: there is no script, no shared library, and no code that runs in the app's
own address space.

A plugin does one of two jobs, or both. It **publishes** — a NMEA gateway on the
boat's network becomes vessel values and AIS targets in the core's stores. It
**draws** — it posts retained overlay objects in longitude and latitude, and the
core turns them into triangles and renders them with the chart. The plugin never
touches a socket, a file, a pipeline or a frame. It asks the host, and the host
does it.

```
        the boat's network              the mariner's settings
                │                                │
                ▼                                ▼
   ┌───────────────────────────────────────────────────────┐
   │  a plugin:  <id>.wasm  +  <id>.manifest.json          │
   │  wasm32-freestanding · no WASI · single-threaded      │
   └──────────────┬────────────────────────────────────────┘
                  │  five exports out, fifteen imports in,
                  │  every import checked against the manifest
                  ▼
   ┌───────────────────────────────────────────────────────┐
   │  host   registry, lifecycle, one thread per plugin    │  src/plugin/host.zig
   │  broker grants, sockets, timers, subscriber fanout    │  src/plugin/broker.zig
   │  stores vessel paths · AIS targets · overlay objects  │  src/plugin/, src/overlay.zig
   └──────────────┬────────────────────────────────────────┘
                  ▼
          the core renders the frame                          include/lookout.h
                  │
                  ▼
          the shell draws its own chrome                      macos/ linux/ windows/ android/
```

**The mariner never sees the machinery.** A plugin's settings appear in the
settings window as chart settings, in the topic they belong to — the collision
alarm sits under Alarms beside every other alarm. No pane names a plugin, and the
word "plugin" does not appear in the app. This is deliberate: a person at the
helm is configuring the boat, not administering software.

## What exists today

The prototype is on the `feat/plugins-prototype` branch. Four first-party plugins
run: `nmea0183` publishes, `ownship`, `ais` and `laylines` draw.

| Platform | Plugin host | Overlay rendering |
|---|---|---|
| macOS | Runs. The reference. | Metal, seen on screen |
| iOS, iPadOS | Runs on the simulator | Metal, seen on screen |
| Linux | Compiles and links; no socket has carried a byte | Vulkan, run offscreen through MoltenVK, never on a Linux driver |
| Windows | Compiles and links; never run | Direct3D 12, compiled, never rendered |
| Android | No WAMR archive and no shell call yet | The Vulkan pass is in the APK; the plugin host is not |

The runtime is [WAMR]'s fast interpreter, built by `scripts/build-wamr.sh`. There
is no JIT and no AOT, which is what makes iOS possible: the host asks for no
executable pages. On macOS and iOS the host turns on when the archive is present;
elsewhere it needs `-Dplugins=true`.

Built and usable:

- The five exports, the fifteen `lookout` imports, and the seven capabilities.
- The vessel store (election between sources, one 5 s staleness window) and the
  AIS store (MMSI-keyed, aged).
- The retained overlay: symbols, polylines, polygons, palette tokens, pick
  payloads, and an own-ship anchor the core substitutes per frame.
- Settings: a manifest schema of number and toggle fields, grouped into the
  shell's own settings tabs, applied hot through `CONFIG_CHANGED`.
- One dispatch thread per plugin, a 1 s watchdog, per-plugin event queues with
  backpressure, and a fault path that erases everything a dead plugin drew.
- `lookout-plugin-dev`, the replay harness.

Planned, and **not built** — do not write against any of it:

| Not built | Where it is described |
|---|---|
| UDP, HTTP, storage, file access, weather grids | `specs/plugins/implementation.md` |
| WASI (so Go and Rust standard libraries boot), and the Go and Rust SDKs | `specs/plugins/implementation.md` |
| `.lkplug` packaging, install, and the consent flow for grants | `specs/plugins/implementation.md`, `capabilities.md` |
| Chrome beyond one status string per plugin — jobs, tables, an alarm surface | `specs/plugins/chrome.md` |
| Restarting a plugin that trapped. It stays down until the app restarts. | `specs/plugins/PROTOTYPE-CONCERNS.md` |
| Per-plugin memory, time and queue budgets in the manifest | `specs/plugins/PROTOTYPE-CONCERNS.md` |
| AOT compilation of bundled plugins on iOS | `specs/plugins/ios.md` |
| Imports filtered at instantiation, so an ungranted call cannot be made at all | `specs/plugins/PROTOTYPE-CONCERNS.md` |

That last one matters when you read [the rules](rules.md). Today a plugin can
call anything and the broker answers an ungranted call with `-1` and a log line.
The intended model refuses the module at load. Write your plugin so both are the
same thing: ask for what you use, and use only what you ask for.

## The ABI is v0 and unstable

`lk_abi` returns 1, and the host refuses a module that reports anything else. That
number is a handshake, not a promise. **Expect the ABI to change** — event kinds,
JSON shapes, capability names, the manifest schema, all of it — until it is
declared public. There is no deprecation period and no compatibility shim.

The policy is **first-party first**. The four plugins in `plugins/` are built with
the core, in the same tree, and they move with it. The ABI is shaped by what they
need, and it is changed whenever they need something different. If you build
against it now, pin the commit and expect to fix your plugin when you move.

## Where to go next

| Page | What it is |
|---|---|
| [Build your first plugin](build-your-first.md) | The whole walkthrough in Zig: a directory, a manifest, a module, the harness, the app |
| [The ABI](abi.md) | The reference: exports, imports, event kinds, JSON shapes, the manifest |
| [The rules](rules.md) | The contract that bites, and why each rule exists |
| [The dev harness](dev-harness.md) | `lookout-plugin-dev`, the replay log, and golden tests |

## Files

```
plugins/common/lk.zig      the plugin-side library: externs, arena, JSON helpers
plugins/nmea0183/          TCP client, NMEA 0183 and AIVDM, publishes
plugins/ownship/           the boat: symbol, heading line, COG vector, track
plugins/ais/               targets, CPA/TCPA, the collision alarm, AtoNs
plugins/laylines/          two close-hauled lines from the true wind
plugins/echo/              the host tests' fixture; not installed
src/plugin/host.zig        registry, manifests, lifecycle, dispatch, watchdog
src/plugin/broker.zig      the imports, the grants, sockets, timers, fanout
src/plugin/wasm.zig        the WAMR embedding
src/plugin/store.zig       the vessel store: election and staleness
src/plugin/aisstore.zig    the AIS store: MMSI-keyed, aged
src/overlay.zig            retained overlay objects, tokens, geometry, hit tests
src/plugin_dev_main.zig    lookout-plugin-dev
tools/nmea_gen.zig         the synthetic Annapolis replay log
specs/plugins/             the design notes behind all of it
```

[WAMR]: https://github.com/bytecodealliance/wasm-micro-runtime
