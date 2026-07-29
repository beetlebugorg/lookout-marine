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

    // Renderer backend: native on mobile, SDL on extended platforms —
    //   * metal: Apple (macOS / iOS), direct Metal
    //   * vk:    Android, direct Vulkan onto an ANativeWindow (the Java shell
    //            owns the Activity/Surface; no SDL, no SDLActivity)
    //   * sdl:   Windows / Linux (SDL_GPU: D3D12/Vulkan), also `-Dbackend=sdl`
    //            on macOS to exercise that path natively (SDL_GPU -> Metal)
    // Default by platform; see src/gpu.zig.
    const Backend = enum { metal, sdl, vk };
    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const target_android = target.result.abi == .android or target.result.abi == .androideabi;
    const backend = b.option(Backend, "backend", "renderer backend: metal | sdl | vk") orelse
        (if (is_apple) Backend.metal else if (target_android) Backend.vk else Backend.sdl);
    const use_sdl = backend == .sdl;
    const use_vk = backend == .vk;
    // vk serves Android and the desktop shells; Apple stays on metal.
    if (use_vk and is_apple)
        @panic("-Dbackend=vk targets Android, Linux and Windows; use metal on Apple");
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "gpu_sdl", use_sdl);
    build_opts.addOption(bool, "gpu_vk", use_vk);
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
        android: bool,
        apple: bool,
        windows: bool,
        sdl_include: ?[]const u8,
        build_opts_mod: *std.Build.Module,
        /// `link_tile57` adds the engine archive: always for an exe, but for a
        /// static lib only where the linker copes with it (see addObjectFile below).
        fn apply(self: @This(), mod: *std.Build.Module, link_tile57: bool) void {
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
            if (link_tile57) mod.addObjectFile(self.tile57_lib);
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
            if (!self.use_sdl and !self.use_vk) {
                // The Metal transport (ObjC behind a C face). Manual
                // retain/release on purpose — objects live in C structs.
                mod.addCSourceFile(.{ .file = bb.path("src/metal_shim.m"), .flags = &.{ "-O2", "-fno-objc-arc", "-fno-sanitize=undefined" } });
                // Metal shader source, compiled by the shim at runtime.
                mod.addAnonymousImport("metal_src", .{ .root_source_file = self.tile57_dep.path("shaders/lookout.metal") });
            }
        }
    };
    const cfg = Cfg{ .b = b, .tile57_inc = tile57_inc, .tile57_lib = tile57_lib, .tile57_dep = tile57_dep, .use_sdl = use_sdl, .use_vk = use_vk, .android = is_android, .apple = is_apple, .windows = target.result.os.tag == .windows, .sdl_include = sdl_include, .build_opts_mod = build_opts_mod };

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
    // Metal only — `!use_sdl` now also catches vk, which wants no frameworks.
    if (!use_sdl and !use_vk) {
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

    // ---- unit tests ----
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cfg.apply(test_mod, true);
    if (use_vk) test_mod.linkSystemLibrary(if (target.result.os.tag == .windows) "vulkan-1" else "vulkan", .{});
    if (!use_sdl and !use_vk) {
        test_mod.linkFramework("Metal", .{});
        test_mod.linkFramework("QuartzCore", .{});
        test_mod.linkFramework("Foundation", .{});
    }
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
