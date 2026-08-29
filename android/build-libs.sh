#!/usr/bin/env bash
# Cross-compile the Zig core (lookout + tile57, raw-Vulkan backend + JNI
# natives) for Android and drop the archives where the gradle/CMake build links
# them (app/jni/prebuilt/<abi>/). Gradle's buildZigCore task runs this
# automatically; run by hand only to cross-build outside gradle.
#
# Needs: the Android NDK (ANDROID_NDK or the default sdkmanager path).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
core="$(cd "$here/.." && pwd)"

# Locate the NDK: explicit env, else the highest ndk/<version> under a known SDK
# root (Android Studio, Homebrew cmdline-tools, Linux). Fail loudly rather than
# passing a bad path (which yields cryptic "stdio.h file not found" C errors).
find_ndk() {
    for d in "${ANDROID_NDK:-}" "${ANDROID_NDK_HOME:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return 0; }
    done
    for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
                "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" \
                "/opt/homebrew/share/android-commandlinetools" \
                "/usr/local/share/android-commandlinetools"; do
        [ -n "$root" ] || continue
        if [ -d "$root/ndk" ]; then
            local v
            v="$(ls -1 "$root/ndk" 2>/dev/null | sort -V | tail -1)"
            [ -n "$v" ] && [ -d "$root/ndk/$v" ] && { echo "$root/ndk/$v"; return 0; }
        fi
        [ -d "$root/ndk-bundle" ] && { echo "$root/ndk-bundle"; return 0; }
    done
    return 1
}
NDK="$(find_ndk)" || {
    echo "error: Android NDK not found. Set ANDROID_NDK=/path/to/ndk/<version> (or" >&2
    echo "       install one: sdkmanager 'ndk;27.2.12479018')." >&2
    exit 1
}
echo "using NDK: $NDK"

# ABIs to build (space-separated). macOS ships bash 3.2 — no associative arrays.
ABIS="${ABIS:-arm64-v8a}"
# Zig optimize mode. Debug compiles ~2.4x faster but runs ~8.7x slower in compose,
# so gradle passes ReleaseFast for both APKs; OPT= overrides from the CLI.
OPT="${OPT:-ReleaseFast}"

# The wasm plugin host. Own ship, AIS targets, laylines and the two source
# plugins are wasm modules, so an APK without the host is a chartplotter with
# no boat and no traffic: it loads nothing and says so in the log.
#
# WAMR is a vendored C tree with no build output in git, so the archive is
# built here on the first run rather than left as a step to remember. It takes
# about a minute once; after that the file is there and this is a test.
# WAMR=0 skips it, for a build that deliberately ships no plugins.
WAMR="${WAMR:-1}"
wamr_lib="$core/vendor/wamr-dist-android-arm64/lib/libvmlib.a"
case " $ABIS " in
    *" arm64-v8a "*)
        if [ "$WAMR" = 1 ] && [ ! -f "$wamr_lib" ]; then
            echo ">> building the wasm plugin host (once)"
            "$core/scripts/build-wamr.sh" android-arm64
        fi
        ;;
esac

abi_triple() {
    case "$1" in
        arm64-v8a) echo "aarch64-linux-android" ;;
        x86_64)    echo "x86_64-linux-android" ;;
        armeabi-v7a) echo "arm-linux-androideabi" ;;
        x86)       echo "i686-linux-android" ;;
        *) echo "unknown abi: $1" >&2; exit 1 ;;
    esac
}

for abi in $ABIS; do
    triple="$(abi_triple "$abi")"
    echo ">> building core for $abi ($triple) [$OPT]"
    # backend defaults to vk on *-linux-android (raw Vulkan; no SDL anywhere)
    #
    # -Dplugins: the wasm plugin host. Off by default everywhere but Apple
    # (build.zig's note: the non-Apple shells didn't name libvmlib.a in their
    # link lines), so android asks for it explicitly and the CMake link below
    # carries the third archive. Only arm64 has a WAMR archive
    # (vendor/wamr-dist-android-arm64), so another ABI must build without it.
    plugins=false
    [ "$abi" = "arm64-v8a" ] && [ -f "$wamr_lib" ] && plugins=true
    # Its OWN install prefix, per ABI, the way the iOS build phases use
    # zig-out-$PLATFORM_NAME. The default zig-out is where a NATIVE `zig build`
    # also installs, so a desktop build running at the same time (an editor, a
    # test run, another checkout task) overwrites liblookout_marine.a between
    # this build and the copy below — the archive then links as Mach-O and the
    # ELF check at the foot of this loop is what catches it. Separate prefixes
    # make the two builds independent instead of racing.
    prefix="$core/zig-out-android-$abi"
    ( cd "$core" && zig build -Dtarget="$triple" -Doptimize="$OPT" -Dandroid-ndk="$NDK" -Dplugins="$plugins" -p "$prefix" )
    dest="$here/app/jni/prebuilt/$abi"
    mkdir -p "$dest"
    # On android liblookout doesn't embed tile57 (nested .a breaks ld.lld), so
    # ship both archives; CMake links liblookout then libtile57.
    cp "$prefix/lib/liblookout_marine.a" "$prefix/lib/libtile57.a" "$dest/"
    # Same reason for the wasm runtime: off Apple the static core embeds no
    # archive, so libvmlib.a rides along and CMake links it third. A stale copy
    # from an earlier plugins=true build would otherwise linger and link.
    rm -f "$dest/libvmlib.a"
    [ "$plugins" = true ] && cp "$prefix/lib/libvmlib.a" "$dest/"
    # CMake decides whether to link the runtime with if(EXISTS ...), and that is
    # a CONFIGURE-TIME test: a cache written when the archive was absent goes on
    # linking without it, and the core's wasm_* symbols come out undefined at
    # the link. So when the answer changes, drop the cache and configure again.
    marker="$dest/.plugins"
    if [ "$(cat "$marker" 2>/dev/null || echo)" != "$plugins" ]; then
        rm -rf "$here/app/.cxx"
        echo "$plugins" > "$marker"
    fi
    # sanity: must be an AArch64/x86-64 ELF archive, never a native Mach-O one.
    # llvm-objdump reports the first member's format, and it ships with the NDK
    # this script already requires.
    objdump="$(echo "$NDK"/toolchains/llvm/prebuilt/*/bin/llvm-objdump)"
    fmt="$("$objdump" -f "$dest/liblookout_marine.a" 2>/dev/null |
        sed -n 's/.*file format \([a-z0-9-]*\).*/\1/p' | head -1)"
    case "$fmt" in
        elf64-littleaarch64) echo "   ok: AArch64" ;;
        elf64-x86-64)        echo "   ok: x86-64" ;;
        elf*)                echo "   ok: $fmt" ;;
        "") echo "error: cannot read $dest/liblookout_marine.a" >&2; exit 1 ;;
        *)  echo "error: $fmt, not an ELF archive (a native macOS build leaked in?)" >&2; exit 1 ;;
    esac
done
echo "done -> app/jni/prebuilt/"
