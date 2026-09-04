#!/usr/bin/env bash
# Compile the shipped core plugins ahead of time, one .aot per architecture.
#
#     scripts/build-plugin-aot.sh [target]     (default: the host's)
#
# One target per run, each into its own directory:
#
#   macos-arm64    vendor/wamr-dist-aot/macos-arm64/
#   ios            vendor/wamr-dist-aot/ios/            arm64 device — SEE IOS
#   linux-x64      vendor/wamr-dist-aot/linux-x64/
#   linux-arm64    vendor/wamr-dist-aot/linux-arm64/
#   windows-x64    vendor/wamr-dist-aot/windows-x64/
#   android-arm64  vendor/wamr-dist-aot/android-arm64/
#
#   all            every target above
#
# Each holds <id>.aot for the shipped org.beetlebug plugins and an AOT_VERSION
# stamp. All are gitignored (vendor/wamr-dist-aot/).
#
# WHY ONLY THE SHIPPED SET. A .aot is native code. We ship it because we compiled it
# from a module we built, with flags we chose, on a machine we control. A
# third-party plugin package carries wasm and only wasm — an .aot inside a
# .lkplug would be native code nobody here compiled, running with no sandbox
# and no way to tell whether its bounds checks were even switched on. The host
# refuses such a package by name (host.zig, unpackToTemp) and interprets every
# third-party module. We compile, or we interpret.
#
# ONE BUILD MACHINE EMITS EVERY ARCHITECTURE. wamrc cross-compiles with
# --target=<arch>; there is no cross toolchain and no per-architecture runner
# involved, and wamrc itself is never shipped in any app.
#
# IOS. The file is produced for completeness and IS NOT KNOWN TO WORK. WAMR
# maps an AOT text section with MAP_JIT and PROT_EXEC; an App Store iOS app
# cannot get executable pages, so the load is expected to fail and the host
# falls back to the .wasm. Nothing here has been run on a device. The iOS app
# should keep shipping the interpreter until someone proves otherwise.
#
# Idempotent per target: returns at once when the directory's AOT_VERSION
# matches what this script would write now — which covers the WAMR pin, the
# wamrc flags AND a digest of the shipped .wasm inputs, so rebuilding a plugin
# invalidates its .aot. Force a rebuild with `rm -rf vendor/wamr-dist-aot/<target>`.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wamrc="$root/vendor/wamr-dist-wamrc/bin/wamrc"

# The shipped set: exactly what `zig build plugins` installs into
# zig-out/plugins-bundled, which is the set the app carries inside itself.
PLUGINS=(
    org.beetlebug.ais
    org.beetlebug.aiscast
    org.beetlebug.laylines
    org.beetlebug.nmea0183
    org.beetlebug.ownship
    org.beetlebug.signalk
)
WASM_DIR="$root/zig-out/plugins-bundled"

usage="usage: ${BASH_SOURCE[0]##*/} [macos-arm64|ios|linux-x64|linux-arm64|windows-x64|android-arm64|all]"

host_target() {
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)  echo macos-arm64 ;;
        Linux-x86_64)  echo linux-x64 ;;
        Linux-aarch64) echo linux-arm64 ;;
        *) return 1 ;;
    esac
}

target="${1:-$(host_target || true)}"
[ -n "$target" ] || { echo "build-plugin-aot.sh: no default target for $(uname -s)-$(uname -m)"; echo "$usage" >&2; exit 2; }
case "$target" in
    macos-arm64|ios|linux-x64|linux-arm64|windows-x64|android-arm64) targets=("$target") ;;
    all) targets=(macos-arm64 ios linux-x64 linux-arm64 windows-x64 android-arm64) ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "$usage" >&2; exit 2; }

