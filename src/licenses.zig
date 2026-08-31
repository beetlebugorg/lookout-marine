//! The component list the licenses screen draws.
//!
//! vendor/licenses/licenses.json is maintained by hand. A dependency added to
//! this repo, to tile57 or to charttable belongs in it, including one that
//! arrives through another dependency: what links into the binary is what has
//! to be listed. The tests below are the only check on it.
//!
//! A shell keeps the entries whose `shells` array names it.

const std = @import("std");
const owned = @import("owned");

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
        license_short: []const u8,
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

// ---- the read a shell draws ---------------------------------------------------

/// Above this many components a screen groups the rows under their headings and
/// offers a search. Below it the headings outnumber the rows.
pub const group_above: usize = 12;

/// One component, or this app's own terms. The app entry sets `name`,
/// `summary`, `license`, `copyright`, `url` and `text`, and leaves the rest
/// empty: it is not a component.
pub const Entry = extern struct {
    id: [*:0]const u8,
    name: [*:0]const u8,
    group: [*:0]const u8,
    summary: [*:0]const u8,
    license: [*:0]const u8,
    license_short: [*:0]const u8,
    license_note: [*:0]const u8,
    version: [*:0]const u8,
    commit: [*:0]const u8,
    pinned_in: [*:0]const u8,
    copyright: [*:0]const u8,
    url: [*:0]const u8,
    text: [*:0]const u8,
    notice: [*:0]const u8,
};

/// The components, plus this app's own entry beside them.
pub const Read = struct {
    inner: owned.Owned(Entry),
    app: *const Entry,

    pub fn free(self: *Read) void {
        const gpa = self.inner.arena.child_allocator;
        self.inner.arena.deinit();
        gpa.destroy(self);
    }

    pub fn rows(self: *const Read) []const *const Entry {
        return self.inner.rows;
    }
};

