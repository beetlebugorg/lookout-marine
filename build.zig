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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Non-debug by default: the app chases 60 fps and a Debug core visibly
    // drops frames (and bakes/tessellates far slower). `-Doptimize=Debug` for
    // development. (Same rationale + mechanism as tile57's build.zig — NOT
    // standardOptimizeOption, which would keep the no-flag default at Debug.)
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    const tile57_dep = (if (haveLocalTile57(b))
        b.lazyDependency("tile57_local", .{ .target = target, .optimize = optimize })
    else
        b.lazyDependency("tile57", .{ .target = target, .optimize = optimize })) orelse
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
        fn apply(self: @This(), mod: *std.Build.Module) void {
            const bb = self.b;
            // Non-macOS Apple targets (-Dtarget=aarch64-ios[-simulator]) need
            // that SDK's libc AND framework headers (Metal/QuartzCore for the
            // shim): pass --sysroot; Zig only bundles macOS's.
            if (bb.sysroot) |sysroot| {
                mod.addSystemIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ sysroot, "usr/include" }) });
                mod.addSystemFrameworkPath(.{ .cwd_relative = bb.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            }
            mod.addIncludePath(self.tile57_inc);
            mod.addIncludePath(bb.path("vendor/stb"));
            mod.addIncludePath(bb.path("src")); // metal_shim.h for the @cImport
            // Tessellation, sprite/SDF quad building and paint order all live
            // in tile57 (the GPU-scene ABI hands back draw-ready buffers), so
            // the host vendors no tessellator. stb stays for atlas PNG decode.
            mod.addCSourceFile(.{ .file = bb.path("vendor/stb/stb_image_impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
            // The Metal transport (ObjC behind a C face). Manual retain/release
            // on purpose — objects live in C structs (see metal_shim.m).
            mod.addCSourceFile(.{ .file = bb.path("src/metal_shim.m"), .flags = &.{ "-O2", "-fno-objc-arc", "-fno-sanitize=undefined" } });
            mod.addObjectFile(self.tile57_lib);
            // Metal shader source, compiled by the shim at runtime (no offline
            // shader toolchain).
            mod.addAnonymousImport("metal_src", .{ .root_source_file = bb.path("shaders/lookout.metal") });
        }
    };
    const cfg = Cfg{ .b = b, .tile57_inc = tile57_inc, .tile57_lib = tile57_lib };

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
    cfg.apply(lib_mod);
    const lib = b.addLibrary(.{ .name = "lookout_marine", .linkage = .static, .root_module = lib_mod });
    lib.installHeader(b.path("include/lookout.h"), "lookout.h");
    // tile57.h rides along (lookout.h includes it), so the app's header search
    // path is just <prefix>/include.
    lib.installHeader(tile57_dep.path("include/tile57.h"), "tile57.h");
    b.installArtifact(lib);
    // The engine archive lands next to liblookout_marine.a: the app links the
    // pair from one <prefix>/lib (after the ld64 loose-object repack — see
    // macos/project.yml).
    b.getInstallStep().dependOn(&b.addInstallLibFile(tile57_lib, "libtile57.a").step);

    // ---- the demo executable + tests (host platforms only: an iOS cross-build
    // `-Dtarget=aarch64-ios` produces just the static libs for the app to link) ----
    if (target.result.os.tag == .ios) return;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cfg.apply(exe_mod);
    exe_mod.linkFramework("Metal", .{});
    exe_mod.linkFramework("QuartzCore", .{});
    exe_mod.linkFramework("Foundation", .{});
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
    cfg.apply(test_mod);
    test_mod.linkFramework("Metal", .{});
    test_mod.linkFramework("QuartzCore", .{});
    test_mod.linkFramework("Foundation", .{});
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
