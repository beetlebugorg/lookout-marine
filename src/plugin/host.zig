//! The plugin registry, instance lifecycle and event loop.
//!
//! WHAT THIS FILE DOES. It turns a directory of manifests and .wasm modules
//! into running plugins: read the manifest, instantiate the module through
//! `wasm.zig`, hand it `lk_start`, then deliver events from the broker's queue
//! one at a time until shutdown. It owns nothing about what an event MEANS —
//! that is broker.zig — and nothing about the runtime's C API — that is
//! wasm.zig.
//!
//! THE API root.zig DRIVES
//!
//!   var h = try Host.init(alloc, &broker, .{});   // once
//!   defer h.deinit();
//!   try h.loadDir("zig-out/plugins");             // manifests + modules
//!   try h.start();                                // dispatch thread
//!   ...
//!   h.stop();                                     // SHUTDOWN, best effort
//!
//! ONE DISPATCH THREAD PER PLUGIN, each draining that plugin's own FIFO in the
//! broker. PROTOTYPE.md requires one event at a time PER plugin, which this
//! still gives: a plugin is entered by exactly one thread, ever. What it adds
//! is TIME ISOLATION — a plugin that takes a second over an event, or never
//! returns at all, delays nobody but itself. The single shared thread the
//! prototype started with made every plugin as slow as the slowest one.
//!
//! THE WATCHDOG is the other half of that. A dispatch thread publishes the
//! monotonic time at which it entered the module; the broker's 100 ms tick
//! reads those stamps on the I/O thread and terminates any instance that has
//! been inside longer than `Options.event_budget_ms`. The terminated call
//! comes back as a trap, lands in the ordinary disable path, and the plugin's
//! thread exits. The I/O thread never joins or waits on a stuck thread — if it
//! did, one bad plugin would take the sockets and timers down with it.
//!
//! LIFETIMES WAMR IMPOSES. Two buffers must outlive an instance and neither is
//! copied by the runtime: the module BYTES (loaded in place and patched) and
//! the NativeSymbol array (broker.zig holds that one in a container-level var).
//! Each registry entry therefore owns its byte buffer until the instance is
//! gone. The registry itself must not move while the dispatch threads are
//! running — each holds a pointer into it — so loading is refused once `start`
//! has been called.
//!
//! A TRAPPED PLUGIN IS DISABLED, not retried. WAMR's exception text is logged,
//! the instance is left instantiated but never entered again, and everything
//! the plugin contributed — overlay objects, vessel paths, AIS targets,
//! sockets, timers, queued events — is dropped. A chartplotter that keeps
//! drawing the last position a crashed plugin published is worse than one that
//! draws nothing.

const std = @import("std");
const builtin = @import("builtin");

pub const wasm = @import("wasm.zig");
pub const store = @import("store.zig");
pub const aisstore = @import("aisstore.zig");
pub const broker = @import("broker.zig");
pub const webio = @import("webio.zig");

const io = std.Io.Threaded.global_single_threaded.io();

/// The API version this host speaks. A module reporting anything else is not
/// loaded — the exports may have the same names and a different meaning.
pub const api_version: u32 = 1;

/// Largest plugin module accepted. The prototype's plugins are tens of KiB;
/// the cap is here so a stray file in the plugin directory cannot be read into
/// memory whole.
pub const max_module_bytes: usize = 8 * 1024 * 1024;
pub const max_manifest_bytes: usize = 64 * 1024;

/// Longest version string a manifest may carry. "2024.12.31-rc1" is 14 bytes.
pub const max_version_bytes: usize = 32;

pub const Error = error{
    BadManifest,
    ApiMismatch,
    StartRefused,
    /// `configSet` named an id no plugin here answers to.
    UnknownPlugin,
    /// The config JSON is not an object, or a field it names does not match
    /// the kind the schema declares.
    BadConfig,
    /// `grantFile` named a plugin whose manifest did not ask for `files`, or
    /// `grantSet` named a capability the manifest never asked for.
    NotGranted,
    /// Two manifests claim the file type the mariner opened. Neither gets the
    /// file: see `openFile`.
    FileTypeConflict,
    /// A .lkplug was refused. The sentence saying why — the one the shell
    /// shows — is in `installMessage`.
    PackageRefused,
    /// `uninstall` named a bundled or developer plugin. Only what install put
    /// on disk can be taken off it.
    NotInstalled,
    /// `grantSet` named a capability no manifest could declare.
    UnknownCapability,
    /// This platform has no per-user plugin directory and `Options.install_root`
    /// was not set (Android's files dir has no path in the environment).
    NoInstallRoot,
    OutOfMemory,
};

/// Where a settings group asks to be shown. These are TOPICS the shell owns,
/// never plugin names: a mariner hunting the collision alarm finds it under
/// Alarms, beside every other alarm, and never learns that a plugin put it
/// there.
///
/// An unknown or absent target falls back to `advanced`, so a typo in a
/// manifest cannot invent a tab of its own.
pub const Tab = enum {
    display,
    depths,
    text,
    charts,
    vessels,
    alarms,
    connections,
    advanced,

    pub fn fromName(s: []const u8) Tab {
        return std.meta.stringToEnum(Tab, s) orelse .advanced;
    }
};

/// One settings field a manifest declares. A shell renders these; the plugin
/// receives their values and nothing else.
///
/// A number field is clamped to `min`..`max` on the way in, so a plugin never
/// has to defend against a setting outside the range it published.
pub const Field = struct {
    key: []u8,
    /// What the shell shows beside the control. Defaults to the key.
    label: []u8,
    /// One sentence on what the setting does for the person at the helm. Empty
    /// when the manifest declares none.
    desc: []u8,
    /// The unit of a number field, for display only: values cross the API in
    /// the unit the schema names.
    unit: []u8,
    /// The section heading this field sits under, from its group. Empty when
    /// the schema declares no groups.
    group: []u8,
    /// The tab the field's group asked for.
    tab: Tab = .advanced,
    kind: Kind,
    min: f64 = 0,
    max: f64 = 0,
    /// A toggle's default is 0 or 1.
    default_value: f64 = 0,
    /// A text field's default. Empty for the other kinds.
    default_text: []u8 = &.{},
    /// A text field the mariner may leave empty. The shell says so; the plugin
    /// decides what an empty one means.
    optional: bool = false,

    /// `text` is only legal inside a LIST: a scalar value crosses the API as a
    /// number, and there is nowhere to keep a scalar string.
    pub const Kind = enum { number, toggle, text };
};

/// Longest settings schema a manifest may declare. A pane a mariner has to
/// scroll past is a pane nobody reads at sea.
pub const max_fields = 16;

/// Longest text value the host keeps. A host name is 253 bytes at most; this
/// holds any of them plus a name a mariner would type.
pub const max_text_bytes = 128;

/// A group the mariner adds ROWS to — connections, waypoints, anything there
/// can be more than one of. The config value of `key` is a JSON array of row
/// objects, replaced whole on every edit, and delivered like any other setting
/// through CONFIG_CHANGED.
///
/// Every row carries an `id` the shell assigns when it adds the row. The plugin
/// echoes that id in its status items, which is how one row's "connected" is
/// told from another's.
pub const List = struct {
    key: []u8,
    /// The section heading, from the group's label.
    group: []u8,
    tab: Tab,
    /// The columns of one row.
    items: []Field,
    /// The sentence under the section: what these rows are and what a mariner
    /// needs to know to fill one in. Empty when the manifest declares none.
    footer: []u8 = &.{},
    /// What the section says when it holds no rows yet.
    empty: []u8 = &.{},
    /// The wording on the button that adds a row, for example "Add Server".
    add_label: []u8 = &.{},
    /// Which toggle column is the row's own on/off switch — the one a shell
    /// draws on the row's line rather than inside it. Empty means the first
    /// toggle column, which is what a list with one toggle wants.
    switch_key: []u8 = &.{},
};

/// Most rows one list may hold, and the longest row id kept. Eight NMEA
/// gateways is already more than any boat this prototype targets.
pub const max_list_rows = 8;
pub const max_row_id = 32;

/// How long a plugin may stay inside ONE module call before the watchdog
/// terminates it.
///
/// A second is enormous for an event handler — the prototype's four take
/// microseconds — and small enough that a mariner watching a stuck plugin
/// disappear never sees the chart stall. Precision is one tick of the broker's
/// 100 ms I/O loop, so the kill lands between budget and budget + 100 ms; the
/// number is a floor on patience, not a deadline anybody meets exactly.
///
/// One budget for every plugin. Per-plugin budgets out of the manifest, and
/// criticality tiers that would let a chart-drawing plugin die while the
/// autopilot's is given longer, are the obvious next thing and are not built.
pub const default_event_budget_ms: i64 = 1000;

/// A plugin's manifest.json:
/// `{"id":"org.beetlebug.ais","name":"AIS","api":1,"capabilities":[...],
///   "settings":{"groups":[{"label":"Collision alarm","tab":"alarms","fields":[
///     {"key":"cpa_limit","label":"Closest approach","desc":"Alarm when a
///      vessel will pass closer than this.","kind":"number","unit":"m",
///      "min":93,"max":9260,"default":926}]}]}}`.
///
/// Schema v1 — `"settings"` as a bare array of fields — still parses. Those
/// fields carry no group and land on the fallback tab.
///
/// A group may be a LIST instead of a set of fields:
/// `{"label":"Connections","tab":"connections","list":{"key":"connections",
///   "item_fields":[{"key":"host","kind":"text"},…]}}`.
///
/// A manifest may also claim FILE TYPES: `"file_types":[".grib2",".grb"]`. The
/// mariner opens one of those files the way they open a chart, and `openFile`
/// hands it to this plugin.
pub const Manifest = struct {
    id: []u8,
    name: []u8,
    /// The manifest's `"version"` string, or empty when it declares none. The
    /// consent sheet and the settings rows show it; the host compares it only
    /// to say that a reinstall is a downgrade.
    version: []u8 = &.{},
    api: u32,
    caps: broker.Caps,
    /// The hosts `net.http` named, and the hosts `net.ws` named. Empty unless
    /// the capability was granted, and a granted one is never empty.
    http_hosts: [][]u8 = &.{},
    ws_hosts: [][]u8 = &.{},
    /// The file extensions this plugin claims, each lowercase and with the
    /// leading dot. Empty unless the manifest declares some, and never
    /// non-empty without the `files` capability.
    file_types: [][]u8 = &.{},
    /// The settings schema, empty when the manifest declares none.
    settings: []Field = &.{},
    /// The repeating groups, empty when the manifest declares none.
    lists: []List = &.{},

    pub fn deinit(self: *Manifest, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        if (self.version.len > 0) alloc.free(self.version);
        freeStrings(alloc, self.http_hosts);
        freeStrings(alloc, self.ws_hosts);
        freeStrings(alloc, self.file_types);
        freeFields(alloc, self.settings, self.settings.len);
        freeLists(alloc, self.lists, self.lists.len);
        self.* = undefined;
    }

    /// True when this plugin claims `ext`, which must already be lowercase and
    /// carry its dot — `fileExtension` gives it in that form.
    pub fn claimsFileType(self: *const Manifest, ext: []const u8) bool {
        for (self.file_types) |ft| {
            if (std.mem.eql(u8, ft, ext)) return true;
        }
        return false;
    }

    pub fn field(self: *const Manifest, key: []const u8) ?usize {
        for (self.settings, 0..) |f, i| {
            if (std.mem.eql(u8, f.key, key)) return i;
        }
        return null;
    }

    pub fn list(self: *const Manifest, key: []const u8) ?usize {
        for (self.lists, 0..) |l, i| {
            if (std.mem.eql(u8, l.key, key)) return i;
        }
        return null;
    }
};