# ---- the flags, and why each one is here ----
#
# These are not defaults. Every one of them exists because the runtime
# scripts/build-wamr.sh builds is not the runtime wamrc assumes, and an .aot
# that disagrees with its runtime is either refused at load or — for the first
# flag — silently unsafe.
#
#   --bounds-checks=1
#       THE IMPORTANT ONE. wamrc defaults this to 0 on a 64-bit target: it
#       assumes the runtime reserves an 8 GiB guard region around linear memory
#       and catches an out-of-range access as a SIGSEGV. This project builds
#       WAMR with WAMR_DISABLE_HW_BOUND_CHECK=1 — no guard region, no signal
#       handler — for the reasons in build-wamr.sh. With the default, wamrc's
#       own help says it "enables some optimisations which make the compiled
#       AOT module incompatible with a runtime without the hardware bounds
#       checks": the emitted code has NO check of any kind, and a plugin's
#       out-of-range store becomes a store into host memory. Nothing in the
#       AOT file records this setting and nothing in the loader checks it, so
#       there is no error to see — just a plugin that is no longer sandboxed.
#       =1 emits the software check, the same one the interpreter does.
#       --stack-bounds-checks follows --bounds-checks when it is not given, so
#       the native stack check is on for the same reason.
#
#   --enable-multi-thread
#       THE WATCHDOG. It reads as a threading flag and it is not one here: it
#       sets the compiler's enable_thread_mgr, and that is the only thing that
#       makes the AOT code emit a suspend-flag test at loop back edges and
#       calls (aot_emit_control.c, check_suspend_flags). Without it,
#       wasm_runtime_terminate has nothing to interrupt and a core plugin
#       spinning in a `while (true)` would never come back — the watchdog in
#       host.zig would fire and nothing would happen. It matches the runtime's
#       WAMR_BUILD_THREAD_MGR=1. It does NOT enable shared memory or pthreads;
#       it turns on bulk memory, which is on in the runtime anyway.
#
#   --disable-simd
#       The runtime is built WAMR_BUILD_SIMD=0. wamrc enables SIMD by default
#       and stamps WASM_FEATURE_SIMD_128BIT into the file, which the loader
#       refuses outright ("SIMD is not enabled in this build"). Nothing we
#       build emits SIMD, so this costs nothing.
#
#   --enable-extended-const
#       The Zig wasm32 default CPU (lime1) emits extended const expressions in
#       data segment offsets, and the runtime is built to accept them
#       (WAMR_BUILD_EXTENDED_CONST_EXPR=1). wamrc's wasm front end rejects them
#       without this.
#
#   --target=<arch> [--target-abi=<abi>]
#       Explicit ALWAYS, even for this host's own architecture. Given no
#       --target, wamrc on macOS bakes in the host CPU (`target cpu: apple-m1`)
#       and the file stops being a generic arm64 file. Given --target, the cpu
#       is left generic. The ABI is spelled out for the same reason: on macOS
#       wamrc silently picks `gnu` to avoid emitting Mach-O, which the AOT
#       loader cannot read, and a flag we depend on should be visible.
#
# Left at their defaults, deliberately: --opt-level=3 --size-level=3, ref
# types on (the runtime has them), GC and tail call off (the runtime has
# neither), the auxiliary stack check on.
AOT_FLAGS=(
    --bounds-checks=1
    --enable-multi-thread
    --disable-simd
    --enable-extended-const
)
# Names the flag set in the stamp. Bump it whenever AOT_FLAGS changes, for the
# same reason WAMR_FEATURES exists in build-wamr.sh: a file compiled under the
# old flags is indistinguishable from a current one by looking at it.
AOT_FLAGS_ID="swbounds+threadmgr+nosimd+extconst"

# Each target names the ARCHITECTURE the code is for, the ABI it must use, and
# the WAMR runtime dist it has to agree with.
#
#   aarch64 covers four of the six. The AOT file holds a relocatable ELF object
#   that WAMR's own loader relocates, so the operating system does not enter
#   into it; what has to match is the machine and the C calling convention the
#   generated code uses to reach the runtime's native symbols, and AAPCS64 is
#   AAPCS64 on Darwin, Linux and Android alike. The four files come out
#   byte-identical today. They are kept apart anyway, because they are stamped
#   against four different runtime archives and the day one of them diverges
#   is not a day to discover that they shared a directory.
#
#   windows-x64 is the exception that proves it: same machine as linux-x64,
#   different calling convention, so --target-abi=msvc.
aot_target() {
    case "$1" in
        macos-arm64)   echo "aarch64 gnu  wamr-dist" ;;
        ios)           echo "aarch64 gnu  wamr-dist-ios" ;;
        linux-arm64)   echo "aarch64 gnu  wamr-dist-linux-arm64" ;;
        android-arm64) echo "aarch64 gnu  wamr-dist-android-arm64" ;;
        linux-x64)     echo "x86_64  gnu  wamr-dist-linux-x64" ;;
        windows-x64)   echo "x86_64  msvc wamr-dist-windows-x64" ;;
    esac
}

sha_of() { shasum -a 256 "$@" 2>/dev/null || sha256sum "$@"; }

[ -x "$wamrc" ] || {
    echo "build-plugin-aot.sh: $wamrc is not there." >&2
    echo "                     Run scripts/build-wamr.sh wamrc first." >&2
    exit 1
}

