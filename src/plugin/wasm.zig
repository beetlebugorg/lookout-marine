//! WAMR embedding: load a plugin module, instantiate it under a memory cap,
//! call the five ABI exports, and move bytes across the boundary.
//!
//! This file knows nothing about what a plugin does. It is the mechanical
//! layer: the broker supplies the native functions, the host supplies the
//! module bytes and the lifecycle. The runtime is the fast interpreter built
//! by scripts/build-wamr.sh (no AOT, no JIT, no WASI).
//!
//! Nothing here is thread-safe. The host contract is one event at a time per
//! plugin, so an Instance belongs to whichever thread is currently inside it.
//!
//! Two rules the ABI depends on:
//!   * Nothing crosses as a host pointer. A plugin sees only app addresses —
//!     offsets into its own linear memory — and the host copies bytes in and
//!     out through them.
//!   * A native pointer obtained from an app address is invalidated by any
//!     memory growth inside the module, so it may be used only for the copy
//!     it was taken for, never stored.

const std = @import("std");

pub const c = @cImport({
    @cInclude("wasm_export.h");
});

pub const Error = error{
    RuntimeInit,
    RegisterNatives,
    LoadFailed,
    InstantiateFailed,
    ExecEnvFailed,
    MissingExport,
    /// The module trapped, or the call itself was rejected (wrong argument
    /// count or types). Instance.exception() has WAMR's text.
    Trap,
    /// An (app address, length) pair that does not lie inside the module's
    /// linear memory.
    BadAppAddr,
    /// The module's lk_alloc returned null.
    PluginOutOfMemory,
};

/// WAMR reports load and instantiate failures by filling a caller buffer.
/// 192 bytes is the size its own samples use; longer messages are truncated
/// by the runtime, not here.
pub const ErrBuf = struct {
    bytes: [192]u8 = @splat(0),

    pub fn msg(self: *const ErrBuf) []const u8 {
        return std.mem.sliceTo(&self.bytes, 0);
    }
};

// ---- process-global runtime ----

/// Initialise the runtime. WAMR keeps one runtime per process: call this once
/// before the first load, and deinitRuntime() after the last instance is gone.
/// Natives are registered separately so the broker can build its table after
/// the runtime exists.
pub fn initRuntime() Error!void {
    var args: c.RuntimeInitArgs = std.mem.zeroes(c.RuntimeInitArgs);
    // System allocator rather than a fixed pool: the host has a real malloc
    // and a pool would put a second, unrelated cap on top of the per-instance
    // memory cap.
    args.mem_alloc_type = c.Alloc_With_System_Allocator;
    args.running_mode = c.Mode_Interp;
    if (!c.wasm_runtime_full_init(&args)) return error.RuntimeInit;
}

pub fn deinitRuntime() void {
    c.wasm_runtime_destroy();
}

/// Every thread that enters wasm needs its own runtime thread environment —
/// the interpreter's stack boundary and signal handling are per-thread, and a
/// call from a thread without one traps with "thread signal env not inited"
/// rather than running. initRuntime does this for the thread that calls it;
/// any OTHER thread (the host's dispatch thread, the harness's) calls this
/// once before its first call and destroyThreadEnv when it is done.
///
/// The setup mprotects the guard page below the calling thread's stack, and on
/// macOS that fails for stacks of 8 MiB and up — Zig's std.Thread default is
/// 16 MiB, so a thread that will enter wasm must be spawned with a smaller
/// one (host.zig uses 2 MiB).
pub fn initThreadEnv() Error!void {
    if (!c.wasm_runtime_init_thread_env()) return error.RuntimeInit;
}

pub fn destroyThreadEnv() void {
    c.wasm_runtime_destroy_thread_env();
}

// ---- native functions the host offers plugins ----

