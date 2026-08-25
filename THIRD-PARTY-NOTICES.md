# Third party notices

Lookout Marine is MIT licensed. Refer to [LICENSE](LICENSE). The app carries the components below, each under its own terms.

## GSHHG

A low resolution extract of the Global Self-consistent, Hierarchical, High-resolution Geography Database, baked into the world basemap the app embeds.

Copyright Paul Wessel (SOEST, University of Hawaii) and Walter H. F. Smith (NOAA Laboratory for Satellite Altimetry). Released under the GNU Lesser General Public License. <https://www.soest.hawaii.edu/pwessel/gshhg/>

Cite as: Wessel, P., and W. H. F. Smith, A Global Self-consistent, Hierarchical, High-resolution Shoreline Database, *J. Geophys. Res.*, 101(B4), 8741-8743, 1996.

The data and the full statement are in [vendor/gshhg](vendor/gshhg/README.md).

## WebAssembly Micro Runtime

The runtime that executes the wasm plugins, linked into the core.

Copyright the Intel Corporation and the WAMR contributors. Apache License 2.0 with the LLVM exception (`Apache-2.0 WITH LLVM-exception`). Full text, including the exception, in [vendor/wamr/LICENSE](vendor/wamr/LICENSE). <https://github.com/bytecodealliance/wasm-micro-runtime>

## stb_image

PNG and JPEG decode for the sprite and raster paths.

By Sean Barrett. Dual licensed: MIT, or public domain under the Unlicense, at your option. Both texts are at the end of [vendor/stb/stb_image.h](vendor/stb/stb_image.h). <https://github.com/nothings/stb>

## Vulkan headers

The Vulkan API headers the Linux and Android builds compile against.

Copyright 2015-2026 The Khronos Group Inc. Apache License 2.0. Headers in [vendor/vulkan/include](vendor/vulkan/include). <https://github.com/KhronosGroup/Vulkan-Headers>

## IHO S-101 Portrayal Catalogue

The portrayal rules the chart is rendered with. It reaches the binary through the tile57 engine, which fetches it from <https://github.com/iho-ohi/S-101_Portrayal-Catalogue>.

Published by the International Hydrographic Organization. That repository states no license, and IHO publications are subject to the IHO's own terms.

## tile57 and charttable

The chart engine and the renderer, both compiled into the core.

Copyright 2026 Jeremy Collins. MIT. <https://github.com/beetlebugorg/tile57> and <https://github.com/beetlebugorg/charttable>
