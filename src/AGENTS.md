# The core

Rendering, the camera, the raster underlay, the C API in `include/lookout.h`,
and the plugin host under `src/plugin/`.

## What must stay true

- **Overlay vertices are origin-relative f32** with a per-frame uniform.
  Absolute world coordinates in f32 quantise visibly at zoom.
- **Fractional zoom.** Every dash test and harness render used integer zooms,
  which hid a bug that truncated every dashed line at any other zoom. Test
  fractional zooms.

- **The C API is what every shell calls.** Read `include/lookout.h` first for
  anything cross-shell. A pointer it hands out is borrowed until the next call
  of its kind, so a shell decodes before doing anything else.
