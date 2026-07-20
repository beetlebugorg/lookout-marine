# NOTES — recorded tile57 API + deviations from the spec

Source of truth: `tile57.h` (identical across the `tile57`, `tile57-main`, `tile57-asm`
checkouts — 871 lines, `TILE57_VERSION 0.3.0`). Canonical copy bound against:
`/home/claude/Projects/tile57-main/include/tile57.h`.
Prebuilt static lib: `/home/claude/Projects/tile57-main/zig-out/lib/libtile57.a`
(aarch64; only external undefined symbol is `pthread_create`, so link `libc` + `pthread`).

This file is the M0 deliverable required by spec §3/§10. **The spec's §5–§7 made several
assumptions that the real header contradicts.** Those deviations are recorded here and
drive the architecture; where they matter they are called out inline in the code too.

---

## 1. Recorded signatures (verbatim from the header)

### Lifecycle
```c
tile57_status tile57_chart_open(const char *path, tile57_chart **out, tile57_error *err);
tile57_status tile57_chart_open_bytes(const uint8_t *pmtiles, size_t len,
                                      tile57_chart **out, tile57_error *err);
void          tile57_chart_close(tile57_chart *chart);
void          tile57_chart_get_info(tile57_chart *chart, tile57_info *out);   // min/max zoom, bounds, anchor, native_scale
void          tile57_warmup(void);   // call once on main thread before open/render
void          tile57_free(void *ptr);
const char   *tile57_version(void);
```

### Mariner (S-52 display options) — struct `tile57_mariner` (header lines 385–437)
```c
typedef enum { TILE57_SCHEME_DAY=0, TILE57_SCHEME_DUSK=1, TILE57_SCHEME_NIGHT=2 } tile57_scheme;
typedef enum { TILE57_DEPTH_METERS=0, TILE57_DEPTH_FEET=1 } tile57_depth_unit;
// key fields used by this prototype:
//   scheme                          -> palette (day/dusk/night)
//   shallow_contour/safety_contour/deep_contour/safety_depth
//   display_base/display_standard/display_other  (bool)  -> category gating AT EMISSION
//   text_names/show_light_descriptions/text_other        -> text gating AT EMISSION
//   soundings (uint8: 0 follow-category, 1 force-on, 2 force-off)
//   size_scale / text_size_scale / sounding_size_scale   (0 read as 1.0)
//   ignore_scamin (bool)  -> host-debug: drop SCAMIN gating
void tile57_mariner_defaults(tile57_mariner *m);   // start here, then edit
```

### The Surface interface — THE thing we build on (header lines 499–601)
```c
typedef struct { double x, y; } tile57_world_point;   // web-mercator [0,1], y DOWN
typedef struct { float  x, y; } tile57_local_point;   // anchor-relative REFERENCE px (constant screen size)
typedef struct { const tile57_world_point *pts; uint32_t n;
                 const uint32_t *ring_starts; uint32_t ring_count; } tile57_world_rings;
typedef struct { const tile57_local_point *pts; uint32_t n;
                 const uint32_t *ring_starts; uint32_t ring_count; } tile57_local_rings;
typedef struct { uint8_t r,g,b,a; } tile57_rgba;       // RESOLVED straight-alpha (NOT a token)
typedef enum { TILE57_ALIGN_VIEWPORT=0, TILE57_ALIGN_MAP=1 } tile57_rot_align;
typedef enum { TILE57_DISP_BASE=0, TILE57_DISP_STANDARD=1, TILE57_DISP_OTHER=2 } tile57_disp_cat;

typedef struct {                       // per-feature metadata carried on EVERY draw call
    const char *cls;                   // S-57 object-class acronym, NUL-terminated ("" if none)
    int64_t     scamin;                // SCAMIN 1:N denominator; <=0 => always visible
    int32_t     draw_prio;             // S-52 draw priority (S-101 DrawingPriority 0..30) — host re-sorts by this if it batches
    tile57_disp_cat disp_cat;          // BASE never SCAMIN-gated
} tile57_feature;

typedef struct {
    void *ctx;
    void (*fill_area)  (void*, const tile57_feature*, const tile57_world_rings*, tile57_rgba, int even_odd);
    void (*stroke_line)(void*, const tile57_feature*, const tile57_world_rings*, float width_px,
                        float dash_on, float dash_off, tile57_rgba);
    void (*draw_symbol)(void*, const tile57_feature*, tile57_world_point anchor,
                        const tile57_local_rings*, tile57_rgba, int even_odd, float stroke_w, tile57_rot_align);
    void (*draw_text)  (void*, const tile57_feature*, tile57_world_point anchor,
                        const tile57_local_rings* glyphs, tile57_rgba, tile57_rgba halo, float halo_px, tile57_rot_align);
    // OPTIONAL atlas-based twins — leave NULL to get the tessellated fallback above:
    void (*draw_sprite)(...);      // NULL => symbols come through draw_symbol as outline rings
    void (*draw_pattern)(...);     // NULL => pattern fills come through fill_area as a flat tint
    void (*draw_text_str)(...);    // NULL => text comes through draw_text as glyph outline rings
} tile57_surface_cb;

tile57_status tile57_chart_surface(tile57_chart *chart, double lon, double lat, double zoom,
                                   double rotation_rad, uint32_t width, uint32_t height,
                                   const tile57_mariner *m, const tile57_surface_cb *surface,
                                   tile57_error *err);
// tile / MLT twins (for the caching stretch goal, not used yet):
tile57_status tile57_chart_tile_surface(chart, z,x,y, m, surface, err);
tile57_status tile57_render_mlt_tile(mlt,len, z,x,y, m, surface, err);
// compose twin (multi-chart stretch goal):
tile57_status tile57_compose_surface(compose, lon,lat,zoom, rotation_rad, w,h, m, surface, err);
```