/// One settings field out of a manifest. Everything the shell needs to draw a
/// control, and everything `configSet` needs to police one. `group` and `tab`
/// come from the group the field was declared in.
fn parseField(alloc: std.mem.Allocator, v: std.json.Value, group: []const u8, tab: Tab) !Field {
    if (v != .object) return Error.BadManifest;
    const o = v.object;
    const key = switch (o.get("key") orelse return Error.BadManifest) {
        .string => |s| s,
        else => return Error.BadManifest,
    };
    if (key.len == 0 or key.len > 32) return Error.BadManifest;
    const kind_text = switch (o.get("kind") orelse return Error.BadManifest) {
        .string => |s| s,
        else => return Error.BadManifest,
    };
    const kind = std.meta.stringToEnum(Field.Kind, kind_text) orelse return Error.BadManifest;
    const label = switch (o.get("label") orelse std.json.Value{ .string = key }) {
        .string => |s| s,
        else => key,
    };
    const unit = switch (o.get("unit") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    const desc = switch (o.get("desc") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };

    const default_text = switch (o.get("default") orelse std.json.Value{ .string = "" }) {
        .string => |s| if (s.len <= max_text_bytes) s else return Error.BadManifest,
        else => "",
    };

    var f = Field{
        .key = try alloc.dupe(u8, key),
        .label = undefined,
        .desc = undefined,
        .unit = undefined,
        .group = undefined,
        .tab = tab,
        .kind = kind,
        .optional = switch (o.get("optional") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        },
    };
    errdefer alloc.free(f.key);
    f.label = try alloc.dupe(u8, label);
    errdefer alloc.free(f.label);
    f.desc = try alloc.dupe(u8, desc);
    errdefer alloc.free(f.desc);
    f.unit = try alloc.dupe(u8, unit);
    errdefer alloc.free(f.unit);
    f.group = try alloc.dupe(u8, group);
    errdefer alloc.free(f.group);
    f.default_text = try alloc.dupe(u8, if (kind == .text) default_text else "");
    errdefer alloc.free(f.default_text);

    switch (kind) {
        .number => {
            f.min = jsonNumber(o.get("min")) orelse return Error.BadManifest;
            f.max = jsonNumber(o.get("max")) orelse return Error.BadManifest;
            if (!(f.max > f.min)) return Error.BadManifest;
            const d = jsonNumber(o.get("default")) orelse return Error.BadManifest;
            f.default_value = std.math.clamp(d, f.min, f.max);
        },
        .toggle => {
            f.max = 1;
            f.default_value = switch (o.get("default") orelse return Error.BadManifest) {
                .bool => |b| if (b) 1 else 0,
                else => return Error.BadManifest,
            };
        },
        // A text field needs no range and may declare no default at all: an
        // empty string is a usable starting point for a host name.
        .text => f.max = max_text_bytes,
    }
    return f;
}

fn jsonNumber(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |x| if (std.math.isFinite(x)) x else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Parse a manifest. Unknown capability names are refused rather than ignored:
/// a typo in a grant is a plugin that silently loses a permission at sea.
pub fn parseManifest(alloc: std.mem.Allocator, json: []const u8) !Manifest {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return Error.BadManifest;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.BadManifest;
    const o = parsed.value.object;

    const id = switch (o.get("id") orelse return Error.BadManifest) {
        .string => |s| s,
        else => return Error.BadManifest,
    };
    if (id.len == 0 or id.len > 128) return Error.BadManifest;
    const name = switch (o.get("name") orelse std.json.Value{ .string = id }) {
        .string => |s| s,
        else => id,
    };
    const api: u32 = switch (o.get("api") orelse return Error.BadManifest) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return Error.BadManifest,
        else => return Error.BadManifest,
    };
    // The version is a label the mariner reads, not a scheme the host enforces.
    // Anything that is not a short string refuses the manifest: a version that
    // cannot be shown is a typo, not a version.
    const version = switch (o.get("version") orelse std.json.Value{ .string = "" }) {
        .string => |s| if (s.len <= max_version_bytes) s else return Error.BadManifest,
        else => return Error.BadManifest,
    };

    // A capability is a NAME, or a one-key object whose value is the list of
    // hosts the grant covers: `{"net.http":["nomads.ncep.noaa.gov"]}`. The
    // object form exists because "may reach the internet" is not a permission
    // a mariner can weigh, and "may reach nomads.ncep.noaa.gov" is.
    var caps = broker.Caps.initEmpty();
    var http_hosts: [][]u8 = &.{};
    var ws_hosts: [][]u8 = &.{};
    var file_types: [][]u8 = &.{};
    errdefer freeStrings(alloc, http_hosts);
    errdefer freeStrings(alloc, ws_hosts);
    errdefer freeStrings(alloc, file_types);
    if (o.get("capabilities")) |c| {
        if (c != .array) return Error.BadManifest;
        for (c.array.items) |item| switch (item) {
            .string => |text| {
                const cap = broker.Cap.fromName(text) orelse return Error.BadManifest;
                if (cap.needsHosts()) return Error.BadManifest;
                caps.insert(cap);
            },
            .object => |entry| {
                if (entry.count() != 1) return Error.BadManifest;
                var it = entry.iterator();
                const kv = it.next().?;
                const cap = broker.Cap.fromName(kv.key_ptr.*) orelse return Error.BadManifest;
                if (!cap.needsHosts()) return Error.BadManifest;
                const hosts = try parseHosts(alloc, kv.value_ptr.*);
                errdefer freeStrings(alloc, hosts);
                switch (cap) {
                    .net_http => {
                        if (http_hosts.len > 0) return Error.BadManifest;
                        http_hosts = hosts;
                    },
                    .net_ws => {
                        if (ws_hosts.len > 0) return Error.BadManifest;
                        ws_hosts = hosts;
                    },
                    else => unreachable,
                }
                caps.insert(cap);
            },
            else => return Error.BadManifest,
        };
    }

    // The file types the plugin claims. `files` is what the grant actually
    // rests on, so a manifest that claims a type without it is refused rather
    // than loaded with a claim it could never act on.
    if (o.get("file_types")) |v| {
        if (!caps.contains(.files)) return Error.BadManifest;
        file_types = try parseFileTypes(alloc, v);
    }

    const id_owned = try alloc.dupe(u8, id);
    errdefer alloc.free(id_owned);
    const name_owned = try alloc.dupe(u8, name);
    errdefer alloc.free(name_owned);
    const version_owned: []u8 = if (version.len > 0) try alloc.dupe(u8, version) else &.{};
    errdefer if (version_owned.len > 0) alloc.free(version_owned);

    // `built` counts the fields already allocated, so a malformed field
    // halfway down the schema frees exactly the ones before it. `lists_built`
    // does the same for the repeating groups.
    var fields: []Field = &.{};
    var built: usize = 0;
    errdefer freeFields(alloc, fields, built);
    var lists: []List = &.{};
    var lists_built: usize = 0;
    errdefer freeLists(alloc, lists, lists_built);
    if (o.get("settings")) |sv| switch (sv) {
        // v1: a bare array of fields, no groups, no tab.
        .array => |arr| {
            if (arr.items.len > max_fields) return Error.BadManifest;
            fields = try alloc.alloc(Field, arr.items.len);
            try appendFields(alloc, arr.items, "", .advanced, fields, &built);
        },
        // v2: groups, each naming its heading and the tab it belongs to. One
        // plugin's settings may span tabs. A group holds `fields`, or a `list`
        // the mariner adds rows to.
        .object => |so| {
            const groups = switch (so.get("groups") orelse return Error.BadManifest) {
                .array => |g| g.items,
                else => return Error.BadManifest,
            };
            var total: usize = 0;
            var list_count: usize = 0;
            for (groups) |gv| {
                const go = switch (gv) {
                    .object => |x| x,
                    else => return Error.BadManifest,
                };
                if (go.get("list")) |_| {
                    list_count += 1;
                    continue;
                }
                total += switch (go.get("fields") orelse return Error.BadManifest) {
                    .array => |a| a.items.len,
                    else => return Error.BadManifest,
                };
            }
            if (total > max_fields) return Error.BadManifest;
            fields = try alloc.alloc(Field, total);
            if (list_count > 0) lists = try alloc.alloc(List, list_count);
            for (groups) |gv| {
                const go = gv.object;
                const label = switch (go.get("label") orelse std.json.Value{ .string = "" }) {
                    .string => |s| s,
                    else => "",
                };
                const tab = switch (go.get("tab") orelse std.json.Value{ .string = "" }) {
                    .string => |s| Tab.fromName(s),
                    else => .advanced,
                };
                if (go.get("list")) |lv| {
                    lists[lists_built] = try parseList(alloc, lv, label, tab);
                    lists_built += 1;
                    continue;
                }
                try appendFields(alloc, go.get("fields").?.array.items, label, tab, fields, &built);
            }
            // One key, one value: a list may not shadow a field or another
            // list, or a config object would have to carry both.
            for (lists[0..lists_built], 0..) |l, i| {
                if (fieldIndex(fields[0..built], l.key) != null) return Error.BadManifest;
                for (lists[0..i]) |g| {
                    if (std.mem.eql(u8, g.key, l.key)) return Error.BadManifest;
                }
            }
        },
        else => return Error.BadManifest,
    };
    // A text value has nowhere to live outside a row: the scalar settings cross
    // the API as numbers.
    for (fields[0..built]) |f| {
        if (f.kind == .text) return Error.BadManifest;
    }
    return .{
        .id = id_owned,
        .name = name_owned,
        .version = version_owned,
        .api = api,
        .caps = caps,
        .http_hosts = http_hosts,
        .ws_hosts = ws_hosts,
        .file_types = file_types,
        .settings = fields,
        .lists = lists,
    };
}

/// Most file types one plugin may claim. A plugin that answers for nine kinds
/// of file is one whose grant sentence nobody can read.
pub const max_file_types = 8;

/// Longest file type, the dot counted. `.pmtiles` is eight bytes.
pub const max_file_type = 16;

/// The file types a `"file_types":[…]` entry names. Each must be written the
/// way the routing compares them — lowercase, with the leading dot and nothing
/// else — because a manifest that says ".GRIB2" or "grib2" would read as a
/// claim and never match a file.
///
/// An empty list refuses the manifest: it is the same claim as not asking,
/// written in a way that looks like asking.
fn parseFileTypes(alloc: std.mem.Allocator, v: std.json.Value) ![][]u8 {
    if (v != .array) return Error.BadManifest;
    const items = v.array.items;
    if (items.len == 0 or items.len > max_file_types) return Error.BadManifest;
    const out = try alloc.alloc([]u8, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |ft| alloc.free(ft);
        alloc.free(out);
    }
    for (items) |item| {
        const text = switch (item) {
            .string => |s| s,
            else => return Error.BadManifest,
        };
        if (text.len < 2 or text.len > max_file_type) return Error.BadManifest;
        if (text[0] != '.') return Error.BadManifest;
        // One extension, not a compound one: `.tar.gz` cannot be matched by the
        // last-dot rule the routing uses, so it is refused instead of ignored.
        for (text[1..]) |c| switch (c) {
            'a'...'z', '0'...'9' => {},
            else => return Error.BadManifest,
        };
        for (out[0..built]) |seen| {
            if (std.mem.eql(u8, seen, text)) return Error.BadManifest;
        }
        out[built] = try alloc.dupe(u8, text);
        built += 1;
    }
    return out;
}

/// The extensions the CHART side of the application owns: the baked vector
/// cells the core opens, and the picture charts the raster layer adds. A plugin
/// may name one, and it is never routed one — the mariner's charts keep the
/// path they have always taken.
const chart_extensions = [_][]const u8{ ".pmtiles", ".mbtiles" };

/// The lowercase extension of `path`, dot included, written into `buf`.
///
/// Null when the name carries no dot, when the dot begins the name (`.profile`
/// is a hidden file, not a file type), or when what follows is longer than a
/// manifest may claim. macOS hands back the name the mariner's disk holds, so
/// `GFS.GRIB2` and `gfs.grib2` must reach the same plugin.
pub fn fileExtension(path: []const u8, buf: []u8) ?[]const u8 {
    var base = path;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |slash| base = base[slash + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    if (dot == 0) return null;
    const ext = base[dot..];
    if (ext.len < 2 or ext.len > buf.len or ext.len > max_file_type) return null;
    return std.ascii.lowerString(buf, ext);
}

/// Most hosts one capability may name. A plugin that needs nine servers is a
/// plugin nobody can read the grant sentence for.
pub const max_hosts = 8;

/// The hosts a `{"net.http":[…]}` entry names. An empty list refuses the
/// manifest: it is the same grant as not asking, written in a way that looks
/// like asking.
fn parseHosts(alloc: std.mem.Allocator, v: std.json.Value) ![][]u8 {
    if (v != .array) return Error.BadManifest;
    const items = v.array.items;
    if (items.len == 0 or items.len > max_hosts) return Error.BadManifest;
    const out = try alloc.alloc([]u8, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |h| alloc.free(h);
        alloc.free(out);
    }
    for (items) |item| {
        const text = switch (item) {
            .string => |s| s,
            else => return Error.BadManifest,
        };
        // `local` is the one entry that is not a hostname: it grants this
        // boat's own network, for a plugin whose server is a mariner's setting.
        if (std.mem.eql(u8, text, broker.local_token)) {
            out[built] = try alloc.dupe(u8, text);
            built += 1;
            continue;
        }
        // Otherwise a hostname, not a URL and not a pattern: no scheme, no
        // path, no port and no wildcard. The check is against what the URL's
        // host resolves to, so anything else could never match and would read
        // as a grant that does nothing.
        if (text.len == 0 or text.len > 253) return Error.BadManifest;
        for (text) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', ':' => {},
            else => return Error.BadManifest,
        };
        out[built] = try alloc.dupe(u8, text);
        built += 1;
    }
    return out;
}

/// The owned string lists a manifest holds: hosts, and file types.
fn freeStrings(alloc: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| alloc.free(s);
    if (list.len > 0) alloc.free(list);
}

/// Longest sentence a list may put around its rows. Room for two lines of
/// caption and no more: a settings section is not documentation.
pub const max_list_text = 240;

/// One optional string of a list's own wording. Anything that is not a string,
/// or is too long, reads as absent — a caption is never worth refusing a
/// manifest over.
fn listText(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    const s = switch (v) {
        .string => |text| text,
        else => return "",
    };
    return if (s.len > max_list_text) s[0..max_list_text] else s;
}

/// One repeating group: the key its rows are stored under, and the fields one
/// row holds.
fn parseList(alloc: std.mem.Allocator, v: std.json.Value, group: []const u8, tab: Tab) !List {
    if (v != .object) return Error.BadManifest;
    const o = v.object;
    const key = switch (o.get("key") orelse return Error.BadManifest) {
        .string => |s| s,
        else => return Error.BadManifest,
    };
    if (key.len == 0 or key.len > 32) return Error.BadManifest;
    const raw = switch (o.get("item_fields") orelse return Error.BadManifest) {
        .array => |a| a.items,
        else => return Error.BadManifest,
    };
    if (raw.len == 0 or raw.len > max_fields) return Error.BadManifest;

    var l = List{
        .key = try alloc.dupe(u8, key),
        .group = undefined,
        .tab = tab,
        .items = &.{},
    };
    errdefer alloc.free(l.key);
    l.group = try alloc.dupe(u8, group);
    errdefer alloc.free(l.group);
    // The three sentences the settings window puts around the rows. They belong
    // to the plugin because only the plugin knows what a row IS: two lists on
    // one tab would otherwise both wear whichever one the application hard-coded.
    l.footer = try alloc.dupe(u8, listText(o, "footer"));
    errdefer alloc.free(l.footer);
    l.empty = try alloc.dupe(u8, listText(o, "empty"));
    errdefer alloc.free(l.empty);
    l.add_label = try alloc.dupe(u8, listText(o, "add_label"));
    errdefer alloc.free(l.add_label);
    l.switch_key = try alloc.dupe(u8, listText(o, "switch_key"));
    errdefer alloc.free(l.switch_key);

    const items = try alloc.alloc(Field, raw.len);
    var built: usize = 0;
    errdefer freeFields(alloc, items, built);
    try appendFields(alloc, raw, group, tab, items, &built);
    // `id` is the host's, on every row. A column of that name would fight it.
    for (items) |f| {
        if (std.mem.eql(u8, f.key, "id")) return Error.BadManifest;
    }
    // A switch that names a column the list does not have, or one that is not
    // a toggle, would leave the shell drawing no switch at all.
    if (l.switch_key.len > 0) {
        const at = fieldIndex(items, l.switch_key) orelse return Error.BadManifest;
        if (items[at].kind != .toggle) return Error.BadManifest;
    }
    l.items = items;
    return l;
}

fn fieldIndex(fields: []const Field, key: []const u8) ?usize {
    for (fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.key, key)) return i;
    }
    return null;
}

/// Parse one group's fields into `fields`, from `built` on. Two fields with one
/// key would give the shell two controls over the same value, so a repeat
/// refuses the manifest.
fn appendFields(
    alloc: std.mem.Allocator,
    items: []const std.json.Value,
    group: []const u8,
    tab: Tab,
    fields: []Field,
    built: *usize,
) !void {
    for (items) |item| {
        fields[built.*] = try parseField(alloc, item, group, tab);
        built.* += 1;
        for (fields[0 .. built.* - 1]) |g| {
            if (std.mem.eql(u8, g.key, fields[built.* - 1].key)) return Error.BadManifest;
        }
    }
}

fn freeFields(alloc: std.mem.Allocator, fields: []Field, built: usize) void {
    for (fields[0..built]) |f| {
        alloc.free(f.key);
        alloc.free(f.label);
        alloc.free(f.desc);
        alloc.free(f.unit);
        alloc.free(f.group);
        alloc.free(f.default_text);
    }
    if (fields.len > 0) alloc.free(fields);
}

fn freeLists(alloc: std.mem.Allocator, lists: []List, built: usize) void {
    for (lists[0..built]) |l| {
        alloc.free(l.key);
        alloc.free(l.group);
        alloc.free(l.footer);
        alloc.free(l.empty);
        alloc.free(l.add_label);
        alloc.free(l.switch_key);
        freeFields(alloc, l.items, l.items.len);
    }
    if (lists.len > 0) alloc.free(lists);
}

/// Where a plugin came from. It decides two things: whether Settings offers
/// Uninstall (only `installed`), and who wins an id collision — the first
/// origin loaded keeps the id, and the app loads the developer directory
/// before the installed set.
pub const Origin = enum { bundled, installed, developer };

/// One loaded plugin, and the thread that runs it.
///
/// Heap-allocated, one address for its whole life: the dispatch thread and
/// the watchdog hold the pointer while the registry list grows under them,
/// which is what lets a plugin install while the chart runs.
pub const Entry = struct {
    manifest: Manifest,
    /// WAMR loads the module in place and keeps referring to this buffer.
    bytes: []align(8) u8,
    module: wasm.Module,
    inst: wasm.Instance,
    /// Heap-allocated so its address, which every native reaches through
    /// `wasm.callerUserData`, survives the registry list growing.
    state: *broker.Plugin,
    /// The value in force for each field of `manifest.settings`, in the same
    /// order. Guarded by the host's `cfg_mu`: a shell writes these from its own
    /// thread while the plugin runs.
    values: []f64 = &.{},
    /// The rows in force for each list of `manifest.lists`, in the same order,
    /// each an owned JSON array. Empty rows are `[]`. Guarded by `cfg_mu` with
    /// `values`.
    rows: [][]u8 = &.{},
    /// Cleared when the plugin trapped, was terminated, or was shut down.
    /// Atomic: its own dispatch thread writes it, the watchdog on the I/O
    /// thread and the harness read it.
    live: std.atomic.Value(bool) = .init(true),
    /// This plugin's dispatch thread, and its private stop flag.
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Monotonic ms at which the dispatch thread entered the module, or 0 when
    /// it is not inside one. Written by the dispatch thread on both sides of
    /// every call, read by the watchdog.
    entered_ms: std.atomic.Value(i64) = .init(0),
    /// How long the plugin had been inside the module when the watchdog
    /// terminated it, or 0 if it never did. Doubles as the "the watchdog got
    /// here first" flag, claimed with a compare-and-swap so one overrun is
    /// terminated once.
    killed_ms: std.atomic.Value(i64) = .init(0),
    /// Set once everything the plugin contributed has been dropped, so the
    /// clean-up runs exactly once whichever path reaches it.
    retired: std.atomic.Value(bool) = .init(false),
    /// Where this plugin came from; see `Origin`.
    origin: Origin = .bundled,
    /// The capabilities in force: the manifest's set minus what the mariner
    /// switched off in Settings. `state.caps` is always a copy of this.
    grants: broker.Caps = broker.Caps.initEmpty(),
    /// The directory this plugin was loaded from, owned. For an installed
    /// plugin that is its own directory under the install root — the one
    /// `uninstall` deletes; for a flat set it is the shared directory, which
    /// is only ever read.
    dir: []u8 = &.{},
    /// True once `uninstall` tore the instance down. The slot stays — indices
    /// tag queued events and must keep meaning — but everything heavy is
    /// freed, and every walk over the registry skips the tombstone.
    removed: bool = false,

    pub fn isLive(self: *const Entry) bool {
        return self.live.load(.acquire);
    }
};

