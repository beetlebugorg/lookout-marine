---
id: zig-api
title: Zig API
sidebar_position: 7
---

# Zig API

The C ABI is a thin shim over the Zig `Lookout` type in `src/root.zig`. Add the
module to your `build.zig` (or read `src/capi.zig` for the mapping) and use it
directly:

```zig
const lk = @import("lookout");

var l = try lk.Lookout.open(alloc, "chart.pmtiles", .{
    .width = 1280,
    .height = 960,
    .want_window = true,     // or .native_handle/.native_kind to embed
    .want_msaa = true,
});
defer l.close();

l.setView(l.fitChart());
while (running) {
    // … feed input …
    if (l.needsRedraw()) _ = try l.render();
}
```

## OpenOptions

```zig
pub const OpenOptions = struct {
    width: u32 = 1280,
    height: u32 = 960,
    want_window: bool = false,
    want_msaa: bool = true,
    schemes: []const Scheme = &.{ DAY, DUSK, NIGHT },  // palettes captured at build
    partition_path: ?[:0]const u8 = null,              // compose partition sidecar
    native_handle: ?*anyopaque = null,                 // embed in a native window
    native_kind: NativeKind = .none,
};
```

## Lookout

| Method | Purpose |
|---|---|
| `open` / `openCharts` / `close` | one chart, or compose many |
| `fitChart` / `setView` / `view` / `resize` | the `View` (lon, lat, zoom, rotation_deg) |
| `panPixels` / `zoomAt` / `panLogical` / `zoomAtLogical` | interaction (px or HiDPI points) |
| `screenToGeo` / `geoToScreen` / `pixelDensity` | overlays and picks |
| `getMariner` / `setMariner` | the full `tile57_mariner` |
| `cycleScheme` / `toggleText` / `toggleSoundings` / `toggleOtherCategory` / `nudgeSafetyContour` / `adjustSize` | live toggles |
| `build` | force a synchronous (re)tessellation |
| `render` / `needsRedraw` / `isBuilding` | window frame + on-demand hints |
| `snapshotPng` / `snapshotRgba` | offscreen output |
| `pick` | S-52 cursor pick |

The Zig and C APIs stay in lock-step; the C header documents the same surface.
