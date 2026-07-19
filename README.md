# lookout-core

A native library + demo that opens a baked **tile57** nautical chart and renders
it interactively on **SDL3 `SDL_GPU`** (Vulkan/Metal/D3D12), consuming tile57's
**Surface interface** — the world-space, semantically-tagged draw-call stream.
It follows the interface's contract: **tessellate the scene once, then transform
it per frame** with a camera matrix. Day/night palette and mariner display gates
switch without re-tessellating.

This is a prototype/proof-of-concept — not for navigation, not S-52 pixel-perfect.

![Annapolis Harbor, day scheme](docs/day.png)

## What it is

- **`liblookout.a`** — the core, a static library with a small C ABI
  (`include/lookout.h`) meant to be embedded as a chart widget in an existing
  app. It opens a chart (or composes a whole library), owns all the
  SDL/GPU/tessellation internally, and renders into **your app's native window**
  (NSWindow / NSView / HWND / X11) or into a pixel buffer you upload yourself.
- **`lookout`** — a demo executable driving the library (window or headless PNG).

Written in **Zig** (0.16). **The host never sees or links SDL** — SDL is an
internal implementation detail (window transport + `SDL_GPU`). All vector work
(polygon tessellation, line stroking, glyph/symbol tessellation, paint ordering,
per-frame gating, camera, level-of-detail) is ours — see `NOTES.md`.

## Embedding in your app

You write your shell in whatever you like — Swift/Cocoa on macOS, Win32, GTK on
Linux — create a native window, and hand its handle to lookout:

```c
#include "lookout.h"
lookout *lk = lookout_open_in_window(LOOKOUT_NATIVE_COCOA_WINDOW, nsWindow,
                                     "chart.pmtiles", 1280, 960, /*msaa*/1);
// your own run loop:
lookout_render(lk);                       // draws + presents into your window
lookout_pan(lk, dx, dy);                  // feed your input events
lookout_zoom_at(lk, dz, mx, my);
lookout_resize(lk, w, h);                 // on native resize
// tap-to-identify, place a boat marker, etc.:
double lon, lat; lookout_screen_to_geo(lk, mx, my, &lon, &lat);
float x, y;      lookout_geo_to_screen(lk, boat_lon, boat_lat, &x, &y);
lookout_close(lk);
```

Prefer pixels (Qt canvas, an existing GL/Metal texture, a server)? Skip the
window handle and pull frames: `lookout_snapshot_rgba(lk, dst, w*h*4)`.

Full S-52 control is `lookout_get_mariner` / `lookout_set_mariner` (the whole
`tile57_mariner`): visibility toggles (scheme, categories, text, soundings, size)
apply live; portrayal/geometry changes (contours, units, dates, groups) rebuild
in the background. Tessellation runs on a worker thread, so opening a large
library never freezes the window, and zooming across bands re-tessellates for
fresh level-of-detail without blocking.

## Architecture in one paragraph

The whole chart is one vertex format and **one flat-color pipeline**. Geometry is
uploaded once in web-mercator `[0,1]` space (camera-relative f32). Each vertex
carries a world position, a reference-px `local` offset the shader adds in screen
space (line half-width, glyph/symbol px — so marks hold constant screen size), a
SCAMIN denominator, and packed flags (display category / kind / rotation-align).
The vertex shader (`shaders/chart.vert`) applies the per-frame MVP and **culls
live from uniforms** (SCAMIN vs current scale, category mask, text/soundings
toggles). Colors are resolved by the engine per palette; we capture one color
buffer per scheme at build, so **day↔night is a buffer swap, never a rebuild**.

## Build

Requirements found/used on this machine:

- **Zig 0.16**
- **SDL3 3.4.2** with `SDL_gpu.h` (`libsdl3-dev`)
- **glslangValidator** (`glslang-tools`) — only for `zig build shaders`; precompiled
  SPIR-V is committed under `shaders/*.spv`, so a normal build needs no shader tool
- **libtile57.a** — the tile57 engine, prebuilt. Points at
  `/home/claude/Projects/tile57-main` by default; override with `-Dtile57=<dir>`
  (expects `<dir>/include/tile57.h` and `<dir>/zig-out/lib/libtile57.a`)
- **libtess2** — vendored under `vendor/libtess2/`, no external dep

```sh
zig build                 # builds liblookout.a + the lookout demo into zig-out/
zig build -Dtile57=/path/to/tile57   # point at a different tile57 checkout
zig build test            # unit tests
zig build shaders         # recompile GLSL -> SPIR-V (needs glslangValidator)
```

## Run

Headless (default): renders the whole cell to PNGs and exits.

