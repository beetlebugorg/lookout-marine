const std = @import("std");

// Prebuilt tile57 engine (C ABI static lib) + its header. Overridable on the
// command line: `zig build -Dtile57=/path/to/checkout`.
const DEFAULT_TILE57 = "/home/claude/Projects/tile57-main";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tile57 = b.option([]const u8, "tile57", "tile57 checkout dir") orelse DEFAULT_TILE57;

    const tile57_inc = b.pathJoin(&.{ tile57, "include" });
    const tile57_lib = b.pathJoin(&.{ tile57, "zig-out/lib/libtile57.a" });

    const Cfg = struct {
        b: *std.Build,
        tile57_inc: []const u8,
        tile57_lib: []const u8,
        fn apply(self: @This(), mod: *std.Build.Module) void {
            const bb = self.b;
            mod.addIncludePath(.{ .cwd_relative = self.tile57_inc });
            mod.addIncludePath(bb.path("vendor/stb"));
            // Tessellation, sprite/SDF quad building and paint order all moved
            // into tile57 (the GPU-scene ABI hands back draw-ready buffers), so
            // the host no longer vendors libtess2. stb stays for atlas PNG decode.
            mod.addCSourceFile(.{ .file = bb.path("vendor/stb/stb_image_impl.c"), .flags = &.{"-O2"} });
            mod.addObjectFile(.{ .cwd_relative = self.tile57_lib });
            mod.linkSystemLibrary("SDL3", .{});
            // precompiled SPIR-V shaders, embedded (no runtime shader compilation)
            mod.addAnonymousImport("chart_vert_spv", .{ .root_source_file = bb.path("shaders/chart.vert.spv") });
            mod.addAnonymousImport("chart_frag_spv", .{ .root_source_file = bb.path("shaders/chart.frag.spv") });
            mod.addAnonymousImport("sprite_vert_spv", .{ .root_source_file = bb.path("shaders/sprite.vert.spv") });
            mod.addAnonymousImport("sprite_frag_spv", .{ .root_source_file = bb.path("shaders/sprite.frag.spv") });
            mod.addAnonymousImport("sdf_frag_spv", .{ .root_source_file = bb.path("shaders/sdf.frag.spv") });
            mod.addAnonymousImport("pattern_vert_spv", .{ .root_source_file = bb.path("shaders/pattern.vert.spv") });
            mod.addAnonymousImport("pattern_frag_spv", .{ .root_source_file = bb.path("shaders/pattern.frag.spv") });
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
    });
    cfg.apply(lib_mod);
    const lib = b.addLibrary(.{ .name = "lookout_marine", .linkage = .static, .root_module = lib_mod });
    lib.installHeader(b.path("include/lookout.h"), "lookout.h");
    b.installArtifact(lib);

    // ---- the demo executable ----
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cfg.apply(exe_mod);
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
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // ---- shader (re)compilation: `zig build shaders` ----
    const shaders = b.step("shaders", "Recompile GLSL -> SPIR-V (needs glslangValidator)");
    inline for (.{ "chart.vert", "chart.frag", "sprite.vert", "sprite.frag", "sdf.frag", "pattern.vert", "pattern.frag" }) |name| {
        const cmd = b.addSystemCommand(&.{ "glslangValidator", "-V" });
        cmd.addFileArg(b.path("shaders/" ++ name));
        cmd.addArg("-o");
        const out = cmd.addOutputFileArg(name ++ ".spv");
        const install = b.addInstallFileWithDir(out, .{ .custom = "../shaders" }, name ++ ".spv");
        shaders.dependOn(&install.step);
    }
}
