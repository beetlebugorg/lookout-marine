# Lookout Marine — the app (Linux / GTK4)

A native **GTK4** chartplotter around the Zig chart core, which renders **raw
Vulkan** (`src/gpu_vk.zig`) into a subsurface the compositor presents, placed below
a transparent hole in the window so the chrome floats over the chart. The Linux
counterpart of the SwiftUI shell on macOS/iOS and the Java shell on Android: same
core, same C ABI, same behaviour.

**Architecture, design history and gotchas: [docs/linux.md](../docs/docs/developer-guide/linux.md).**

![Annapolis Harbor and the Naval Academy, day scheme](../docs/docs/img/linux-day.webp)

## Prerequisites

- **GTK 4.14+**, **Vulkan** headers and a loader, X11 and/or Wayland client libs.
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

### Plugins

Own ship, AIS, NMEA 0183, Signal K and laylines are wasm plugins, so the build
turns the plugin host on by default: `build-core.sh` passes `-Dplugins=true` and
the executable links `libvmlib.a` (the WAMR interpreter) beside the core. That
needs the archive for this architecture, which `scripts/build-wamr.sh linux-x64`
or `linux-arm64` builds into `vendor/`. On an architecture the script has no
archive for, configure with `-Dplugins=false`: the chart still draws, with no
own ship, no traffic and no instrument input.

`meson install` places the shipped modules under
`$prefix/share/lookout-marine/plugins`, and the app loads them at every chart
open — from `../share/lookout-marine/plugins` relative to `/proc/self/exe` when
that exists (so a relocated bundle finds its own copy), else from the prefix
path baked in at configure time. The set a mariner installed
(`$XDG_DATA_HOME/lookout-marine/plugins`) loads after it. `LOOKOUT_PLUGINS=<dir>`
overrides both.

Plugin settings are filed with the chart settings they belong to: an AIS alarm
lands under **Alarms**, connections under **Connections**. Those sections exist
only while a plugin puts something in them.

**Settings ▸ Plugins** is where plugins are managed. Each one is a row with its
live status, and a disclosure holds the rest: where the copy came from, a
switch per capability in the consent sheet's own words, and **Uninstall** for
what an install wrote. A grant never exceeds the manifest, so a switch only
ever takes something away; the plugin keeps running and the calls it lost
answer -1.

**Install Plugin…** takes a `.lkplug` package. Dropping one on the chart does
the same thing. The consent sheet reads the package without installing it and
lists what it will be able to do; nothing touches the disk until Install.

An alarm a plugin raises stands at the top of the chart and sounds until
somebody acknowledges it. A warning and a notice are shown and never sounded.
Acknowledging silences one alert and no other.

A plugin that declares a table gets a window: **Commands ▸ Vessels ▸ AIS
Targets…**. The columns are typed, so the shell prints metres, knots and
degrees true while the core sorts the numbers. A click on the heading sorts
within each band, never across one, so an alarmed vessel keeps the top line.
Activating a row with a position centres the chart on it.

A click on a symbol a plugin drew pins a bubble to it. The bubble follows the
target, refreshes its values and closes itself when the target is gone. The
chart pick report does not open for that click.

You need a baked `.pmtiles` chart to see anything. **Ctrl+O**, or **Charts** in the
mariner settings, picks a folder of cells; on first launch the app probes
`$LOOKOUT_OPEN`, then the saved chart library, then
`~/.cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles`.
`$LOOKOUT_VIEW="lon,lat,zoom[,rot]"` pins the opening camera.

## Raster charts

**Ctrl+Shift+I** adds `.mbtiles` raster charts; the **Charts** tab of the mariner
settings adds a whole folder and switches one off. The engine draws them below the
ENC. The pill at the end of the readouts names the set drawn over the view: blue
when it draws, amber when one covers the view and is off. **Ctrl+I** steps to the
next set covering this water, and **Ctrl+Shift+H** hides the ENC where a picture
covers it. The installed list lives in `settings.ini` and is replayed into every
chart the engine opens, along with the rest of what the mariner chose: the
charts switched off (`off`), the sets they stopped drawing (`hidden`, by set
name) and the ENC-over-picture state (`chart_hidden`). They are put back before
the first frame, because the engine draws a set as it opens it.

## Testing

