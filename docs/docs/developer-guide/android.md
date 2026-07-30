---
id: android
title: Android
sidebar_position: 5
---

# Android

A **Java shell** — a plain Activity, a `SurfaceView` and the platform gesture
detectors — around the Zig core. The core cross-compiles to
`aarch64-linux-android` and renders **raw Vulkan** (`src/gpu_vk.zig`) onto the
view's `ANativeWindow`. The chrome above it is Compose.

The JNI natives (`Java_org_beetlebug_lookout_Lookout_*`) live in the core
itself (`src/jni_android.zig`, compiled in with `-Dbackend=vk`), so the whole
native side ships as two Zig archives.

Units at the JNI boundary are logical points. Java divides pixels by
`DisplayMetrics.density`, and the core derives its pixel density from the
surface pixels and the size in points that `resize()` states.

## Prerequisites

- **JDK 17**, the **Android SDK** (platform 35, build-tools 35, NDK
  27.2.12479018, CMake 3.22.1) and **Zig 0.16**.
- Set `sdk.dir` in `local.properties` and `ANDROID_NDK` in the environment.

## Build and run

```sh
cd android
./gradlew assembleDebug         # -> app/build/outputs/apk/debug/app-debug.apk

$ANDROID_HOME/emulator/emulator -avd <avd> -gpu host &
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.beetlebug.lookout/.LookoutActivity
adb logcat -s lookout
```

Gradle's `buildZigCore<Variant>` task runs `build-libs.sh` before the CMake
link, with the NDK that `ndkVersion` resolves. A debug APK compiles the core
`-Doptimize=Debug` for fast iteration; release gets ReleaseFast. Override with
`-PcoreOpt=<mode>`.

Only `arm64-v8a` is wired today, which covers Apple-silicon emulators and real
arm64 devices. Add ABIs in `abiFilters` in `app/build.gradle`.

## Gestures

One finger pans, a pinch zooms about the focal point, a twist rotates past an
18 degree dead zone, a double tap zooms in, a tap identifies, and a long press
steps through day, dusk and night.

## Charts

The app ships a baked cell (`assets/charts/US5MD1MC.pmtiles`, Annapolis) and
copies it to internal storage at the first launch. Bake your own with
`tile57 bake <cell.000> -o out/` and drop `out/tiles/<cell>.pmtiles` into
`assets/charts/`, or add a folder in the Charts tab.

## Files

| File | Role |
|---|---|
| `Lookout.java` | The handle-based Java binding to the C ABI |
| `LookoutView.java` | `SurfaceView`, the gesture detectors, and a Choreographer loop that runs only when the scene is dirty |
| `LookoutActivity.kt` | The Activity: chart assets, then the Compose chrome over the view |
| `ChartScreen.kt` | The chrome layout |
| `ChartController.kt` | The one handle and every call into it |
| `Hud.kt` | The readouts, the compass and the pick report |
| `SettingsSheet.kt` | The mariner form |
| `app/jni/src/CMakeLists.txt` | `liblookout_jni.so`: the two Zig archives plus vulkan, log and android |
| `build-libs.sh` | Cross-compiles the core into `app/jni/prebuilt/<abi>/` |

## Caution

The emulator needs Hypervisor.framework, which means a real Mac and not a
nested VM, and it needs a display. A headless box can build the APK but cannot
run it.
