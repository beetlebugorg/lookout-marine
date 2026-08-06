//! The smallest module that speaks the plugin ABI: five exports, no imports.
//! Built for wasm32-freestanding by `zig build` and loaded by the WAMR
//! embedding test in src/plugin/wasm.zig, which is the only thing that runs
//! it. Real plugins get the same exports from plugins/common/lk.zig.

/// Bump arena for lk_alloc. A real plugin's allocator reuses memory; this one
/// only has to survive the handful of allocations the smoke test makes.
var arena: [4096]u8 align(16) = undefined;
var used: usize = 0;

/// Sum of the bytes of the last lk_event payload, read back by the test to
/// prove the host wrote into this module's linear memory at the address
/// lk_alloc handed out. Not part of the ABI.
var last_sum: u32 = 0;

export fn lk_abi() u32 {
    return 1;
}

export fn lk_alloc(len: u32) ?[*]u8 {
    // 8-byte alignment: the ABI passes JSON and raw bytes, but keeping the
    // arena aligned matches what a real allocator hands back.
    const start = (used + 7) & ~@as(usize, 7);
    if (start + len > arena.len) return null;
    used = start + len;
    return arena[start..].ptr;
}

export fn lk_free(ptr: [*]u8, len: u32) void {
    _ = ptr;
    _ = len;
}

export fn lk_start(ptr: [*]const u8, len: u32) i32 {
    _ = ptr;
    _ = len;
    return 0;
}

export fn lk_event(kind: u32, handle: u64, ptr: [*]const u8, len: u32) i32 {
    _ = handle;
    var sum: u32 = 0;
    for (ptr[0..len]) |b| sum +%= b;
    last_sum = sum;
    // Unknown kinds are ignored and return 0 — every kind is unknown here.
    _ = kind;
    return 0;
}

/// Test hook, not ABI: the byte sum lk_event last saw.
export fn lk_test_last_sum() u32 {
    return last_sum;
}