pub const Options = struct {
    /// `LOOKOUT_NMEA=host:port`, passed to the nmea0183 plugin's config.
    nmea_host: []const u8 = "127.0.0.1",
    nmea_port: u16 = 10110,
    limits: wasm.Limits = .{},
    /// How long `stop` waits for SHUTDOWN to reach every plugin before the
    /// dispatch threads are torn down anyway. Best effort by contract: a plugin
    /// stuck in a loop must not stop the app from closing.
    shutdown_ms: u32 = 500,
    /// The watchdog's budget for one module call. See
    /// `default_event_budget_ms`.
    event_budget_ms: i64 = default_event_budget_ms,
    /// Where installed plugins live, overriding the platform's own place
    /// (install.md's table). Tests point it at scratch; a platform with no
    /// path in the environment (Android) must set it.
    install_root: []const u8 = "",
};

/// Longest disable reason kept. It has to fit inside the JSON status line the
/// host writes, which `broker.max_status` bounds.
const max_reason: usize = broker.max_status - 40;

/// How long `stop` lets an in-flight call finish after the threads have been
/// told to stop, before it terminates the instance so the join cannot hang.
/// Short: by this point the plugin has already had `shutdown_ms` to drain.
const shutdown_grace_ms: u32 = 100;

/// Native stack for a dispatch thread, one per plugin. Ample for the fast
/// interpreter plus the JSON the natives parse, and small enough to be cheap
/// per plugin.
///
/// It was once forced: with hardware bound checking on, WAMR's per-thread
/// setup mprotects the guard page below the thread's stack, and on macOS that
/// mprotect fails for stacks of 8 MiB and up — including Zig's 16 MiB default,
/// which made every call from this thread trap with "thread signal env not
/// inited". scripts/build-wamr.sh now builds with WAMR_DISABLE_HW_BOUND_CHECK,
/// so any stack size works; this one is kept because it is a good size, not
/// because it has to be.
const dispatch_stack_bytes: usize = 2 * 1024 * 1024;

/// WAMR keeps ONE runtime per process, and the native table is registered
/// against it. Counted so two Lookout handles in one process (the harness
/// opening a second chart, a test) do not tear down each other's runtime.
var runtime_refs: usize = 0;
var runtime_mu: store.Lock = .{};

fn runtimeAcquire() !void {
    runtime_mu.lock();
    defer runtime_mu.unlock();
    if (runtime_refs == 0) {
        try wasm.initRuntime();
        errdefer wasm.deinitRuntime();
        try broker.registerNatives();
        wasm.stdio_sink = stdioToLog;
    }
    runtime_refs += 1;
}

/// A plugin's WASI stdout and stderr, as log lines under that plugin's id.
///
/// A Go or Rust runtime prints to stdout before any plugin code runs — a panic,
/// a runtime warning — and those lines are the only sign of what went wrong.
/// `user_data` is the broker's per-plugin state, which is what lets the line
/// carry the plugin's name instead of arriving anonymously on the host's own
/// stderr. stdout goes out at info and stderr at warn: a language runtime uses
/// stderr for what it wants somebody to read.
fn stdioToLog(user_data: ?*anyopaque, stream: wasm.Stream, line: []const u8) void {
    const p: *broker.Plugin = @ptrCast(@alignCast(user_data orelse return));
    p.broker.say(if (stream == .err) broker.level_warn else broker.level_info, p.id, "{s}", .{line});
}

fn runtimeRelease() void {
    runtime_mu.lock();
    defer runtime_mu.unlock();
    if (runtime_refs == 0) return;
    runtime_refs -= 1;
    if (runtime_refs != 0) return;
    wasm.stdio_sink = null;
    broker.unregisterNatives();
    wasm.deinitRuntime();
    // Process-wide, like the runtime: the last plugin layer out gives the root
    // certificates back.
    webio.deinitCaBundle();
}

