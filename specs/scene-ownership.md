# Scene ownership — move the scene into tile57

Status: IN PROGRESS — engine side landed through tile57 `b2641e2`; lookout still
has `src/scene.zig`. Spans three repos, see Branches.

## Where we are

Started as "wrecks are overwriting soundings and lights, and
`tile57_feature.plane` should be `draw_prio`". The rename was right. The ordering
bug was four defects stacked, two of them introduced during this work.

The end state: **lookout owns no scene.** tile57 emits draw-ready buffers; lookout
uploads and draws. Engine side is most of the way there. lookout cannot switch
over yet — see Next.

## Branches

| repo | branch | state |
|---|---|---|
| `tile57-main` | `feat/label-cache` | clean, tests green |
| `lookout-core` | `main` | clean, builds |
| `chartplotter` | `feat/display-priority-abi` | clean except submodule pin (deliberate) |

`tile57-main` and `chartplotter/tile57` are separate checkouts of the same repo.
`~/Projects/tile57` is a THIRD checkout at `8ec6ecc`, WITHOUT this work — it gave
the wrong answer early on. Check which checkout you are reading.

## Root causes (all fixed)

1. **Class-major ordering in the engine.** The surfaces sorted
   `(OpLayer, priority, seq)`. S-52 PresLib Ed 4.0.0 §10.3.4.1 makes priority
   dominant — it "applies irrespective of whether an object is a point, line or
   area" — with class as the tiebreak *only* at equal priority. A `LightSectored`
   arc is a LINE at 24; a `Wreck` is a POINT at 12. Came from `332e5db`, which
   imported the MapLibre layer stack as though it were the standard.
   Normative text: `../chartplotter-specs/s52/specs/pslb04_0_part1.pdf`. The
   vendored S-101 catalogue has no ordering prose, only the Lua tokens.
2. **Host batching re-inverted it.** lookout drew each pipeline buffer whole,
   making draw type dominant again. 5,963 inverted orderings in one small cell.
3. **DisplayPlane applied unconditionally — introduced in `82b56f4`.**
   §10.3.4.2 gates OVERRADAR precedence on a radar overlay being present.
   Ungated, every OverRadar feature climbs above higher-priority ones (`BUAARE`
   over a sector arc, both at 24). Only visible once tiles carried real
   `display_plane`, i.e. after a rebake.
4. **Duplicated rules drifting.** Same DisplayPlane bug fixed twice (engine +
   lookout); `OpLayer`/`orderLt` triplicated inside the engine; lookout's class
   numbering never matched (no `pattern` tier, `line` was 1 vs 2).

## Landed

**tile57** (`feat/label-cache`)
- `82b56f4` order by `(text-last, DisplayPlane, priority, class, seq)`; `display_*` rename
- `9b526d2` `bake -j/--workers` (was single-threaded; 3.15s → 2.00s on 2 cells)
- `1cc75ac` partition made internal — canonical cell order, self-discovery, self-heal
- `5d8ac88` DisplayPlane gated on `Settings.radar_overlay`
- `3512350` `tile57_feature.paint_key` — the ordering as one opaque `u32`
- `b9dde98` libtess2 vendored (SGI FSL B) + `render/tess.zig`
- `b2641e2` `render/gpu.zig` (GpuSurface) + `render/paint.zig` (single rule, all four surfaces)
- `7b6d0c0` `drawSounding` (shared SNDFRM composition); fixed `emitMark` dropping
  the mm→0.01 mm factor and the device scale — every mark was 100x too small
- `e556832` `fillPattern` — `Scene.patterns` (deduped RGBA cells) + `Range.pattern`;
  host tiles at 1:1 device px, phase-anchored to the world origin
- `1974d00` `drawText` — outline rings as marks, ranked through `declutter.zig`
- `50ef7e2` the GPU C ABI: `tile57_chart_gpu_scene` + `tile57_gpu_scene_free`,
  `Chart.renderGpuScene`, `include/tile57.h`

