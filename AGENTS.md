# Lookout Marine: the map

A cross-platform S-57/S-101 chartplotter. A Zig core renders and holds state;
each platform has a native shell; wasm plugins bring the boat's data in and
draw on the chart.

Read this before exploring. It exists so you do not have to read 16,000 lines
to find out where something lives.

## Where things are

| Path | What it is |
|---|---|
| `src/` | the core: rendering, camera, raster underlay, the C API |
| `src/plugin/` | the plugin host: WAMR, the broker, the stores, sockets |
| `plugins/common/` | the plugin SDK the plugins import |
| `plugins/<name>/` | the shipped plugins: nmea0183, signalk, ownship, ais, laylines |
| `apple/LookoutMarine/` | the macOS and iOS shell, SwiftUI. THE REFERENCE SHELL |
| `android/`, `linux/`, `windows/` | the other shells |
| `include/lookout.h` | the C API every shell calls. Read this first for anything cross-shell |
| `specs/plugins/` | design contracts, gitignored. Read the one for your feature BEFORE coding |
| `docs/docs/` | the published site. See docs/STYLE.md, its rules are enforced |
| `test/` | host-level tests that need WAMR |

## The big files, by section

Do not read these end to end. Grep for the section you need.

- `src/plugin/broker.zig` (2.3k) plus `src/plugin/broker/` (eleven parts):
  every host call a plugin can make, the capability checks, the
  overlay/store/table/chrome sinks, budgets. `broker.zig` holds the Broker
  struct and dispatch; the parts hold caps, budgets, tables, the queue,
  sockets, http, ws, storage, the registry JSON and the natives table. Each
  part carries its own tests. `broker.zig` has a comptime block referencing
  every part: without it a part's tests go dead, because a re-export alone
  does not pull them into a test build.
- `src/plugin/host.zig` (4k): the manifest parser, plugin load and unload,
  install and uninstall, grants, the registry JSON the shells read, restart
  with backoff.
- `src/overlay.zig` (3k): the retained overlay scene, the canvas command VM,
  tessellation, the dash and stroke geometry.
- `plugins/common/lk2.zig` (2.7k): the SDK. `lk.plugin(@This())` wires a
  module by looking up EXACT declaration names: inputs, draw, draw_rate_ms,
  Settings, Connections, onData, onEvent, onStart, onShutdown.
- `src/root.zig`: the core's public Zig surface, and the test collector.

## Invariants you must not break

- **Units are SI on every boundary.** Metres, metres per second, degrees
  true. Convert only in text a mariner reads.
- **Colours are palette tokens, never RGB**, except inside a plugin canvas
  where the author owns night. The core resolves tokens per scheme.
- **Idle means idle.** A boat runs off a battery, so anything that wakes on a
  clock must stop when there is nothing left to change: no repaint without a
  reason to repaint, no timer that keeps ticking after it has said everything
  it has to say, no poll that could be an event. A plugin's update heartbeat
  stops once every input it declared has gone stale and it has been told once.
  Work that costs nothing when idle is a feature, not an optimisation.

## The gates

Every change runs these. Never trust a pipe's exit code; check the command's.

```sh
zig build && zig build plugins && zig build test
./zig-out/bin/lookout-plugin-dev --chart ~/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles \
  --plugins zig-out/plugins --replay test/annapolis.nmea --rate 20 --until 410 \
  --view -76.4767,38.9763,15
```

The day-run bar passes when there is **exactly one CPA alarm** (MMSI
899000101), every plugin reads `live, 0 denied call(s)`, and it exits 0.

`zig build` alone does NOT rebuild plugin wasm. Run `zig build plugins`. A
stale wasm has sent this project chasing a phantom bug more than once.

macOS: `xcodebuild -project apple/LookoutMarine.xcodeproj -scheme LookoutMarine
-configuration Debug -derivedDataPath apple/build-mac`.

## Traps that have cost real time

- **The app runs at 2x, the harness at 1x.** A bug can live in the gap.
- **A test build collects a file's tests only if it ANALYSES the file.** A
  re-export is not enough. Every test-bearing `.zig` must therefore be named in
  build.zig, on `pure_test_roots` or `reached_test_files`; the `test` step
  fails for one that is not. Being listed is a claim, not a proof: prove a new
  entry by making one of its tests fail and checking the suite names it.
- **Check disk before a big build**: `df -h /System/Volumes/Data`. The caches
  here fill 100 GB fast.
- **"Behind main" on this branch may be ancestry, not content.** `feat/plugins`
  was rebuilt at some point, so main's work is here under different SHAs and
  the commit count lies. Before merging anything, ask what is actually missing:
  `git cherry HEAD origin/main` compares by patch and prints `+` only for a
  commit whose content you really lack. In August every one of main's 104
  non-merge commits came back `-`, and a merge would have re-applied all of
  them as 159 conflicts.
- **`grep` in this shell is a gitignore-aware wrapper**, not `/usr/bin/grep`. A
  recursive sweep from the repo root silently skips ignored paths and reports
  clean when the string is still on disk. Verify with `git grep -n --untracked`
  for what ships, and `command grep -rn <dir>` for one ignored directory.
  `command grep -rn .` from the root walks `.zig-cache` and takes minutes.
## House style

Comments and commit messages: plain technical English, short sentences, no
narration, no em dashes, no provenance ("moved from…"), no AI attribution
trailers. A commit message is a subject line with no body. Docs follow
`docs/STYLE.md`, which is enforced by review.