pub const Host = struct {
    alloc: std.mem.Allocator,
    br: *broker.Broker,
    opts: Options,
    /// The registry. Pointers, not values: an entry's address must survive
    /// the list growing while dispatch threads and the watchdog hold it.
    entries: std.ArrayList(*Entry) = .empty,
    /// Guards the LIST itself — append on install, the tombstone flip on
    /// uninstall — against the watchdog iterating it on the I/O thread.
    /// Everything else that walks the registry runs on the shell's API
    /// thread, which the C ABI already serializes.
    reg_mu: store.Lock = .{},
    /// True between `start` and `stop`, while the dispatch threads exist.
    started: bool = false,
    /// The sentence the last refused install left behind, for the shell to
    /// show. NUL-terminated so the C ABI can hand it out borrowed.
    install_msg: [max_install_msg:0]u8 = @splat(0),
    install_msg_len: usize = 0,
    /// The install root in force, resolved once from `opts.install_root` or
    /// the platform default. Null until something needed it.
    root_cache: ?[]u8 = null,
    /// True between the first successful load and deinit.
    runtime_held: bool = false,
    /// Source ids are handed out in load order, which the vessel store reads
    /// as priority order. 1-based: 0 is the host's own reserved id.
    next_source: store.SourceId = 1,
    /// Guards every entry's `values`. A settings change comes from the shell's
    /// thread; the config JSON it produces is built under this lock and handed
    /// to the broker as a plain payload.
    cfg_mu: store.Lock = .{},

    pub fn init(alloc: std.mem.Allocator, br: *broker.Broker, opts: Options) Host {
        return .{ .alloc = alloc, .br = br, .opts = opts };
    }

    /// Stops everything and releases every instance, module and buffer. The
    /// broker is not owned here and is not stopped.
    pub fn deinit(self: *Host) void {
        self.stop();
        // The watchdog holds this host's address and runs on the broker's I/O
        // thread. `stop` joined that thread; clearing the hook keeps a broker
        // restarted without a host from reaching freed entries.
        self.br.setWatchdog(null, null);
        for (self.entries.items) |e| {
            // An uninstalled entry already gave its instance, module and
            // bytes back; the rest is freed here like everyone else's.
            if (!e.removed) {
                e.inst.deinit();
                e.module.deinit();
                self.alloc.free(e.bytes);
            }
            if (e.values.len > 0) self.alloc.free(e.values);
            freeRows(self.alloc, e.rows, e.rows.len);
            if (e.dir.len > 0) self.alloc.free(e.dir);
            e.manifest.deinit(self.alloc);
            self.alloc.destroy(e.state);
            self.alloc.destroy(e);
        }
        self.entries.deinit(self.alloc);
        if (self.root_cache) |r| self.alloc.free(r);
        if (self.runtime_held) {
            runtimeRelease();
            self.runtime_held = false;
        }
        self.* = undefined;
    }

    pub fn count(self: *const Host) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (!e.removed) n += 1;
        }
        return n;
    }

    /// The plugin state by manifest id, for the harness and the tests.
    pub fn find(self: *Host, id: []const u8) ?*broker.Plugin {
        const e = self.entryFor(id) orelse return null;
        return e.state;
    }

    // -- loading -------------------------------------------------------------

    /// Load every plugin in `dir`, in two layouts at once:
    ///
    ///   - flat: `<id>.manifest.json` + `<id>.wasm`, which is what `zig build
    ///     plugins` installs and what LOOKOUT_PLUGINS points at;
    ///   - installed: `<id>/manifest.json` + `<id>/<id>.wasm`, which is what
    ///     `installPackage` writes under the install root.
    ///
    /// A plugin that fails to load is logged and skipped — one bad module must
    /// not take the others down with it. An id already in the registry is
    /// skipped too, so whoever loads first keeps the id; the app loads the
    /// developer directory before the installed set, which is what makes the
    /// developer copy win.
    ///
    /// Load order is the sorted file order, and load order IS source priority
    /// in the vessel store, so it is deterministic across machines. Loading
    /// while the dispatch threads run is fine: entries are stable pointers,
    /// and a new plugin gets its thread the moment it is appended.
    pub fn loadDir(self: *Host, dir_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
            self.br.say(broker.level_warn, "host", "plugins: cannot open {s}: {s}", .{ dir_path, @errorName(e) });
            return e;
        };
        defer dir.close(io);

        // A flat directory is the developer override when it IS the override:
        // same path the environment names. Everything else flat is bundled.
        const flat_origin: Origin = blk: {
            const raw = std.c.getenv("LOOKOUT_PLUGINS") orelse break :blk .bundled;
            break :blk if (std.mem.eql(u8, std.mem.span(raw), dir_path)) .developer else .bundled;
        };

        var names: std.ArrayList([]u8) = .empty;
        var subdirs: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
            for (subdirs.items) |n| self.alloc.free(n);
            subdirs.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (try it.next(io)) |ent| {
            if (ent.kind == .directory) {
                if (ent.name.len == 0 or ent.name[0] == '.') continue;
                try subdirs.append(self.alloc, try self.alloc.dupe(u8, ent.name));
                continue;
            }
            if (!std.mem.endsWith(u8, ent.name, manifest_suffix)) continue;
            try names.append(self.alloc, try self.alloc.dupe(u8, ent.name));
        }
        std.mem.sort([]u8, names.items, {}, lessName);
        std.mem.sort([]u8, subdirs.items, {}, lessName);

        for (names.items) |n| {
            const stem = n[0 .. n.len - manifest_suffix.len];
            self.loadOne(dir, stem, n, flat_origin, dir_path) catch |e| {
                self.br.say(broker.level_err, "host", "plugins: {s} not loaded: {s}", .{ stem, @errorName(e) });
            };
        }
        for (subdirs.items) |n| {
            self.loadInstalledOne(dir_path, n) catch |e| {
                self.br.say(broker.level_err, "host", "plugins: {s} not loaded: {s}", .{ n, @errorName(e) });
            };
        }
    }

    const manifest_suffix = ".manifest.json";

    /// One installed plugin: `<root>/<name>/manifest.json` beside its module.
    /// A subdirectory with no manifest is not a plugin and is left alone.
    fn loadInstalledOne(self: *Host, root_path: []const u8, name: []const u8) !void {
        const dir_path = try std.fs.path.join(self.alloc, &.{ root_path, name });
        defer self.alloc.free(dir_path);
        var sub = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
        defer sub.close(io);
        const probe = sub.openFile(io, "manifest.json", .{}) catch return;
        probe.close(io);
        try self.loadOne(sub, "", "manifest.json", .installed, dir_path);
    }

    /// Read, validate, instantiate and start one plugin. `stem` names the
    /// module file (`<stem>.wasm`); empty means the manifest's id names it,
    /// which is the installed layout. `plugin_dir` is copied into the entry;
    /// the caller keeps its own.
    fn loadOne(self: *Host, dir: std.Io.Dir, stem: []const u8, manifest_name: []const u8, origin: Origin, plugin_dir: []const u8) !void {
        const manifest_text = try dir.readFileAlloc(io, manifest_name, self.alloc, .limited(max_manifest_bytes));
        defer self.alloc.free(manifest_text);
        var manifest = try parseManifest(self.alloc, manifest_text);
        errdefer manifest.deinit(self.alloc);
        if (manifest.api != api_version) return Error.ApiMismatch;

        // First loaded keeps the id. The status the mariner reads says which
        // copy is running, so a developer set beside an installed one is not a
        // mystery.
        if (self.entryFor(manifest.id)) |have| {
            self.br.say(
                broker.level_warn,
                manifest.id,
                "already loaded ({s} copy wins); {s} copy skipped",
                .{ @tagName(have.origin), @tagName(origin) },
            );
            manifest.deinit(self.alloc);
            return;
        }

        // Every setting starts at its schema default. A shell that has one
        // saved sends it with `configSet` once the plugin is up.
        const values = try self.alloc.alloc(f64, manifest.settings.len);
        errdefer if (values.len > 0) self.alloc.free(values);
        for (manifest.settings, values) |f, *v| v.* = f.default_value;

        // A list starts empty. The plugin decides what no rows means — the
        // nmea0183 plugin seeds one from LOOKOUT_NMEA — and a shell that has
        // rows saved sends them with `configSet` once the plugin is up.
        const rows = try self.alloc.alloc([]u8, manifest.lists.len);
        var rows_built: usize = 0;
        errdefer freeRows(self.alloc, rows, rows_built);
        while (rows_built < rows.len) : (rows_built += 1) {
            rows[rows_built] = try self.alloc.dupe(u8, "[]");
        }

        // The second and last nmea0183 line in the host, beside the host/port
        // injection in `startJson`: the address the app was started with
        // becomes connection ONE, so the settings window shows the source the
        // mariner is already receiving instead of an empty list. A shell that
        // has rows saved overwrites this the moment it pushes them.
        if (std.mem.endsWith(u8, manifest.id, "nmea0183") and self.opts.nmea_host.len > 0) {
            if (manifest.list("connections")) |li| {
                const seeded = try std.fmt.allocPrint(
                    self.alloc,
                    "[{{\"id\":\"lookout-nmea\",\"name\":\"\",\"host\":\"{s}\",\"port\":{d},\"enabled\":true}}]",
                    .{ self.opts.nmea_host, self.opts.nmea_port },
                );
                self.alloc.free(rows[li]);
                rows[li] = seeded;
            }
        }

        // Flat layout names the module after the file stem; the installed
        // layout names it after the manifest's id, which is authoritative.
        const wasm_name = try std.fmt.allocPrint(self.alloc, "{s}.wasm", .{if (stem.len > 0) stem else manifest.id});
        defer self.alloc.free(wasm_name);
        const raw = try dir.readFileAlloc(io, wasm_name, self.alloc, .limited(max_module_bytes));
        defer self.alloc.free(raw);

        // The grants in force: what the manifest asked for, minus whatever the
        // mariner switched off. The file lives beside the wasm — `grants.json`
        // in an installed plugin's directory, `<id>.grants.json` in a flat one
        // — and its absence means everything the manifest asked for.
        const grants = blk: {
            var name_buf: [160]u8 = undefined;
            const grants_name = if (stem.len > 0)
                std.fmt.bufPrint(&name_buf, "{s}.grants.json", .{manifest.id}) catch break :blk manifest.caps
            else
                grants_file;
            const text = dir.readFileAlloc(io, grants_name, self.alloc, .limited(max_grants_bytes)) catch
                break :blk manifest.caps;
            defer self.alloc.free(text);
            const saved = parseGrants(self.alloc, text) orelse {
                // A permissions file that will not parse grants NOTHING.
                // Failing open is the one wrong answer here.
                self.br.say(broker.level_err, manifest.id, "{s} is unreadable; granting nothing until it is rewritten", .{grants_name});
                break :blk broker.Caps.initEmpty();
            };
            break :blk saved.intersectWith(manifest.caps);
        };

        // WAMR patches the bytecode in place and keeps pointing at it, so the
        // module gets its own aligned, writable copy for the instance's life.
        const bytes = try self.alloc.alignedAlloc(u8, .@"8", raw.len);
        errdefer self.alloc.free(bytes);
        @memcpy(bytes, raw);

        try self.ensureRuntime();

        var err: wasm.ErrBuf = .{};
        var module = wasm.Module.load(bytes, &err) catch |e| {
            self.br.say(broker.level_err, manifest.id, "load failed: {s}", .{err.msg()});
            return e;
        };
        errdefer module.deinit();

        var inst = wasm.Instance.init(module, self.opts.limits, &err) catch |e| {
            self.br.say(broker.level_err, manifest.id, "instantiate failed: {s}", .{err.msg()});
            return e;
        };
        errdefer inst.deinit();

        const state = try self.alloc.create(broker.Plugin);
        errdefer self.alloc.destroy(state);
        state.* = .{
            .broker = self.br,
            .index = @intCast(self.entries.items.len),
            .id = manifest.id,
            .source = self.next_source,
            .caps = grants,
            .http_hosts = manifest.http_hosts,
            .ws_hosts = manifest.ws_hosts,
        };
        inst.setUserData(state);

        const reported = try inst.apiVersion();
        if (reported != api_version) {
            self.br.say(broker.level_err, manifest.id, "lk_abi reported {d}, host speaks {d}", .{ reported, api_version });
            return Error.ApiMismatch;
        }

        // Priority order in the vessel store is registration order, and the
        // source has to exist before the plugin's first publish.
        try self.br.vessels.registerSource(state.source);
        try self.br.registerPlugin(state);
        // Both, in this order: dropPlugin releases what the plugin managed to
        // acquire during lk_start, removePlugin takes the record itself out of
        // the broker's list. Without the second one a plugin that fails here
        // leaves a pointer to freed memory behind, and the NEXT plugin loaded
        // gets its index.
        errdefer {
            self.br.dropPlugin(state.index, broker.wallMs());
            self.br.removePlugin(state);
        }

        const cfg = try self.startJson(&manifest, values, rows);
        defer self.alloc.free(cfg);
        const rc = inst.start(cfg) catch |e| {
            self.reportTrap(&inst, manifest.id, "lk_start");
            return e;
        };
        if (rc != 0) {
            self.br.say(broker.level_err, manifest.id, "lk_start refused with {d}", .{rc});
            return Error.StartRefused;
        }

        const dir_owned: []u8 = if (plugin_dir.len > 0) try self.alloc.dupe(u8, plugin_dir) else &.{};
        errdefer if (dir_owned.len > 0) self.alloc.free(dir_owned);
        const entry = try self.alloc.create(Entry);
        errdefer self.alloc.destroy(entry);
        entry.* = .{
            .manifest = manifest,
            .bytes = bytes,
            .module = module,
            .inst = inst,
            .state = state,
            .values = values,
            .rows = rows,
            .origin = origin,
            .grants = grants,
            .dir = dir_owned,
        };

        self.next_source += 1;
        {
            self.reg_mu.lock();
            defer self.reg_mu.unlock();
            try self.entries.append(self.alloc, entry);
        }
        self.br.say(broker.level_info, manifest.id, "started ({s}, source {d})", .{ manifest.name, state.source });
        // Loaded hot: the dispatch threads are already running, so this
        // plugin gets its own at once instead of waiting for a start() that
        // already happened.
        if (self.started) self.spawnDispatch(state.index);
    }

    fn ensureRuntime(self: *Host) !void {
        if (self.runtime_held) return;
        try runtimeAcquire();
        self.runtime_held = true;
    }

    /// `{"abi":1,"config":{...}}`. The config is the plugin's settings at
    /// their current values, so a plugin reads one shape at start and at every
    /// CONFIG_CHANGED. nmea0183's host and port ride in the same object: they
    /// are configuration the host owns rather than the mariner.
    fn startJson(self: *Host, manifest: *const Manifest, values: []const f64, rows: []const []u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try out.print(self.alloc, "{{\"abi\":{d},\"config\":{{", .{api_version});
        var first = true;
        if (std.mem.endsWith(u8, manifest.id, "nmea0183")) {
            try out.print(self.alloc, "\"host\":\"{s}\",\"port\":{d}", .{ self.opts.nmea_host, self.opts.nmea_port });
            first = false;
        }
        try writeSettings(&out, self.alloc, manifest, values, rows, first);
        try out.appendSlice(self.alloc, "}}");
        return out.toOwnedSlice(self.alloc);
    }

    // -- settings --------------------------------------------------------------

    fn entryFor(self: *Host, id: []const u8) ?*Entry {
        for (self.entries.items) |e| {
            if (!e.removed and std.mem.eql(u8, e.manifest.id, id)) return e;
        }
        return null;
    }

    /// The plugin's settings object, `{"cpa_limit":926,"cpa_alarm":true,...}`,
    /// appended to `out`. Every field the schema declares is present, whether
    /// or not the mariner has ever touched it.
    pub fn configJson(self: *Host, id: []const u8, out: *std.ArrayList(u8)) !void {
        self.cfg_mu.lock();
        defer self.cfg_mu.unlock();
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        try out.append(self.alloc, '{');
        try writeSettings(out, self.alloc, &e.manifest, e.values, e.rows, true);
        try out.append(self.alloc, '}');
    }

    /// Apply a settings object and tell the plugin. Keys the schema does not
    /// declare are ignored; a number outside its range is clamped rather than
    /// refused, because a shell that sends 10 000 m wants the largest limit
    /// the plugin offers, not an error it will not show anybody.
    ///
    /// The plugin receives the WHOLE config, not the change, so a handler
    /// never has to merge. Delivery goes through the ordinary event queue, so
    /// it lands in order behind whatever the plugin is already handling.
    pub fn configSet(self: *Host, id: []const u8, json: []const u8) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.alloc);
        var index: u32 = 0;

        {
            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch
                return Error.BadConfig;
            defer parsed.deinit();
            if (parsed.value != .object) return Error.BadConfig;

            self.cfg_mu.lock();
            defer self.cfg_mu.unlock();
            const e = self.entryFor(id) orelse return Error.UnknownPlugin;
            if (e.manifest.settings.len == 0 and e.manifest.lists.len == 0) return Error.BadConfig;
            index = e.state.index;

            var it = parsed.value.object.iterator();
            while (it.next()) |kv| {
                // A list arrives whole: the shell sends every row it wants to
                // keep, so a removed row is simply absent from the array.
                if (e.manifest.list(kv.key_ptr.*)) |li| {
                    const text = try normalizeRows(self.alloc, e.manifest.lists[li], kv.value_ptr.*);
                    self.alloc.free(e.rows[li]);
                    e.rows[li] = text;
                    continue;
                }
                const at = e.manifest.field(kv.key_ptr.*) orelse continue;
                const f = e.manifest.settings[at];
                switch (f.kind) {
                    .number => {
                        const v = jsonNumber(kv.value_ptr.*) orelse return Error.BadConfig;
                        e.values[at] = std.math.clamp(v, f.min, f.max);
                    },
                    .toggle => e.values[at] = switch (kv.value_ptr.*) {
                        .bool => |b| if (b) 1 else 0,
                        else => return Error.BadConfig,
                    },
                    // Only inside a row, and parseManifest refused it here.
                    .text => unreachable,
                }
            }
            try payload.append(self.alloc, '{');
            try writeSettings(&payload, self.alloc, &e.manifest, e.values, e.rows, true);
            try payload.append(self.alloc, '}');
        }

        self.br.push(index, broker.Kind.config_changed, 0, payload.items);
        self.br.say(broker.level_info, id, "config {s}", .{payload.items});
    }

    // -- files the mariner chose ------------------------------------------------

    /// Hand one plugin one file, and tell it with a FILE_OPENED event carrying
    /// the handle. The plugin may then `file_read` it, or `file_write` it when
    /// `write` is true.
    ///
    /// THIS IS THE WHOLE FILESYSTEM. There is no `file_open` import, so a
    /// plugin cannot name a path: every file it ever sees came through here,
    /// because the mariner opened it or an operator passed `--grant-file`.
    pub fn grantFile(self: *Host, id: []const u8, path: []const u8, write: bool) !i64 {
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        if (!e.manifest.caps.contains(.files)) return Error.NotGranted;
        if (!e.isLive()) return Error.UnknownPlugin;
        return self.br.grantFile(e.state.index, path, write);
    }

    /// Give the plugins a file the mariner opened. True when one took it, false
    /// when no manifest claims that file type — the shell then does with the
    /// file whatever it did before there were plugins.
    ///
    /// THE MARINER OPENS A FILE, NOT A PLUGIN. There is no menu of plugins to
    /// choose from: a manifest claims `.grib2`, the mariner opens a .grib2 the
    /// way they open a chart, and the plugin that claimed it gets read access
    /// and a FILE_OPENED event. The mariner never learns a plugin was involved.
    ///
    /// A CHART IS STILL A CHART. An extension the chart side owns is never
    /// offered to a plugin, so the path a .pmtiles takes is the path it always
    /// took, whatever a manifest says.
    ///
    /// TWO CLAIMS ON ONE TYPE REFUSE BOTH, with one log line naming them. The
    /// alternative is load order deciding which plugin reads the mariner's
    /// weather, silently and differently on each machine. Asking the mariner
    /// which one they meant needs consent chrome that does not exist yet.
    pub fn openFile(self: *Host, path: []const u8) !bool {
        var buf: [max_file_type]u8 = undefined;
        const ext = fileExtension(path, &buf) orelse return false;
        for (chart_extensions) |ce| {
            if (std.mem.eql(u8, ce, ext)) return false;
        }

        var claimant: ?*Entry = null;
        for (self.entries.items) |e| {
            if (e.removed or !e.isLive()) continue;
            if (!e.manifest.claimsFileType(ext)) continue;
            if (claimant) |first| {
                self.br.say(
                    broker.level_err,
                    "host",
                    "{s} is claimed by both {s} and {s}; neither gets {s}",
                    .{ ext, first.manifest.id, e.manifest.id, path },
                );
                return Error.FileTypeConflict;
            }
            claimant = e;
        }
        const e = claimant orelse return false;

        const handle = try self.grantFile(e.manifest.id, path, false);
        self.br.say(broker.level_info, e.manifest.id, "opened {s} (handle {d})", .{ path, handle });
        return true;
    }

    /// Every loaded plugin, its state, its status line, and its settings
    /// schema with the value in force. This is what a shell reads to draw a
    /// settings pane; it never has to know what a plugin is for.
    pub fn registryJson(self: *Host, out: *std.ArrayList(u8)) !void {
        self.cfg_mu.lock();
        defer self.cfg_mu.unlock();
        const alloc = self.alloc;
        try out.appendSlice(alloc, "{\"plugins\":[");
        var written: usize = 0;
        for (self.entries.items) |e| {
            if (e.removed) continue;
            if (written > 0) try out.append(alloc, ',');
            written += 1;
            try out.appendSlice(alloc, "{\"id\":");
            try writeJsonString(out, alloc, e.manifest.id);
            try out.appendSlice(alloc, ",\"name\":");
            try writeJsonString(out, alloc, e.manifest.name);
            try out.appendSlice(alloc, ",\"version\":");
            try writeJsonString(out, alloc, e.manifest.version);
            // Where the plugin came from. The shell reads it two ways: only
            // an "installed" row offers Uninstall, and a "developer" row says
            // "developer copy" beside its status.
            try out.print(alloc, ",\"origin\":\"{s}\"", .{@tagName(e.origin)});
            try out.print(alloc, ",\"live\":{s}", .{if (e.isLive()) "true" else "false"});
            // The status line is a string, not an object: it is text a plugin
            // wrote, and the shell decides what to do with it.
            try out.appendSlice(alloc, ",\"status\":");
            try writeJsonString(out, alloc, e.state.status());
            // Every capability the manifest asked for, its consent sentence,
            // and whether the mariner currently grants it. The wording lives
            // here so every shell shows the same sentence.
            try out.appendSlice(alloc, ",\"capabilities\":[");
            var caps_written: usize = 0;
            for (sentence_order) |cap| {
                if (!e.manifest.caps.contains(cap)) continue;
                if (caps_written > 0) try out.append(alloc, ',');
                caps_written += 1;
                try out.appendSlice(alloc, "{\"cap\":");
                try writeJsonString(out, alloc, cap.name());
                try out.appendSlice(alloc, ",\"sentence\":");
                var sentence: std.ArrayList(u8) = .empty;
                defer sentence.deinit(alloc);
                try writeSentence(&sentence, alloc, cap, &e.manifest);
                try writeJsonString(out, alloc, sentence.items);
                const hosts: []const []u8 = switch (cap) {
                    .net_http => e.manifest.http_hosts,
                    .net_ws => e.manifest.ws_hosts,
                    else => &.{},
                };
                if (hosts.len > 0) {
                    try out.appendSlice(alloc, ",\"hosts\":[");
                    for (hosts, 0..) |h, k| {
                        if (k > 0) try out.append(alloc, ',');
                        try writeJsonString(out, alloc, h);
                    }
                    try out.append(alloc, ']');
                }
                try out.print(alloc, ",\"granted\":{s}", .{if (e.grants.contains(cap)) "true" else "false"});
                try out.append(alloc, '}');
            }
            try out.append(alloc, ']');
            // The file types this plugin claims, written only when it claims
            // some, so a plugin that opens no files writes the JSON it always
            // wrote. A shell reads these to tell the mariner what its open
            // panel now accepts.
            if (e.manifest.file_types.len > 0) {
                try out.appendSlice(alloc, ",\"file_types\":[");
                for (e.manifest.file_types, 0..) |ft, k| {
                    if (k > 0) try out.append(alloc, ',');
                    try writeJsonString(out, alloc, ft);
                }
                try out.append(alloc, ']');
            }
            try out.appendSlice(alloc, ",\"settings\":[");
            for (e.manifest.settings, e.values, 0..) |f, v, k| {
                if (k > 0) try out.append(alloc, ',');
                try writeFieldJson(out, alloc, f, v);
            }
            try out.append(alloc, ']');
            // The repeating groups: what one row holds, and the rows in force.
            // Written only when the manifest declares one, so a plugin without
            // lists writes the JSON it always wrote.
            if (e.manifest.lists.len > 0) {
                try out.appendSlice(alloc, ",\"lists\":[");
                for (e.manifest.lists, e.rows, 0..) |l, text, k| {
                    if (k > 0) try out.append(alloc, ',');
                    try out.appendSlice(alloc, "{\"key\":");
                    try writeJsonString(out, alloc, l.key);
                    if (l.group.len > 0) {
                        try out.appendSlice(alloc, ",\"group\":");
                        try writeJsonString(out, alloc, l.group);
                    }
                    // The plugin's own wording, written only when it declared
                    // some, so a manifest that says nothing writes the JSON it
                    // always wrote and the application keeps its own default.
                    for ([_][2][]const u8{
                        .{ "footer", l.footer },
                        .{ "empty", l.empty },
                        .{ "add_label", l.add_label },
                        .{ "switch_key", l.switch_key },
                    }) |pair| {
                        if (pair[1].len == 0) continue;
                        try out.append(alloc, ',');
                        try writeJsonString(out, alloc, pair[0]);
                        try out.append(alloc, ':');
                        try writeJsonString(out, alloc, pair[1]);
                    }
                    try out.print(alloc, ",\"tab\":\"{s}\",\"item_fields\":[", .{@tagName(l.tab)});
                    for (l.items, 0..) |f, j| {
                        if (j > 0) try out.append(alloc, ',');
                        try out.append(alloc, '{');
                        try writeFieldCore(out, alloc, f);
                        try out.append(alloc, '}');
                    }
                    try out.appendSlice(alloc, "],\"rows\":");
                    try out.appendSlice(alloc, text);
                    try out.append(alloc, '}');
                }
                try out.append(alloc, ']');
            }
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]}");
    }

    // -- install and consent ---------------------------------------------------

    /// The install root in force, created on first use and cached: the
    /// override from `Options`, else install.md's per-platform directory.
    pub fn installRoot(self: *Host) Error![]const u8 {
        if (self.root_cache) |r| return r;
        const root: []u8 = if (self.opts.install_root.len > 0)
            self.alloc.dupe(u8, self.opts.install_root) catch return Error.OutOfMemory
        else
            installRootAlloc(self.alloc) orelse return Error.NoInstallRoot;
        std.Io.Dir.cwd().createDirPath(io, root) catch {};
        self.root_cache = root;
        return root;
    }

    /// The sentence the last refused install left for the mariner. Borrowed;
    /// overwritten by the next install or inspect.
    pub fn installMessage(self: *const Host) [:0]const u8 {
        return self.install_msg[0..self.install_msg_len :0];
    }

    /// The refusal text for `err`, for a shell that got an error the message
    /// buffer does not already describe (an allocation failure, a load error).
    pub fn installErrorText(self: *Host, err: anyerror) [:0]const u8 {
        if (err != Error.PackageRefused) {
            self.setInstallMessage("The install failed: {s}.", .{@errorName(err)});
        }
        return self.installMessage();
    }

    /// Truncation keeps the head of the sentence, which is the part that says
    /// what happened.
    fn setInstallMessage(self: *Host, comptime fmt: []const u8, args: anytype) void {
        const kept = std.fmt.bufPrint(self.install_msg[0..max_install_msg], fmt, args) catch
            self.install_msg[0..max_install_msg];
        self.install_msg_len = kept.len;
        self.install_msg[kept.len] = 0;
    }

    /// Write the mariner's sentence and refuse.
    fn refuse(self: *Host, comptime fmt: []const u8, args: anytype) Error {
        self.setInstallMessage(fmt, args);
        return Error.PackageRefused;
    }

    /// A validated package, unpacked into a temporary directory under the
    /// install root (same volume, so placing it is one rename).
    const Unpacked = struct {
        manifest: Manifest,
        tmp_path: []u8,
    };

    /// Open a .lkplug, check it holds exactly `manifest.json` and the
    /// manifest's `<id>.wasm` — anything else refuses by name — and unpack it.
    /// Every refusal sets `installMessage` to the sentence the shell shows.
    fn unpackToTemp(self: *Host, path: []const u8) !Unpacked {
        const root = try self.installRoot();
        const cwd = std.Io.Dir.cwd();

        var file = cwd.openFile(io, path, .{}) catch |e|
            return self.refuse("Cannot open {s}: {s}.", .{ pkgBaseName(path), @errorName(e) });
        defer file.close(io);
        var rbuf: [4096]u8 = undefined;
        var fr = file.reader(io, &rbuf);

        var it = std.zip.Iterator.init(&fr) catch
            return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)});

        // Pass one, the members by name. The module's name is checked against
        // the manifest's id after the manifest is read.
        var manifest_entry: ?std.zip.Iterator.Entry = null;
        var wasm_entry: ?std.zip.Iterator.Entry = null;
        var wasm_name_buf: [max_zip_name]u8 = undefined;
        var wasm_name: []const u8 = "";
        var name_buf: [max_zip_name]u8 = undefined;
        while (it.next() catch return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)})) |entry| {
            if (entry.filename_len > name_buf.len)
                return self.refuse("The package holds a name longer than any plugin file's.", .{});
            const name = name_buf[0..entry.filename_len];
            fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch
                return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)});
            fr.interface.readSliceAll(name) catch
                return self.refuse("{s} is not a plugin package this host can read.", .{pkgBaseName(path)});
            if (std.mem.eql(u8, name, "manifest.json")) {
                if (manifest_entry != null) return self.refuse("The package holds manifest.json twice.", .{});
                if (entry.uncompressed_size > max_manifest_bytes)
                    return self.refuse("The manifest is larger than a manifest can be.", .{});
                manifest_entry = entry;
                continue;
            }
            if (std.mem.endsWith(u8, name, ".wasm") and std.mem.indexOfAny(u8, name, "/\\") == null) {
                if (wasm_entry != null)
                    return self.refuse("The package holds two modules: {s} and {s}.", .{ wasm_name, name });
                if (entry.uncompressed_size > max_module_bytes)
                    return self.refuse("The module is larger than a plugin may be.", .{});
                @memcpy(wasm_name_buf[0..name.len], name);
                wasm_name = wasm_name_buf[0..name.len];
                wasm_entry = entry;
                continue;
            }
            // install.md's rule: anything else refuses the install BY NAME.
            return self.refuse("The package holds {s}; a plugin package holds only manifest.json and its module.", .{name});
        }
        const me = manifest_entry orelse return self.refuse("The package holds no manifest.json.", .{});
        const we = wasm_entry orelse return self.refuse("The package holds no wasm module.", .{});

        // Unpack into a scratch directory beside the real ones, so a refusal
        // deletes one directory and a success is one rename. The name only
        // has to dodge a concurrent install of the same second, and the C ABI
        // serializes installs anyway; extraction creates exclusively, so a
        // stale leftover refuses rather than mixes.
        const stamp: u64 = @bitCast(broker.wallMs() *% 1_000 +% broker.monoMs());
        var tmp_name_buf: [40]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".install-{x}", .{stamp}) catch unreachable;
        const tmp_path = try std.fs.path.join(self.alloc, &.{ root, tmp_name });
        errdefer self.alloc.free(tmp_path);
        cwd.createDirPath(io, tmp_path) catch |e|
            return self.refuse("Cannot write to the plugin directory: {s}.", .{@errorName(e)});
        errdefer cwd.deleteTree(io, tmp_path) catch {};
        var tmp_dir = cwd.openDir(io, tmp_path, .{}) catch |e|
            return self.refuse("Cannot write to the plugin directory: {s}.", .{@errorName(e)});
        defer tmp_dir.close(io);

        var scratch: [max_zip_name]u8 = undefined;
        me.extract(&fr, .{}, &scratch, tmp_dir) catch |e|
            return self.refuse("The package would not unpack: {s}.", .{@errorName(e)});
        we.extract(&fr, .{}, &scratch, tmp_dir) catch |e|
            return self.refuse("The package would not unpack: {s}.", .{@errorName(e)});

        const text = tmp_dir.readFileAlloc(io, "manifest.json", self.alloc, .limited(max_manifest_bytes)) catch |e|
            return self.refuse("The manifest would not read back: {s}.", .{@errorName(e)});
        defer self.alloc.free(text);
        var manifest = parseManifest(self.alloc, text) catch
            return self.refuse("The manifest is not one this host can read.", .{});
        errdefer manifest.deinit(self.alloc);
        if (manifest.api != api_version)
            return self.refuse("{s} speaks plugin API {d}; this host speaks {d}.", .{ manifest.id, manifest.api, api_version });
        if (!idSafe(manifest.id))
            return self.refuse("The manifest's id is not a name this host can install.", .{});
        // The manifest is authoritative, so the module must carry its id. A
        // mismatch is a repack error, not something to guess about.
        var want_buf: [max_zip_name]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}.wasm", .{manifest.id}) catch
            return self.refuse("The manifest's id is too long for a module name.", .{});
        if (!std.mem.eql(u8, wasm_name, want))
            return self.refuse("The module is named {s} but the manifest's id wants {s}.", .{ wasm_name, want });

        return .{ .manifest = manifest, .tmp_path = tmp_path };
    }

    /// What the consent sheet shows, as JSON, without installing anything:
    /// `{"id":..,"name":..,"version":..,"sentences":[..]}`. When the id is
    /// already loaded it adds `"installed":{"version":..,"origin":..,
    /// "adds":[..],"drops":[..],"downgrade":bool}` so the sheet can call out
    /// the delta, downgrades included. A refused package answers
    /// `{"error":"…"}` with the sentence the shell shows.
    pub fn inspectPackage(self: *Host, path: []const u8, out: *std.ArrayList(u8)) error{OutOfMemory}!void {
        const alloc = self.alloc;
        var up = self.unpackToTemp(path) catch |e| {
            try out.appendSlice(alloc, "{\"error\":");
            try writeJsonString(out, alloc, self.installErrorText(e));
            try out.append(alloc, '}');
            return;
        };
        defer {
            std.Io.Dir.cwd().deleteTree(io, up.tmp_path) catch {};
            alloc.free(up.tmp_path);
            up.manifest.deinit(alloc);
        }
        try out.appendSlice(alloc, "{\"id\":");
        try writeJsonString(out, alloc, up.manifest.id);
        try out.appendSlice(alloc, ",\"name\":");
        try writeJsonString(out, alloc, up.manifest.name);
        try out.appendSlice(alloc, ",\"version\":");
        try writeJsonString(out, alloc, up.manifest.version);
        try out.appendSlice(alloc, ",\"sentences\":[");
        try writeSentences(out, alloc, &up.manifest, null);
        try out.append(alloc, ']');
        if (self.entryFor(up.manifest.id)) |have| {
            try out.appendSlice(alloc, ",\"installed\":{\"version\":");
            try writeJsonString(out, alloc, have.manifest.version);
            try out.print(alloc, ",\"origin\":\"{s}\"", .{@tagName(have.origin)});
            try out.appendSlice(alloc, ",\"adds\":[");
            try writeSentences(out, alloc, &up.manifest, &have.manifest);
            try out.appendSlice(alloc, "],\"drops\":[");
            try writeSentences(out, alloc, &have.manifest, &up.manifest);
            try out.print(alloc, "],\"downgrade\":{s}}}", .{
                if (versionLess(up.manifest.version, have.manifest.version)) "true" else "false",
            });
        }
        try out.append(alloc, '}');
    }

    /// Unpack, validate, place under the install root and load hot. The
    /// consent already happened on the sheet; this is the Install button.
    ///
    /// An id already running is replaced — its instance unloaded, its
    /// directory and grants file overwritten — except a developer copy, which
    /// keeps the id for this run per install.md; the files still land so the
    /// next launch without the override has them.
    pub fn installPackage(self: *Host, path: []const u8) !void {
        var up = try self.unpackToTemp(path);
        var placed = false;
        defer {
            if (!placed) std.Io.Dir.cwd().deleteTree(io, up.tmp_path) catch {};
            self.alloc.free(up.tmp_path);
            up.manifest.deinit(self.alloc);
        }
        const root = try self.installRoot();
        const final = try std.fs.path.join(self.alloc, &.{ root, up.manifest.id });
        defer self.alloc.free(final);
        const cwd = std.Io.Dir.cwd();

        var developer_stays = false;
        if (self.entryFor(up.manifest.id)) |have| {
            if (have.origin == .developer) {
                developer_stays = true;
            } else {
                // Consent was re-asked with the delta on the sheet, so the
                // old instance, its files and its grants file all go.
                self.unload(have);
            }
        }
        cwd.deleteTree(io, final) catch {};
        cwd.rename(up.tmp_path, cwd, final, io) catch |e|
            return self.refuse("Cannot place {s}: {s}.", .{ up.manifest.id, @errorName(e) });
        placed = true;
        if (developer_stays) {
            self.br.say(broker.level_warn, up.manifest.id, "installed; the developer copy stays in force until the override is dropped", .{});
            return;
        }

        self.loadInstalledOne(root, up.manifest.id) catch |e| {
            // Nothing half-installed: a module that will not start leaves no
            // directory behind, and the sentence says which plugin failed.
            cwd.deleteTree(io, final) catch {};
            return self.refuse("{s} did not start: {s}. Nothing was installed.", .{ up.manifest.id, @errorName(e) });
        };
    }

    /// Remove an installed plugin: instance down, broker record gone, overlay
    /// and store contributions erased (the same dropPlugin path a dead plugin
    /// takes), directory deleted, persisted storage deleted. Bundled and
    /// developer copies refuse: only what install wrote can be removed.
    pub fn uninstall(self: *Host, id: []const u8) !void {
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        if (e.origin != .installed) return Error.NotInstalled;
        self.unload(e);
        if (e.dir.len > 0) std.Io.Dir.cwd().deleteTree(io, e.dir) catch {};
        self.deleteStorage(e.manifest.id);
        self.br.say(broker.level_info, id, "uninstalled: its files, storage and overlay are gone", .{});
    }

    /// Take a loaded plugin out of the registry: SHUTDOWN, thread down,
    /// instance gone, broker record gone, slot tombstoned. The files are the
    /// caller's business — installPackage replaces them, uninstall deletes
    /// them, and a developer or bundled set is never written.
    fn unload(self: *Host, e: *Entry) void {
        const index = e.state.index;
        if (e.thread != null) {
            if (e.isLive()) self.br.push(index, broker.Kind.shutdown, 0, "");
            const until = broker.monoMs() + self.opts.shutdown_ms;
            while (e.isLive() and broker.monoMs() < until) broker.sleepMs(2);
            e.stopping.store(true, .release);
            var grace: u32 = 0;
            while (grace < shutdown_grace_ms and e.entered_ms.load(.acquire) != 0) : (grace += 2) broker.sleepMs(2);
            if (e.entered_ms.load(.acquire) != 0) {
                self.br.say(broker.level_warn, e.manifest.id, "still inside the module; terminating", .{});
                e.inst.terminate();
            }
            if (e.thread) |th| {
                th.join();
                e.thread = null;
            }
        } else if (e.isLive()) {
            self.deliverTo(index, broker.Kind.shutdown, 0, "");
        }
        // SHUTDOWN delivery retired it; this is the path where it could not.
        self.retire(index, false, "unloaded");
        self.br.removePlugin(e.state);
        {
            // The watchdog walks the registry on the I/O thread; it must see
            // the tombstone before the instance behind it goes away.
            self.reg_mu.lock();
            e.removed = true;
            self.reg_mu.unlock();
        }
        e.inst.deinit();
        e.module.deinit();
        self.alloc.free(e.bytes);
    }

    /// Switch one capability on or off, live. The broker checks per call, so
    /// the flip is felt on the plugin's next mediated call: a revoked
    /// capability answers -1 and counts denied exactly as if the manifest had
    /// never asked. No restart, no event, no redelivery.
    pub fn grantSet(self: *Host, id: []const u8, cap_name: []const u8, on: bool) !void {
        const cap = broker.Cap.fromName(cap_name) orelse return Error.UnknownCapability;
        var grants: broker.Caps = undefined;
        {
            self.cfg_mu.lock();
            defer self.cfg_mu.unlock();
            const e = self.entryFor(id) orelse return Error.UnknownPlugin;
            // A grant can never exceed the manifest: switching ON something
            // it never asked for is refused, not stored.
            if (!e.manifest.caps.contains(cap)) return Error.NotGranted;
            if (on) e.grants.insert(cap) else e.grants.remove(cap);
            // The natives read this set unlocked on the dispatch threads. It
            // is one machine word; a call racing the flip lands on one side
            // of it or the other, which is what "live" means.
            e.state.caps = e.grants;
            grants = e.grants;
        }
        self.persistGrants(id, grants) catch |e| {
            self.br.say(broker.level_warn, id, "grant change not saved: {s}", .{@errorName(e)});
        };
        self.br.say(broker.level_info, id, "grant {s} switched {s}", .{ cap.name(), if (on) "on" else "off" });
    }

    /// Write the grants file beside the plugin's wasm, atomically. A set that
    /// cannot be written (the app bundle is read-only) keeps the flip for
    /// this run and says so.
    fn persistGrants(self: *Host, id: []const u8, caps: broker.Caps) !void {
        const e = self.entryFor(id) orelse return Error.UnknownPlugin;
        if (e.dir.len == 0) return;
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.alloc);
        try writeGrantsJson(&json, self.alloc, caps);
        const name = if (e.origin == .installed)
            try self.alloc.dupe(u8, grants_file)
        else
            try std.fmt.allocPrint(self.alloc, "{s}.grants.json", .{id});
        defer self.alloc.free(name);
        const final = try std.fs.path.join(self.alloc, &.{ e.dir, name });
        defer self.alloc.free(final);
        const tmp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{final});
        defer self.alloc.free(tmp);
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = json.items });
        try cwd.rename(tmp, cwd, final, io);
    }

    /// Take the plugin's persisted storage with it. The broker keeps the file
    /// on a mere disable so a reload finds its settings; an uninstall is the
    /// mariner saying goodbye, and everything the plugin owns goes.
    fn deleteStorage(self: *Host, id: []const u8) void {
        var name_buf: [192]u8 = undefined;
        const name = storageFileName(id, &name_buf);
        var dir_owned: ?[]u8 = null;
        var resolved = false;
        {
            self.br.mu.lock();
            defer self.br.mu.unlock();
            resolved = self.br.storage_dir_resolved;
            if (resolved) {
                if (self.br.storage_dir) |d| dir_owned = self.alloc.dupe(u8, d) catch null;
            }
        }
        // Never resolved this run does not mean no file: an earlier run may
        // have written one in the default place.
        if (!resolved) dir_owned = storageDirDefault(self.alloc);
        const dir = dir_owned orelse return;
        defer self.alloc.free(dir);
        const path = std.fs.path.join(self.alloc, &.{ dir, name }) catch return;
        defer self.alloc.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    // -- the event loop ------------------------------------------------------

    /// Start the broker's I/O thread, arm the watchdog, and give every live
    /// plugin its own dispatch thread. Call after `loadDir`: `lk_start` runs on
    /// the caller's thread, and nothing should be delivering events while it
    /// does. Idempotent, and a repeat call picks up plugins loaded since —
    /// which is what `loadPlugins` leans on when it loads a second directory.
    pub fn start(self: *Host) !void {
        // Armed before the I/O thread exists, so the first tick already has it.
        self.br.setWatchdog(self, watchdogTick);
        try self.br.start();
        self.started = true;
        for (self.entries.items, 0..) |e, i| {
            if (e.removed or !e.isLive() or e.thread != null) continue;
            self.spawnDispatch(@intCast(i));
        }
    }

    /// One plugin's dispatch thread, spawned at `start` or the moment a hot
    /// install appends it.
    fn spawnDispatch(self: *Host, index: u32) void {
        const e = self.entries.items[index];
        e.stopping.store(false, .release);
        e.thread = std.Thread.spawn(
            .{ .stack_size = dispatch_stack_bytes },
            dispatchMain,
            .{ self, index },
        ) catch |err| {
            // No thread means no events, ever. Better a plugin that is
            // visibly gone than one that is silently deaf.
            self.br.say(broker.level_err, e.manifest.id, "no dispatch thread: {s}", .{@errorName(err)});
            self.retire(index, true, "no dispatch thread");
            return;
        };
    }

    /// SHUTDOWN to every live plugin, drained best effort, then every thread
    /// down. Safe to call twice and safe to call without `start`.
    ///
    /// The join at the end is bounded because anything still inside a module
    /// when the grace period runs out is terminated first. A plugin in a loop
    /// must not stop the app from closing, and a thread that never returns
    /// cannot be joined.
    pub fn stop(self: *Host) void {
        if (!self.started) {
            // Never started: deliver SHUTDOWN inline so a plugin that opened a
            // socket in lk_start still gets told.
            for (self.entries.items, 0..) |e, i| {
                if (!e.removed and e.isLive()) self.deliverTo(@intCast(i), broker.Kind.shutdown, 0, "");
            }
            self.br.stop();
            return;
        }

        for (self.entries.items, 0..) |e, i| {
            if (!e.removed and e.isLive()) self.br.push(@intCast(i), broker.Kind.shutdown, 0, "");
        }
        var waited: u32 = 0;
        while (self.br.queued() > 0 and waited < self.opts.shutdown_ms) : (waited += 2) {
            broker.sleepMs(2);
        }

        for (self.entries.items) |e| e.stopping.store(true, .release);
        var grace: u32 = 0;
        while (grace < shutdown_grace_ms and self.anyInModule()) : (grace += 2) broker.sleepMs(2);
        for (self.entries.items) |e| {
            if (e.removed or e.thread == null or e.entered_ms.load(.acquire) == 0) continue;
            self.br.say(broker.level_warn, e.manifest.id, "still inside the module at shutdown; terminating", .{});
            e.inst.terminate();
        }
        for (self.entries.items) |e| {
            if (e.thread) |th| {
                th.join();
                e.thread = null;
            }
        }
        self.started = false;
        self.br.stop();
    }

    fn anyInModule(self: *Host) bool {
        for (self.entries.items) |e| {
            if (e.thread != null and e.entered_ms.load(.acquire) != 0) return true;
        }
        return false;
    }

    /// Deliver everything queued, on the CALLING thread, and return how many
    /// events went. For the replay harness and the tests, where delivery has
    /// to be deterministic rather than concurrent. Never call this while
    /// `start` has dispatch threads running — two threads would enter the same
    /// instance.
    ///
    /// Round robin rather than plugin by plugin, so an event that makes one
    /// plugin publish still reaches the others in something like the order the
    /// old single queue gave them.
    pub fn pump(self: *Host) usize {
        var n: usize = 0;
        var moved = true;
        while (moved) {
            moved = false;
            for (0..self.entries.items.len) |i| {
                const e = self.br.popFor(@intCast(i)) orelse continue;
                defer self.br.freeEvent(e);
                self.deliverTo(@intCast(i), e.kind, e.handle, e.payload);
                n += 1;
                moved = true;
            }
        }
        return n;
    }

    /// One plugin's dispatch thread: its queue, its instance, nobody else's.
    fn dispatchMain(self: *Host, index: u32) void {
        const e = self.entries.items[index];
        // WAMR keeps the interpreter's native stack boundary per THREAD, and
        // the load thread got its own from initRuntime. Cheap, and the
        // documented way to enter wasm from a thread the runtime has not seen;
        // without the hardware bound check it is no longer the difference
        // between running and trapping.
        wasm.initThreadEnv() catch {
            self.br.say(broker.level_err, e.manifest.id, "dispatch thread has no wasm runtime env; no events will be delivered", .{});
            return;
        };
        defer wasm.destroyThreadEnv();

        // Polled rather than waited on a condition variable, for the same
        // reason raster.zig's worker is: Zig 0.16 has no std.Thread.Condition
        // outside an Io. The backoff keeps an idle plugin off the CPU; the
        // broker's fanout tick lands every 100 ms anyway.
        var idle_ms: u32 = 1;
        while (!e.stopping.load(.acquire) and e.isLive()) {
            // The watchdog may have terminated this instance while the thread
            // was between events, or just after a call returned. Either way the
            // plugin overran and is finished.
            if (e.killed_ms.load(.acquire) != 0) {
                self.disableStuck(index);
                break;
            }
            const ev = self.br.popFor(index) orelse {
                broker.sleepMs(idle_ms);
                if (idle_ms < 8) idle_ms *= 2;
                continue;
            };
            idle_ms = 1;
            defer self.br.freeEvent(ev);
            self.deliverTo(index, ev.kind, ev.handle, ev.payload);
        }
        // Anything still queued belongs to nobody now.
        self.br.clearQueue(index);
    }

    fn deliverTo(self: *Host, index: u32, kind: u32, handle: u64, payload: []const u8) void {
        if (index >= self.entries.items.len) return;
        const e = self.entries.items[index];
        if (e.removed or !e.isLive()) return;
        // SHUTDOWN is the last thing a plugin ever sees, whatever it returns.
        if (kind == broker.Kind.shutdown) e.live.store(false, .release);

        // The stamp the watchdog reads. Set before the call and cleared after
        // it however it ends, so a plugin is only ever judged on time it is
        // actually spending inside the module.
        e.entered_ms.store(broker.monoMs(), .release);
        const rc = e.inst.eventWith(kind, handle, payload) catch |err| {
            e.entered_ms.store(0, .release);
            if (e.killed_ms.load(.acquire) != 0) {
                self.disableStuck(index);
                return;
            }
            // An ordinary trap keeps its OWN text. WAMR's message says what the
            // module did wrong ("unreachable", "out of bounds memory access"),
            // which is the only useful thing anybody has; the error name is the
            // fallback for a failure with no exception behind it, such as
            // lk_alloc answering zero.
            var tbuf: [max_reason]u8 = undefined;
            const text = e.inst.exception() orelse @errorName(err);
            const kept = tbuf[0..@min(text.len, tbuf.len)];
            @memcpy(kept, text[0..kept.len]);
            e.inst.clearException();
            self.br.say(broker.level_err, e.manifest.id, "lk_event trapped: {s}", .{kept});
            self.retire(index, true, kept);
            return;
        };
        e.entered_ms.store(0, .release);

        // A non-zero return is the plugin's own complaint, not a fault: it
        // stays running and the line says which event it disliked.
        if (rc != 0) self.br.say(broker.level_warn, e.manifest.id, "event {d} returned {d}", .{ kind, rc });
        if (kind == broker.Kind.shutdown) self.retire(index, false, "shutdown");
    }

    fn reportTrap(self: *Host, inst: *wasm.Instance, id: []const u8, what: []const u8) void {
        const text = inst.exception() orelse "(no exception text)";
        self.br.say(broker.level_err, id, "{s} trapped: {s}", .{ what, text });
        inst.clearException();
    }

    /// The disable path for a plugin the watchdog terminated. WAMR's own text
    /// for this trap is "terminated by user", which says who did it and nothing
    /// about why, so it is dropped in favour of the budget it blew. Every other
    /// trap keeps its original exception text.
    fn disableStuck(self: *Host, index: u32) void {
        const e = self.entries.items[index];
        e.inst.clearException();
        var buf: [max_reason]u8 = undefined;
        const reason = std.fmt.bufPrint(
            &buf,
            "stuck in lk_event (terminated after {d} ms)",
            .{e.killed_ms.load(.acquire)},
        ) catch "stuck in lk_event";
        self.retire(index, true, reason);
    }

    /// Take a plugin out of service and erase everything it contributed:
    /// overlay objects, published values, AIS targets, sockets, timers and
    /// whatever was still queued. `fault` distinguishes a plugin that broke —
    /// logged as an error, status line replaced with the reason — from one that
    /// was shut down, which keeps whatever it last said about itself.
    fn retire(self: *Host, index: u32, fault: bool, reason: []const u8) void {
        const e = self.entries.items[index];
        e.live.store(false, .release);
        if (e.retired.swap(true, .acq_rel)) return;
        if (fault) {
            // The reason goes into a JSON status line, and part of it is text
            // WAMR wrote, so quotes, backslashes and control bytes are folded
            // to spaces rather than escaped: this is a one-line status, not a
            // document, and it must not be able to break the shape.
            var safe: [max_reason]u8 = undefined;
            const n = @min(reason.len, safe.len);
            for (reason[0..n], 0..) |ch, i| safe[i] = switch (ch) {
                '"', '\\', 0...31, 127 => ' ',
                else => ch,
            };
            var buf: [broker.max_status]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{{\"state\":\"disabled\",\"detail\":\"{s}\"}}", .{safe[0..n]}) catch "{\"state\":\"disabled\"}";
            _ = e.state.setStatus(line);
            self.br.say(broker.level_err, e.manifest.id, "disabled: {s}; overlays and published values cleared", .{safe[0..n]});
        }
        self.br.dropPlugin(index, broker.wallMs());
    }

    // -- the watchdog --------------------------------------------------------

    /// Called from the broker's 100 ms tick, on the I/O thread, with no lock
    /// held. Terminates any plugin that has been inside a module call for
    /// longer than the budget, and returns at once: it never joins the stuck
    /// thread, never waits for it, and does not touch anything the stuck thread
    /// owns. The plugin's own dispatch thread does the clean-up when the
    /// terminated call unwinds.
    fn watchdogTick(ctx: ?*anyopaque, mono_ms: i64) void {
        const self: *Host = @ptrCast(@alignCast(ctx orelse return));
        // Under the registry lock: an install appends to this list from the
        // API thread while the tick walks it here on the I/O thread.
        self.reg_mu.lock();
        defer self.reg_mu.unlock();
        for (self.entries.items) |e| {
            if (e.removed or !e.isLive()) continue;
            const entered = e.entered_ms.load(.acquire);
            if (entered == 0) continue;
            const elapsed = mono_ms - entered;
            if (elapsed < self.opts.event_budget_ms) continue;
            // Claim the kill. A second tick over the same stuck call must not
            // terminate it twice, and must not overwrite the elapsed time the
            // disable line will report.
            if (e.killed_ms.cmpxchgStrong(0, elapsed, .acq_rel, .acquire) != null) continue;
            self.br.say(
                broker.level_err,
                e.manifest.id,
                "over the {d} ms event budget ({d} ms inside the module); terminating",
                .{ self.opts.event_budget_ms, elapsed },
            );
            e.inst.terminate();
        }
    }
};

fn lessName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---- install: the package, the grants, the consent sentences ----------------

/// Longest refusal sentence kept for the shell to show.
pub const max_install_msg = 240;

/// Longest member name read out of a package. An id is 128 bytes at most and
/// the module name adds five; anything longer is not a plugin file.
pub const max_zip_name = 160;

/// Longest grants.json read back. A full grant list is under 200 bytes.
pub const max_grants_bytes: usize = 4096;

/// The revocation file beside an installed plugin's wasm. A flat directory
/// uses `<id>.grants.json` instead, because its plugins share the directory.
pub const grants_file = "grants.json";

/// The consent table's order (install.md). The sheet and the settings rows
/// list sentences in this order whatever order the manifest declared.
pub const sentence_order = [_]broker.Cap{
    .vessel_read,
    .ais_read,
    .vessel_publish,
    .ais_publish,
    .overlay_draw,
    .alerts_raise,
    .net_tcp_client,
    .net_udp,
    .net_http,
    .net_ws,
    .storage,
    .files,
};

/// One capability's consent sentence, worded exactly as install.md's table.
/// Host lists print inline; the `local` token prints as the boat's own
/// network, because "local" is jargon and that is what it grants.
pub fn writeSentence(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cap: broker.Cap, m: *const Manifest) !void {
    switch (cap) {
        .vessel_read => try out.appendSlice(alloc, "Read your instruments: position, heading, depth, wind."),
        .ais_read => try out.appendSlice(alloc, "Read AIS traffic."),
        .vessel_publish => try out.appendSlice(alloc, "Provide instrument readings to the chart."),
        .ais_publish => try out.appendSlice(alloc, "Provide AIS targets to the chart."),
        .overlay_draw => try out.appendSlice(alloc, "Draw on the chart."),
        .alerts_raise => try out.appendSlice(alloc, "Raise alarms."),
        .net_tcp_client => try out.appendSlice(alloc, "Connect to instruments on your network."),
        .net_udp => try out.appendSlice(alloc, "Listen for broadcasts on your network."),
        .net_http => {
            try out.appendSlice(alloc, "Fetch data from: ");
            try writeHostList(out, alloc, m.http_hosts);
            try out.append(alloc, '.');
        },
        .net_ws => {
            try out.appendSlice(alloc, "Stream data from: ");
            try writeHostList(out, alloc, m.ws_hosts);
            try out.append(alloc, '.');
        },
        .storage => try out.appendSlice(alloc, "Keep its own settings and data."),
        .files => {
            try out.appendSlice(alloc, "Open ");
            for (m.file_types, 0..) |ft, i| {
                if (i > 0) try out.appendSlice(alloc, if (i + 1 == m.file_types.len) " and " else ", ");
                try out.appendSlice(alloc, ft);
            }
            if (m.file_types.len > 0) try out.append(alloc, ' ');
            try out.appendSlice(alloc, "files you choose.");
        },
    }
}

fn writeHostList(out: *std.ArrayList(u8), alloc: std.mem.Allocator, hosts: []const []u8) !void {
    for (hosts, 0..) |h, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, if (std.mem.eql(u8, h, broker.local_token)) "your own network" else h);
    }
}

