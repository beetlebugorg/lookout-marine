# Lookout Marine — the app (Linux / GTK4)

A native **GTK4** chartplotter around the Zig chart core, which renders **raw
Vulkan** (`src/gpu_vk.zig`) into a subsurface the compositor presents, placed below
a transparent hole in the window so the chrome floats over the chart. The Linux
counterpart of the SwiftUI shell on macOS/iOS and the Java shell on Android: same
core, same C ABI, same behaviour.

**Architecture, design history and gotchas: [docs/linux.md](../docs/docs/developer-guide/linux.md).**

![Annapolis Harbor and the Naval Academy, day scheme](../docs/docs/img/linux-day.png)

## Prerequisites

- **GTK 4.10+**, **Vulkan** headers and a loader, X11 and/or Wayland client libs.
- **Zig 0.16** on `PATH`; **meson** + **ninja**.

```sh
sudo apt install libgtk-4-dev libvulkan-dev libx11-dev libwayland-dev \
                 meson ninja-build          # Debian/Ubuntu
sudo pacman -S   gtk4 vulkan-headers vulkan-icd-loader libx11 wayland \
                 meson ninja                # Arch
```

tile57 is **not** a prerequisite: it is a Zig package dependency of the core. A
sibling `../../tile57` checkout is used when present; otherwise the commit pinned
in `../build.zig.zon` is fetched on first build.

## Build & run

```sh
meson setup build
ninja -C build
./build/lookout-marine
```

One step: `meson` drives `build-core.sh`, which runs `zig build lib -Dbackend=vk`
and drops `liblookout_marine.a`, `libtile57.a`, `lookout.h` and `tile57.h` into the
build directory. The core is `ReleaseFast` in every configuration
(`-Dcore-optimize=Debug` to develop on it) — the app chases 60 fps and a Debug core
visibly drops frames.

You need a baked `.pmtiles` chart to see anything. **Open** in the headerbar picks a
folder of cells; on first launch the app probes `$LOOKOUT_OPEN`, then the last
recent, then `~/.cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles`.
`$LOOKOUT_VIEW="lon,lat,zoom[,rot]"` pins the opening camera.

## Testing

- **Core unit tests:** `zig build test -Dbackend=vk` from the repo root.
- **Render parity / smoke:** `zig-out/bin/lookout-marine-demo <chart.pmtiles>`.
- **Screenshots:** `./screenshots.sh all` — runs the app in an off-screen sway
  session and writes `../docs/docs/img/linux-*.png`. Needs `sway` + `grim`; see
  [the protocol](../docs/docs/developer-guide/screenshots.md).

## What's in here

| File | Role |
|------|------|
| `src/main.c` | `GtkApplication` entry, CSS, accelerators |
| `src/lk-window.c` | The window: headerbar, chart, status bar, actions, open dialog |
| `src/lk-chart-view.c` | The chart widget: owns the surface, the transparent hole, all input |
| `src/lk-chart-controller.c` | The one `lookout*` handle; every `lookout_*` call; the render loop |
| `src/lk-native-surface.c` | The X11 child window / Wayland subsurface the chart presents into |
| `src/lk-app-model.c` | Shared state, recents, open paths, coordinate parser |
| `src/lk-hud.c` | Status-bar readouts, identify panel, DMS formatting |
| `src/lk-search.c` | Coordinate go-to (feature search stubbed) |
| `src/lk-mariner.c` | The live `tile57_mariner` behind the settings form |
| `src/lk-settings-window.c` | The mariner panel (Display / Depths / Text / Charts / Advanced) |
| `src/lk-store.c` | Camera pose, recents and settings in one XDG keyfile |
| `build-core.sh` | Builds the Zig core where meson expects its outputs |
| `screenshots.sh` | The documentation screenshots, headless |
