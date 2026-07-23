const std = @import("std");

// Prebuilt tile57 engine (C ABI static lib) + its header. Overridable on the
// command line: `zig build -Dtile57=/path/to/checkout`.
const DEFAULT_TILE57 = "/home/claude/Projects/tile57-main";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tile57 = b.option([]const u8, "tile57", "tile57 checkout dir") orelse DEFAULT_TILE57;

    const tile57_inc = b.pathJoin(&.{ tile57, "include" });
    // Cross builds keep per-platform archives (zig-out-iphonesimulator/…) —
    // point tile57_lib at the one matching -Dtarget.
    const tile57_lib = b.option([]const u8, "tile57_lib", "path to libtile57.a (default <tile57>/zig-out/lib/libtile57.a)") orelse
        b.pathJoin(&.{ tile57, "zig-out/lib/libtile57.a" });

    const Cfg = struct {
        b: *std.Build,
        tile57_inc: []const u8,
        tile57_lib: []const u8,
        fn apply(self: @This(), mod: *std.Build.Module) void {
            const bb = self.b;
            // Non-macOS Apple targets (-Dtarget=aarch64-ios[-simulator]) need
            // that SDK's libc AND framework headers (Metal/QuartzCore for the
            // shim): pass --sysroot; Zig only bundles macOS's.
            if (bb.sysroot) |sysroot| {
                mod.addSystemIncludePath(.{ .cwd_relative = bb.pathJoin(&.{ sysroot, "usr/include" }) });
                mod.addSystemFrameworkPath(.{ .cwd_relative = bb.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            }
            mod.addIncludePath(.{ .cwd_relative = self.tile57_inc });
            mod.addIncludePath(bb.path("vendor/stb"));
            mod.addIncludePath(bb.path("src")); // metal_shim.h for the @cImport
            // Tessellation, sprite/SDF quad building and paint order all moved
            // into tile57 (the GPU-scene ABI hands back draw-ready buffers), so
            // the host no longer vendors libtess2. stb stays for atlas PNG decode.
            mod.addCSourceFile(.{ .file = bb.path("vendor/stb/stb_image_impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
            // The Metal transport (ObjC behind a C face). Manual retain/release
            // on purpose — objects live in C structs (see metal_shim.m).
            mod.addCSourceFile(.{ .file = bb.path("src/metal_shim.m"), .flags = &.{ "-O2", "-fno-objc-arc", "-fno-sanitize=undefined" } });
            mod.addObjectFile(.{ .cwd_relative = self.tile57_lib });
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
    b.installArtifact(lib);

    // ---- the demo executable + tests (host platforms only: an iOS cross-build
    // `-Dtarget=aarch64-ios` produces just the static lib for the app to link) ----
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
