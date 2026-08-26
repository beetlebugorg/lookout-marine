# Third party notices

Lookout Marine is MIT licensed. Refer to [LICENSE](LICENSE). The app carries the
components below, each under its own terms.

This file is written from
[vendor/licenses/licenses.json](vendor/licenses/licenses.json), which carries the
full text of every license and is what the app's Licenses screen reads. A change
to one belongs in the other.

## Chart and rendering

### tile57

The S-57, S-101 and raster chart engine.

- License: MIT
- Commit: `edcac132a2dad7cbb0144947bac7d1a838e7ee57`
- Copyright: © 2026 Jeremy Collins
- Pinned in: `build.zig.zon`
- Upstream: <https://github.com/beetlebugorg/tile57>
- Ships on: macOS, iOS, Android, Linux, Windows

### charttable

Renders the chart.

- License: MIT
- Commit: `0d137fa893e3215d02d0237c7d3112136734d4bd`
- Copyright: © 2026 Jeremy Collins
- Pinned in: `build.zig.zon`
- Upstream: <https://github.com/beetlebugorg/charttable>
- Ships on: macOS, iOS, Android, Linux, Windows

### IHO S-101 Portrayal Catalogue

The portrayal rules: which symbol, which color, which text, at which scale.

- License: Not resolved
- Commit: `62f7773a5641fb22ad88e5508a58d668ad2a7b98`
- Copyright: International Hydrographic Organization
- Pinned in: `tile57's build.zig.zon`
- Upstream: <https://github.com/iho-ohi/S-101_Portrayal-Catalogue>
- Ships on: macOS, iOS, Android, Linux, Windows

No license stated. IHO publications are subject to the IHO's own terms.

## Plugins

### WebAssembly Micro Runtime

The runtime the plugins execute in.

- License: Apache 2.0 with the LLVM exception
- Version: WAMR-2.4.5
- Commit: `25bd7eb63e828e4bd242cc9b38d260b4b31c6605`
- Copyright: Intel Corporation and the WAMR contributors
- Pinned in: `scripts/build-wamr.sh`
- Upstream: <https://github.com/bytecodealliance/wasm-micro-runtime>
- Ships on: macOS, iOS, Android, Linux, Windows

Apache License 2.0 with the LLVM exception appended.

## Images and data

### stb_image

Reads the PNG and JPEG files a chart carries.

- License: MIT or the Unlicense, at your option
- Version: 2.30
- Copyright: © 2017 Sean Barrett
- Pinned in: `vendor/stb/stb_image.h`
- Upstream: <https://github.com/nothings/stb>
- Ships on: macOS, iOS, Android, Linux, Windows

### GSHHG coastline

The world coastline baked into the basemap.

- License: GNU Lesser General Public License
- Copyright: © Paul Wessel (SOEST, University of Hawaii) and Walter H. F. Smith (NOAA Laboratory for Satellite Altimetry)
- Pinned in: `vendor/gshhg/coastline.geojson.gz`
- Upstream: <https://www.soest.hawaii.edu/pwessel/gshhg/>
- Ships on: macOS, iOS, Android, Linux, Windows

Upstream states no version. Text is LGPL 3 and the GPL 3 it incorporates. Cite as: Wessel, P., and W. H. F. Smith, A Global Self-consistent, Hierarchical, High-resolution Shoreline Database, J. Geophys. Res., 101(B4), 8741-8743, 1996.

### libwebp

Decodes the WebP tiles a chart link serves.

- License: BSD 3-Clause
- Version: 1.4.0
- Copyright: © 2010 Google Inc.
- Pinned in: `charttable's build.zig.zon`
- Upstream: <https://github.com/webmproject/libwebp>
- Ships on: macOS, iOS, Android, Linux, Windows

### libpng

Reads interlaced and 16-bit PNGs.

