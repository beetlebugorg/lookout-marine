//! The settings store's C ABI (see include/lookout-shell.h).
//!
//! No handle: a shell reads its store before it opens anything, and the store
//! outlives whatever chart is up.

const std = @import("std");

const capi = @import("../capi.zig");
const settings = @import("../settings.zig");

const gpa = capi.gpa;
const capi_io = capi.capi_io;

pub const lookout_store = settings.Store;

fn count(out_n: ?*usize, n: usize) void {
    if (out_n) |p| p.* = n;
}

fn span(p: ?[*:0]const u8) []const u8 {
    return if (p) |s| std.mem.span(s) else "";
}

/// Open the store under `dir`. See lookout-shell.h.
export fn lookout_store_open(dir: ?[*:0]const u8) ?*lookout_store {
    const d = dir orelse return null;
    return settings.Store.open(gpa, capi_io, std.mem.span(d)) catch null;
}

/// Write anything waiting, then close.
export fn lookout_store_close(s: ?*lookout_store) void {
    if (s) |x| x.close();
}

/// Write anything waiting now, whatever the coalesce window says.
export fn lookout_store_flush(s: ?*lookout_store) void {
    if (s) |x| x.flush();
}

// ---- reading ------------------------------------------------------------------

export fn lookout_store_has(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8) c_int {
    const x = s orelse return 0;
    return @intFromBool(x.has(span(group), span(key)));
}

/// The value as text, or NULL when the key is not set. Borrowed until the next
/// write to this store.
export fn lookout_store_text(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8) ?[*:0]const u8 {
    const x = s orelse return null;
    const v = x.text(span(group), span(key)) orelse return null;
    return v.ptr;
}

export fn lookout_store_number(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8, fallback: f64) f64 {
    const x = s orelse return fallback;
    return x.number(span(group), span(key), fallback);
}

export fn lookout_store_flag(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8, fallback: c_int) c_int {
    const x = s orelse return fallback;
    return @intFromBool(x.flag(span(group), span(key), fallback != 0));
}

/// The value as a list. Borrowed until the next write to this store.
export fn lookout_store_list(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8, out_n: ?*usize) ?[*]const [*:0]const u8 {
    const x = s orelse {
        count(out_n, 0);
        return null;
    };
    const items = x.listPtrs(span(group), span(key));
    count(out_n, items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

/// The keys set under a group, in the order they were written. Borrowed until
/// the next write to this store.
export fn lookout_store_keys(s: ?*lookout_store, group: ?[*:0]const u8, out_n: ?*usize) ?[*]const [*:0]const u8 {
    const x = s orelse {
        count(out_n, 0);
        return null;
    };
    const items = x.keyPtrs(span(group));
    count(out_n, items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

// ---- writing ------------------------------------------------------------------

export fn lookout_store_set_text(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8, value: ?[*:0]const u8) void {
    const x = s orelse return;
    x.setText(span(group), span(key), span(value));
}

export fn lookout_store_set_number(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8, value: f64) void {
    const x = s orelse return;
    x.setNumber(span(group), span(key), value);
}

export fn lookout_store_set_flag(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8, value: c_int) void {
    const x = s orelse return;
    x.setFlag(span(group), span(key), value != 0);
}

/// Set a key to a list. An EMPTY list clears the key.
export fn lookout_store_set_list(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8, items: ?[*]const [*:0]const u8, n: usize) void {
    const x = s orelse return;
    if (items == null or n == 0) {
        x.remove(span(group), span(key));
        return;
    }
    var buf = std.ArrayList([]const u8).empty;
    defer buf.deinit(gpa);
    for (items.?[0..n]) |p| buf.append(gpa, std.mem.span(p)) catch return;
    x.setList(span(group), span(key), buf.items);
}

export fn lookout_store_remove(s: ?*lookout_store, group: ?[*:0]const u8, key: ?[*:0]const u8) void {
    const x = s orelse return;
    x.remove(span(group), span(key));
}

/// Hand a store to a chart handle. See lookout.h.
export fn lookout_set_store(h: ?*capi.lookout, s: ?*lookout_store) void {
    const l = capi.locked(h);
    defer l.apiUnlock();
    l.setStore(s);
}