/// The sentences of `of`'s capabilities as a comma-separated run of JSON
/// strings, skipping any whose sentence `unless` would print identically.
/// With `unless` null that is simply all of them; with it, the run is the
/// consent delta — a changed host list changes the sentence, so it shows.
fn writeSentences(out: *std.ArrayList(u8), alloc: std.mem.Allocator, of: *const Manifest, unless: ?*const Manifest) error{OutOfMemory}!void {
    var first = true;
    for (sentence_order) |cap| {
        if (!of.caps.contains(cap)) continue;
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(alloc);
        try writeSentence(&s, alloc, cap, of);
        if (unless) |other| {
            if (other.caps.contains(cap)) {
                var o: std.ArrayList(u8) = .empty;
                defer o.deinit(alloc);
                try writeSentence(&o, alloc, cap, other);
                if (std.mem.eql(u8, s.items, o.items)) continue;
            }
        }
        if (!first) try out.append(alloc, ',');
        first = false;
        try writeJsonString(out, alloc, s.items);
    }
}

fn pkgBaseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[cut + 1 ..];
}

/// install.md's per-platform table. Null when the platform names no place —
/// Android's files directory has no path in the environment, so a shell there
/// sets `Options.install_root` instead.
pub fn installRootAlloc(alloc: std.mem.Allocator) ?[]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const appdata = std.c.getenv("APPDATA") orelse return null;
            const s = std.mem.span(appdata);
            if (s.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}\\Lookout Marine\\Plugins", .{s}) catch null;
        },
        .macos => {
            const home = std.mem.span(std.c.getenv("HOME") orelse return null);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/Lookout Marine/Plugins", .{home}) catch null;
        },
        .linux => {
            if (std.c.getenv("XDG_DATA_HOME")) |x| {
                const s = std.mem.span(x);
                if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout-marine/plugins", .{s}) catch null;
            }
            const home = std.mem.span(std.c.getenv("HOME") orelse return null);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/.local/share/lookout-marine/plugins", .{home}) catch null;
        },
        else => return null,
    }
}

