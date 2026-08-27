const std = @import("std");

// tile57 (the chart engine) is a zig package dependency — see build.zig.zon.
// A sibling checkout at ../tile57 wins (dev setups: engine edits rebuild
// live); otherwise the pinned git dependency is fetched automatically. Either
// way libtile57.a is built from source inside THIS build, and installed —
// together with tile57.h and lookout.h — into the install prefix, so the
// Xcode targets consume everything from zig-out*/ with no tile57 checkout,
// TILE57_DIR, or manual pre-build.

/// True when a sibling checkout of `name` exists next to this repo.
fn haveLocalDep(b: *std.Build, comptime name: []const u8) bool {
    const probe = b.pathFromRoot("../" ++ name ++ "/build.zig");
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
        // The x64 dist holds whichever ABI was written last (mingw cross or
        // the --print-msvc native recipe); the arm64 one is always MSVC ABI,
        // built on the ARM64 Windows machine itself (`bash
        // scripts/build-wamr.sh windows-arm64` under Git Bash).
        .windows => switch (t.cpu.arch) {
            .x86_64 => WamrDist{ .dir = "vendor/wamr-dist-windows-x64", .mode = "windows-x64" },
            .aarch64 => WamrDist{ .dir = "vendor/wamr-dist-windows-arm64", .mode = "windows-arm64" },
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

/// True when `text` declares a test at top level. zig fmt puts every one of
/// them at column 0, so a line prefix finds them all. The three spellings are
/// a named test, an anonymous one, and one named after a declaration.
fn carriesTests(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "test")) continue;
        if (line.len > 4 and (line[4] == ' ' or line[4] == '{' or line[4] == '"')) return true;
    }
    return false;
}

