---
id: compositing
title: Compositing a library
sidebar_position: 5
---

# Compositing a library

A single chart is one baked `.pmtiles`. A real chart plotter has a **library** —
dozens to thousands of cells at different scales, covering overlapping ground.
tile57 stitches them through its **ownership partition** (which cell renders which
ground at each zoom); lookout drives that.

## Open a directory of baked charts

```c
const char *paths[] = { "d5/US5MD1MC.pmtiles", "d5/US5MD13M.pmtiles", /* … */ };
lookout *lk = lookout_open_charts(paths, n, 1280, 960, /*window*/0, /*msaa*/1);
```

Each path is `tile57_chart_open`'d, which **mmaps** it — the cell set is *never
fully resident*, the OS pages tiles in on demand. The compositor composes each
view on the fly from the mmapped archives and its ownership partition. The demo
does this for you when you pass a directory:

```sh
./zig-out/bin/lookout /path/to/charts/     # composes every *.pmtiles inside
```

lookout doesn't manage your library or reinvent tile57's model — it hands the
paths to the engine, which owns baking, mmap, the partition, and composition.

## From raw S-57 (ENC_ROOT)

lookout opens **baked** archives, not raw `.000` cells. Bake first with tile57 —
`tile57_bake_tree` walks an ENC_ROOT and bakes every cell into a cache you name,
incrementally (a warm cache re-bakes nothing) — then point lookout at the cache.

## The ownership partition (performance)

Building the partition over a large library is the expensive part of opening. Pass
a **partition sidecar** so it is built once and reused:

```c
// (Zig / the OpenOptions form) — a path lookout loads if present, else builds
// and saves for next time:
//   .partition_path = "charts/partition.tpart"
```

With the sidecar in place, reopening a large library skips the O(charts)
partition build entirely.

## What you get across the composite

`lookout_render`, `lookout_snapshot_*`, `screen_to_geo` / `geo_to_screen`, and
`lookout_pick` all work identically over a composed set — the view fits the union
of coverage, and picks report the feature and its **source cell** across chart
boundaries.
