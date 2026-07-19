---
id: mariner
title: Mariner settings
sidebar_position: 6
---

# Mariner settings (S-52)

The mariner's S-52 display options are the whole `tile57_mariner` struct. lookout
holds one and you edit it wholesale:

```c
tile57_mariner m;
lookout_get_mariner(lk, &m);
m.scheme         = TILE57_SCHEME_NIGHT;   // day / dusk / night
m.safety_contour = 10.0;                  // metres
m.display_other  = false;                 // hide the OTHER category
m.soundings      = 1;                     // 0 follow-category, 1 on, 2 off
lookout_set_mariner(lk, &m);
```

`lookout_mariner_defaults(&m)` fills tile57's canonical defaults to start from.

## Live vs. rebuild

lookout splits the mariner into two classes, so common toggles are instant:

| Applies **live** (uniform-only, no re-tessellation) | Triggers a **rebuild** (changes what the engine emits) |
|---|---|
| `scheme` (day/dusk/night) | `shallow_/safety_/deep_contour`, `safety_depth` |
| `display_base` / `_standard` / `_other` | `four_shade_water`, `depth_unit` |
| `text_names` / `show_light_descriptions` / `text_other` | `boundary_style`, `simplified_points`, `show_full_sector_lines` |
| `soundings` | `date_dependent` / `date_view`, `viewing_groups_off` |
| `size_scale` | `text_size_scale`, `sounding_size_scale`, `show_overscale`, … |

**Live** changes are per-frame: the palette is a color-buffer swap, and category /
text / sounding visibility and SCAMIN are gated in the vertex shader. **Rebuild**
changes re-run the tile57 Surface on the worker thread; the previous scene keeps
rendering until the new one lands.

`lookout_set_mariner` figures out which class a change falls in for you.

## How live gates work

At build time lookout drives the Surface with a *maximally permissive* mariner
(all categories, all text, soundings on) so **every** feature reaches the GPU
tagged with its display category, SCAMIN denominator, and kind. Each frame the
shader culls from uniforms — an enable mask per display category, the current
display scale vs. each feature's SCAMIN, and text/sounding kind flags. So the day/
night toggle, the category/text/sounding toggles, and zoom-driven SCAMIN
decluttering all cost nothing but a uniform update. (See
[Architecture](./architecture.md).)

## Convenience toggles

For interactive shells there are one-call toggles that mutate the mariner and
apply live: `lookout_cycle_scheme`, `lookout_toggle_text`,
`lookout_toggle_soundings`, `lookout_toggle_other_category`,
`lookout_nudge_safety_contour` (rebuilds), `lookout_adjust_size`.