/// One host import. `signature` is WAMR's argument-type string, written from
/// the wasm-visible types of the function:
///   `i` i32 · `I` i64 · `f` f32 · `F` f64 · `*` pointer argument (an i32 app
///   address that WAMR bounds-checks and hands over as a native pointer) ·
///   `~` the length of the preceding `*` · `$` NUL-terminated string.
/// The return type follows the parens, empty for void — `log(level, ptr, len)`
/// is `"(i*~)"`, `now_ms()` is `"()I"`, `publish(ptr, len)` is `"(*~)i"`.
/// Every native takes `wasm_exec_env_t` as its first parameter, which the
/// signature does not mention.
pub const Native = struct {
    name: [:0]const u8,
    /// Pointer to the native function itself.
    func: *const anyopaque,
    signature: [:0]const u8,
    /// Retrieved inside the native with attachment(exec_env). Per-symbol, so
    /// one Zig function can serve several imports.
    user_data: ?*anyopaque = null,
};

/// Build the C symbol table for a comptime-known list. The result must live
/// as long as the runtime does — WAMR stores the array pointer, it does not
/// copy — so hold it in a container-level `var`, not on the stack.
pub fn nativeSymbols(comptime list: []const Native) [list.len]c.NativeSymbol {
    var out: [list.len]c.NativeSymbol = undefined;
    for (list, 0..) |n, i| out[i] = .{
        .symbol = n.name.ptr,
        .func_ptr = @constCast(n.func),
        .signature = n.signature.ptr,
        .attachment = n.user_data,
    };
    return out;
}

/// Register a symbol table under a wasm import module name (`lookout` for
/// this host). Imports are resolved at instantiation, so every native a
/// plugin may import has to be registered before Instance.init — a module
/// importing an unregistered name fails to instantiate, which is how the
/// grant filter refuses capabilities structurally. `syms` must outlive the
/// runtime; see nativeSymbols().
pub fn registerNatives(module_name: [:0]const u8, syms: []c.NativeSymbol) Error!void {
    if (!c.wasm_runtime_register_natives(module_name.ptr, syms.ptr, @intCast(syms.len)))
        return error.RegisterNatives;
}

pub fn unregisterNatives(module_name: [:0]const u8, syms: []c.NativeSymbol) void {
    _ = c.wasm_runtime_unregister_natives(module_name.ptr, syms.ptr);
}

// ---- helpers for use inside a native function ----

/// The instance that called the native.
pub fn callerInstance(env: c.wasm_exec_env_t) c.wasm_module_inst_t {
    return c.wasm_runtime_get_module_inst(env);
}

/// The per-instance pointer set with Instance.setUserData — how a native
/// finds which plugin is calling it.
pub fn callerUserData(env: c.wasm_exec_env_t) ?*anyopaque {
    return c.wasm_runtime_get_user_data(env);
}

/// The per-symbol pointer given as Native.user_data.
pub fn attachment(env: c.wasm_exec_env_t) ?*anyopaque {
    return c.wasm_runtime_get_function_attachment(env);
}

/// Translate an (app address, length) pair from any module instance into a
/// host slice, rejecting anything outside linear memory. Natives declared
/// with `*~` already receive a checked pointer; this is for the ones that
/// take a bare i32 address.
pub fn sliceOf(inst: c.wasm_module_inst_t, off: u32, len: u32) Error![]u8 {
    // A zero-length range has no address to check and nothing to read.
    if (len == 0) return @constCast(&[_]u8{});
    if (!c.wasm_runtime_validate_app_addr(inst, off, len)) return error.BadAppAddr;
    const native = c.wasm_runtime_addr_app_to_native(inst, off) orelse return error.BadAppAddr;
    return @as([*]u8, @ptrCast(native))[0..len];
}

// ---- modules and instances ----

pub const Module = struct {
    handle: c.wasm_module_t,

    /// Load wasm bytecode. WAMR reads and patches the buffer in place and
    /// keeps referring to it, so `bytes` must be writable, at least 4-byte
    /// aligned, and must outlive the Module.
    pub fn load(bytes: []u8, err: *ErrBuf) Error!Module {
        const handle = c.wasm_runtime_load(bytes.ptr, @intCast(bytes.len), &err.bytes, err.bytes.len) orelse
            return error.LoadFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Module) void {
        c.wasm_runtime_unload(self.handle);
        self.handle = null;
    }
};