/// The components `shell` ships with, and this app's terms. `shell` is one of
/// `shell_ids`. A shell the manifest never names gets the app entry and no
/// components.
pub fn read(gpa: std.mem.Allocator, shell: []const u8) !*Read {
    const self = try gpa.create(Read);
    errdefer gpa.destroy(self);
    self.* = .{
        .inner = .{ .arena = std.heap.ArenaAllocator.init(gpa) },
        .app = undefined,
    };
    errdefer self.inner.arena.deinit();
    const a = self.inner.arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(Manifest, a, json, .{});
    const none = try owned.str(a, "");

    const app = try a.create(Entry);
    app.* = .{
        .id = none,
        .name = try owned.str(a, parsed.app.name),
        .group = none,
        .summary = try owned.str(a, parsed.app.summary),
        .license = try owned.str(a, parsed.app.license),
        .license_short = none,
        .license_note = none,
        .version = none,
        .commit = none,
        .pinned_in = none,
        .copyright = try owned.str(a, parsed.app.copyright),
        .url = try owned.str(a, parsed.app.url),
        .text = try owned.str(a, parsed.app.text),
        .notice = none,
    };
    self.app = app;

    var kept = std.ArrayList(*const Entry).empty;
    for (parsed.components) |c| {
        var carries = false;
        for (c.shells) |s| {
            if (std.mem.eql(u8, s, shell)) carries = true;
        }
        if (!carries) continue;
        const e = try a.create(Entry);
        e.* = .{
            .id = try owned.str(a, c.id),
            .name = try owned.str(a, c.name),
            .group = try owned.str(a, c.group),
            .summary = try owned.str(a, c.summary),
            .license = try owned.str(a, c.license),
            .license_short = try owned.str(a, c.license_short),
            .license_note = try owned.str(a, c.license_note),
            .version = try owned.str(a, c.version),
            .commit = try owned.str(a, c.commit),
            .pinned_in = try owned.str(a, c.pinned_in),
            .copyright = try owned.str(a, c.copyright),
            .url = try owned.str(a, c.url),
            .text = try owned.str(a, c.text),
            .notice = try owned.str(a, c.notice),
        };
        try kept.append(a, e);
    }
    self.inner.rows = kept.items;
    return self;
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

// The column a shell lists a component in is narrow, so the terms are named
// there in short. Twenty characters is what fits beside the version.
test "every component that names a license names it in short" {
    const p = try parse(std.testing.allocator);
    defer p.deinit();
    for (p.value.components) |c| {
        if (c.license.len == 0) continue;
        std.testing.expect(c.license_short.len > 0 and c.license_short.len <= 20) catch |e| {
            std.debug.print("{s} has no short license name, or one too long\n", .{c.id});
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

test "a read holds the components one shell ships with and no others" {
    const a = std.testing.allocator;
    const p = try parse(a);
    defer p.deinit();

    for (shell_ids) |id| {
        const r = try read(a, id);
        defer r.free();
        var want: usize = 0;
        for (p.value.components) |c| {
            for (c.shells) |s| {
                if (std.mem.eql(u8, s, id)) want += 1;
            }
        }
        try std.testing.expectEqual(want, r.rows().len);
        for (r.rows()) |e| try std.testing.expect(std.mem.span(e.id).len > 0);
    }
}

test "a read says what the manifest says, field for field" {
    const a = std.testing.allocator;
    const p = try parse(a);
    defer p.deinit();
    const r = try read(a, "macos");
    defer r.free();

    var seen: usize = 0;
    for (p.value.components) |c| {
        var carries = false;
        for (c.shells) |s| {
            if (std.mem.eql(u8, s, "macos")) carries = true;
        }
        if (!carries) continue;
        const e = r.rows()[seen];
        seen += 1;
        try std.testing.expectEqualStrings(c.id, std.mem.span(e.id));
        try std.testing.expectEqualStrings(c.name, std.mem.span(e.name));
        try std.testing.expectEqualStrings(c.group, std.mem.span(e.group));
        try std.testing.expectEqualStrings(c.summary, std.mem.span(e.summary));
        try std.testing.expectEqualStrings(c.license, std.mem.span(e.license));
        try std.testing.expectEqualStrings(c.license_short, std.mem.span(e.license_short));
        try std.testing.expectEqualStrings(c.license_note, std.mem.span(e.license_note));
        try std.testing.expectEqualStrings(c.version, std.mem.span(e.version));
        try std.testing.expectEqualStrings(c.commit, std.mem.span(e.commit));
        try std.testing.expectEqualStrings(c.pinned_in, std.mem.span(e.pinned_in));
        try std.testing.expectEqualStrings(c.copyright, std.mem.span(e.copyright));
        try std.testing.expectEqualStrings(c.url, std.mem.span(e.url));
        try std.testing.expectEqualStrings(c.text, std.mem.span(e.text));
        try std.testing.expectEqualStrings(c.notice, std.mem.span(e.notice));
    }
    try std.testing.expectEqual(seen, r.rows().len);
}

test "this app's own entry rides beside the components, out of the count" {
    const a = std.testing.allocator;
    const p = try parse(a);
    defer p.deinit();
    const r = try read(a, "macos");
    defer r.free();

    try std.testing.expectEqualStrings(p.value.app.name, std.mem.span(r.app.name));
    try std.testing.expectEqualStrings(p.value.app.license, std.mem.span(r.app.license));
    try std.testing.expectEqualStrings(p.value.app.text, std.mem.span(r.app.text));
    // The fields only a component has are empty on the app entry.
    try std.testing.expectEqualStrings("", std.mem.span(r.app.id));
    try std.testing.expectEqualStrings("", std.mem.span(r.app.group));
    for (r.rows()) |e| try std.testing.expect(e != r.app);
}

test "a shell the manifest never names carries nothing" {
    const a = std.testing.allocator;
    const r = try read(a, "amiga");
    defer r.free();
    try std.testing.expectEqual(@as(usize, 0), r.rows().len);
    // The app's own terms still ship.
    try std.testing.expect(std.mem.span(r.app.name).len > 0);
}
