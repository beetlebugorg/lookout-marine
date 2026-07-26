# Lookout Marine — Android

The Android app: a **Java shell** (plain Activity + `SurfaceView` + platform
gesture recognizers) around the Zig core (lookout + the [tile57] engine),
which cross-compiles to `aarch64-linux-android` and renders **raw Vulkan**
(`src/gpu_vk.zig`) straight onto the view's `ANativeWindow` — the exact
Android analogue of the iOS app's SwiftUI shell around the Metal core. No SDL
anywhere on mobile; SDL_GPU remains the desktop (Windows/Linux) backend.

## Layout

```
app/src/main/java/org/beetlebug/lookout/
  Lookout.java          the Java binding (handle-based, AutoCloseable) to the C ABI
  LookoutView.java      SurfaceView + GestureDetector/ScaleGestureDetector +
                        Choreographer loop (renders only when needsRedraw/animating)
  LookoutActivity.java  plain Activity: extract the chart asset, host the view
app/jni/src/CMakeLists.txt  liblookout_jni.so = --whole-archive liblookout_marine.a
                            (JNI natives inside) + libtile57.a + vulkan/log/android
app/jni/src/stub.c      JNI_OnLoad stub (the .so is otherwise all Zig archives)
app/jni/prebuilt/<abi>/ the Zig core archives (gitignored; see build-libs.sh)
app/src/main/assets/charts/  a baked tile57 chart, extracted to internal storage at first run
build-libs.sh           cross-compile the core -> app/jni/prebuilt/<abi>/
```

The JNI natives (`Java_org_beetlebug_lookout_Lookout_*`) live in the core
itself (`src/jni_android.zig`, compiled in on `-Dbackend=vk`), so the whole
native side ships as the two Zig archives. Units at the JNI boundary are
LOGICAL points (dp): Java divides pixels by `DisplayMetrics.density`; the core
derives its pixel density from surface px / resize() points.

## Build

Prerequisites: JDK 17, Android SDK (platform 35, build-tools 35, **NDK
27.2.12479018**, CMake 3.22.1), and **Zig 0.16**. Point the SDK/NDK via
`local.properties` (`sdk.dir=…`) and `ANDROID_NDK`.

```sh
./gradlew assembleDebug    # -> app/build/outputs/apk/debug/app-debug.apk
```

One step: gradle's `buildZigCore<Variant>` task runs `build-libs.sh` before the
CMake link (with the exact NDK gradle resolved from `ndkVersion`). The debug
APK compiles the core `-Doptimize=Debug` (fast iteration); release gets
ReleaseFast; override with `-PcoreOpt=<mode>`. Per ABI it runs
`zig build -Dtarget=<triple> -Dandroid-ndk=$ANDROID_NDK` (backend defaults to
vk on android) and copies `liblookout_marine.a` + `libtile57.a` into
`app/jni/prebuilt/<abi>/`. Only `arm64-v8a` is wired today (Apple-silicon
emulators + real arm64 devices); add ABIs in `app/build.gradle`'s `abiFilters`.

## Run

```sh
# a windowed arm64 emulator (drop -no-window for the phone window)
$ANDROID_HOME/emulator/emulator -avd <avd> -gpu host &
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.beetlebug.lookout/.LookoutActivity
adb logcat -s lookout   # logs
```

Gestures: one finger pans, pinch zooms about the focal point, double-tap zooms
in a level, long-press cycles day/dusk/night.

The bundled chart (`assets/charts/US5MD1MC.pmtiles`, Annapolis) is copied to
internal storage on first launch. Bake your own with
`tile57 bake <cell.000> -o out/` and drop `out/tiles/<cell>.pmtiles` into
`assets/charts/`.

> The emulator needs Hypervisor.framework (a real Mac, not a nested VM) and a
> display; a headless/CI box without those can build the APK but not run it.

[tile57]: https://github.com/beetlebugorg/tile57
