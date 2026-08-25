//! The component list the licenses screen draws.
//!
//! vendor/licenses/licenses.json is maintained by hand. A dependency added to
//! this repo, to tile57 or to charttable belongs in it, including one that
//! arrives through another dependency: what links into the binary is what has
//! to be listed. The tests below are the only check on it.
//!
//! A shell keeps the entries whose `shells` array names it.

const std = @import("std");

/// The list, in the binary.
pub const json: []const u8 = @embedFile("licenses_json");

/// The shell ids an entry's `shells` array is drawn from.
pub const shell_ids = [_][]const u8{ "macos", "ios", "android", "linux", "windows" };

/// The shape a shell decodes.
const Manifest = struct {
    app: struct {
        name: []const u8,
        summary: []const u8,
        license: []const u8,
        copyright: []const u8,
        url: []const u8,
        text: []const u8,
    },
    components: []const struct {
        id: []const u8,
        name: []const u8,
        group: []const u8,
        summary: []const u8,
        license: []const u8,
        license_note: []const u8,
        version: []const u8,
        commit: []const u8,
        pinned_in: []const u8,
        copyright: []const u8,
        url: []const u8,
        shells: []const []const u8,
        text: []const u8,
        notice: []const u8,
    },
};

fn parse(alloc: std.mem.Allocator) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, alloc, json, .{});
}

test "the baked manifest parses into the shape the shells decode" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    try std.testing.expect(p.value.components.len > 0);
}

test "this app's own entry carries its terms" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    const a = p.value.app;
    try std.testing.expect(a.name.len > 0);
    try std.testing.expect(a.url.len > 0);
    try std.testing.expect(a.copyright.len > 0);
    try std.testing.expectEqualStrings("MIT", a.license);
    try std.testing.expect(std.mem.indexOf(u8, a.text, "MIT License") != null);
}

// A named license owes its text offline.
test "every component that names a license carries its text" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    for (p.value.components) |c| {
        if (c.license.len == 0) continue;
        std.testing.expect(c.text.len > 0) catch |e| {
            std.debug.print("{s} names a license and carries no text\n", .{c.id});
            return e;
        };
    }
}

// An unresolved license is allowed and has to say why: with no note it reads
// as a component with no terms.
test "a component with no license explains itself" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    for (p.value.components) |c| {
        if (c.license.len > 0) continue;
        try std.testing.expect(c.license_note.len > 0);
    }
}

test "every component is identified, described and placed" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    for (p.value.components) |c| {
        try std.testing.expect(c.id.len > 0);
        try std.testing.expect(c.name.len > 0);
        try std.testing.expect(c.group.len > 0);
        try std.testing.expect(c.summary.len > 0);
        try std.testing.expect(c.url.len > 0);
        try std.testing.expect(c.copyright.len > 0);
        try std.testing.expect(c.pinned_in.len > 0);
    }
}

// Without a version or a commit an entry names nothing checkable.
test "every component states a version or a commit" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    for (p.value.components) |c| {
        if (std.mem.eql(u8, c.id, "gshhg")) continue; // upstream publishes neither
        std.testing.expect(c.version.len > 0 or c.commit.len > 0) catch |e| {
            std.debug.print("{s} states neither a version nor a commit\n", .{c.id});
            return e;
        };
    }
}

test "every component ships on at least one known shell" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    for (p.value.components) |c| {
        try std.testing.expect(c.shells.len > 0);
        for (c.shells) |s| {
            var known = false;
            for (shell_ids) |id| {
                if (std.mem.eql(u8, s, id)) known = true;
            }
            std.testing.expect(known) catch |e| {
                std.debug.print("{s} names an unknown shell {s}\n", .{ c.id, s });
                return e;
            };
        }
    }
}

test "ids are unique" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    for (p.value.components, 0..) |c, i| {
        for (p.value.components[i + 1 ..]) |d| {
            try std.testing.expect(!std.mem.eql(u8, c.id, d.id));
        }
    }
}
