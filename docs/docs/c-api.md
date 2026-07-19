---
id: c-api
title: C API
sidebar_position: 8
---

# C API

`liblookout.a` exposes the widget behind a small C ABI —
[`include/lookout.h`](https://github.com/beetlebugorg/lookout-core/blob/main/include/lookout.h),
prefix `lookout_`. It includes `tile57.h` for the `tile57_mariner` and
`tile57_query_cb` types. A `lookout *` is an opaque handle.

## Lifecycle

```c
lookout *lookout_open(const char *chart_path, uint32_t w, uint32_t h,
                      int want_window, int want_msaa);
lookout *lookout_open_charts(const char *const *paths, size_t n,
                             uint32_t w, uint32_t h, int want_window, int want_msaa);
lookout *lookout_open_in_window(lookout_native_kind kind, void *native_handle,
                                const char *chart_path, uint32_t w, uint32_t h, int want_msaa);
void     lookout_close(lookout *h);
```

`lookout_open_in_window` embeds into your app's native window — see
[Embedding](./embedding.md). `native_kind` is one of `LOOKOUT_NATIVE_COCOA_WINDOW`
(`NSWindow*`), `_COCOA_VIEW` (`NSView*`), `_WIN32_HWND` (`HWND`), or `_X11_WINDOW`
(X11 `Window` XID cast to `void*`).

## View

```c
typedef struct { double lon, lat, zoom, rotation_deg; } lookout_view;

void  lookout_fit_chart(lookout *h, lookout_view *out);  // fit the whole cell/library
void  lookout_set_view (lookout *h, const lookout_view *v);
void  lookout_get_view (lookout *h, lookout_view *out);
int   lookout_resize   (lookout *h, uint32_t w, uint32_t h);   // logical points
float lookout_pixel_density(lookout *h);                       // HiDPI px/pt
```

## Interaction

```c
void lookout_pan     (lookout *h, float dx_px, float dy_px);
void lookout_zoom_at (lookout *h, double dzoom, float x_px, float y_px);
void lookout_pan_logical    (lookout *h, float dx_pt, float dy_pt);      // scale by density
void lookout_zoom_at_logical(lookout *h, double dz, float x_pt, float y_pt);
void lookout_screen_to_geo  (lookout *h, float x_px, float y_px, double *lon, double *lat);
void lookout_geo_to_screen  (lookout *h, double lon, double lat, float *x_px, float *y_px);
```

## Mariner (all S-52 settings)

```c
void lookout_mariner_defaults(tile57_mariner *m);
void lookout_get_mariner(lookout *h, tile57_mariner *out);
void lookout_set_mariner(lookout *h, const tile57_mariner *m);
// convenience live toggles:
void lookout_cycle_scheme(lookout *h);
void lookout_toggle_text(lookout *h);
void lookout_toggle_soundings(lookout *h);
void lookout_toggle_other_category(lookout *h);
void lookout_nudge_safety_contour(lookout *h, double delta);  // rebuilds
void lookout_adjust_size(lookout *h, float factor);
```

See [Mariner settings](./mariner.md) for which changes apply live vs. rebuild.

## Render

```c
int lookout_build(lookout *h);                // force (re)tessellation
int lookout_render(lookout *h);               // one window frame (1=drawn, 0=headless)
int lookout_needs_redraw(lookout *h);         // 1 => call render; 0 => idle, block on events
int lookout_snapshot_png(lookout *h, const char *path);
int lookout_snapshot_rgba(lookout *h, uint8_t *dst, size_t dst_len);   // w*h*4, top-down
```

Render **on demand**: only call `lookout_render` when `lookout_needs_redraw`
returns 1; otherwise block on your window system's events and use no CPU.

## Pick {#pick}

```c
void lookout_pick(lookout *h, double lon, double lat, const tile57_query_cb *cb);
```

The S-52 §10.8 cursor pick: `cb->feature` fires once per feature under the point
with its object-class acronym, the full S-57 attribute JSON, and the source cell.
Convert a screen tap with `lookout_screen_to_geo` first.
