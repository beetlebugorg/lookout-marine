const std = @import("std");

// tile57 (the chart engine) is a zig package dependency — see build.zig.zon.
// A sibling checkout at ../tile57 wins (dev setups: engine edits rebuild
// live); otherwise the pinned git dependency is fetched automatically. Either
// way libtile57.a is built from source inside THIS build, and installed —
// together with tile57.h and lookout.h — into the install prefix, so the
// Xcode targets consume everything from zig-out*/ with no tile57 checkout,
// TILE57_DIR, or manual pre-build.

/// True when a sibling tile57 checkout exists next to this repo.
fn haveLocalTile57(b: *std.Build) bool {
    const probe = b.pathFromRoot("../tile57/build.zig");
    std.Io.Dir.accessAbsolute(b.graph.io, probe, .{}) catch return false;
    return true;
}

/// Where scripts/build-wamr.sh puts the wasm runtime for one target, and the
/// argument that builds it. WAMR is built by cmake, not by this build: it is a
/// large C project with its own option matrix, and the archive is a
/// machine-local artifact. Every platform and architecture pair needs its own
/// archive; `mode` is the script argument that produces this one.
const WamrDist = struct { dir: []const u8, mode: []const u8 };

fn wamrDist(target: std.Build.ResolvedTarget) ?WamrDist {
    const t = target.result;
    const android = t.abi == .android or t.abi == .androideabi;
    return switch (t.os.tag) {
        .macos => .{ .dir = "vendor/wamr-dist", .mode = "macos" },
        .ios => if (t.abi == .simulator)
            WamrDist{ .dir = "vendor/wamr-dist-iossim", .mode = "iossim" }
        else
            WamrDist{ .dir = "vendor/wamr-dist-ios", .mode = "ios" },
        // Android is os.tag .linux with an android abi, and bionic is not
        // glibc, so it takes its own archive.
        .linux => if (android) switch (t.cpu.arch) {
            .aarch64 => WamrDist{ .dir = "vendor/wamr-dist-android-arm64", .mode = "android-arm64" },
            else => null,
        } else switch (t.cpu.arch) {
            .x86_64 => WamrDist{ .dir = "vendor/wamr-dist-linux-x64", .mode = "linux-x64" },
            .aarch64 => WamrDist{ .dir = "vendor/wamr-dist-linux-arm64", .mode = "linux-arm64" },
            else => null,
        },
        // x86_64 only. windows/build-core.ps1 ships aarch64-windows-msvc, and
        // the script builds no archive for it: a mingw archive does not meet
        // an MSVC one. `scripts/build-wamr.sh windows-x64 --print-msvc` has the
        // native recipe.
        .windows => switch (t.cpu.arch) {
            .x86_64 => WamrDist{ .dir = "vendor/wamr-dist-windows-x64", .mode = "windows-x64" },
            else => null,
        },
        else => null,
    };
}

fn haveFile(b: *std.Build, rel: []const u8) bool {
    std.Io.Dir.accessAbsolute(b.graph.io, b.pathFromRoot(rel), .{}) catch return false;
    return true;
}

/// The `id` out of a plugin's manifest.json, read at configure time so the
/// installed files are named the way the host looks them up (`<id>.wasm` and
/// `<id>.manifest.json`). Falls back to the directory name, which keeps a
/// plugin buildable while its manifest is being written.
fn manifestId(b: *std.Build, dir_name: []const u8) []const u8 {
    const path = b.pathFromRoot(b.fmt("plugins/{s}/manifest.json", .{dir_name}));
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(64 * 1024)) catch
        return dir_name;
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, text, .{}) catch
        return dir_name;
    defer parsed.deinit();
    if (parsed.value != .object) return dir_name;
    return switch (parsed.value.object.get("id") orelse return dir_name) {
        .string => |s| b.dupe(s),
        else => dir_name,
    };
}

// The NDK triple for an *-linux-android target (null otherwise). Mirrors
// tile57's build.zig: the C deps need the NDK sysroot's bionic + arch headers.
fn androidTriple(target: std.Build.ResolvedTarget) ?[]const u8 {
    const t = target.result;
    if (t.abi != .android and t.abi != .androideabi) return null;
    return switch (t.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .x86 => "i686-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        else => null,
    };
}

