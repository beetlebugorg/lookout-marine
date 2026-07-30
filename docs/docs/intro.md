---
id: intro
title: Lookout Marine
slug: /
sidebar_position: 0
---

# Lookout Marine

A fast, native chartplotter for Mac, iPad, iPhone, Android and Linux. It draws
official ENC charts with the IHO portrayal rules, straight to the GPU with Metal or
Vulkan, and holds 60 fps.

:::warning Not for navigation
This is a prototype. It is not pixel-perfect and it makes no claim of ECDIS
conformance.
:::

<table>
  <tr valign="top">
    <td align="center"><b>macOS</b> · SwiftUI<br /><img src="./img/macos-day.png" width="330" alt="Annapolis Harbor on macOS, day scheme" /></td>
    <td align="center"><b>Linux</b> · GTK4<br /><img src="./img/linux-day.png" width="330" alt="Annapolis Harbor on Linux, day scheme" /></td>
  </tr>
  <tr valign="top">
    <td align="center"><b>iPadOS</b> · SwiftUI<br /><img src="./img/ipad-day.png" width="230" alt="Annapolis Harbor on iPad, day scheme" /></td>
    <td align="center"><b>iOS</b> · SwiftUI<br /><img src="./img/iphone-day.png" width="160" alt="Annapolis Harbor on iPhone, day scheme" /></td>
  </tr>
</table>

## These pages

- **[Architecture](architecture.md)** — the shared Zig core, the C ABI, the GPU
  backends, and how each native shell connects to them.
- **[The Linux host (GTK4)](hosts-linux.md)** — the GTK4 shell in detail. It shows
  how the host composites the chart to make the chrome float above it. It also
  describes the two designs that failed.
- **[Screenshot protocol](screenshots.md)** — the chart, the camera, and the window
  size that each host must use. You can then compare the hosts frame by frame.

`macos/README.md` and `android/README.md` in the repository describe the Apple host
and the Android host. The chart engine has its own documentation at
[tile57](https://github.com/beetlebugorg/tile57).

To learn why the project has this structure — one core and several native shells
written by AI — refer to
[the README](https://github.com/beetlebugorg/lookout-marine#how-we-use-ai).
