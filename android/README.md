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

Homebrew's JDK is keg-only, so it is not on the PATH; gradle needs it named:

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  ./gradlew assembleDebug
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

## Plugins

Own ship, AIS targets, laylines and the NMEA 0183 / Signal K sources are wasm
modules run by the host in `src/plugin/`, which on Android is the **interpreter**
(no JIT, so no executable pages; WAMR's hardware bound check is off, so the JVM
keeps SIGSEGV). `build-libs.sh` passes `-Dplugins=true` for `arm64-v8a` and
copies `libvmlib.a` beside the two core archives; `jni/src/CMakeLists.txt` links
it when it is there, so an ABI without a `vendor/wamr-dist-android-*` archive
still builds — without the host.

The shipped set (`zig-out/plugins-bundled`) rides in the APK as assets under
`assets/plugins/`, staged by the `stageBundledPlugins` gradle task. An APK asset
has no filesystem path and the host loads a DIRECTORY, so `LookoutActivity`
extracts them to `filesDir/plugins` at first run — the same shape as the bundled
chart — and `ChartController` names that path to `lookout_plugins_load`.

There is no plugin settings pane on Android yet, so the NMEA source is addressed
from the launch intent — a developer affordance, not a mariner one:

```sh
adb reverse tcp:10110 tcp:10110    # device localhost -> the host's replay
adb shell am start -n org.beetlebug.lookout/.LookoutActivity \
  -e nmea 127.0.0.1:10110
adb logcat -s lookout | grep plugin
```

The core plugins need `android.permission.INTERNET` (a normal permission,
granted at install): without it bionic's `connect()` answers EACCES and every
source plugin sits reconnecting.

The bundled chart (`assets/charts/US5MD1MC.pmtiles`, Annapolis) is copied to
internal storage on first launch. Bake your own with
`tile57 bake <cell.000> -o out/` and drop `out/tiles/<cell>.pmtiles` into
`assets/charts/`.

> The emulator needs Hypervisor.framework (a real Mac, not a nested VM) and a
> display; a headless/CI box without those can build the APK but not run it.

[tile57]: https://github.com/beetlebugorg/tile57