fn ndkSysroot(b: *std.Build, ndk: []const u8) []const u8 {
    const base = b.fmt("{s}/toolchains/llvm/prebuilt", .{ndk});
    // The NDK ships one host toolchain dir. Probe the host-OS default FIRST (what
    // the NDK actually ships — e.g. darwin-x86_64 even on Apple silicon) so the
    // result is correct regardless of how accessAbsolute behaves; only fall
    // through to alternates (a future darwin-arm64 toolchain) if it's absent.
    const candidates: []const []const u8 = switch (@import("builtin").os.tag) {
        .macos => &.{ "darwin-x86_64", "darwin-arm64" },
        .windows => &.{"windows-x86_64"},
        else => &.{ "linux-x86_64", "linux-aarch64" },
    };
    for (candidates) |host| {
        const sysroot = b.fmt("{s}/{s}/sysroot", .{ base, host });
        std.Io.Dir.accessAbsolute(b.graph.io, b.fmt("{s}/usr/include", .{sysroot}), .{}) catch continue;
        return sysroot;
    }
    return b.fmt("{s}/{s}/sysroot", .{ base, candidates[0] }); // default; clear path in errors
}

fn androidLibcFile(b: *std.Build, ndk: []const u8, triple: []const u8, api: u32) std.Build.LazyPath {
    const sysroot = ndkSysroot(b, ndk);
    const content = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/{s}
        \\crt_dir={s}/usr/lib/{s}/{d}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, triple, sysroot, triple, api });
    return b.addWriteFiles().add(b.fmt("android-libc-{s}.txt", .{triple}), content);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Non-debug by default: the app chases 60 fps and a Debug core visibly
    // drops frames (and bakes/tessellates far slower). `-Doptimize=Debug` for
    // development. (Same rationale + mechanism as tile57's build.zig — NOT
    // standardOptimizeOption, which would keep the no-flag default at Debug.)
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    // Renderer backend: native everywhere —
    //   * metal: Apple (macOS / iOS), direct Metal
    //   * vk:    Android and Linux, direct Vulkan onto the shell's surface
    //   * d3d12: Windows, direct D3D12 into a composition swapchain
    //   * sdl:   the SDL_GPU fallback, `-Dbackend=sdl` anywhere
    // Default by platform; see src/gpu.zig.
    const Backend = enum { metal, sdl, vk, d3d12 };
    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const is_windows = target.result.os.tag == .windows;
    const target_android = target.result.abi == .android or target.result.abi == .androideabi;
    const backend = b.option(Backend, "backend", "renderer backend: metal | sdl | vk | d3d12") orelse
        (if (is_apple) Backend.metal else if (target_android) Backend.vk else if (is_windows) Backend.d3d12 else Backend.sdl);
    const use_sdl = backend == .sdl;
    const use_vk = backend == .vk;
    const use_d3d12 = backend == .d3d12;
    // vk serves Android and the desktop shells; Apple stays on metal.
    if (use_vk and is_apple)
        @panic("-Dbackend=vk targets Android, Linux and Windows; use metal on Apple");
    if (use_d3d12 and !is_windows)
        @panic("-Dbackend=d3d12 targets Windows only");
    // The wasm plugin host (src/plugin/). It builds for any target
    // scripts/build-wamr.sh has an archive for, and it is ON BY DEFAULT ON
    // APPLE ONLY. The Apple app links the runtime through the Xcode project
    // already; the Linux, Windows and Android shells do not name libvmlib.a in
    // their link lines yet, so a default there would break a build that works
    // today. Those targets take -Dplugins=true. Asking for it without the
    // archive is an error with the fix in it, not a silent skip.
    // iOS works because the runtime is the fast INTERPRETER: no JIT, so no
    // executable pages, and the hardware bound check is off, so no signal
    // handlers of WAMR's own. The same two settings serve Android, where the
    // JVM owns SIGSEGV.
    const wamr = wamrDist(target);
    const wamr_dir = if (wamr) |w| w.dir else "vendor/wamr-dist";
    const wamr_dist = wamr != null and haveFile(b, b.fmt("{s}/lib/libvmlib.a", .{wamr_dir}));
    const plugins_host = wamr != null;
    const want_plugins = b.option(bool, "plugins", "Build the wasm plugin host (needs the target's scripts/build-wamr.sh archive)") orelse
        (is_apple and wamr_dist);
    const plugins = want_plugins and plugins_host and wamr_dist;
    // Asked for and not possible: a build error carrying the fix, not a panic
    // and not a silent skip that would leave the host quietly missing.
    const plugins_refusal: ?[]const u8 = if (!want_plugins or plugins)
        null
    else if (wamr) |w|
        b.fmt("-Dplugins: {s}/lib/libvmlib.a is missing. Run `scripts/build-wamr.sh {s}` to build the pinned WAMR runtime for this target, then build again.", .{ w.dir, w.mode })
    else
        "-Dplugins: scripts/build-wamr.sh builds no WAMR archive for this target. It covers macos, ios, iossim, linux-x64, linux-arm64, windows-x64 and android-arm64.";
    const plugins_fail: ?*std.Build.Step = if (plugins_refusal) |msg| &b.addFail(msg).step else null;
    if (plugins_fail) |fail| b.getInstallStep().dependOn(fail);

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "gpu_sdl", use_sdl);
    build_opts.addOption(bool, "gpu_vk", use_vk);
    build_opts.addOption(bool, "gpu_d3d12", use_d3d12);
    build_opts.addOption(bool, "plugins", plugins);
    const build_opts_mod = build_opts.createModule();

    // Android cross-compile (mirrors tile57's -Dandroid-ndk): the C deps need the
    // NDK sysroot's bionic + arch headers; the SDL backend also needs SDL3 headers
    // (SDL itself is linked by the android gradle/CMake build, not here).
    const android_ndk = b.option([]const u8, "android-ndk", "Android NDK root (for -Dtarget=*-linux-android)");
    const android_api = b.option(u32, "android-api", "Android API level (default 24)") orelse 24;
    const sdl_include = b.option([]const u8, "sdl-include", "SDL3 include dir for the android sdl backend (e.g. SDL/include)");
    const android_libc: ?std.Build.LazyPath = if (androidTriple(target)) |triple|
        (if (android_ndk) |ndk| androidLibcFile(b, ndk, triple, android_api) else null)
    else
        null;
    const is_android = androidTriple(target) != null;

    const dep_args = .{ .target = target, .optimize = optimize, .@"android-ndk" = android_ndk, .@"android-api" = android_api };
    const tile57_dep = (if (haveLocalTile57(b))
        b.lazyDependency("tile57_local", dep_args)
    else
        b.lazyDependency("tile57", dep_args)) orelse
        return; // fetch scheduled; the runner downloads it and re-runs build()

    // The engine archive rides a named lazy path, not dep.artifact() — tile57's
    // default install step has a CLI executable also named `tile57`, and its
    // macOS lib install is a repacked file, not an InstallArtifact. A plain
    // map probe (vs Dependency.namedLazyPath) so the pending-fetch pass of
    // tile57's OWN lazy portrayal-catalogue dependency returns null here
    // instead of panicking; the runner then fetches and re-runs.
    const tile57_lib = tile57_dep.builder.named_lazy_paths.get("libtile57_a") orelse return;
    const tile57_inc = tile57_dep.path("include");

    const Cfg = struct {
        b: *std.Build,
        tile57_inc: std.Build.LazyPath,
        tile57_lib: std.Build.LazyPath,
        // The shaders come from the engine too (tile57 shaders/): they read the
        // vertex/quad/uniform layouts it defines, so it owns them. Two hand-synced
        // copies here — one per shading language — had already drifted.
        tile57_dep: *std.Build.Dependency,
        use_sdl: bool,
        use_vk: bool,
        use_d3d12: bool,
        android: bool,
        apple: bool,
        windows: bool,
        sdl_include: ?[]const u8,
        build_opts_mod: *std.Build.Module,
        plugins: bool,
        /// The vendor/wamr-dist* directory for this target (see wamrDist).
        wamr_dir: []const u8,
        /// `link_archives` adds the prebuilt archives (tile57, and WAMR when
        /// the plugin host is on): always for an exe, but for a static lib
        /// only where the linker copes with it (see addObjectFile below).
        fn apply(self: @This(), mod: *std.Build.Module, link_archives: bool) void {
            const bb = self.b;
            mod.addImport("build_options", self.build_opts_mod); // src/gpu.zig backend switch
            if (self.android) {
                // Neutralise bionic's nullability keywords for OUR parse: clang's
                // translate-c (@cImport of stb_image.h -> stdlib.h) rejects
                // `_Nonnull` on array params ("cannot be applied to non-pointer
                // type 'unsigned short [3]'"). Defining them empty drops the hints
                // — harmless (annotations only) and applies to C-compile + cImport.
                mod.addCMacro("_Nonnull", "");
                mod.addCMacro("_Nullable", "");
                mod.addCMacro("_Null_unspecified", "");
            }
            // Non-macOS Apple targets (-Dtarget=aarch64-ios[-simulator]) need
            // that SDK's libc AND framework headers (Metal/QuartzCore for the
            // shim): pass --sysroot; Zig only bundles macOS's.
            if (bb.sysroot) |sysroot| {
                mod.addSystemIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ sysroot, "usr/include" }) });
                mod.addSystemFrameworkPath(.{ .cwd_relative = bb.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            }
            mod.addIncludePath(self.tile57_inc);
            mod.addIncludePath(bb.path("vendor/stb"));
            mod.addIncludePath(bb.path("src")); // metal_shim.h / c_sdl.zig for the @cImport
            // Tessellation, sprite/SDF quad building and paint order all live
            // in tile57 (the GPU-scene ABI hands back draw-ready buffers), so
            // the host vendors no tessellator. stb stays for atlas PNG decode.
            // -std=gnu99: under the newer clang default, Android's bionic
            // stdlib.h `_Nonnull`-on-array declarations error; gnu99 accepts them
            // (matches tile57's C flags). Harmless for stb elsewhere.
            mod.addCSourceFile(.{ .file = bb.path("vendor/stb/stb_image_impl.c"), .flags = &.{ "-std=gnu99", "-O2", "-fno-sanitize=undefined" } });
            // Embedding an archive into a static lib nests it as a .a member: ld64
            // unpacks it (one-archive convenience on Apple), but ELF/COFF linkers
            // reject it, so off Apple the host links libtile57.a alongside (both
            // are installed to <prefix>/lib below). Exes always link it.
            if (link_archives) mod.addObjectFile(self.tile57_lib);
            if (self.plugins) {
                // WAMR: wasm_export.h for the @cImport in src/plugin/wasm.zig,
                // libvmlib.a for the interpreter itself. Both come from this
                // target's vendor/wamr-dist* dir, which scripts/build-wamr.sh
                // fills. The headers are the same on every target; the archive
                // is not.
                mod.addIncludePath(bb.path(bb.fmt("{s}/include", .{self.wamr_dir})));
                if (link_archives) mod.addObjectFile(bb.path(bb.fmt("{s}/lib/libvmlib.a", .{self.wamr_dir})));
            }
            if (self.use_sdl) {
                if (self.android) {
                    // Android: the gradle/CMake build links SDL3; here we only need
                    // its headers so c_sdl.zig's @cInclude("SDL3/SDL.h") resolves.
                    if (self.sdl_include) |inc| mod.addSystemIncludePath(.{ .cwd_relative = inc });
                } else {
                    // Native: pkg-config gives include + link.
                    mod.linkSystemLibrary("SDL3", .{});
                }
            }
            if (self.use_sdl or self.use_vk) {
                // Precompiled SPIR-V, embedded (no runtime shader toolchain).
                // Shared by both Vulkan-flavoured backends: the raw-vk pipeline
                // layout mirrors SDL_GPU's set numbering (vtx UBO set 1, frag
                // sampler set 2, frag UBO set 3), so one .spv set serves both.
                const spv = [_][2][]const u8{
                    .{ "chart_vert_spv", "shaders/vk/chart.vert.spv" },
                    .{ "chart_frag_spv", "shaders/vk/chart.frag.spv" },
                    .{ "sprite_vert_spv", "shaders/vk/sprite.vert.spv" },
                    .{ "sprite_frag_spv", "shaders/vk/sprite.frag.spv" },
                    .{ "sdf_frag_spv", "shaders/vk/sdf.frag.spv" },
                    .{ "pattern_vert_spv", "shaders/vk/pattern.vert.spv" },
                    .{ "pattern_frag_spv", "shaders/vk/pattern.frag.spv" },
                };
                for (spv) |e| mod.addAnonymousImport(e[0], .{ .root_source_file = self.tile57_dep.path(e[1]) });
            }
            if (self.use_vk and !self.android) {
                // Vendored headers only (the exe links the loader); Android uses the NDK sysroot.
                mod.addIncludePath(bb.path("vendor/vulkan/include"));
            }
            if (self.use_d3d12) {
                // The D3D12 transport (COM in C behind a C face). Shader source
                // compiled by the shim at runtime (D3DCompile).
                mod.addCSourceFile(.{ .file = bb.path("src/d3d12_shim.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
                mod.addAnonymousImport("hlsl_src", .{ .root_source_file = self.tile57_dep.path("shaders/lookout.hlsl") });
            }
            if (!self.use_sdl and !self.use_vk and !self.use_d3d12) {
                // The Metal transport (ObjC behind a C face). Manual
                // retain/release on purpose — objects live in C structs.
                mod.addCSourceFile(.{ .file = bb.path("src/metal_shim.m"), .flags = &.{ "-O2", "-fno-objc-arc", "-fno-sanitize=undefined" } });
                // Metal shader source, compiled by the shim at runtime.
                mod.addAnonymousImport("metal_src", .{ .root_source_file = self.tile57_dep.path("shaders/lookout.metal") });
            }
        }
    };
    const cfg = Cfg{ .b = b, .tile57_inc = tile57_inc, .tile57_lib = tile57_lib, .tile57_dep = tile57_dep, .use_sdl = use_sdl, .use_vk = use_vk, .use_d3d12 = use_d3d12, .android = is_android, .apple = is_apple, .windows = is_windows, .sdl_include = sdl_include, .build_opts_mod = build_opts_mod, .plugins = plugins, .wamr_dir = wamr_dir };

    // ---- the core: static library (C ABI in capi.zig -> include/lookout.h) ----
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        // iOS: std.debug's stack-trace machinery references
        // _dyld_get_image_header_containing_address, which iOS' libdyld doesn't
        // export — strip so the panic path never pulls it in.
        .strip = target.result.os.tag == .ios,
    });
    cfg.apply(lib_mod, is_apple);
    const lib = b.addLibrary(.{ .name = "lookout_marine", .linkage = .static, .root_module = lib_mod });
    if (android_libc) |libc| lib.setLibCFile(libc); // NDK sysroot for the C deps

    lib.installHeader(b.path("include/lookout.h"), "lookout.h");
    // tile57.h rides along (lookout.h includes it), so the app's header search
    // path is just <prefix>/include.
    lib.installHeader(tile57_dep.path("include/tile57.h"), "tile57.h");
    b.installArtifact(lib);
    // The engine archive lands next to liblookout_marine.a: the app links the
    // pair from one <prefix>/lib (after the ld64 loose-object repack — see
    // macos/project.yml).
    b.getInstallStep().dependOn(&b.addInstallLibFile(tile57_lib, "libtile57.a").step);
    // Archive + headers, no demo exe: what a native shell links, and all that's
    // buildable when the target's Vulkan loader isn't on this machine.
    const lib_step = b.step("lib", "Build the static core + headers only");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    lib_step.dependOn(&b.addInstallLibFile(tile57_lib, "libtile57.a").step);
    // Off Apple the static lib embeds neither archive (see addObjectFile
    // above), so the wasm runtime rides beside libtile57.a for the shell to
    // link. Nothing else in <prefix>/lib resolves the WAMR symbols.
    if (plugins and !is_apple) {
        const vmlib = b.path(b.fmt("{s}/lib/libvmlib.a", .{wamr_dir}));
        b.getInstallStep().dependOn(&b.addInstallLibFile(vmlib, "libvmlib.a").step);
        lib_step.dependOn(&b.addInstallLibFile(vmlib, "libvmlib.a").step);
    }
    // The refusal above hangs off the install step. `lib` is its own root, so
    // without this a -Dplugins with no archive builds a core that quietly has
    // no plugin host.
    if (plugins_fail) |fail| lib_step.dependOn(fail);

    // ---- the demo executable + tests (host platforms only: an iOS cross-build
    // `-Dtarget=aarch64-ios` produces just the static libs for the app to link) ----
    const cross_only = target.result.os.tag == .ios or
        target.result.abi == .android or target.result.abi == .androideabi;
    if (cross_only) return;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cfg.apply(exe_mod, true);
    // An executable resolves the Vulkan loader; the static lib leaves it open.
    if (use_vk) exe_mod.linkSystemLibrary(if (target.result.os.tag == .windows) "vulkan-1" else "vulkan", .{});
    if (use_d3d12) for ([_][]const u8{ "d3d12", "dxgi", "d3dcompiler", "dxguid" }) |l|
        exe_mod.linkSystemLibrary(l, .{});
    if (backend == .metal) {
        exe_mod.linkFramework("Metal", .{});
        exe_mod.linkFramework("QuartzCore", .{});
        exe_mod.linkFramework("Foundation", .{});
    }
    const exe = b.addExecutable(.{ .name = "lookout-marine-demo", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |a| run.addArgs(a);
    b.step("run", "Run the lookout demo").dependOn(&run.step);

    // ---- the plugin replay harness ----
    // lookout-plugin-dev: the core opened offscreen with the plugin host
    // inside it, fed a recorded NMEA log over loopback. Only buildable where
    // the plugin host is, since it drives that host directly.
    const dev_step = b.step("plugin-dev", "Build the plugin replay harness (lookout-plugin-dev)");
    if (plugins) {
        const dev_mod = b.createModule(.{
            .root_source_file = b.path("src/plugin_dev_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        cfg.apply(dev_mod, true);
        if (use_vk) dev_mod.linkSystemLibrary(if (target.result.os.tag == .windows) "vulkan-1" else "vulkan", .{});
        if (use_d3d12) for ([_][]const u8{ "d3d12", "dxgi", "d3dcompiler", "dxguid" }) |l|
            dev_mod.linkSystemLibrary(l, .{});
        if (backend == .metal) {
            dev_mod.linkFramework("Metal", .{});
            dev_mod.linkFramework("QuartzCore", .{});
            dev_mod.linkFramework("Foundation", .{});
        }
        const dev = b.addExecutable(.{ .name = "lookout-plugin-dev", .root_module = dev_mod });
        b.installArtifact(dev);
        dev_step.dependOn(&b.addInstallArtifact(dev, .{}).step);
    } else {
        // Asked for and not possible: say which of the three reasons it is,
        // the way -Dplugins does above.
        dev_step.dependOn(&b.addFail(if (!plugins_host)
            "plugin-dev: scripts/build-wamr.sh builds no WAMR archive for this target, so neither the plugin host nor this harness can be built for it."
        else if (!wamr_dist)
            b.fmt("plugin-dev: the harness needs the wasm plugin host. Run `scripts/build-wamr.sh {s}`, then build again.", .{wamr.?.mode})
        else
            "plugin-dev: the harness drives the wasm plugin host, so it cannot be built with -Dplugins=false.").step);
    }

    // ---- unit tests ----
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cfg.apply(test_mod, true);
    if (use_vk) test_mod.linkSystemLibrary(if (target.result.os.tag == .windows) "vulkan-1" else "vulkan", .{});
    if (use_d3d12) for ([_][]const u8{ "d3d12", "dxgi", "d3dcompiler", "dxguid" }) |l|
        test_mod.linkSystemLibrary(l, .{});
    if (backend == .metal) {
        test_mod.linkFramework("Metal", .{});
        test_mod.linkFramework("QuartzCore", .{});
        test_mod.linkFramework("Foundation", .{});
    }
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ---- plugin-layer unit tests ----
    // Each file rooted the way its own `zig test <file>` roots it, so what the
    // phase gate runs and what an agent runs by hand are the same compilation.
    // These do not need tile57 or a GPU, so they skip cfg.apply.
    for ([_][]const u8{
        "src/plugin/store.zig",
        "src/plugin/aisstore.zig",
        "src/overlay.zig",
        "src/plugin_dev_replay.zig",
        "plugins/nmea0183/parser.zig",
        "plugins/nmea0183/paths.zig",
        "plugins/nmea0183/config.zig",
        "plugins/ownship/track.zig",
        "plugins/ais/cpa.zig",
        "plugins/ais/vector.zig",
        "plugins/ais/config.zig",
        "plugins/ais/aton.zig",
        "plugins/laylines/geo.zig",
        // The generator's round trip re-parses the log it writes and runs the
        // ais plugin's own solver over it, so the scenario the harness replays
        // is checked by the gate here rather than only by eye in the harness.
        // It reaches parser.zig and cpa.zig through the tools/ symlinks, which
        // is why their tests appear twice in the summary.
        "tools/nmea_gen.zig",
    }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // the stores' and overlay's lock is os_unfair_lock
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }

    // ---- the wasm plugins ----
    // wasm32-freestanding, no WASI: what every plugin is built as. Exports
    // only — no _start — and rdynamic so the linker keeps them. Each plugin
    // lands in zig-out/plugins as `<id>.wasm` beside `<id>.manifest.json`,
    // which is the pair src/plugin/host.zig loads.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const lk_mod = b.createModule(.{
        .root_source_file = b.path("plugins/common/lk.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const plugins_step = b.step("plugins", "Build the wasm plugin modules into zig-out/plugins");
    // `echo` is BUILT but not installed: it is the host tests' fixture, not a
    // plugin anybody runs. Installed beside the four real ones it would be
    // loaded by the harness and draw its own symbol over own ship. The other
    // four are PROTOTYPE.md's. A name with no main.zig yet is skipped, so a
    // plugin agent adds one file and it builds.
    var echo_wasm: ?std.Build.LazyPath = null;
    // The nmea0183 module is installed like the other three AND handed to the
    // multi-connection test below.
    var nmea_wasm: ?std.Build.LazyPath = null;
    for ([_][]const u8{ "echo", "nmea0183", "ownship", "ais", "laylines" }) |name| {
        const main_rel = b.fmt("plugins/{s}/main.zig", .{name});
        if (!haveFile(b, main_rel)) continue;
        const mod = b.createModule(.{
            .root_source_file = b.path(main_rel),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        mod.addImport("lk", lk_mod);
        const wasm_exe = b.addExecutable(.{ .name = name, .root_module = mod });
        wasm_exe.entry = .disabled;
        wasm_exe.rdynamic = true;

        if (std.mem.eql(u8, name, "echo")) {
            echo_wasm = wasm_exe.getEmittedBin();
            continue;
        }
        if (std.mem.eql(u8, name, "nmea0183")) nmea_wasm = wasm_exe.getEmittedBin();

        const id = manifestId(b, name);
        plugins_step.dependOn(&b.addInstallFileWithDir(
            wasm_exe.getEmittedBin(),
            .{ .custom = "plugins" },
            b.fmt("{s}.wasm", .{id}),
        ).step);
        const manifest_rel = b.fmt("plugins/{s}/manifest.json", .{name});
        if (haveFile(b, manifest_rel)) plugins_step.dependOn(&b.addInstallFileWithDir(
            b.path(manifest_rel),
            .{ .custom = "plugins" },
            b.fmt("{s}.manifest.json", .{id}),
        ).step);
    }

    // ---- wasm plugin host smoke tests ----
    // A module built for the plugin ABI is loaded by the real embedding and
    // driven through its exports: verification-bar item 4, and the guard that
    // keeps the WAMR wiring honest.
    if (plugins) {
        const smoke_plugin_mod = b.createModule(.{
            .root_source_file = b.path("test/smoke_plugin.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        const smoke_plugin = b.addExecutable(.{ .name = "smoke_plugin", .root_module = smoke_plugin_mod });
        smoke_plugin.entry = .disabled;
        smoke_plugin.rdynamic = true;

        // The wrapper alone: the smoke test needs the runtime, not the chart
        // engine, so it skips cfg.apply and its Metal/tile57 baggage.
        const wasm_mod = b.createModule(.{
            .root_source_file = b.path("src/plugin/wasm.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        wasm_mod.addIncludePath(b.path(b.fmt("{s}/include", .{wamr_dir})));
        wasm_mod.addObjectFile(b.path(b.fmt("{s}/lib/libvmlib.a", .{wamr_dir})));

        const smoke_mod = b.createModule(.{
            .root_source_file = b.path("test/wasm_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        smoke_mod.addImport("wasm", wasm_mod);
        smoke_mod.addAnonymousImport("smoke_plugin_wasm", .{ .root_source_file = smoke_plugin.getEmittedBin() });

        const smoke_run = b.addRunArtifact(b.addTest(.{ .root_module = smoke_mod }));
        b.step("wasm-smoke", "Run the WAMR embedding smoke test").dependOn(&smoke_run.step);
        test_step.dependOn(&smoke_run.step);

        // host.zig and broker.zig import nothing above src/plugin/, so they
        // build as their own module — which is what lets the tests below use
        // them without the chart core. Rooting at host.zig picks up broker's
        // and the stores' tests too.
        const host_mod = b.createModule(.{
            .root_source_file = b.path("src/plugin/host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        host_mod.addIncludePath(b.path(b.fmt("{s}/include", .{wamr_dir})));
        host_mod.addObjectFile(b.path(b.fmt("{s}/lib/libvmlib.a", .{wamr_dir})));
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = host_mod })).step);

        // The whole plugin layer end to end: manifests, grants, the broker's
        // natives, the event loop and the overlay store, driven by the echo
        // plugin. The overlay store rides in as its own module and is wired to
        // the broker through OverlaySink.
        if (echo_wasm) |bin| {
            const ov_mod = b.createModule(.{
                .root_source_file = b.path("src/overlay.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });

            const host_smoke_mod = b.createModule(.{
                .root_source_file = b.path("test/host_smoke.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            host_smoke_mod.addImport("host", host_mod);
            host_smoke_mod.addImport("overlay", ov_mod);
            host_smoke_mod.addAnonymousImport("echo_plugin_wasm", .{ .root_source_file = bin });
            host_smoke_mod.addAnonymousImport("echo_manifest", .{ .root_source_file = b.path("plugins/echo/manifest.json") });
            // The manifests the app ships, so the test can prove the real
            // parser accepts them. A schema the parser refuses is a plugin
            // that silently does not load.
            host_smoke_mod.addAnonymousImport("nmea_manifest", .{ .root_source_file = b.path("plugins/nmea0183/manifest.json") });
            host_smoke_mod.addAnonymousImport("ais_manifest", .{ .root_source_file = b.path("plugins/ais/manifest.json") });

            const host_smoke_run = b.addRunArtifact(b.addTest(.{ .root_module = host_smoke_mod }));
            b.step("host-smoke", "Run the plugin host + broker end-to-end test").dependOn(&host_smoke_run.step);
            test_step.dependOn(&host_smoke_run.step);

            // Several connections at once: the real nmea0183 module against two
            // loopback gateways. It needs the plugin's own .wasm, which is
            // built above for installation; the LazyPath is captured there.
            if (nmea_wasm) |nbin| {
                const nmea_mod = b.createModule(.{
                    .root_source_file = b.path("test/nmea_multi.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                });
                nmea_mod.addImport("host", host_mod);
                nmea_mod.addAnonymousImport("nmea_plugin_wasm", .{ .root_source_file = nbin });
                nmea_mod.addAnonymousImport("nmea_manifest", .{ .root_source_file = b.path("plugins/nmea0183/manifest.json") });
                const nmea_run = b.addRunArtifact(b.addTest(.{ .root_module = nmea_mod }));
                b.step("nmea-multi", "Run the multi-connection nmea0183 test").dependOn(&nmea_run.step);
                test_step.dependOn(&nmea_run.step);
            }

            // Time isolation: echo beside a plugin that stops answering. Like
            // echo, the spinner is BUILT and never installed — it is a fixture
            // for this test, not something `zig build plugins` should emit.
            const spin_mod = b.createModule(.{
                .root_source_file = b.path("test/spin_plugin.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
            });
            spin_mod.addImport("lk", lk_mod);
            const spin_plugin = b.addExecutable(.{ .name = "spin_plugin", .root_module = spin_mod });
            spin_plugin.entry = .disabled;
            spin_plugin.rdynamic = true;

            const isolation_mod = b.createModule(.{
                .root_source_file = b.path("test/host_isolation.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            isolation_mod.addImport("host", host_mod);
            isolation_mod.addImport("overlay", ov_mod);
            isolation_mod.addAnonymousImport("echo_plugin_wasm", .{ .root_source_file = bin });
            isolation_mod.addAnonymousImport("echo_manifest", .{ .root_source_file = b.path("plugins/echo/manifest.json") });
            isolation_mod.addAnonymousImport("spin_plugin_wasm", .{ .root_source_file = spin_plugin.getEmittedBin() });

            const isolation_run = b.addRunArtifact(b.addTest(.{ .root_module = isolation_mod }));
            b.step("host-isolation", "Run the per-plugin thread + watchdog test").dependOn(&isolation_run.step);
            test_step.dependOn(&isolation_run.step);
        }
    }
    if (plugins_fail) |fail| test_step.dependOn(fail);
}