**lookout-core** (`main`)
- `9820c17` paint-order bands across pipelines
- `ff46e33` / `d3f521a` stop managing the partition; drop DisplayPlane from the band key
- `379c689` deleted the duplicated rules — buckets on `paint_key` and nothing else

**chartplotter** (`feat/display-priority-abi`)
- `3dae5df` client follows the MVT key rename; rebuilt `style-engine.wasm` (had
  old keys compiled in). Go needed no change — it uses bake/metadata APIs, not
  the draw-callback surface.

## Next — in this order

1. ~~**Finish `GpuSurface`.**~~ DONE — no stubs left (`7b6d0c0`, `e556832`,
   `1974d00`).
2. ~~**Wire the GPU C ABI.**~~ DONE (`50ef7e2`) — `tile57_chart_gpu_scene` /
   `tile57_gpu_scene_free`, `Chart.renderGpuScene`, header declarations.
3. **Delete lookout's `Scene`.** `src/scene.zig`, `vendor/libtess2`, band
   bookkeeping. THE REMAINING STEP — nothing in tile57 blocks it now.

Deferred: port libtess2 to Zig (own PR); once ported, evaluate replacing the
hand-rolled sweep in `src/geometry/boolean.zig`.

## Blocked / unverified

**The original sector bug has never been confirmed fixed on real charts.** No NY
source cells on the dev box; `~/.cache/chartplotter/NOAA/tiles/` is dated 07-18
(pre-rename). All "verification" ran against `chartplotter/testdata/US5MD1MC.000`
(Annapolis), which does not reproduce it. It was reported fixed twice on that
basis; both were wrong.

To settle it, from a machine with the real charts: for the sector arc and the
`BUAARE` covering it, get `display_plane` and `display_priority`. Either at plane
1 → cause #3 explains it. Both plane 0 → theory is wrong, instrument instead.

## Also open

- **Zoom-to-nodata.** Zooming in far enough goes NODATA; it never should. Untouched.
- **Bake slowdown.** Reported after the engine upgrade. `82b56f4` ruled out
  (1.75s vs 1.80s on its parent), but the submodule jumped 92 commits
  (`4b6d73c..82b56f4`) and that range was never bisected.
- **chartplotter submodule pin** not committed — the engine commit isn't on
  `main`. `ci.yml:32` runs `git submodule update --remote`, so CI ignores the pin
  and builds against tile57 `main`: **green but wrong** until the rename lands
  there (Go never touches the keys; the style coalesces a missing
  `display_priority` to 0).

## Traps

- **Stale tiles fail silently.** Old archives lack the renamed MVT keys; replay
  coalesces to priority 0, everything lands in one band, chart looks plausible
  and is wrong. Rebake is mandatory after `82b56f4`. Check:
  `tile57 compose-tile <tiles-dir> 12 1179 1569 -o /tmp/t.mvt`, then count
  `display_priority` vs `draw_prio` in the (gzipped) bytes.
- **`bake-ienc`/`bake-noaa` skip when the output exists** — a "rebake" over an
  existing archive is a no-op. `make clear-cache` first.
- **Test discovery in `src/render/`.** `render.zig`'s `test {}` block gates it AND
  the pkg-test module needs its own `addTess()`. `tess.zig` reported green while
  compiling nowhere. Verify new tests by forcing a failure and watching it fire.
- **`capi.zig` has NO tests at all.** It links libc and lives in `lib_root.zig`,
  outside the pure-Zig `zig build test` module — a test written there passes
  unconditionally. Hit during `50ef7e2`; the ABI layout assertions had to move to
  `render/gpu.zig` to run. Anything C-facing that needs testing goes in a module
  the test build actually reaches.
- **`include/tile57.h` is hand-maintained and nothing checks it against the Zig.**
  `render/gpu.zig`'s layout test pins the GPU structs only. The rest of the header
  is still on trust.
- **`pickCmp` in `chartplotter.mjs` is class-major on purpose** — cursor pick
  ranking, not paint order. Priority-first made features on land unclickable
  under the LNDARE polygon. Do not "fix" it.
