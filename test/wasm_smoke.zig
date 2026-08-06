//! WAMR embedding smoke test: the wasm32 module built from
//! test/smoke_plugin.zig is loaded, instantiated under a memory cap, and
//! driven through the ABI exports. Item 4 of the prototype verification bar.
//!
//! Kept out of src/plugin/wasm.zig so that importing the wrapper never drags
//! in the embedded module bytes: the .wasm arrives as an anonymous import
//! wired up by build.zig, which only this test root declares.

const std = @import("std");
const wasm = @import("wasm");

const smoke_wasm = @embedFile("smoke_plugin_wasm");

/// A native the module does not import. Registering it proves the table is
/// accepted and gives the broker's shape a rehearsal: an exec_env first
/// parameter, a bounds-checked (ptr, len) pair, per-symbol user data.
fn hostLog(env: wasm.c.wasm_exec_env_t, level: u32, ptr: [*c]const u8, len: u32) callconv(.c) void {
    _ = env;
    _ = level;
    _ = ptr;
    _ = len;
}

var natives = wasm.nativeSymbols(&.{
    .{ .name = "log", .func = @ptrCast(&hostLog), .signature = "(i*~)" },
});

test "wamr loads a plugin-shaped module and runs the ABI exports" {
    const allocator = std.testing.allocator;

    try wasm.initRuntime();
    defer wasm.deinitRuntime();

    try wasm.registerNatives("lookout", &natives);
    defer wasm.unregisterNatives("lookout", &natives);

    // WAMR patches the bytecode in place and keeps pointing at it, so the
    // module needs a writable copy that outlives the Module.
    const bytes = try allocator.alignedAlloc(u8, .@"8", smoke_wasm.len);
    defer allocator.free(bytes);
    @memcpy(bytes, smoke_wasm);

    var err: wasm.ErrBuf = .{};
    var module = wasm.Module.load(bytes, &err) catch |e| {
        std.debug.print("wamr load failed: {s}\n", .{err.msg()});
        return e;
    };
    defer module.deinit();

    // 4 MiB cap: well above the module's initial memory (1 MiB linker stack
    // plus data) and well below anything a plugin should need.
    var inst = wasm.Instance.init(module, .{ .max_memory_pages = 64 }, &err) catch |e| {
        std.debug.print("wamr instantiate failed: {s}\n", .{err.msg()});
        return e;
    };
    defer inst.deinit();

    try std.testing.expectEqual(@as(u32, 1), try inst.abiVersion());
    try std.testing.expectEqual(@as(i32, 0), try inst.start("{\"abi\":1,\"config\":{}}"));

    // Write a payload through the module's own lk_alloc, deliver it as an
    // event, and read back the byte sum the module computed — proof the bytes
    // landed at the app address lk_alloc returned.
    const payload = "{\"values\":[]}";
    const buf = try inst.writeAlloc(payload);
    defer inst.free(buf) catch {};
    try std.testing.expectEqual(@as(i32, 0), try inst.event(10, 7, buf));

    var expect_sum: u32 = 0;
    for (payload) |b| expect_sum +%= b;
    const sum_fn = inst.lookup("lk_test_last_sum") orelse return error.MissingExport;
    var results: [1]wasm.c.wasm_val_t = undefined;
    var no_args: [0]wasm.c.wasm_val_t = .{};
    try inst.call(sum_fn, &results, &no_args);
    try std.testing.expectEqual(expect_sum, @as(u32, @bitCast(results[0].of.i32)));

    // The host reads plugin memory only through checked translations. A range
    // past the end of linear memory is refused, and WAMR records an exception
    // on the instance that has to be cleared before it is used again.
    try std.testing.expectError(error.BadAppAddr, inst.slice(0xffff_fff0, 16));
    inst.clearException();
    try std.testing.expectEqual(@as(u32, 1), try inst.abiVersion());
}