---

## 2. Deviations from the spec — READ THIS

| Spec §7 said | Reality in `tile57.h` | Consequence for us |
|---|---|---|
| callbacks `fillArea` `fillPattern` `strokeLine` `drawSymbol` **`drawSounding`** `drawText` + **begin/end scene/feature hooks** | `fill_area` `stroke_line` `draw_symbol` `draw_text` (+ optional `draw_sprite`/`draw_pattern`/`draw_text_str`). **No begin/end hooks; no `drawSounding`.** Per-feature metadata rides on every call via `const tile57_feature*`. | We record per call, not per feature-span. There is no separate sounding path — see below. |
| "Color **tokens**; resolve token→RGB live per frame" | Colors are **already resolved** `tile57_rgba` for the mariner's `scheme`. No token is exposed. | Day/night can't be a shader LUT swap. We capture **one resolved-color array per scheme** at build (geometry shared) and swap the color source per frame — geometry buffers are never rebuilt. See §3. |
| `drawSounding(depth, anchor)` → host composes digits | **No such callback.** The engine composes sounding digits itself and emits them through `draw_text` (glyph outline rings), `cls == "SOUNDG"`, honouring `mariner.soundings` + `sounding_size_scale`. | We do **not** compose digits (spec §5/§7 "reuse SNDFRM" is unnecessary). Soundings are just text with `cls=="SOUNDG"`. |
| "Symbol atlas / glyph atlas we must build" | Leaving `draw_sprite`/`draw_text_str` **NULL** makes the engine deliver symbols and text as **pre-tessellated local outline rings** (`draw_symbol`/`draw_text`) in reference px. | **No atlas needed for the prototype.** Symbols and text tessellate exactly like areas. The atlas path (`draw_sprite`+`tile57_bake_sprite_mln`, `draw_text_str`+`tile57_bake_glyph_sdf`) is a later optimization, not required. |
| world space = "mercator meters" (open Q §12) | `tile57_world_point` is **web-mercator normalized [0,1], y down.** `tile57_local_point` is anchor-relative reference px (constant screen size). | Camera math is in [0,1] space; screen↔world via the inverse MVP in [0,1] units. |
| stream may be pre-sorted into paint order | **It is** (since tile57 `ba0d083`): "CALLS ARRIVE IN S-52 PAINT ORDER" — class-major (areas, patterns, lines, symbols, soundings, text), `draw_prio` within a class. But the header is equally clear that **batching by draw type destroys that order**, which is exactly what a GPU host does. | We batch, so we re-sort. Geometry goes out as one paint-ordered index buffer keyed `(draw-class, draw_prio)`; sprites are their own pass, keyed `layer*1000 + draw_prio` where layer is symbol(3)/sounding(4). |
| sorting each tile's sprites is enough | **No.** Tiles are drawn one after another, so a per-tile sort still lets a low-priority symbol in one tile paint over a high-priority one in its neighbour — wrecks over soundings and lights at tile seams. | `Scene.quad_band_off` records where each `(layer, draw_prio)` band starts in the tile's quad buffer, and `gpu.recordTiles` walks the **bands outside the tile loop**. Paint order is then global across the view, at ~(non-empty bands × visible tiles) draw calls. |

