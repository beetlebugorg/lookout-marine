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
    ( cd "$core" && zig build -Dtarget="$triple" -Doptimize="$OPT" -Dandroid-ndk="$NDK" )
    dest="$here/app/jni/prebuilt/$abi"
    mkdir -p "$dest"
    # On android liblookout doesn't embed tile57 (nested .a breaks ld.lld), so
    # ship both archives; CMake links liblookout then libtile57.
    cp "$core/zig-out/lib/liblookout_marine.a" "$core/zig-out/lib/libtile57.a" "$dest/"
    # sanity: must be an AArch64/x86-64 ELF archive, never a native Mach-O one
    python3 - "$dest/liblookout_marine.a" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"\x7fELF")
assert i >= 0, "not an ELF archive (a native macOS build leaked in?)"
print("   ok:", {0xb7: "AArch64", 0x3e: "x86-64"}.get(int.from_bytes(d[i+18:i+20], "little"), "?"))
PY
done
echo "done -> app/jni/prebuilt/"