/// True when the id can be a directory name under the install root:
/// reverse-DNS characters only, no separators, no leading dot. An id that
/// fails this is refused at install and never touches the disk.
pub fn idSafe(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    if (id[0] == '.') return false;
    for (id) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// `{"v":1,"granted":["ais.read",…]}` — the capabilities the mariner has left
/// on. The manifest stays the asked-for set; this file is the subset in force.
pub fn writeGrantsJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, caps: broker.Caps) !void {
    try out.appendSlice(alloc, "{\"v\":1,\"granted\":[");
    var first = true;
    for (sentence_order) |cap| {
        if (!caps.contains(cap)) continue;
        if (!first) try out.append(alloc, ',');
        first = false;
        try writeJsonString(out, alloc, cap.name());
    }
    try out.appendSlice(alloc, "]}");
}

/// Null when the text is not a grants file at all. The caller treats that as
/// nothing granted, never as everything: this is a permissions file. A cap
/// name a newer host wrote and this one does not know grants nothing and
/// refuses nothing.
pub fn parseGrants(alloc: std.mem.Allocator, text: []const u8) ?broker.Caps {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const list = parsed.value.object.get("granted") orelse return null;
    if (list != .array) return null;
    var caps = broker.Caps.initEmpty();
    for (list.array.items) |item| switch (item) {
        .string => |s| if (broker.Cap.fromName(s)) |cap| caps.insert(cap),
        else => return null,
    };
    return caps;
}