/// Fail the test step for any .zig under src/, plugins/, test/ or tools/ that
/// carries tests and appears on neither list.
///
/// A Zig test build collects a file's tests only when it ANALYSES that file,
/// and reaching a type through a re-export does not analyse the file it came
/// from. So a file can carry tests that nothing ever runs while every build
/// and every gate stays green, which is silent and has happened. Naming every
/// test-bearing file turns the next one into a build error with the fix in it.
///
/// Only those four trees are scanned: that is where code lives. Symlinked
/// directories (tools/) are not descended into, so the files under them are
/// seen once, under their real path.
fn checkTestCoverage(b: *std.Build, step: *std.Build.Step, roots: []const []const u8, reached: []const []const u8) void {
    const io = b.graph.io;
    for ([_][]const u8{ "src", "plugins", "test", "tools" }) |tree| {
        var dir = std.Io.Dir.cwd().openDir(io, b.pathFromRoot(tree), .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = dir.walk(b.allocator) catch continue;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            // The walker yields entry.path with the PLATFORM separator, and
            // both declared lists are written with '/'. Left as-is every file
            // under a subdirectory compares unequal on Windows, so every one
            // of them is reported as uncollected and the test step never runs.
            const rel = b.fmt("{s}/{s}", .{ tree, entry.path });
            std.mem.replaceScalar(u8, rel, '\\', '/');
            const text = std.Io.Dir.cwd().readFileAlloc(io, b.pathFromRoot(rel), b.allocator, .limited(4 * 1024 * 1024)) catch continue;
            if (!carriesTests(text)) continue;
            var declared = false;
            for (roots) |p| declared = declared or std.mem.eql(u8, p, rel);
            for (reached) |p| declared = declared or std.mem.eql(u8, p, rel);
            if (declared) continue;
            step.dependOn(&b.addFail(b.fmt(
                "{s} carries tests and nothing collects them. Either root it: add it to pure_test_roots in build.zig. Or reference it from a file already collected (src/root.zig's test block, src/plugin/broker.zig's comptime block) and add it to reached_test_files. Prove whichever you chose the only reliable way: make one of the file's tests fail and check `zig build test` names it.",
                .{rel},
            )).step);
        }
    }
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

    // charttable draws the chart. It owns the style, the tile sources, the
    // tessellators and the GPU; src/ct/ drives it and the host keeps only what
    // is above the renderer (the library, picks, overlays, the plugin layer).
    // charttable picks its backend off the target: Metal on Apple, Vulkan
    // everywhere else (charttable src/gpu/gpu.zig). Nothing to select here —
    // the shells link the loader their platform uses.
    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const is_linux = target.result.os.tag == .linux;
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
    build_opts.addOption(bool, "plugins", plugins);
    const build_opts_mod = build_opts.createModule();

    // Android cross-compile (mirrors tile57's -Dandroid-ndk): the C deps need the
    // NDK sysroot's bionic + arch headers; the SDL backend also needs SDL3 headers
    // (SDL itself is linked by the android gradle/CMake build, not here).
    const android_ndk = b.option([]const u8, "android-ndk", "Android NDK root (for -Dtarget=*-linux-android)");
    const android_api = b.option(u32, "android-api", "Android API level (default 24)") orelse 24;
    const android_libc: ?std.Build.LazyPath = if (androidTriple(target)) |triple|
        (if (android_ndk) |ndk| androidLibcFile(b, ndk, triple, android_api) else null)
    else
        null;
    const is_android = androidTriple(target) != null;

    const dep_args = .{ .target = target, .optimize = optimize, .@"android-ndk" = android_ndk, .@"android-api" = android_api };
    const tile57_dep = (if (haveLocalDep(b, "tile57"))
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

    // System image codecs, handed to charttable.
    //
    // WebP is not a nicety here: elevation tiles are commonly served as WebP
    // (Open Waters' seascape DEM is), and without libwebp those tiles fetch
    // fine, fail to decode, and the hillshade and colour-relief layers built
    // from them simply never appear — with nothing said anywhere. libpng
    // likewise reads the PNG shapes charttable's own reader declines
    // (interlaced, 16-bit).
    //
    // Default ON, unlike charttable's own build, where they default off so an
    // embedder is never forced into a system dependency. Lookout HAS an
    // embedder — this repo's Apple app — and it would rather have the codecs
    // than a chart with a hole in it. `-Dwebp=false -Dlibpng=false` builds
    // without them on a host that has neither.
    const use_webp = b.option(bool, "webp", "Decode WebP tiles with libwebp") orelse true;
    const use_libpng = b.option(bool, "libpng", "Decode PNG with libpng") orelse true;

    // The renderer, as a Zig module: `@import("charttable")`. It carries its
    // own Metal shim and frameworks, so nothing here declares them. Same
    // local-or-pinned selection as tile57 above.
    const charttable_args = .{
        .target = target,
        .optimize = optimize,
        .webp = use_webp,
        .libpng = use_libpng,
    };
    const charttable_dep = (if (haveLocalDep(b, "charttable"))
        b.lazyDependency("charttable_local", charttable_args)
    else
        b.lazyDependency("charttable", charttable_args)) orelse
        return; // fetch scheduled; the runner downloads it and re-runs build()
    const charttable_mod = charttable_dep.module("charttable");

    // ---- the basemap bake ----
    // vendor/gshhg/coastline.geojson.gz -> vendor/gshhg/basemap.pmtiles, which
    // src/basemap.zig embeds. The archive is committed and this step is the
    // only thing that writes it, so an app build never compiles the tool.
    //
    // It CANNOT ride an ordinary build. The Apple targets pass --sysroot for
    // their cross compile, that flag reaches every compile in the invocation,
    // and a host tool built under a phone's SDK has no libc to link against.
    const basemap_step = b.step("basemap", "Bake vendor/gshhg/coastline.geojson.gz into basemap.pmtiles");
    if (if (haveLocalDep(b, "tile57"))
        b.lazyDependency("tile57_local", .{ .target = b.graph.host, .optimize = .ReleaseFast })
    else
        b.lazyDependency("tile57", .{ .target = b.graph.host, .optimize = .ReleaseFast })) |host_t57|
    {
        const bake_mod = b.createModule(.{
            .root_source_file = b.path("tools/basemap.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        bake_mod.addImport("tiles", host_t57.module("tiles"));
        const bake = b.addRunArtifact(b.addExecutable(.{ .name = "lookout-basemap", .root_module = bake_mod }));
        bake.addFileArg(b.path("vendor/gshhg/coastline.geojson.gz"));
        bake.addArg("vendor/gshhg/basemap.pmtiles");
        basemap_step.dependOn(&bake.step);
    }

    const Cfg = struct {
        b: *std.Build,
        tile57_inc: std.Build.LazyPath,
        tile57_lib: std.Build.LazyPath,
        charttable_mod: *std.Build.Module,
        android: bool,
        build_opts_mod: *std.Build.Module,
        plugins: bool,
        /// The vendor/wamr-dist* directory for this target (see wamrDist).
        wamr_dir: []const u8,
        /// charttable leaves the Vulkan loader to its host, so every
        /// executable on a Vulkan target links it (the meson and gradle
        /// shells do the same for theirs).
        vk_loader: bool,
        /// `link_archives` adds the prebuilt archives (tile57, and WAMR when
        /// the plugin host is on): always for an exe, but for a static lib
        /// only where the linker copes with it (see addObjectFile below).
        fn apply(self: @This(), mod: *std.Build.Module, link_archives: bool) void {
            const bb = self.b;
            mod.addImport("build_options", self.build_opts_mod); // the plugin-host switch
            mod.addImport("charttable", self.charttable_mod);
            // The world coastline src/basemap.zig embeds. An anonymous import
            // rather than a path: @embedFile cannot reach outside the module's
            // own directory, and the archive sits in vendor/ beside the source
            // data it was baked from.
            mod.addAnonymousImport("basemap_pmtiles", .{
                .root_source_file = bb.path("vendor/gshhg/basemap.pmtiles"),
            });
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
            // The chart's geometry and paint come from charttable, so the host
            // vendors no tessellator. stb stays for PNG decode.
            // -std=gnu99: under the newer clang default, Android's bionic
            // stdlib.h `_Nonnull`-on-array declarations error; gnu99 accepts them
            // (matches tile57's C flags). Harmless for stb elsewhere.
            mod.addCSourceFile(.{ .file = bb.path("vendor/stb/stb_image_impl.c"), .flags = &.{ "-std=gnu99", "-O2", "-fno-sanitize=undefined" } });
            // Embedding an archive into a static lib nests it as a .a member: ld64
            // unpacks it (one-archive convenience on Apple), but ELF/COFF linkers
            // reject it, so off Apple the host links libtile57.a alongside (both
            // are installed to <prefix>/lib below). Exes always link it.
            if (link_archives) mod.addObjectFile(self.tile57_lib);
            if (link_archives and self.vk_loader) mod.linkSystemLibrary("vulkan", .{});
            if (self.plugins) {
                // WAMR: wasm_export.h for the @cImport in src/plugin/wasm.zig,
                // libvmlib.a for the interpreter itself. Both come from this
                // target's vendor/wamr-dist* dir, which scripts/build-wamr.sh
                // fills. The headers are the same on every target; the archive
                // is not.
                mod.addIncludePath(bb.path(bb.fmt("{s}/include", .{self.wamr_dir})));
                if (link_archives) mod.addObjectFile(bb.path(bb.fmt("{s}/lib/libvmlib.a", .{self.wamr_dir})));
            }
        }
    };
    const cfg = Cfg{ .b = b, .tile57_inc = tile57_inc, .tile57_lib = tile57_lib, .charttable_mod = charttable_mod, .android = is_android, .build_opts_mod = build_opts_mod, .plugins = plugins, .wamr_dir = wamr_dir, .vk_loader = is_android or is_linux };

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
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ---- plugin-layer unit tests ----
    // Each file rooted the way its own `zig test <file>` roots it, so what the
    // phase gate runs and what an agent runs by hand are the same compilation.
    // These do not need tile57 or a GPU, so they skip cfg.apply.
    const pure_test_roots = [_][]const u8{
        "src/plugin/store.zig",
        "src/plugin/aisstore.zig",
        "src/overlay.zig",
        "src/markers.zig",
        "src/chartlinks.zig",
        "src/library.zig",
        "src/plugin_dev_replay.zig",
        "plugins/nmea0183/parser.zig",
        "plugins/nmea0183/paths.zig",
        "plugins/nmea0183/config.zig",
        // The raw-line TAG framing for the bus rides in the plugin's root; it
        // is pure byte math, so the file tests natively like aiscast's.
        "plugins/nmea0183/main.zig",
        "plugins/signalk/delta.zig",
        "plugins/signalk/transport.zig",
        "plugins/signalk/config.zig",
        "plugins/ownship/track.zig",
        "plugins/ownship/config.zig",
        "plugins/ais/cpa.zig",
        "plugins/ais/vector.zig",
        "plugins/ais/config.zig",
        "plugins/ais/aton.zig",
        "plugins/ais/vessel.zig",
        "plugins/laylines/geo.zig",
        "plugins/laylines/config.zig",
        "plugins/aiscast/config.zig",
        // The box, hysteresis and time math ride in the plugin's root: they
        // touch nothing but arithmetic, so the file tests natively.
        "plugins/aiscast/main.zig",
        // lk v2. The surface has no wasm builtin on any path a test reaches,
        // so the geodesy, the settings schema and the manifest checks run
        // natively beside everything else.
        "plugins/common/schema.zig",
        "plugins/common/lk2.zig",
        // The connection library, rooted on its own: lk2.zig imports it but
        // does not analyse it, so nothing else collects its tests. They reach
        // the host imports, which under a test build resolve to the seam at the
        // bottom of plugins/common/lk.zig. schema.zig rides in with it, which
        // is why its tests appear twice in the summary.
        "plugins/common/conn.zig",
        // The generator's round trip re-parses the log it writes and runs the
        // ais plugin's own solver over it, so the scenario the harness replays
        // is checked by the gate here rather than only by eye in the harness.
        // It reaches parser.zig and cpa.zig through the tools/ symlinks, which
        // is why their tests appear twice in the summary.
        "tools/nmea_gen.zig",
    };
    for (pure_test_roots) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // the stores' and overlay's lock is os_unfair_lock
        });
        // A plugin file that declares its settings imports lk2 for the types
        // and the schema generator. Nothing a test reaches calls a host
        // import, so the same file compiles for the host and for wasm.
        mod.addImport("lk2", b.createModule(.{
            .root_source_file = b.path("plugins/common/lk2.zig"),
            .target = target,
            .optimize = optimize,
        }));
        // overlay.zig and markers.zig do their geometry in the renderer's
        // world space, so they take its camera. Cheap for the roots that do
        // not: an unimported module is not analysed.
        mod.addImport("charttable", cfg.charttable_mod);
        if (cfg.vk_loader) mod.linkSystemLibrary("vulkan", .{});
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
    // lk v2: the simple surface. It roots its own copy of lk.zig as the raw
    // shim below it, so a plugin imports one or the other and never both.
    const lk2_mod = b.createModule(.{
        .root_source_file = b.path("plugins/common/lk2.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const plugins_step = b.step("plugins", "Build the wasm plugin modules into zig-out/plugins (and the shipped set into zig-out/plugins-bundled)");
    // The shipped set: the plugins the app carries inside itself, which are
    // ours by id. Everything under org.example.* is a demo or a documentation
    // example and is never bundled.
    const shipped_prefix = "org.beetlebug.";
    // `echo` is BUILT but not installed: it is the host tests' fixture, not a
    // plugin anybody runs. Installed beside the real ones it would be
    // loaded by the harness and draw its own symbol over own ship. A name
    // with no main.zig yet is skipped, so a plugin agent adds one file and it
    // builds.
    var echo_wasm: ?std.Build.LazyPath = null;
    // The nmea0183 module is installed like the other three AND handed to the
    // multi-connection test below.
    var nmea_wasm: ?std.Build.LazyPath = null;
    // The signalk module is installed like the others AND handed to the
    // Signal K host test below.
    var signalk_wasm: ?std.Build.LazyPath = null;
    // The ais module is installed like the others AND handed to the
    // multi-connection test below, which drives an AIS name from the wire to
    // the row the targets dialog shows.
    var ais_wasm: ?std.Build.LazyPath = null;
    // The windline module is the install test's payload: the walkthrough's
    // downwind plugin under the id its package carries.
    var windline_wasm: ?std.Build.LazyPath = null;
    // The aiscast module is installed like the others AND handed to the
    // Open Waters AIS host test below.
    var aiscast_wasm: ?std.Build.LazyPath = null;
    for ([_][]const u8{ "echo", "nmea0183", "signalk", "ownship", "ais", "laylines", "windline", "canvasdemo", "aiscast" }) |name| {
        const main_rel = b.fmt("plugins/{s}/main.zig", .{name});
        if (!haveFile(b, main_rel)) continue;
        const mod = b.createModule(.{
            .root_source_file = b.path(main_rel),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        mod.addImport("lk", lk_mod);
        mod.addImport("lk2", lk2_mod);
        const wasm_exe = b.addExecutable(.{ .name = name, .root_module = mod });
        wasm_exe.entry = .disabled;
        wasm_exe.rdynamic = true;

        if (std.mem.eql(u8, name, "echo")) {
            echo_wasm = wasm_exe.getEmittedBin();
            continue;
        }
        // `windline` is BUILT but not installed, for the same reason as echo:
        // it is the documentation's worked example, and beside the real
        // ones the harness would load it and draw a second line off own ship.
        // Building it keeps the recipes compiling — and hands the install test
        // below its module, which it packs as the doc's org.example.downwind.
        if (std.mem.eql(u8, name, "windline")) {
            windline_wasm = wasm_exe.getEmittedBin();
            continue;
        }
        // `canvasdemo` installs into its own zig-out/plugins-canvas so the
        // standard harness bar stays what it was; a canvas run copies the
        // pair in beside the real plugins deliberately.
        if (std.mem.eql(u8, name, "canvasdemo")) {
            const cid = manifestId(b, name);
            plugins_step.dependOn(&b.addInstallFileWithDir(
                wasm_exe.getEmittedBin(),
                .{ .custom = "plugins-canvas" },
                b.fmt("{s}.wasm", .{cid}),
            ).step);
            plugins_step.dependOn(&b.addInstallFileWithDir(
                b.path("plugins/canvasdemo/manifest.json"),
                .{ .custom = "plugins-canvas" },
                b.fmt("{s}.manifest.json", .{cid}),
            ).step);
            continue;
        }
        if (std.mem.eql(u8, name, "nmea0183")) nmea_wasm = wasm_exe.getEmittedBin();
        if (std.mem.eql(u8, name, "signalk")) signalk_wasm = wasm_exe.getEmittedBin();
        if (std.mem.eql(u8, name, "ais")) ais_wasm = wasm_exe.getEmittedBin();
        if (std.mem.eql(u8, name, "aiscast")) aiscast_wasm = wasm_exe.getEmittedBin();

        const id = manifestId(b, name);
        const manifest_rel = b.fmt("plugins/{s}/manifest.json", .{name});
        // Two destinations out of one build.
        //
        //   zig-out/plugins is the WORKING set: what LOOKOUT_PLUGINS points at
        //   for the harness and the dev runs, and where a developer drops
        //   extra pairs beside these.
        //
        //   zig-out/plugins-bundled holds the shipped set and nothing else, so
        //   a shell's copy step takes a whole directory and gets exactly what
        //   the product ships, whatever else is lying in the working set.
        const dests: []const []const u8 = if (std.mem.startsWith(u8, id, shipped_prefix))
            &.{ "plugins", "plugins-bundled" }
        else
            &.{"plugins"};
        for (dests) |dest| {
            plugins_step.dependOn(&b.addInstallFileWithDir(
                wasm_exe.getEmittedBin(),
                .{ .custom = dest },
                b.fmt("{s}.wasm", .{id}),
            ).step);
            if (haveFile(b, manifest_rel)) plugins_step.dependOn(&b.addInstallFileWithDir(
                b.path(manifest_rel),
                .{ .custom = dest },
                b.fmt("{s}.manifest.json", .{id}),
            ).step);
        }
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
            // The store builds its geometry in the renderer's world space, so
            // it takes the renderer's camera even in a host test that never
            // draws anything.
            ov_mod.addImport("charttable", cfg.charttable_mod);

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
            // The ais module comes too: the second test in that file carries an
            // AIS name off the wire all the way to the row the targets dialog
            // shows, which takes both plugins running together.
            if (nmea_wasm) |nbin| {
                if (ais_wasm) |abin| {
                    const nmea_mod = b.createModule(.{
                        .root_source_file = b.path("test/nmea_multi.zig"),
                        .target = target,
                        .optimize = optimize,
                        .link_libc = true,
                    });
                    nmea_mod.addImport("host", host_mod);
                    nmea_mod.addAnonymousImport("nmea_plugin_wasm", .{ .root_source_file = nbin });
                    nmea_mod.addAnonymousImport("nmea_manifest", .{ .root_source_file = b.path("plugins/nmea0183/manifest.json") });
                    nmea_mod.addAnonymousImport("ais_plugin_wasm", .{ .root_source_file = abin });
                    nmea_mod.addAnonymousImport("ais_manifest", .{ .root_source_file = b.path("plugins/ais/manifest.json") });
                    const nmea_run = b.addRunArtifact(b.addTest(.{ .root_module = nmea_mod }));
                    b.step("nmea-multi", "Run the multi-connection nmea0183 test").dependOn(&nmea_run.step);
                    test_step.dependOn(&nmea_run.step);
                }

                // The Signal K plugin against a loopback delta stream, and
                // beside the nmea0183 plugin so the store's election between
                // two sources of one path is exercised end to end.
                if (signalk_wasm) |sbin| {
                    const sk_mod = b.createModule(.{
                        .root_source_file = b.path("test/signalk_host.zig"),
                        .target = target,
                        .optimize = optimize,
                        .link_libc = true,
                    });
                    sk_mod.addImport("host", host_mod);
                    sk_mod.addAnonymousImport("signalk_plugin_wasm", .{ .root_source_file = sbin });
                    sk_mod.addAnonymousImport("signalk_manifest", .{ .root_source_file = b.path("plugins/signalk/manifest.json") });
                    sk_mod.addAnonymousImport("nmea_plugin_wasm", .{ .root_source_file = nbin });
                    sk_mod.addAnonymousImport("nmea_manifest", .{ .root_source_file = b.path("plugins/nmea0183/manifest.json") });
                    sk_mod.addAnonymousImport("signalk_deltas", .{ .root_source_file = b.path("test/signalk.deltas") });
                    const sk_run = b.addRunArtifact(b.addTest(.{ .root_module = sk_mod }));
                    b.step("signalk-host", "Run the Signal K stream + arbitration test").dependOn(&sk_run.step);
                    test_step.dependOn(&sk_run.step);
                }
            }

            // The aiscast plugin against a loopback relay speaking the Open
            // Waters v1 protocol: the view fanout, the bbox subscription with
            // its hysteresis, the net provenance, and — beside the real
            // nmea0183 plugin — the bus-carried sharing path, end to end.
            if (aiscast_wasm) |acbin| {
                if (nmea_wasm) |nbin| {
                    const ac_mod = b.createModule(.{
                        .root_source_file = b.path("test/aiscast_host.zig"),
                        .target = target,
                        .optimize = optimize,
                        .link_libc = true,
                    });
                    ac_mod.addImport("host", host_mod);
                    ac_mod.addAnonymousImport("aiscast_plugin_wasm", .{ .root_source_file = acbin });
                    ac_mod.addAnonymousImport("aiscast_manifest", .{ .root_source_file = b.path("plugins/aiscast/manifest.json") });
                    ac_mod.addAnonymousImport("nmea_plugin_wasm", .{ .root_source_file = nbin });
                    ac_mod.addAnonymousImport("nmea_manifest", .{ .root_source_file = b.path("plugins/nmea0183/manifest.json") });
                    const ac_run = b.addRunArtifact(b.addTest(.{ .root_module = ac_mod }));
                    b.step("aiscast-host", "Run the Open Waters AIS relay test").dependOn(&ac_run.step);
                    test_step.dependOn(&ac_run.step);
                }
            }

            // The ais module's collision alarm on the data path: the real
            // stores driven by hand, no gateway and no sockets. The overlay
            // store comes too, to prove what did and did not reach the chart.
            if (ais_wasm) |abin| {
                const alarm_mod = b.createModule(.{
                    .root_source_file = b.path("test/ais_alarm.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                });
                alarm_mod.addImport("host", host_mod);
                alarm_mod.addImport("overlay", ov_mod);
                alarm_mod.addAnonymousImport("ais_plugin_wasm", .{ .root_source_file = abin });
                alarm_mod.addAnonymousImport("ais_manifest", .{ .root_source_file = b.path("plugins/ais/manifest.json") });
                const alarm_run = b.addRunArtifact(b.addTest(.{ .root_module = alarm_mod }));
                b.step("ais-alarm", "Run the AIS collision alarm data-path test").dependOn(&alarm_run.step);
                test_step.dependOn(&alarm_run.step);
            }

            // The install path end to end: a .lkplug packed in-test around the
            // windline module (the docs' downwind example), refused packages,
            // hot install, live grant revocation, grants.json persistence and
            // uninstall taking the directory and the overlay with it.
            if (windline_wasm) |wbin| {
                const install_mod = b.createModule(.{
                    .root_source_file = b.path("test/install_host.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                });
                install_mod.addImport("host", host_mod);
                install_mod.addImport("overlay", ov_mod);
                install_mod.addAnonymousImport("windline_plugin_wasm", .{ .root_source_file = wbin });
                const install_run = b.addRunArtifact(b.addTest(.{ .root_module = install_mod }));
                b.step("install-host", "Run the plugin install + consent test").dependOn(&install_run.step);
                test_step.dependOn(&install_run.step);
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

            // Faults, restarts and load precedence: echo beside a plugin that
            // traps on cue, in lk_event and in lk_start. Built and never
            // installed, like echo and the spinner.
            const trap_mod = b.createModule(.{
                .root_source_file = b.path("test/trap_plugin.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
            });
            trap_mod.addImport("lk", lk_mod);
            const trap_plugin = b.addExecutable(.{ .name = "trap_plugin", .root_module = trap_mod });
            trap_plugin.entry = .disabled;
            trap_plugin.rdynamic = true;

            const restart_mod = b.createModule(.{
                .root_source_file = b.path("test/host_restart.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            restart_mod.addImport("host", host_mod);
            restart_mod.addImport("overlay", ov_mod);
            restart_mod.addAnonymousImport("echo_plugin_wasm", .{ .root_source_file = bin });
            restart_mod.addAnonymousImport("echo_manifest", .{ .root_source_file = b.path("plugins/echo/manifest.json") });
            restart_mod.addAnonymousImport("trap_plugin_wasm", .{ .root_source_file = trap_plugin.getEmittedBin() });

            const restart_run = b.addRunArtifact(b.addTest(.{ .root_module = restart_mod }));
            b.step("host-restart", "Run the plugin fault, restart and load-precedence test").dependOn(&restart_run.step);
            test_step.dependOn(&restart_run.step);
        }
    }
    if (plugins_fail) |fail| test_step.dependOn(fail);

    // Every other test-bearing .zig, and the compilation that analyses it.
    // These are not roots of their own: each rides into a compilation rooted
    // somewhere else, so listing it here is the claim that it is analysed
    // there. checkTestCoverage fails the test step for a test-bearing file on
    // neither list.
    const reached_test_files = [_][]const u8{
        // The test module's root, and the core files it reaches. pick and the
        // renderer layer are reached only through root.zig's `test` block.
        "src/root.zig",
        "src/pick.zig",
        "src/ct/host.zig",
        "src/ct/style.zig",
        "src/ct/tiles.zig",
        "src/ct/provided.zig",
        "src/ct/raster.zig",
        // The host test module's root, and the plugin layer under it. The
        // host's and the broker's parts are reached through the comptime block
        // in host.zig and broker.zig.
        "src/plugin/host.zig",
        "src/plugin/broker.zig",
        "src/plugin/webio.zig",
        "src/plugin/host/install.zig",
        "src/plugin/host/manifest.zig",
        "src/plugin/host/settings_json.zig",
        "src/plugin/broker/alerts.zig",
        "src/plugin/broker/budgets.zig",
        "src/plugin/broker/caps.zig",
        "src/plugin/broker/http.zig",
        "src/plugin/broker/natives.zig",
        "src/plugin/broker/queue.zig",
        "src/plugin/broker/registry_json.zig",
        "src/plugin/broker/sockets.zig",
        "src/plugin/broker/storage.zig",
        "src/plugin/broker/tables.zig",
        "src/plugin/broker/ws.zig",
        // One module each, rooted by the host test steps. They need WAMR, so
        // with -Dplugins=false none of them is built and none of their tests
        // runs.
        "test/wasm_smoke.zig",
        "test/host_smoke.zig",
        "test/nmea_multi.zig",
        "test/signalk_host.zig",
        "test/aiscast_host.zig",
        "test/install_host.zig",
        "test/host_isolation.zig",
        "test/host_restart.zig",
        "test/ais_alarm.zig",
    };
    checkTestCoverage(b, test_step, &pure_test_roots, &reached_test_files);
}