- **Core unit tests:** `zig build test -Dbackend=vk` from the repo root.
- **Render parity / smoke:** `zig-out/bin/lookout-marine-demo <chart.pmtiles>`.
- **Screenshots:** `./screenshots.sh all` — runs the app in an off-screen sway
  session and writes `../docs/docs/img/linux-*.webp`. Needs `sway`, `grim` and
  ImageMagick; see [the protocol](../docs/docs/developer-guide/screenshots.md).

## What's in here

```
src/
  main.c              GtkApplication entry, the CSS, the accelerators

  engine/
    controller.c      The one lookout* handle, every lookout_* call, the render loop
    surface.c         The X11 child window / Wayland subsurface the chart presents into

  model/
    app-model.c       The shared state every widget reads and the commands act on
    coord.c           The coordinate and scale parsers
    store.c           Camera pose, recents and settings in one XDG keyfile
    mariner.c         The live tile57_mariner behind the settings form

  library/
    sets.c            The sets aboard, which are on, and their background scans
    scan.c            Looking through a folder or an archive for charts
    bake.c            Preparing cells and sheets the engine cannot draw yet
    links.c           Charts by link: a publisher's live map drawn as the chart
    raster.c          The installed raster charts, and the engine's set election

  plugins/
    registry.c        The wasm plugins' schemas, values, list rows, apply and save
    install.c         The .lkplug consent sheet, and the install
    discovery.c       Browsing the boat's network for what a plugin can talk to

  ui/
    window.c          The window: titlebar, chart, floating chrome, actions, drops
    window-private.h  The LkWindow struct the ui/ units share
    open-dialogs.c    Every file picker, and the one route in
    startup-view.c    The opening loader and the first-run page
    dev-hooks.c       The LOOKOUT_* hooks the screenshot script drives
    chart/
      view.c          The chart widget: the surface, the transparent hole, all input
      pick-report.c   The cursor pick: the decode, the card, the callout placement
      overlay.c       The bubble pinned to a symbol a plugin drew
    hud/
      hud.c           The readouts capsule, the raster pill, the bubbles, the formats
      pills.c         The build indicator and the bake pill
      scale-bar.c     The distance bar at the bottom left
      scale-entry.c   Type a scale, or pick a navigational purpose band
    settings/
      window.c        The lifecycle, the sidebar, and the Text and Advanced pages
      private.h       The LkSettings struct the pages share
      widgets.c       The page, the sections, the rows, the field bindings
      display.c       The colour scheme, the display category, the soundings rule
      depths.c        The four contours, the unit, the shading
      charts.c        The chart by link, the library of sets, the raster charts
      plugins.c       The controls a plugin declared, and the rows of its lists
      plugins-page.c  What is loaded, what it may reach, and adding or removing one
    chrome/
      alerts.c        The plugin alert strip, and the siren behind an alarm
      search.c        Coordinate go-to (feature search stubbed)
      table-window.c  A plugin's declared table, as a window
      about.c         The About screen
      licenses.c      The Licenses screen

  util/
    json.c            A small JSON reader for the engine's pick payload
    tether.h          Ties a model signal handler to a widget's life
```

| Elsewhere | Role |
|------|------|
| `build-core.sh` | Builds the Zig core where meson expects its outputs |
| `screenshots.sh` | The documentation screenshots, headless |
| `data/` | The desktop entry and the hicolor icons `meson install` ships |
| `tests/` | The unit and widget suites, run with `meson test -C build` |

## The app icon

`meson install` puts the icon in the hicolor theme, which every icon theme
inherits from:

```
<prefix>/share/icons/hicolor/<size>x<size>/apps/org.beetlebug.LookoutMarine.png
<prefix>/share/icons/hicolor/scalable/apps/org.beetlebug.LookoutMarine.svg
<prefix>/share/applications/org.beetlebug.LookoutMarine.desktop
```

Three things have to name the same string and do: the `Icon=` key in the desktop
entry, `gtk_window_set_default_icon_name()` in `src/main.c`, and the installed
filenames — all `org.beetlebug.LookoutMarine`, which is also `LK_APP_ID`.

No icon cache is generated. GTK scans the theme directories when there is no
cache, so the icon resolves from a plain `meson install`; distro packaging runs
`gtk-update-icon-cache` in its own post-install step.

Running from the build tree without installing leaves the icon unresolvable —
there is nothing in the theme search path to find. That is expected.