build_one() {
    local t="$1" arch abi distname dist stamp inputs_sha out id
    read -r arch abi distname <<<"$(aot_target "$t")"
    dist="$root/vendor/wamr-dist"
    [ "$distname" = "wamr-dist" ] || dist="$root/vendor/$distname"

    # THE RUNTIME ARCHIVE IS THE AUTHORITY. The stamp an .aot carries is the
    # stamp of the runtime it was compiled to run under, read from that
    # runtime's own WAMR_VERSION rather than repeated here. So there is no
    # second copy of the WAMR pin to drift, and an .aot cannot be produced for
    # a target whose runtime has not been built — which is exactly the pairing
    # the host checks at load time.
    local runtime_stamp
    runtime_stamp=$(cat "$dist/WAMR_VERSION" 2>/dev/null || true)
    [ -n "$runtime_stamp" ] || {
        echo "build-plugin-aot.sh: ${dist#$root/}/WAMR_VERSION is missing, and an .aot is" >&2
        echo "                     tied to the WAMR build it will run under." >&2
        echo "                     Run scripts/build-wamr.sh for that target first." >&2
        exit 1
    }
    case "$runtime_stamp" in
        *aot*) ;;
        *) echo "build-plugin-aot.sh: ${dist#$root/} is '$runtime_stamp' — a runtime with no" >&2
           echo "                     AOT loader. Re-run scripts/build-wamr.sh for it." >&2
           exit 1 ;;
    esac
    # Drop the runtime's own target word (the last field): macos-arm64 and ios
    # are different .aot targets built against different archives, but what the
    # host compares is the WAMR release, commit and feature set.
    local wamr_key
    wamr_key=$(echo "$runtime_stamp" | awk '{print $1, $2, $3}')

    local -a wasm=()
    for id in "${PLUGINS[@]}"; do
        [ -f "$WASM_DIR/$id.wasm" ] || {
            echo "build-plugin-aot.sh: ${WASM_DIR#$root/}/$id.wasm is missing." >&2
            echo "                     Run \`zig build plugins\` first." >&2
            exit 1
        }
        wasm+=("$WASM_DIR/$id.wasm")
    done
    inputs_sha=$(sha_of "${wasm[@]}" | sha_of | cut -c1-16)

    local outdir="$root/vendor/wamr-dist-aot/$t"
    stamp="$wamr_key $AOT_FLAGS_ID $t $inputs_sha"
    if [ -f "$outdir/AOT_VERSION" ] && [ "$(cat "$outdir/AOT_VERSION")" = "$stamp" ]; then
        echo "aot: ${outdir#$root/} already built ($stamp)"
        return 0
    fi

    echo "aot: compiling ${#PLUGINS[@]} plugins for $t (--target=$arch --target-abi=$abi)"
    local tmp="$outdir.tmp"
    rm -rf "$tmp"; mkdir -p "$tmp"
    for id in "${PLUGINS[@]}"; do
        out="$tmp/$id.aot"
        if ! "$wamrc" --target="$arch" --target-abi="$abi" "${AOT_FLAGS[@]}" \
             -o "$out" "$WASM_DIR/$id.wasm" >"$tmp/$id.log" 2>&1
        then
            cat "$tmp/$id.log" >&2
            echo "build-plugin-aot.sh: wamrc failed on $id for $t" >&2
            exit 1
        fi
        rm -f "$tmp/$id.log"
        echo "aot:   $id.aot ($(du -h "$out" | cut -f1) from $(du -h "$WASM_DIR/$id.wasm" | cut -f1) of wasm)"
    done
    echo "$stamp" >"$tmp/AOT_VERSION"
    rm -rf "$outdir"
    mkdir -p "$(dirname "$outdir")"
    mv "$tmp" "$outdir"
    echo "aot: ${outdir#$root/} ($stamp)"
}

for t in "${targets[@]}"; do build_one "$t"; done

# The host's own set goes in beside the modules, because that is where the host
# looks: `<id>.aot` next to `<id>.wasm`, with the directory's AOT_VERSION
# saying which WAMR build it belongs to. A shell copies zig-out/plugins-bundled
# whole, so its platform's .aot travels with it and nothing else has to know.
# The other targets stay in vendor/wamr-dist-aot/ for the platform that packages
# them.
#
# INSTALLING IS OPT IN, through LOOKOUT_AOT_INSTALL=1. The files wamrc produces
# here are compiled for an architecture and an ABI with no platform in them, so
# their code uses registers that Darwin, iOS, Android and Windows on arm64
# reserve for the platform. `load_aot_modules` in src/plugin/host.zig is the
# matching gate and is off, so an installed file is read by nothing until both
# are turned on together.
host="$(host_target || true)"
if [ "${LOOKOUT_AOT_INSTALL:-0}" != "1" ]; then
    echo "aot: vendor/wamr-dist-aot only; set LOOKOUT_AOT_INSTALL=1 to copy the"
    echo "aot: $host set beside the modules in zig-out (see load_aot_modules)."
    exit 0
fi
for t in "${targets[@]}"; do
    [ "$t" = "$host" ] || continue
    for d in "$root/zig-out/plugins" "$root/zig-out/plugins-bundled"; do
        [ -d "$d" ] || continue
        cp "$root/vendor/wamr-dist-aot/$t"/*.aot "$root/vendor/wamr-dist-aot/$t/AOT_VERSION" "$d/"
        echo "aot: installed the $t set into ${d#$root/}"
    done
done
