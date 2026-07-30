---
id: building
title: Building
sidebar_position: 2
---

# Building

Each shell builds the core first, then itself. The core needs **Zig 0.16**. The
tile57 engine is a Zig package dependency: the build uses a sibling `../tile57`
checkout when there is one, and otherwise fetches the commit that
`build.zig.zon` pins.

## Core alone

```sh
zig build                       # the host default backend -> zig-out/
zig build lib -Dbackend=vk      # one backend only
zig build test                  # the camera and geometry tests
```

`zig build` installs `liblookout_marine.a`, `libtile57.a`, `lookout.h` and
`tile57.h` into `zig-out/`. A cross build installs into `zig-out-<platform>/`.

## macOS, iPadOS and iOS

Prerequisites: Xcode (macOS 14 and iOS 15 deployment targets), Zig, and
XcodeGen.

```sh
cd macos && xcodegen generate   # writes LookoutMarine.xcodeproj from project.yml
macos/build.sh mac              # or: ios, both. Debug unless you name Release
```

`build.sh` builds with `-derivedDataPath macos/build-mac`, so the products stay
beside the source:

```
macos/build-mac/Build/Products/Debug/LookoutMarine.app
macos/build-mac/Build/Products/Debug-iphonesimulator/LookoutMarine.app
```

The project runs `zig build` before it compiles Swift, and repacks the Zig
archives through `libtool`. Both `ld64` and `libtool` drop Zig archive members
whose offsets are not aligned, so the script extracts the members to loose
objects and packs those.

Xcode also works: open the project and run. Point **File ▸ Workspace Settings ▸
Derived Data** at `macos/build-mac` to keep one build tree.

Without Xcode, `macos/build-dev.sh` builds the macOS app with the Command Line
Tools alone.

Three environment variables help dev runs and screenshots:

| Variable | Effect |
|---|---|
| `LOOKOUT_OPEN` | Open this chart or folder at start |
| `LOOKOUT_VIEW` | `lon,lat,zoom[,rotation]` — the opening camera |
| `LOOKOUT_WINDOW` | `WIDTHxHEIGHT` — the window content size (macOS) |
| `LOOKOUT_SHOW` | `settings`, `scale`, `search` — open that chrome at start (macOS) |

`simctl` forwards the first two as `SIMCTL_CHILD_LOOKOUT_OPEN` and
`SIMCTL_CHILD_LOOKOUT_VIEW`.

## Linux

```sh
cd linux
meson setup build
ninja -C build
./build/lookout-marine
```

`meson` drives `build-core.sh`, which runs `zig build lib -Dbackend=vk`.

## Windows

```powershell
pwsh windows/build-core.ps1     # zig build lib -Dbackend=d3d12 -> ../zig-out
cd windows
msbuild LookoutMarine.vcxproj -t:Restore /p:Configuration=Release /p:Platform=ARM64
msbuild LookoutMarine.vcxproj /p:Configuration=Release /p:Platform=ARM64
.\ARM64\Release\LookoutMarine.exe
```

## Android

Prerequisites: JDK 17, the Android SDK (platform 35, build-tools 35, NDK
27.2.12479018, CMake 3.22.1) and Zig. Set `sdk.dir` in `local.properties` and
`ANDROID_NDK` in the environment.

```sh
cd android
./gradlew assembleDebug         # -> app/build/outputs/apk/debug/app-debug.apk
```

## Headless

`lookout-marine-demo` renders without a window. It is the parity and smoke-test
tool, not the app.

```sh
./zig-out/bin/lookout-marine-demo chart.pmtiles [--png out.png] [--lon L --lat L --zoom Z]
```