```sh
./zig-out/bin/lookout [chart.pmtiles] [--lon L --lat L --zoom Z] [--png OUT]
```

Writes `lookout.png` (day), `lookout-night.png` (palette swap only, **no
re-tessellation**), and `lookout-zoom.png` (zoomed via the MVP only, **no
re-tessellation**).

The chart argument is a **baked tile57 PMTiles archive** (what `tile57 bake` /
`tile57_bake_chart_bytes` produce from an S-57 `.000` — not the raw `.000`). Pass
your own as the first argument; there is a built-in default path used only as a
fallback if it exists on the machine. `-h` prints full usage.

Pass a **directory** of baked archives instead of a file to compose a whole
library / ENC_ROOT cache:

```sh
./zig-out/bin/lookout /path/to/charts/   # composes every *.pmtiles within
```

Each cell is `tile57_chart_open`'d (mmap'd — the set is never fully resident) and
stitched through tile57's ownership partition (`tile57_compose_open` /
`tile57_compose_surface`). The widget doesn't bake or manage the library: bake a
raw ENC_ROOT with tile57's `bake_tree` first, then point lookout at the cache.

Windowed (needs a display; on a headless box use `xvfb-run`):

```sh
./zig-out/bin/lookout --window
xvfb-run -a ./zig-out/bin/lookout --window --frames 3   # automated smoke test
```

### Controls (windowed)

| Input | Action |
|---|---|
| drag | pan |
| wheel | cursor-anchored zoom |
| `n` | cycle day / dusk / night palette (uniform only) |
| `t` | toggle text |
| `s` | toggle soundings |
| `d` | toggle the OTHER display category |
| `[` / `]` | nudge safety contour (this one **rebuilds** — it changes geometry) |
| `-` / `=` | shrink / grow symbol & text size (uniform only) |
| `Esc` | quit |

## Status vs the milestones

All of M0–M5 are functional against the Annapolis cell:

- **M0** bind + window/offscreen + `NOTES.md` with the real signatures.
- **M1** area fills (libtess2, holes + even-odd).
- **M2** camera: pan + cursor-anchored zoom via MVP; screen↔world; no re-tessellation.
- **M3** stroked lines (constant screen width) + tessellated point symbols.
- **M4** text + soundings as glyph outline rings; engine declutter respected;
  S-52 paint order (class-major, then `plane`, then emission seq).
- **M5** day/night + category/text/soundings gates as uniform-only updates; MSAA.

## MSAA status

**4× MSAA works** on this target (SDL_GPU Vulkan + Mesa **lavapipe** software
device on aarch64 Linux). The pipeline probes `SDL_GPUTextureSupportsSampleCount`
and falls back to 1× if unavailable; the demo prints which it used. Offscreen and
windowed paths both resolve the multisample target.

## Tested on

Linux aarch64, SDL3 **Vulkan** backend via Mesa **lavapipe** (software rasterizer).
Headless offscreen render and (under Xvfb) a real X11 window both verified.

## Known limitations (prototype)

- Line joins are a simple per-segment miter; no true round/bevel joins or caps.
  Dashes are recorded but drawn solid.
- Constant-width lines use an isotropic-scale approximation for the screen-space
  normal (fine north-up at chart aspect ratios; see `NOTES.md §4`).
- Text halos are dropped (fill only). No SDF/atlas path yet — symbols/text use the
  tessellated outline-ring fallback (`draw_sprite`/`draw_text_str` left NULL).
- Pattern fills render as the flat translucent tint the engine emits when
  `draw_pattern` is NULL; no pattern atlas.
- SCAMIN→display-scale mapping is approximate (not matched to the engine's exact
  cutoff). Rotation is wired (`align` flags honored) but exercised only at north-up.
- Large zoom-*in* past the build band does not fetch finer LoD until a rebuild.
- Multi-chart compose (`tile57_compose_surface`) is not wired (single chart only).

## Layout

```
build.zig            build: liblookout.a + lookout, shader step, tests
include/lookout.h    C ABI
shaders/chart.{vert,frag}[.spv]   one flat-color pipeline (+ committed SPIR-V)
src/c.zig            @cImport: SDL3 + tile57 + libtess2
src/camera.zig       web-mercator [0,1] camera math (MVP, screen<->world, SCAMIN scale)
src/scene.zig        Surface recorder + tessellation (build phase)
src/gpu.zig          SDL_GPU device / pipeline / buffers / render / readback
src/root.zig         Lookout: the public Zig API
src/capi.zig         C ABI wrapper
src/main.zig         demo
vendor/libtess2/     vendored tessellator
NOTES.md             recorded tile57 API + deviations from the spec (read this)
```