- License: PNG Reference Library License version 2
- Version: 1.6.44
- Copyright: © 1995-2024 The PNG Reference Library Authors
- Pinned in: `charttable's build.zig.zon`
- Upstream: <https://github.com/pnggroup/libpng>
- Ships on: macOS, iOS, Android, Linux, Windows

### zlib

Deflate compression.

- License: zlib License
- Version: 1.3.1
- Copyright: © 1995-2024 Jean-loup Gailly and Mark Adler
- Pinned in: `charttable's build.zig.zon`
- Upstream: <https://github.com/madler/zlib>
- Ships on: macOS, iOS, Android, Linux, Windows

## Platform

### Vulkan headers

The Vulkan API headers the Linux and Android builds compile against.

- License: Apache 2.0
- Version: VK_HEADER_VERSION 350
- Copyright: © 2015-2026 The Khronos Group Inc.
- Pinned in: `vendor/vulkan/include/vulkan/vulkan_core.h`
- Upstream: <https://github.com/KhronosGroup/Vulkan-Headers>
- Ships on: Android, Linux

### Vulkan loader

Finds the graphics driver and dispatches every Vulkan call the chart draws with. The Linux build links the copy the system provides.

- License: Apache 2.0
- Version: the system copy
- Copyright: © The Khronos Group Inc., LunarG, Inc., Valve Corporation and the Vulkan-Loader contributors
- Pinned in: `linux/meson.build`
- Upstream: <https://github.com/KhronosGroup/Vulkan-Loader>
- Ships on: Linux

### libX11

The X11 connection the chart surface is presented on. The Linux build links the copy the system provides.

- License: MIT
- Version: the system copy
- Copyright: © The Open Group, the X.Org Foundation and the libX11 contributors
- Pinned in: `linux/meson.build`
- Upstream: <https://gitlab.freedesktop.org/xorg/lib/libx11>
- Ships on: Linux

### Wayland

The Wayland connection the chart subsurface is presented on. The Linux build links the copy the system provides.

- License: MIT
- Version: the system copy
- Copyright: © Kristian Høgsberg, Intel Corporation, Benjamin Franzke and Collabora, Ltd.
- Pinned in: `linux/meson.build`
- Upstream: <https://gitlab.freedesktop.org/wayland/wayland>
- Ships on: Linux

### GTK

The toolkit the Linux shell is built with: its windows, its controls and its input. The build links the copy the system provides.

- License: GNU Lesser General Public License version 2.1 or later
- Version: 4.10 or later
- Copyright: © The GTK Team and the GTK contributors
- Pinned in: `linux/meson.build`
- Upstream: <https://gitlab.gnome.org/GNOME/gtk>
- Ships on: Linux

### GLib

The object system, the main loop and the data structures GTK and the shell are built on. The build links the copy the system provides.

- License: GNU Lesser General Public License version 2.1 or later
- Version: 2.0 or later
- Copyright: © Peter Mattis, Spencer Kimball, Josh MacDonald and the GLib contributors
- Pinned in: `linux/meson.build`
- Upstream: <https://gitlab.gnome.org/GNOME/glib>
- Ships on: Linux

### libsoup

The HTTP client that fetches a chart link's style and its tiles. The build links the copy the system provides.

- License: GNU Lesser General Public License version 2.1 or later
- Version: 3.0 or later
- Copyright: © Ximian, Inc., Red Hat, Inc. and the libsoup contributors
- Pinned in: `linux/meson.build`
- Upstream: <https://gitlab.gnome.org/GNOME/libsoup>
- Ships on: Linux

### JSON-GLib

Writes the JSON a chart link's tile server answers with. The shell's own reader only reads. The build links the copy the system provides.

- License: GNU Lesser General Public License version 2.1 or later
- Version: 1.0 or later
- Copyright: © OpenedHand Ltd, Intel Corporation, Emmanuele Bassi and the JSON-GLib contributors
- Pinned in: `linux/meson.build`
- Upstream: <https://gitlab.gnome.org/GNOME/json-glib>
- Ships on: Linux