## 3. Live-toggle strategy (how we satisfy acceptance criteria #2 and #3)

Two axes to keep off the per-frame rebuild path:

- **Palette (day/night), acceptance #3.** `scheme` only recolours — it does not change geometry.
  At build we drive `tile57_chart_surface` **once per scheme** with an otherwise-identical
  mariner, capturing geometry on the first (day) pass and only the `tile57_rgba` color stream
  on subsequent (dusk/night) passes, asserting 1:1 draw-call/vertex parity. Result: one shared
  geometry buffer + N per-scheme color buffers. Toggling palette re-points the color attribute
  via a uniform — **no re-tessellation, no geometry-buffer rebuild.** (Parity of geometry across
  schemes is being verified against the engine; if it ever fails we fall back to re-emit-on-toggle.)

- **Category / SCAMIN / text / soundings gates, acceptance #2 + §8 keys.** Display-category and
  text/sounding gating happen **at emission** in the engine. So we build with a **maximally
  permissive** mariner (all categories on, text on, `soundings=1`, `ignore_scamin`) so *every*
  feature reaches the surface tagged with its `disp_cat`, `scamin`, and class. Per frame we gate
  in the **vertex shader** from uniforms: a disp-cat enable mask, a `current_display_scale` vs the
  per-vertex `scamin` denominator, and text/sounding kind flags. A culled vertex is pushed off-clip.
  Zoom-driven SCAMIN culling and the `t`/`d` keys therefore touch **only uniforms**. (Large zoom-*in*
  past the build band still triggers a rebuild for new LoD, as §8 allows.)
  `safety_contour` nudges (`[`/`]`) DO change geometry → those rebuild, which the spec permits.

## 4. Coordinate + camera model
- World geometry stays in web-mercator **[0,1]** in GPU buffers (never bake the camera in).
- Per frame: `clip = MVP * vec4(world, 0, 1)`, then for anchored marks add the local px offset
  converted to clip space (`+ local_px * (2/viewport) * size_scale`) so symbols/text hold a
  constant screen size. One vertex format, one pipeline, painter's-order index buffer.
- `rotation_rad`: prototype runs north-up (0). `align==MAP` marks would additionally rotate their
  local rings by the view rotation; `align==VIEWPORT` stay upright. Wired but exercised at rot=0.

## 5. Toolchain found in this environment
- zig 0.16.0 (`/home/claude/.local/bin/zig/zig`).
- SDL3 3.4.2 with `SDL_gpu.h` (system pkg-config `sdl3`).
- `glslangValidator` (GLSL 450 → SPIR-V, offline; shaders precompiled, no runtime compilation).
- Vulkan: lavapipe software ICD (`/usr/share/vulkan/icd.d/lvp_icd.json`) — headless render works.
- Headless box (no `$DISPLAY`): default render path is SDL `offscreen` video driver → GPU texture →
  readback → PNG. A real window works where a display/Xvfb is present (`SDL_VIDEODRIVER=x11`).
- Test chart: `US5MD1MC` (Annapolis Harbor). Source `.000` and baked `.pmtiles` both present.

## 6b. Tessellator: libtess2, not earcut
The ABI passes an `even_odd` winding flag on `fill_area` **and** `draw_symbol`/`draw_text`
(header 559/568/574). Glyph outlines (holes in `e`/`o`/`8`) and compound S-52 symbols with
self-intersecting subpaths only fill correctly under a real winding rule. earcut has no
winding-rule concept (contract: one correctly-wound outer ring + simple hole rings) and
would need a second tessellator for glyphs anyway; libtess2 (GLU sweep) does
`TESS_WINDING_ODD`/`NONZERO` natively and is robust to the coincident points / zero-area
spikes real S-57 rings carry. One robust tessellator covers areas+symbols+text. Reversible:
if area tessellation ever profiles hot, areas alone could drop to earcut. Vendored under
`vendor/libtess2/` (14 C files, no deps).

## 6. MSAA
SDL_GPU exposes `SDL_GPUSampleCount`; we probe `SDL_GPUTextureSupportsSampleCount` and use 4x if
the device+format allow, else fall back to 1x. **Found working: 4x** on SDL_GPU Vulkan + Mesa
lavapipe (aarch64), both offscreen (resolve→readback) and windowed (resolve→swapchain).