/// Instantiation limits. Sizes are bytes except where noted.
pub const Limits = struct {
    /// Interpreter stack for this instance's execution environment.
    stack_bytes: u32 = 64 * 1024,
    /// Heap WAMR manages inside linear memory for wasm_runtime_module_malloc.
    /// Zero: the ABI routes host-to-plugin buffers through the module's own
    /// lk_alloc, so nothing needs it.
    heap_bytes: u32 = 0,
    /// Hard cap on linear memory, in 64 KiB wasm pages. 256 pages = 16 MiB,
    /// the default an ordinary plugin never approaches. Instantiation fails
    /// if the module's declared minimum memory exceeds it.
    max_memory_pages: u32 = 256,
};

/// The five exports every plugin provides (PROTOTYPE.md, ABI v0).
const abi_exports = struct {
    const abi = "lk_abi";
    const alloc = "lk_alloc";
    const free = "lk_free";
    const start = "lk_start";
    const event = "lk_event";
};

/// A (app address, length) range inside a plugin's linear memory.
pub const Buf = struct {
    off: u32,
    len: u32,
};

pub const Instance = struct {
    inst: c.wasm_module_inst_t,
    env: c.wasm_exec_env_t,
    fn_abi: c.wasm_function_inst_t,
    fn_alloc: c.wasm_function_inst_t,
    fn_free: c.wasm_function_inst_t,
    fn_start: c.wasm_function_inst_t,
    fn_event: c.wasm_function_inst_t,

    /// Instantiate under `limits` and resolve the ABI exports. A module
    /// missing any of the five is not a plugin, so this fails rather than
    /// deferring the error to the first call.
    pub fn init(module: Module, limits: Limits, err: *ErrBuf) Error!Instance {
        const args: c.InstantiationArgs = .{
            .default_stack_size = limits.stack_bytes,
            .host_managed_heap_size = limits.heap_bytes,
            .max_memory_pages = limits.max_memory_pages,
        };
        const inst = c.wasm_runtime_instantiate_ex(module.handle, &args, &err.bytes, err.bytes.len) orelse
            return error.InstantiateFailed;
        errdefer c.wasm_runtime_deinstantiate(inst);

        const env = c.wasm_runtime_create_exec_env(inst, limits.stack_bytes) orelse
            return error.ExecEnvFailed;
        errdefer c.wasm_runtime_destroy_exec_env(env);

        return .{
            .inst = inst,
            .env = env,
            .fn_abi = c.wasm_runtime_lookup_function(inst, abi_exports.abi) orelse return error.MissingExport,
            .fn_alloc = c.wasm_runtime_lookup_function(inst, abi_exports.alloc) orelse return error.MissingExport,
            .fn_free = c.wasm_runtime_lookup_function(inst, abi_exports.free) orelse return error.MissingExport,
            .fn_start = c.wasm_runtime_lookup_function(inst, abi_exports.start) orelse return error.MissingExport,
            .fn_event = c.wasm_runtime_lookup_function(inst, abi_exports.event) orelse return error.MissingExport,
        };
    }

    pub fn deinit(self: *Instance) void {
        c.wasm_runtime_destroy_exec_env(self.env);
        c.wasm_runtime_deinstantiate(self.inst);
        self.env = null;
        self.inst = null;
    }

    /// Pointer handed to every native this instance calls, via
    /// callerUserData(exec_env) — the broker's per-plugin state.
    pub fn setUserData(self: *Instance, ptr: ?*anyopaque) void {
        c.wasm_runtime_set_user_data(self.env, ptr);
    }

    /// WAMR's text for the last trap, or null. Cleared by clearException().
    pub fn exception(self: *Instance) ?[]const u8 {
        const msg = c.wasm_runtime_get_exception(self.inst) orelse return null;
        return std.mem.sliceTo(msg, 0);
    }

    pub fn clearException(self: *Instance) void {
        c.wasm_runtime_clear_exception(self.inst);
    }

    /// Any export beyond the five, by name. The host uses this for nothing;
    /// tests and future ABI versions do.
    pub fn lookup(self: *Instance, name: [:0]const u8) ?c.wasm_function_inst_t {
        return c.wasm_runtime_lookup_function(self.inst, name.ptr);
    }

    /// Call into the module. Results are written into `results`, which must
    /// have exactly as many slots as the function returns values.
    pub fn call(
        self: *Instance,
        func: c.wasm_function_inst_t,
        results: []c.wasm_val_t,
        args: []c.wasm_val_t,
    ) Error!void {
        const ok = c.wasm_runtime_call_wasm_a(
            self.env,
            func,
            @intCast(results.len),
            results.ptr,
            @intCast(args.len),
            args.ptr,
        );
        if (!ok) return error.Trap;
    }

    // ---- the five ABI exports ----

    /// lk_abi() — the ABI version the module speaks. 1 is the only one this
    /// host accepts; the caller decides what to do with anything else.
    pub fn abiVersion(self: *Instance) Error!u32 {
        var results: [1]c.wasm_val_t = undefined;
        try self.call(self.fn_abi, &results, &.{});
        return @bitCast(results[0].of.i32);
    }

    /// lk_alloc(len) — space inside the module for an inbound payload.
    /// Returns the app address; a module that cannot allocate returns null,
    /// which surfaces as PluginOutOfMemory.
    pub fn alloc(self: *Instance, len: u32) Error!Buf {
        var results: [1]c.wasm_val_t = undefined;
        var args = [_]c.wasm_val_t{iv32(@bitCast(len))};
        try self.call(self.fn_alloc, &results, &args);
        const off: u32 = @bitCast(results[0].of.i32);
        if (off == 0) return error.PluginOutOfMemory;
        return .{ .off = off, .len = len };
    }

    /// lk_free(ptr, len) — hand a buffer back.
    pub fn free(self: *Instance, buf: Buf) Error!void {
        var args = [_]c.wasm_val_t{ iv32(@bitCast(buf.off)), iv32(@bitCast(buf.len)) };
        try self.call(self.fn_free, &.{}, &args);
    }

    /// lk_start(ptr, len) — the start JSON. Non-zero means the plugin refused
    /// to start.
    pub fn start(self: *Instance, json: []const u8) Error!i32 {
        const buf = try self.writeAlloc(json);
        defer self.free(buf) catch {};
        var results: [1]c.wasm_val_t = undefined;
        var args = [_]c.wasm_val_t{ iv32(@bitCast(buf.off)), iv32(@bitCast(buf.len)) };
        try self.call(self.fn_start, &results, &args);
        return results[0].of.i32;
    }

    /// lk_event(kind, handle, ptr, len) with a payload already in plugin
    /// memory. The caller owns `payload` and frees it after the call, so one
    /// buffer can serve a burst of events.
    pub fn event(self: *Instance, kind: u32, handle: u64, payload: Buf) Error!i32 {
        var results: [1]c.wasm_val_t = undefined;
        var args = [_]c.wasm_val_t{
            iv32(@bitCast(kind)),
            iv64(@bitCast(handle)),
            iv32(@bitCast(payload.off)),
            iv32(@bitCast(payload.len)),
        };
        try self.call(self.fn_event, &results, &args);
        return results[0].of.i32;
    }

    /// lk_event with a host buffer: allocate inside the module, copy, call,
    /// free. The common path for a store update or a chunk of TCP data.
    pub fn eventWith(self: *Instance, kind: u32, handle: u64, payload: []const u8) Error!i32 {
        const buf = try self.writeAlloc(payload);
        defer self.free(buf) catch {};
        return self.event(kind, handle, buf);
    }

    // ---- linear memory ----

    /// A host slice over an (app address, length) range, rejecting anything
    /// outside linear memory. Valid only until the module's memory grows.
    pub fn slice(self: *Instance, off: u32, len: u32) Error![]u8 {
        return sliceOf(self.inst, off, len);
    }

    /// Allocate through the module's lk_alloc and copy `bytes` in. The
    /// returned Buf belongs to the caller, who passes it to lk_event/lk_start
    /// and then frees it.
    pub fn writeAlloc(self: *Instance, bytes: []const u8) Error!Buf {
        const buf = try self.alloc(@intCast(bytes.len));
        errdefer self.free(buf) catch {};
        const dst = try self.slice(buf.off, buf.len);
        @memcpy(dst, bytes);
        return buf;
    }
};

fn iv32(v: i32) c.wasm_val_t {
    return .{ .kind = c.WASM_I32, ._paddings = @splat(0), .of = .{ .i32 = v } };
}

fn iv64(v: i64) c.wasm_val_t {
    return .{ .kind = c.WASM_I64, ._paddings = @splat(0), .of = .{ .i64 = v } };
}
