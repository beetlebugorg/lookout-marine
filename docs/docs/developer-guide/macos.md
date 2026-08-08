---
id: macos
title: macOS, iPadOS and iOS
sidebar_position: 2
---

# macOS, iPadOS and iOS

One **SwiftUI** shell in `macos/` serves the three Apple platforms. The core
renders with **Metal** straight into the chart view's own `CAMetalLayer`. The
chrome is SwiftUI above it.

`AppModel`, `MarinerSettings`, `SettingsView`, the HUD, the chrome and all of
`ChartController` are platform-neutral. Only the backing view class, the display
link, the backing scale and the raw input are behind `#if os(...)`.

## Before you build

- **Xcode.** The deployment targets are macOS 14 and iOS 15.
- **Zig 0.16** and **XcodeGen** (`brew install zig xcodegen`).

tile57 is not a prerequisite. It is a Zig package dependency of the core.

## Building and running

```sh
cd macos && xcodegen generate   # writes LookoutMarine.xcodeproj from project.yml
macos/build.sh mac              # or: ios, both. Debug unless you name Release
open -n --env LOOKOUT_OPEN=<chart|folder> \
        macos/build-mac/Build/Products/Debug/LookoutMarine.app
```

`build.sh` passes `-derivedDataPath macos/build-mac`, so the products stay beside
the source and `rm -rf macos/build-mac` is a full clean. Xcode works too: point
**File ▸ Workspace Settings ▸ Derived Data** at the same folder to keep one build
tree.

The project runs `zig build` before it compiles Swift. It then repacks the Zig
archives through `libtool`, because both `ld64` and `libtool` drop Zig archive
members whose offsets are not aligned. The script extracts the members to loose
objects and packs those.

Without Xcode, `macos/build-dev.sh` builds the macOS app with the Command Line
Tools alone: `swiftc` and a hand-made bundle. It writes that bundle to the path
above. That is the one app path on disk, whichever script built it, so there is
never a stale second copy to launch by mistake.

## Environment variables

| Variable | Effect |
|---|---|
| `LOOKOUT_OPEN` | Open this chart or folder at start |
| `LOOKOUT_VIEW` | `lon,lat,zoom[,rotation]` sets the opening camera |
| `LOOKOUT_WINDOW` | `WIDTHxHEIGHT` sets the window content size (macOS) |
| `LOOKOUT_SHOW` | `settings[:tab]`, `scale`, `search` or `pick` opens that chrome |

`simctl` forwards the first two as `SIMCTL_CHILD_LOOKOUT_OPEN` and
`SIMCTL_CHILD_LOOKOUT_VIEW`.

## Why iOS needs two windows

SwiftUI's hosting view hit-tests as itself across its whole window and never
forwards touches to UIKit subviews. A gesture surface inside SwiftUI therefore
renders but hears nothing. iOS uses the UIKit lifecycle and a two-window stack:

1. **The input window.** `ChartUIView` in plain UIKit. Its backing layer is the
   chart's `CAMetalLayer`, and it owns every gesture.
2. **The chrome window.** The SwiftUI overlay in a `PassThroughWindow`. Controls
   keep their touches; everything else falls through to the chart.

A SwiftUI control has no backing view of its own, so the pass-through decision
cannot come from the view tree. The chrome writes the frames of its controls to
`ChromeHitMap`, and both platforms hit-test against that. macOS needs it as
much: without it every chrome click reached the chart.

## What to watch out for

- **FrontBoard caches scene sessions per install.** After a change to the scene
  configuration, a plain reinstall keeps the stale session and the SceneDelegate
  never connects. Uninstall first.
- **Charts arrive as files on iOS.** The picker copies a cell or a folder into
  `Documents/Charts`. Anything in the app's Documents composes into the startup
  library.
- **The rotation gesture sign** is not confirmed on a real device. That needs a
  signing team.

## Where the code lives

| File | Role |
|---|---|
| `LookoutMarineApp.swift` | `@main` App and window group; the iOS AppDelegate and SceneDelegate |
| `ChartView.swift` | The chrome layout, the macOS chart view, and the iOS gesture surface |
| `ChartController.swift` | The one `lookout*` handle, every `lookout_*` call, and the display-link loop |
| `AppModel.swift` | Shared state: open paths, recents, readouts, the coordinate and scale parsers |
| `Chrome.swift` | The chrome vocabulary: sizes, colours, bubbles, button styles, the scale bar |
| `HUDOverlay.swift` | The readout capsule, the scale entry, the pick report, the formats |
| `SettingsView.swift` | The mariner form, tabbed |
| `SettingsWindow.swift` | The macOS settings window the app owns |
| `Platform.swift` | The macOS/iOS seam and `ChromeHitMap` |
| `project.yml` | The XcodeGen target definition, with the Zig pre-build |