/// True when `a` reads as an older version than `b`. Dotted segments compare
/// numerically when both are numbers, lexically otherwise; a missing segment
/// is zero. This only ever decides whether the consent sheet says
/// "downgrade", so a tie or an unparseable pair is simply not one.
pub fn versionLess(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const sa = ia.next();
        const sb = ib.next();
        if (sa == null and sb == null) return false;
        const ta = sa orelse "0";
        const tb = sb orelse "0";
        const na = std.fmt.parseInt(u64, ta, 10) catch null;
        const nb = std.fmt.parseInt(u64, tb, 10) catch null;
        if (na != null and nb != null) {
            if (na.? != nb.?) return na.? < nb.?;
        } else switch (std.mem.order(u8, ta, tb)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
}

/// The name broker.zig's KvStore saves a plugin's storage under, replicated
/// here so `uninstall` can take the file with the plugin. Kept in step with
/// KvStore.fileName by the comment on both.
fn storageFileName(id: []const u8, buf: []u8) []const u8 {
    const n = @min(id.len, buf.len - 5);
    for (id[0..n], 0..) |c, i| buf[i] = switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => c,
        else => '_',
    };
    @memcpy(buf[n .. n + 5], ".json");
    return buf[0 .. n + 5];
}

/// Where broker.zig keeps plugin storage when nobody called setStorageDir,
/// replicated from its defaultStorageDir for the same reason as the name.
fn storageDirDefault(alloc: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = std.c.getenv("APPDATA") orelse return null;
        const s = std.mem.span(appdata);
        if (s.len == 0) return null;
        return std.fmt.allocPrint(alloc, "{s}\\lookout\\plugins", .{s}) catch null;
    }
    if (std.c.getenv("XDG_DATA_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout/plugins", .{s}) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    if (home.len == 0) return null;
    return switch (builtin.os.tag) {
        .macos, .ios => std.fmt.allocPrint(alloc, "{s}/Library/Application Support/lookout/plugins", .{home}) catch null,
        else => std.fmt.allocPrint(alloc, "{s}/.local/share/lookout/plugins", .{home}) catch null,
    };
}

fn boolText(v: f64) []const u8 {
    return if (v != 0) "true" else "false";
}

/// `"key":value` for each field and `"key":[rows]` for each list,
/// comma-separated. `first` says whether the object it is going into is still
/// empty.
fn writeSettings(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    m: *const Manifest,
    values: []const f64,
    rows: []const []u8,
    first: bool,
) !void {
    var lead = first;
    for (m.settings, values) |f, v| {
        if (!lead) try out.append(alloc, ',');
        lead = false;
        try writeJsonString(out, alloc, f.key);
        switch (f.kind) {
            .number => try out.print(alloc, ":{d}", .{v}),
            .toggle => try out.print(alloc, ":{s}", .{boolText(v)}),
            .text => unreachable, // never a scalar; see parseManifest
        }
    }
    for (m.lists, rows) |l, text| {
        if (!lead) try out.append(alloc, ',');
        lead = false;
        try writeJsonString(out, alloc, l.key);
        try out.append(alloc, ':');
        try out.appendSlice(alloc, text);
    }
}

/// Rewrite a list the shell sent into the rows the plugin will see: every
/// column the schema declares, in schema order, clamped and capped, with the
/// row's id kept.
///
/// The rules match the scalar ones. A number out of range is clamped, not
/// refused; a missing column takes its default; a column the schema does not
/// declare is dropped. A row is dropped only if it is not an object, and rows
/// past `max_list_rows` are dropped: a boat with nine NMEA gateways is a
/// misconfiguration, not a use case.
fn normalizeRows(alloc: std.mem.Allocator, l: List, v: std.json.Value) ![]u8 {
    if (v != .array) return Error.BadConfig;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    var written: usize = 0;
    for (v.array.items) |rv| {
        if (written >= max_list_rows) break;
        const ro = switch (rv) {
            .object => |o| o,
            else => continue,
        };
        if (written > 0) try out.append(alloc, ',');
        // The id is the shell's, and it is what a status item points at. A row
        // that arrives without one gets its position, so the plugin always has
        // something to echo.
        try out.appendSlice(alloc, "{\"id\":");
        const id = switch (ro.get("id") orelse std.json.Value{ .string = "" }) {
            .string => |s| if (s.len > max_row_id) s[0..max_row_id] else s,
            else => "",
        };
        if (id.len > 0) {
            try writeJsonString(&out, alloc, id);
        } else {
            try out.print(alloc, "\"row{d}\"", .{written + 1});
        }
        for (l.items) |f| {
            try out.append(alloc, ',');
            try writeJsonString(&out, alloc, f.key);
            try out.append(alloc, ':');
            const cell = ro.get(f.key);
            switch (f.kind) {
                .number => {
                    const n = jsonNumber(cell) orelse f.default_value;
                    try out.print(alloc, "{d}", .{std.math.clamp(n, f.min, f.max)});
                },
                .toggle => {
                    const b = switch (cell orelse std.json.Value{ .bool = f.default_value != 0 }) {
                        .bool => |x| x,
                        else => f.default_value != 0,
                    };
                    try out.appendSlice(alloc, if (b) "true" else "false");
                },
                .text => {
                    const s = switch (cell orelse std.json.Value{ .string = f.default_text }) {
                        .string => |x| x,
                        else => f.default_text,
                    };
                    try writeJsonString(&out, alloc, if (s.len > max_text_bytes) s[0..max_text_bytes] else s);
                },
            }
        }
        try out.append(alloc, '}');
        written += 1;
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

fn freeRows(alloc: std.mem.Allocator, rows: [][]u8, built: usize) void {
    for (rows[0..built]) |r| alloc.free(r);
    if (rows.len > 0) alloc.free(rows);
}

/// What a control IS: the label, the sentence under it, the kind, the unit and
/// the limits. Shared by a scalar field and a list's columns. Keys a schema
/// does not declare are left out, so a v1 manifest still writes what it always
/// wrote.
fn writeFieldCore(out: *std.ArrayList(u8), alloc: std.mem.Allocator, f: Field) !void {
    try out.appendSlice(alloc, "\"key\":");
    try writeJsonString(out, alloc, f.key);
    try out.appendSlice(alloc, ",\"label\":");
    try writeJsonString(out, alloc, f.label);
    if (f.desc.len > 0) {
        try out.appendSlice(alloc, ",\"desc\":");
        try writeJsonString(out, alloc, f.desc);
    }
    try out.print(alloc, ",\"kind\":\"{s}\"", .{@tagName(f.kind)});
    if (f.unit.len > 0) {
        try out.appendSlice(alloc, ",\"unit\":");
        try writeJsonString(out, alloc, f.unit);
    }
    if (f.optional) try out.appendSlice(alloc, ",\"optional\":true");
    switch (f.kind) {
        .number => try out.print(alloc, ",\"min\":{d},\"max\":{d},\"default\":{d}", .{ f.min, f.max, f.default_value }),
        .toggle => try out.print(alloc, ",\"default\":{s}", .{boolText(f.default_value)}),
        .text => {
            try out.appendSlice(alloc, ",\"default\":");
            try writeJsonString(out, alloc, f.default_text);
            try out.print(alloc, ",\"max_len\":{d}", .{max_text_bytes});
        },
    }
}

/// One scalar field of the registry JSON: what the control is, where the shell
/// puts it, and the value in force.
fn writeFieldJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, f: Field, v: f64) !void {
    try out.append(alloc, '{');
    try writeFieldCore(out, alloc, f);
    // Where the shell puts the control. The group is the section heading, left
    // out when the schema declares none. The tab is always written, and always
    // resolved, so every shell reads one answer.
    if (f.group.len > 0) {
        try out.appendSlice(alloc, ",\"group\":");
        try writeJsonString(out, alloc, f.group);
    }
    try out.print(alloc, ",\"tab\":\"{s}\"", .{@tagName(f.tab)});
    switch (f.kind) {
        .number => try out.print(alloc, ",\"value\":{d}", .{v}),
        .toggle => try out.print(alloc, ",\"value\":{s}", .{boolText(v)}),
        .text => unreachable, // never a scalar; see parseManifest
    }
    try out.append(alloc, '}');
}

/// A quoted, escaped JSON string. A manifest is a file on disk and a status
/// line is text a plugin wrote; neither may break the shape of what it lands
/// in.
fn writeJsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        0...8, 11, 12, 14...31 => try out.print(alloc, "\\u{x:0>4}", .{c}),
        else => try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

// ---- tests -------------------------------------------------------------------

const t = std.testing;

test "a manifest parses id, name, api and the granted capabilities" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.ais","name":"AIS targets","api":1,
        \\ "capabilities":["ais.read","overlay.draw","alerts.raise"]}
    );
    defer m.deinit(a);
    try t.expectEqualStrings("org.beetlebug.ais", m.id);
    try t.expectEqualStrings("AIS targets", m.name);
    try t.expectEqual(@as(u32, 1), m.api);
    try t.expect(m.caps.contains(.ais_read));
    try t.expect(m.caps.contains(.overlay_draw));
    try t.expect(m.caps.contains(.alerts_raise));
    try t.expect(!m.caps.contains(.vessel_publish));
    try t.expect(!m.caps.contains(.net_tcp_client));
}

test "a manifest's version is a short string, shown and never enforced" {
    const a = t.allocator;
    var m = try parseManifest(a, "{\"id\":\"x\",\"api\":1,\"version\":\"1.4.0\"}");
    defer m.deinit(a);
    try t.expectEqualStrings("1.4.0", m.version);

    var none = try parseManifest(a, "{\"id\":\"x\",\"api\":1}");
    defer none.deinit(a);
    try t.expectEqualStrings("", none.version);

    // A number and a novel are both typos, not versions.
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"api\":1,\"version\":2}"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"api\":1,\"version\":\"a-version-string-far-longer-than-anyone-prints\"}"));
}

test "a manifest with no capabilities grants nothing, and name defaults to id" {
    const a = t.allocator;
    var m = try parseManifest(a, "{\"id\":\"org.beetlebug.quiet\",\"api\":1}");
    defer m.deinit(a);
    try t.expectEqualStrings("org.beetlebug.quiet", m.name);
    try t.expectEqual(@as(usize, 0), m.caps.count());
}

test "a manifest is refused rather than half-read" {
    const a = t.allocator;
    try t.expectError(Error.BadManifest, parseManifest(a, "not json"));
    try t.expectError(Error.BadManifest, parseManifest(a, "[]"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"api\":1}"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\"}"));
    // An unknown capability is a typo in a grant, so the plugin does not load.
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"net.mqtt\"]}"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"api\":1,\"capabilities\":\"vessel.read\"}"));
}

test "a net.http or net.ws grant carries the hosts it covers, and nothing else" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.grib","api":1,"capabilities":[
        \\  {"net.http":["nomads.ncep.noaa.gov","opendap.nasa.gov"]},
        \\  {"net.ws":["demo.signalk.org"]},
        \\  "storage","files","net.udp"]}
    );
    defer m.deinit(a);
    try t.expect(m.caps.contains(.net_http));
    try t.expect(m.caps.contains(.net_ws));
    try t.expect(m.caps.contains(.storage));
    try t.expect(m.caps.contains(.files));
    try t.expect(m.caps.contains(.net_udp));
    try t.expectEqual(@as(usize, 2), m.http_hosts.len);
    try t.expectEqualStrings("nomads.ncep.noaa.gov", m.http_hosts[0]);
    try t.expectEqualStrings("opendap.nasa.gov", m.http_hosts[1]);
    try t.expectEqual(@as(usize, 1), m.ws_hosts.len);
    try t.expectEqualStrings("demo.signalk.org", m.ws_hosts[0]);

    const bad = [_][]const u8{
        // A bare net.http is "may reach anything", which no manifest may ask
        // for, and an empty list is the same grant written longer.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"net.http\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"net.ws\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[]}]}",
        // A capability that reaches no named server takes no list.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"storage\":[\"a.example\"]}]}",
        // A URL, a wildcard and a path are not hostnames.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"https://a.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"*.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"a.example/x\"]}]}",
        // One entry, one capability; and one list per capability.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"a.example\"],\"net.ws\":[\"b.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"a.example\"]},{\"net.http\":[\"b.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":\"a.example\"}]}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));
}

test "a manifest claims file types, lowercase and dotted, and only with files" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.grib","api":1,"capabilities":["files"],
        \\ "file_types":[".grib2",".grb"]}
    );
    defer m.deinit(a);
    try t.expectEqual(@as(usize, 2), m.file_types.len);
    try t.expectEqualStrings(".grib2", m.file_types[0]);
    try t.expectEqualStrings(".grb", m.file_types[1]);
    try t.expect(m.claimsFileType(".grb"));
    try t.expect(!m.claimsFileType(".gpx"));

    const bad = [_][]const u8{
        // The claim rests on `files`: without it the plugin could not read a
        // byte of what it asked for.
        "{\"id\":\"x\",\"api\":1,\"file_types\":[\".grib2\"]}",
        // Written any way but the way the routing compares it.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[\".GRIB2\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[\"grib2\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[\".tar.gz\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[\".\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[\".grib 2\"]}",
        // Claiming nothing, written like a claim.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":\".grib2\"}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[1]}",
        // The same type twice is a typo, not two claims.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[\".grb\",\".grb\"]}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));

    // Nine types is past what a grant sentence can say.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    try many.appendSlice(a, "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"],\"file_types\":[");
    for (0..max_file_types + 1) |i| {
        if (i > 0) try many.append(a, ',');
        try many.print(a, "\".t{d}\"", .{i});
    }
    try many.appendSlice(a, "]}");
    try t.expectError(Error.BadManifest, parseManifest(a, many.items));

    // A manifest that claims nothing keeps an empty list, not a null one.
    var quiet = try parseManifest(a, "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"files\"]}");
    defer quiet.deinit(a);
    try t.expectEqual(@as(usize, 0), quiet.file_types.len);
}

test "the extension is read from the name, lowercased, dot kept" {
    var buf: [max_file_type]u8 = undefined;
    try t.expectEqualStrings(".grib2", fileExtension("gfs.grib2", &buf).?);
    try t.expectEqualStrings(".grib2", fileExtension("/Users/x/Downloads/GFS.GRIB2", &buf).?);
    try t.expectEqualStrings(".grb", fileExtension("C:\\charts\\wind.GRB", &buf).?);
    // A dot in a directory name is not the file's type.
    try t.expectEqualStrings(".grib2", fileExtension("/x/v1.2/gfs.grib2", &buf).?);
    try t.expect(fileExtension("/x/v1.2/README", &buf) == null);
    // No dot, a name that is only a dot, a hidden file, and an extension no
    // manifest could have claimed.
    try t.expect(fileExtension("noextension", &buf) == null);
    try t.expect(fileExtension("/x/.profile", &buf) == null);
    try t.expect(fileExtension("trailing.", &buf) == null);
    try t.expect(fileExtension("x.thisextensionistoolong", &buf) == null);
}

const ais_settings_manifest =
    \\{"id":"org.beetlebug.ais","name":"AIS targets","api":1,
    \\ "capabilities":["ais.read"],
    \\ "settings":[
    \\  {"key":"cpa_limit","label":"CPA limit","kind":"number","unit":"m","min":93,"max":9260,"default":926},
    \\  {"key":"cpa_alarm","label":"Collision alarm","kind":"toggle","default":true}]}
;

test "the start payload carries the api version, and NMEA config only for nmea0183" {
    var vessels = try store.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(t.allocator);
    defer ais.deinit();
    var br = broker.Broker.init(t.allocator, &vessels, &ais, .{});
    defer br.deinit();
    var h = Host.init(t.allocator, &br, .{ .nmea_host = "10.0.0.4", .nmea_port = 2000 });
    defer h.deinit();

    var nm = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.nmea0183\",\"api\":1}");
    defer nm.deinit(t.allocator);
    const nmea = try h.startJson(&nm, &.{}, &.{});
    defer t.allocator.free(nmea);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"host\":\"10.0.0.4\",\"port\":2000}}", nmea);

    var om = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.ownship\",\"api\":1}");
    defer om.deinit(t.allocator);
    const other = try h.startJson(&om, &.{}, &.{});
    defer t.allocator.free(other);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{}}", other);

    // A plugin with a schema starts on its defaults, in the same shape
    // CONFIG_CHANGED later carries.
    var am = try parseManifest(t.allocator, ais_settings_manifest);
    defer am.deinit(t.allocator);
    const with = try h.startJson(&am, &.{ 926, 1 }, &.{});
    defer t.allocator.free(with);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"cpa_limit\":926,\"cpa_alarm\":true}}", with);
}

