---
id: getting-started
title: Getting started
sidebar_position: 3
---

# Getting started

## The demo

The `lookout` executable opens a baked tile57 chart (a `.pmtiles` archive — what
`tile57 bake` produces) and renders it.

```sh
# headless: render the whole cell to PNGs and exit
./zig-out/bin/lookout /path/to/US5MD1MC.pmtiles

# a window (needs a display; on a headless box use xvfb-run)
./zig-out/bin/lookout /path/to/US5MD1MC.pmtiles --window

# compose a whole directory of baked archives
./zig-out/bin/lookout /path/to/charts/

# pin the view / output size
./zig-out/bin/lookout chart.pmtiles --lon -76.48 --lat 38.98 --zoom 15 \
    --width 2400 --height 1800 --png out.png
```

Headless mode writes `lookout.png` (day), `lookout-night.png` (a palette swap
only — no re-tessellation) and `lookout-zoom.png` (zoomed via the camera only),
then exits. `-h` prints full usage.

:::note The chart must be baked
lookout opens a **baked** tile57 archive (`.pmtiles`), not a raw S-57 `.000`. Bake
a raw cell or an ENC_ROOT with tile57 first (`tile57 bake …` / `tile57_bake_tree`),
then point lookout at the result. See [Compositing](./compositing.md).
:::

### Demo controls (windowed)

| Input | Action |
|---|---|
| drag | pan |
| wheel | cursor-anchored zoom |
| `n` | cycle day / dusk / night palette |
| `t` | toggle text |
| `s` | toggle soundings |
| `d` | toggle the OTHER display category |
| `[` / `]` | nudge safety contour (rebuilds) |
| `-` / `=` | shrink / grow symbol & text size |
| `Esc` | quit |

## The smallest program

```c
#include "lookout.h"

lookout *lk = lookout_open("US5MD1MC.pmtiles", 1280, 960, /*window*/0, /*msaa*/1);
lookout_view v;
lookout_fit_chart(lk, &v);   // center + zoom that fits the cell
lookout_set_view(lk, &v);
lookout_snapshot_png(lk, "out.png");
lookout_close(lk);
```

That is the whole lifecycle: **open → set a view → render**. The first render
lazily tessellates the scene; from then on pan / zoom / palette are per-frame.

To draw into your own app instead of a PNG, see [Embedding](./embedding.md).
