# Lookout Marine — Android

The Android build of the chartplotter. The Zig core (lookout + the [tile57]
engine) cross-compiles to `aarch64-linux-android` and renders through the
**SDL_GPU / Vulkan** backend (`src/gpu_sdl.zig`); a small native shell
(`app/jni/src/main.c`) is SDL's `SDL_main` and drives the lookout C ABI.

## Layout

```
app/jni/SDL/            SDL3 (git submodule, release-3.4.12) — built from source by gradle
app/jni/CMakeLists.txt  add_subdirectory(SDL) + src
app/jni/src/main.c      the app shell: extract the chart, lookout_open(window), event loop
app/jni/src/CMakeLists.txt   libmain.so = main.c + prebuilt liblookout_marine.a + libtile57.a + SDL3
app/jni/include/        lookout.h + tile57.h (C ABI)
app/jni/prebuilt/<abi>/ the Zig core archives (gitignored; see build-libs.sh)
app/src/main/assets/charts/  a baked tile57 chart, extracted to internal storage at first run
build-libs.sh           cross-compile the core -> app/jni/prebuilt/<abi>/
```

## Build

Prerequisites: JDK 17, Android SDK (platform 35, build-tools 35, **NDK
27.2.12479018**, CMake 3.22.1), and **Zig 0.16**. Point the SDK/NDK via
`local.properties` (`sdk.dir=…`) and `ANDROID_NDK`.

```sh
git submodule update --init app/jni/SDL      # SDL3 source (once)
./gradlew assembleDebug                       # -> app/build/outputs/apk/debug/app-debug.apk
```

Gradle's `buildZigCore` task runs `build-libs.sh` automatically before the CMake
link (with the exact NDK gradle resolved from `ndkVersion`), so `assembleDebug`
rebuilds the Zig core too — no separate step. `build-libs.sh` runs, per ABI:
`zig build -Dtarget=<triple> -Dandroid-ndk=$ANDROID_NDK -Dsdl-include=app/jni/SDL/include`
and copies `liblookout_marine.a` + `libtile57.a` into `app/jni/prebuilt/<abi>/`.
Only `arm64-v8a` is wired today (Apple-silicon emulators + real arm64 devices);
add ABIs in `app/build.gradle`'s `abiFilters` (passed to `build-libs.sh` as
`ABIS`). Run `./build-libs.sh` by hand only to cross-compile the core outside a
gradle build.

## Run

```sh
# a windowed arm64 emulator (drop -no-window for the phone window)
$ANDROID_HOME/emulator/emulator -avd <avd> -gpu host &
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.beetlebug.lookout/.LookoutActivity
adb logcat -s SDL lookout   # logs
```

The bundled chart (`assets/charts/US5MD1MC.pmtiles`, Annapolis) is copied to
internal storage on first launch and opened via `lookout_open` (SDL_GPU creates
the window bound to the Activity surface + a Vulkan device). Bake your own with
`tile57 bake <cell.000> -o out/` and drop `out/tiles/<cell>.pmtiles` into
`assets/charts/`.

> The emulator needs Hypervisor.framework (a real Mac, not a nested VM) and a
> display; a headless/CI box without those can build the APK but not run it.

[tile57]: https://github.com/beetlebugorg/tile57