test "a settings schema parses, and a malformed field refuses the manifest" {
    const a = t.allocator;
    var m = try parseManifest(a, ais_settings_manifest);
    defer m.deinit(a);
    try t.expectEqual(@as(usize, 2), m.settings.len);
    try t.expectEqualStrings("cpa_limit", m.settings[0].key);
    try t.expectEqualStrings("CPA limit", m.settings[0].label);
    try t.expectEqualStrings("m", m.settings[0].unit);
    try t.expectEqual(Field.Kind.number, m.settings[0].kind);
    try t.expectEqual(@as(f64, 93), m.settings[0].min);
    try t.expectEqual(@as(f64, 9260), m.settings[0].max);
    try t.expectEqual(@as(f64, 926), m.settings[0].default_value);
    try t.expectEqual(Field.Kind.toggle, m.settings[1].kind);
    try t.expectEqual(@as(f64, 1), m.settings[1].default_value);
    try t.expectEqual(@as(usize, 1), m.field("cpa_alarm").?);
    try t.expect(m.field("nothing") == null);

    // A field with no kind, an unknown kind, a range that is not one, a
    // toggle whose default is a number, and two fields sharing a key.
    const bad = [_][]const u8{
        "{\"id\":\"x\",\"api\":1,\"settings\":[{\"key\":\"a\"}]}",
        "{\"id\":\"x\",\"api\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"slider\",\"default\":1}]}",
        "{\"id\":\"x\",\"api\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"number\",\"min\":5,\"max\":5,\"default\":5}]}",
        "{\"id\":\"x\",\"api\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"number\",\"min\":0,\"max\":5}]}",
        "{\"id\":\"x\",\"api\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"toggle\",\"default\":1}]}",
        "{\"id\":\"x\",\"api\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"toggle\",\"default\":true}," ++
            "{\"key\":\"a\",\"kind\":\"toggle\",\"default\":false}]}",
        "{\"id\":\"x\",\"api\":1,\"settings\":{}}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));

    // A default outside the range it declares is clamped, not refused.
    var clamped = try parseManifest(a,
        \\{"id":"x","api":1,"settings":[{"key":"a","kind":"number","min":1,"max":10,"default":99}]}
    );
    defer clamped.deinit(a);
    try t.expectEqual(@as(f64, 10), clamped.settings[0].default_value);

    // v1 fields have no group and no tab of their own.
    try t.expectEqualStrings("", m.settings[0].desc);
    try t.expectEqualStrings("", m.settings[0].group);
    try t.expectEqual(Tab.advanced, m.settings[0].tab);
}

const v2_manifest =
    \\{"id":"org.beetlebug.ais","name":"AIS targets","api":1,
    \\ "settings":{"groups":[
    \\  {"label":"Collision alarm","tab":"alarms","fields":[
    \\   {"key":"cpa_limit","label":"Closest approach","desc":"Alarm when a vessel will pass closer than this.",
    \\    "kind":"number","unit":"m","min":93,"max":9260,"default":926},
    \\   {"key":"cpa_alarm","label":"Collision alarm","kind":"toggle","default":true}]},
    \\  {"label":"AIS targets","tab":"vessels","fields":[
    \\   {"key":"vector_min","label":"Course vectors","kind":"number","unit":"min","min":1,"max":24,"default":6}]},
    \\  {"fields":[
    \\   {"key":"spare","label":"Spare","kind":"toggle","default":false}]}]}}
;

test "a v2 schema carries labels, descriptions, groups and tabs" {
    const a = t.allocator;
    var m = try parseManifest(a, v2_manifest);
    defer m.deinit(a);
    try t.expectEqual(@as(usize, 4), m.settings.len);

    // One plugin's settings span tabs: the alarm group asks for Alarms, the
    // presentation group for Vessels.
    try t.expectEqualStrings("Closest approach", m.settings[0].label);
    try t.expectEqualStrings("Alarm when a vessel will pass closer than this.", m.settings[0].desc);
    try t.expectEqualStrings("Collision alarm", m.settings[0].group);
    try t.expectEqual(Tab.alarms, m.settings[0].tab);
    try t.expectEqual(Tab.alarms, m.settings[1].tab);
    try t.expectEqualStrings("AIS targets", m.settings[2].group);
    try t.expectEqual(Tab.vessels, m.settings[2].tab);

    // A group that names neither heading nor tab, and a field that names no
    // description, fall back rather than refuse.
    try t.expectEqual(Tab.advanced, m.settings[3].tab);
    try t.expectEqualStrings("", m.settings[3].group);
    try t.expectEqualStrings("", m.settings[3].desc);

    // An unknown tab is a typo, not a new tab.
    var unknown = try parseManifest(a,
        \\{"id":"x","api":1,"settings":{"groups":[{"label":"G","tab":"weather",
        \\ "fields":[{"key":"a","kind":"toggle","default":true}]}]}}
    );
    defer unknown.deinit(a);
    try t.expectEqual(Tab.advanced, unknown.settings[0].tab);

    // A v2 block with no groups array, a group that is not an object, and a
    // group with no fields.
    const bad = [_][]const u8{
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"fields\":[]}}",
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[\"G\"]}}",
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"label\":\"G\"}]}}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));
}

const list_manifest =
    \\{"id":"org.beetlebug.nmea0183","name":"NMEA 0183","api":1,
    \\ "settings":{"groups":[
    \\  {"label":"Connections","tab":"connections","list":{"key":"connections",
    \\   "footer":"Most WiFi gateways serve NMEA 0183 on port 10110.",
    \\   "empty":"No gateways yet.","add_label":"Add Gateway","switch_key":"enabled",
    \\   "item_fields":[
    \\   {"key":"name","label":"Name","kind":"text","optional":true},
    \\   {"key":"host","label":"Address","desc":"The gateway on your network.","kind":"text","default":"127.0.0.1"},
    \\   {"key":"port","label":"Port","kind":"number","min":1,"max":65535,"default":10110},
    \\   {"key":"enabled","label":"On","kind":"toggle","default":true}]}}]}}
;

test "a list group parses, and its rows are policed like any other setting" {
    const a = t.allocator;
    var m = try parseManifest(a, list_manifest);
    defer m.deinit(a);
    try t.expectEqual(@as(usize, 0), m.settings.len);
    try t.expectEqual(@as(usize, 1), m.lists.len);

    const l = m.lists[0];
    try t.expectEqualStrings("connections", l.key);
    try t.expectEqualStrings("Connections", l.group);
    try t.expectEqual(Tab.connections, l.tab);
    // The wording around the rows belongs to the plugin, because only the
    // plugin knows what a row is. Two lists on one tab would otherwise both
    // wear whichever sentence the application hard-coded.
    try t.expectEqualStrings("Most WiFi gateways serve NMEA 0183 on port 10110.", l.footer);
    try t.expectEqualStrings("No gateways yet.", l.empty);
    try t.expectEqualStrings("Add Gateway", l.add_label);
    try t.expectEqualStrings("enabled", l.switch_key);
    try t.expectEqual(@as(usize, 4), l.items.len);
    try t.expectEqual(Field.Kind.text, l.items[0].kind);
    try t.expect(l.items[0].optional);
    try t.expectEqualStrings("127.0.0.1", l.items[1].default_text);
    try t.expectEqual(@as(usize, 0), m.list("connections").?);

    // A row keeps its id, takes the schema's order, clamps a number, drops a
    // column nobody declared, and fills in what is missing.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ja = arena.allocator();
    const rows = try normalizeRows(
        a,
        l,
        try std.json.parseFromSliceLeaky(std.json.Value, ja,
            \\[{"id":"c1","name":"Masthead","host":"10.0.0.9","port":99999,"enabled":false,"junk":1},
            \\ {"host":"nav.local"}]
        , .{ .allocate = .alloc_if_needed }),
    );
    defer a.free(rows);
    try t.expectEqualStrings(
        "[{\"id\":\"c1\",\"name\":\"Masthead\",\"host\":\"10.0.0.9\",\"port\":65535,\"enabled\":false}," ++
            "{\"id\":\"row2\",\"name\":\"\",\"host\":\"nav.local\",\"port\":10110,\"enabled\":true}]",
        rows,
    );

    // Rows past the cap are dropped, and a row that is not an object is not a
    // row at all.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    try many.append(a, '[');
    for (0..max_list_rows + 3) |i| {
        if (i > 0) try many.append(a, ',');
        try many.print(a, "{{\"host\":\"h{d}\"}}", .{i});
    }
    try many.appendSlice(a, ",7]");
    const capped = try normalizeRows(a, l, try std.json.parseFromSliceLeaky(std.json.Value, ja, many.items, .{}));
    defer a.free(capped);
    try t.expectEqual(max_list_rows, std.mem.count(u8, capped, "\"host\":"));

    // A list that is not an array is a shell fault, not a clamp.
    try t.expectError(Error.BadConfig, normalizeRows(a, l, .{ .bool = true }));

    // The registry JSON carries the schema of one row and the rows in force.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try json.append(a, '{');
    try writeFieldCore(&json, a, l.items[1]);
    try json.append(a, '}');
    try t.expectEqualStrings(
        "{\"key\":\"host\",\"label\":\"Address\",\"desc\":\"The gateway on your network.\"," ++
            "\"kind\":\"text\",\"default\":\"127.0.0.1\",\"max_len\":128}",
        json.items,
    );
}

test "a list is refused when it fights another key, and text needs a row" {
    const a = t.allocator;
    const bad = [_][]const u8{
        // A scalar text field has nowhere to keep its value.
        "{\"id\":\"x\",\"api\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"text\"}]}",
        // A list with no key, and one with no columns.
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"list\":{\"item_fields\":[]}}]}}",
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"item_fields\":[]}}]}}",
        // A column called id would fight the one the host writes.
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"item_fields\":" ++
            "[{\"key\":\"id\",\"kind\":\"text\"}]}}]}}",
        // A switch naming a column the list does not have, and one naming a
        // column that is not a toggle: either leaves the shell with no switch.
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"switch_key\":\"nope\"," ++
            "\"item_fields\":[{\"key\":\"on\",\"kind\":\"toggle\",\"default\":true}]}}]}}",
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"switch_key\":\"h\"," ++
            "\"item_fields\":[{\"key\":\"h\",\"kind\":\"text\"}]}}]}}",
        // A list key that a field already uses, and two lists with one key.
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"fields\":[{\"key\":\"c\",\"kind\":\"toggle\",\"default\":true}]}," ++
            "{\"list\":{\"key\":\"c\",\"item_fields\":[{\"key\":\"h\",\"kind\":\"text\"}]}}]}}",
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"item_fields\":[{\"key\":\"h\",\"kind\":\"text\"}]}}," ++
            "{\"list\":{\"key\":\"c\",\"item_fields\":[{\"key\":\"h\",\"kind\":\"text\"}]}}]}}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));
}

test "the registry JSON carries the schema the shell renders" {
    const a = t.allocator;
    var m = try parseManifest(a, v2_manifest);
    defer m.deinit(a);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    for (m.settings) |f| try writeFieldJson(&json, a, f, f.default_value);
    const s = json.items;
    try t.expect(std.mem.indexOf(u8, s, "\"desc\":\"Alarm when a vessel will pass closer than this.\"") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"group\":\"Collision alarm\",\"tab\":\"alarms\"") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"group\":\"AIS targets\",\"tab\":\"vessels\"") != null);
    // Nothing declared: no desc key, no group key, and the fallback tab.
    try t.expect(std.mem.indexOf(u8, s, "{\"key\":\"spare\",\"label\":\"Spare\",\"kind\":\"toggle\"," ++
        "\"default\":false,\"tab\":\"advanced\",\"value\":false}") != null);

    // v1 keeps the shape it always wrote, with the tab added.
    var v1 = try parseManifest(a, ais_settings_manifest);
    defer v1.deinit(a);
    json.clearRetainingCapacity();
    try writeFieldJson(&json, a, v1.settings[0], 926);
    try t.expectEqualStrings("{\"key\":\"cpa_limit\",\"label\":\"CPA limit\",\"kind\":\"number\",\"unit\":\"m\"," ++
        "\"min\":93,\"max\":9260,\"default\":926,\"tab\":\"advanced\",\"value\":926}", json.items);
}

test "the consent sentences read exactly as install.md words them" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.example.everything","api":1,"capabilities":[
        \\ "vessel.read","ais.read","vessel.publish","ais.publish",
        \\ "overlay.draw","alerts.raise","net.tcp-client","net.udp",
        \\ {"net.http":["nomads.ncep.noaa.gov"]},
        \\ {"net.ws":["demo.signalk.org","local"]},
        \\ "storage","files"],
        \\ "file_types":[".grib2",".grb"]}
    );
    defer m.deinit(a);

    const expect = [_][]const u8{
        "Read your instruments: position, heading, depth, wind.",
        "Read AIS traffic.",
        "Provide instrument readings to the chart.",
        "Provide AIS targets to the chart.",
        "Draw on the chart.",
        "Raise alarms.",
        "Connect to instruments on your network.",
        "Listen for broadcasts on your network.",
        "Fetch data from: nomads.ncep.noaa.gov.",
        "Stream data from: demo.signalk.org, your own network.",
        "Keep its own settings and data.",
        "Open .grib2 and .grb files you choose.",
    };
    for (sentence_order, expect) |cap, want| {
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(a);
        try writeSentence(&s, a, cap, &m);
        try t.expectEqualStrings(want, s.items);
    }

    // The delta writer: everything against nothing is everything, and a
    // manifest against itself is silence.
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(a);
    try writeSentences(&all, a, &m, null);
    try t.expectEqual(@as(usize, expect.len), std.mem.count(u8, all.items, "\"") / 2);
    var none: std.ArrayList(u8) = .empty;
    defer none.deinit(a);
    try writeSentences(&none, a, &m, &m);
    try t.expectEqualStrings("", none.items);

    // A changed host list changes the sentence, so it shows in the delta.
    var other = try parseManifest(a,
        \\{"id":"org.example.everything","api":1,"capabilities":[{"net.http":["tiles.example.org"]}]}
    );
    defer other.deinit(a);
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(a);
    try writeSentences(&delta, a, &other, &m);
    try t.expectEqualStrings("\"Fetch data from: tiles.example.org.\"", delta.items);
}

test "grants.json round-trips, and a malformed one grants nothing" {
    const a = t.allocator;
    var caps = broker.Caps.initEmpty();
    caps.insert(.ais_read);
    caps.insert(.overlay_draw);
    caps.insert(.net_http);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try writeGrantsJson(&json, a, caps);
    try t.expectEqualStrings("{\"v\":1,\"granted\":[\"ais.read\",\"overlay.draw\",\"net.http\"]}", json.items);

    const back = parseGrants(a, json.items).?;
    try t.expect(back.eql(caps));

    // An empty grant list is a valid file that grants nothing.
    const empty = parseGrants(a, "{\"v\":1,\"granted\":[]}").?;
    try t.expectEqual(@as(usize, 0), empty.count());

    // A name a newer host knows grants nothing here and refuses nothing.
    const newer = parseGrants(a, "{\"v\":1,\"granted\":[\"ais.read\",\"net.quic\"]}").?;
    try t.expectEqual(@as(usize, 1), newer.count());

    // Not a grants file at all: null, which the loader reads as NOTHING
    // granted, never as everything.
    try t.expect(parseGrants(a, "not json") == null);
    try t.expect(parseGrants(a, "[]") == null);
    try t.expect(parseGrants(a, "{\"v\":1}") == null);
    try t.expect(parseGrants(a, "{\"v\":1,\"granted\":[1]}") == null);
}

test "version order decides only the downgrade sentence" {
    try t.expect(versionLess("1.2", "1.10"));
    try t.expect(!versionLess("1.10", "1.2"));
    try t.expect(versionLess("1.2", "1.2.1"));
    try t.expect(!versionLess("1.2", "1.2"));
    try t.expect(!versionLess("", ""));
    try t.expect(versionLess("", "0.1"));
    // Unparseable segments fall back to text order rather than lying.
    try t.expect(versionLess("1.0-beta", "1.0-rc"));
}

test "an id that could leave the install root is refused" {
    try t.expect(idSafe("org.example.downwind"));
    try t.expect(idSafe("a-b_c.9"));
    try t.expect(!idSafe(""));
    try t.expect(!idSafe(".hidden"));
    try t.expect(!idSafe("../escape"));
    try t.expect(!idSafe("a/b"));
    try t.expect(!idSafe("a\\b"));
    try t.expect(!idSafe("a b"));
}
