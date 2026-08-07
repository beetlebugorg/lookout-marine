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

pub const wasm = @import("wasm.zig");
pub const store = @import("store.zig");
pub const aisstore = @import("aisstore.zig");
pub const broker = @import("broker.zig");
pub const webio = @import("webio.zig");

const io = std.Io.Threaded.global_single_threaded.io();

/// The ABI version this host speaks. A module reporting anything else is not
/// loaded — the exports may have the same names and a different meaning.
pub const abi_version: u32 = 1;

/// Largest plugin module accepted. The prototype's plugins are tens of KiB;
/// the cap is here so a stray file in the plugin directory cannot be read into
/// memory whole.
pub const max_module_bytes: usize = 8 * 1024 * 1024;
pub const max_manifest_bytes: usize = 64 * 1024;

pub const Error = error{
    BadManifest,
    AbiMismatch,
    StartRefused,
    /// A plugin cannot be loaded once the dispatch threads are running: they
    /// hold pointers into the registry, which growing it would invalidate.
    AlreadyStarted,
    /// `configSet` named an id no plugin here answers to.
    UnknownPlugin,
    /// The config JSON is not an object, or a field it names does not match
    /// the kind the schema declares.
    BadConfig,
    /// `grantFile` named a plugin whose manifest did not ask for `files`.
    NotGranted,
    /// Two manifests claim the file type the mariner opened. Neither gets the
    /// file: see `openFile`.
    FileTypeConflict,
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
    /// The unit of a number field, for display only: values cross the ABI in
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

    /// `text` is only legal inside a LIST: a scalar value crosses the ABI as a
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
/// `{"id":"org.beetlebug.ais","name":"AIS","abi":1,"capabilities":[...],
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
    abi: u32,
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
    const abi: u32 = switch (o.get("abi") orelse return Error.BadManifest) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return Error.BadManifest,
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
    // the ABI as numbers.
    for (fields[0..built]) |f| {
        if (f.kind == .text) return Error.BadManifest;
    }
    return .{
        .id = id_owned,
        .name = name_owned,
        .abi = abi,
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

/// One loaded plugin, and the thread that runs it.
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
    entries: std.ArrayList(Entry) = .empty,
    /// True between `start` and `stop`, while the dispatch threads exist.
    started: bool = false,
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
        for (self.entries.items) |*e| {
            e.inst.deinit();
            e.module.deinit();
            self.alloc.free(e.bytes);
            if (e.values.len > 0) self.alloc.free(e.values);
            freeRows(self.alloc, e.rows, e.rows.len);
            e.manifest.deinit(self.alloc);
            self.alloc.destroy(e.state);
        }
        self.entries.deinit(self.alloc);
        if (self.runtime_held) {
            runtimeRelease();
            self.runtime_held = false;
        }
        self.* = undefined;
    }

    pub fn count(self: *const Host) usize {
        return self.entries.items.len;
    }

    /// The plugin state by manifest id, for the harness and the tests.
    pub fn find(self: *Host, id: []const u8) ?*broker.Plugin {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.manifest.id, id)) return e.state;
        }
        return null;
    }

    // -- loading -------------------------------------------------------------

    /// Load every plugin in `dir`: each is a `<id>.manifest.json` and the
    /// `<id>.wasm` beside it, which is what `zig build plugins` installs. A
    /// plugin that fails to load is logged and skipped — one bad module must
    /// not take the others down with it.
    ///
    /// Load order is the sorted file order, and load order IS source priority
    /// in the vessel store, so it is deterministic across machines.
    pub fn loadDir(self: *Host, dir_path: []const u8) !void {
        // The dispatch threads hold pointers into `entries`; appending to it
        // now could move them. Load first, then start.
        if (self.started) return Error.AlreadyStarted;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
            self.br.say(broker.level_warn, "host", "plugins: cannot open {s}: {s}", .{ dir_path, @errorName(e) });
            return e;
        };
        defer dir.close(io);

        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.alloc.free(n);
            names.deinit(self.alloc);
        }
        var it = dir.iterate();
        while (try it.next(io)) |ent| {
            if (ent.kind == .directory) continue;
            if (!std.mem.endsWith(u8, ent.name, manifest_suffix)) continue;
            try names.append(self.alloc, try self.alloc.dupe(u8, ent.name));
        }
        std.mem.sort([]u8, names.items, {}, lessName);

        for (names.items) |n| {
            const stem = n[0 .. n.len - manifest_suffix.len];
            self.loadOne(dir, dir_path, stem, n) catch |e| {
                self.br.say(broker.level_err, "host", "plugins: {s} not loaded: {s}", .{ stem, @errorName(e) });
            };
        }
    }

    const manifest_suffix = ".manifest.json";

    fn loadOne(self: *Host, dir: std.Io.Dir, dir_path: []const u8, stem: []const u8, manifest_name: []const u8) !void {
        const manifest_text = try dir.readFileAlloc(io, manifest_name, self.alloc, .limited(max_manifest_bytes));
        defer self.alloc.free(manifest_text);
        var manifest = try parseManifest(self.alloc, manifest_text);
        errdefer manifest.deinit(self.alloc);
        if (manifest.abi != abi_version) return Error.AbiMismatch;

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

        const wasm_name = try std.fmt.allocPrint(self.alloc, "{s}.wasm", .{stem});
        defer self.alloc.free(wasm_name);
        const raw = try dir.readFileAlloc(io, wasm_name, self.alloc, .limited(max_module_bytes));
        defer self.alloc.free(raw);

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
            .caps = manifest.caps,
            .http_hosts = manifest.http_hosts,
            .ws_hosts = manifest.ws_hosts,
        };
        inst.setUserData(state);

        const reported = try inst.abiVersion();
        if (reported != abi_version) {
            self.br.say(broker.level_err, manifest.id, "lk_abi reported {d}, host speaks {d}", .{ reported, abi_version });
            return Error.AbiMismatch;
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

        self.next_source += 1;
        try self.entries.append(self.alloc, .{
            .manifest = manifest,
            .bytes = bytes,
            .module = module,
            .inst = inst,
            .state = state,
            .values = values,
            .rows = rows,
        });
        self.br.say(broker.level_info, manifest.id, "started ({s}, source {d})", .{ manifest.name, state.source });
        _ = dir_path;
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
        try out.print(self.alloc, "{{\"abi\":{d},\"config\":{{", .{abi_version});
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
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.manifest.id, id)) return e;
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
        for (self.entries.items) |*e| {
            if (!e.isLive()) continue;
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
        for (self.entries.items, 0..) |*e, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"id\":");
            try writeJsonString(out, alloc, e.manifest.id);
            try out.appendSlice(alloc, ",\"name\":");
            try writeJsonString(out, alloc, e.manifest.name);
            try out.print(alloc, ",\"live\":{s}", .{if (e.isLive()) "true" else "false"});
            // The status line is a string, not an object: it is text a plugin
            // wrote, and the shell decides what to do with it.
            try out.appendSlice(alloc, ",\"status\":");
            try writeJsonString(out, alloc, e.state.status());
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

    // -- the event loop ------------------------------------------------------

    /// Start the broker's I/O thread, arm the watchdog, and give every live
    /// plugin its own dispatch thread. Call after `loadDir`: `lk_start` runs on
    /// the caller's thread, and nothing should be delivering events while it
    /// does.
    pub fn start(self: *Host) !void {
        if (self.started) return;
        // Armed before the I/O thread exists, so the first tick already has it.
        self.br.setWatchdog(self, watchdogTick);
        try self.br.start();
        self.started = true;
        for (self.entries.items, 0..) |*e, i| {
            if (!e.isLive()) continue;
            e.stopping.store(false, .release);
            e.thread = std.Thread.spawn(
                .{ .stack_size = dispatch_stack_bytes },
                dispatchMain,
                .{ self, @as(u32, @intCast(i)) },
            ) catch |err| {
                // No thread means no events, ever. Better a plugin that is
                // visibly gone than one that is silently deaf.
                self.br.say(broker.level_err, e.manifest.id, "no dispatch thread: {s}", .{@errorName(err)});
                self.retire(@intCast(i), true, "no dispatch thread");
                continue;
            };
        }
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
            for (self.entries.items, 0..) |*e, i| {
                if (e.isLive()) self.deliverTo(@intCast(i), broker.Kind.shutdown, 0, "");
            }
            self.br.stop();
            return;
        }

        for (self.entries.items, 0..) |*e, i| {
            if (e.isLive()) self.br.push(@intCast(i), broker.Kind.shutdown, 0, "");
        }
        var waited: u32 = 0;
        while (self.br.queued() > 0 and waited < self.opts.shutdown_ms) : (waited += 2) {
            broker.sleepMs(2);
        }

        for (self.entries.items) |*e| e.stopping.store(true, .release);
        var grace: u32 = 0;
        while (grace < shutdown_grace_ms and self.anyInModule()) : (grace += 2) broker.sleepMs(2);
        for (self.entries.items) |*e| {
            if (e.thread == null or e.entered_ms.load(.acquire) == 0) continue;
            self.br.say(broker.level_warn, e.manifest.id, "still inside the module at shutdown; terminating", .{});
            e.inst.terminate();
        }
        for (self.entries.items) |*e| {
            if (e.thread) |th| {
                th.join();
                e.thread = null;
            }
        }
        self.started = false;
        self.br.stop();
    }

    fn anyInModule(self: *Host) bool {
        for (self.entries.items) |*e| {
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
        const e = &self.entries.items[index];
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
        const e = &self.entries.items[index];
        if (!e.isLive()) return;
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
        const e = &self.entries.items[index];
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
        const e = &self.entries.items[index];
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
        for (self.entries.items) |*e| {
            if (!e.isLive()) continue;
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

test "a manifest parses id, name, abi and the granted capabilities" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.ais","name":"AIS targets","abi":1,
        \\ "capabilities":["ais.read","overlay.draw","alerts.raise"]}
    );
    defer m.deinit(a);
    try t.expectEqualStrings("org.beetlebug.ais", m.id);
    try t.expectEqualStrings("AIS targets", m.name);
    try t.expectEqual(@as(u32, 1), m.abi);
    try t.expect(m.caps.contains(.ais_read));
    try t.expect(m.caps.contains(.overlay_draw));
    try t.expect(m.caps.contains(.alerts_raise));
    try t.expect(!m.caps.contains(.vessel_publish));
    try t.expect(!m.caps.contains(.net_tcp_client));
}

test "a manifest with no capabilities grants nothing, and name defaults to id" {
    const a = t.allocator;
    var m = try parseManifest(a, "{\"id\":\"org.beetlebug.quiet\",\"abi\":1}");
    defer m.deinit(a);
    try t.expectEqualStrings("org.beetlebug.quiet", m.name);
    try t.expectEqual(@as(usize, 0), m.caps.count());
}

test "a manifest is refused rather than half-read" {
    const a = t.allocator;
    try t.expectError(Error.BadManifest, parseManifest(a, "not json"));
    try t.expectError(Error.BadManifest, parseManifest(a, "[]"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"abi\":1}"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\"}"));
    // An unknown capability is a typo in a grant, so the plugin does not load.
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"net.mqtt\"]}"));
    try t.expectError(Error.BadManifest, parseManifest(a, "{\"id\":\"x\",\"abi\":1,\"capabilities\":\"vessel.read\"}"));
}

test "a net.http or net.ws grant carries the hosts it covers, and nothing else" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.grib","abi":1,"capabilities":[
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
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"net.http\"]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"net.ws\"]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"net.http\":[]}]}",
        // A capability that reaches no named server takes no list.
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"storage\":[\"a.example\"]}]}",
        // A URL, a wildcard and a path are not hostnames.
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"net.http\":[\"https://a.example\"]}]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"net.http\":[\"*.example\"]}]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"net.http\":[\"a.example/x\"]}]}",
        // One entry, one capability; and one list per capability.
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"net.http\":[\"a.example\"],\"net.ws\":[\"b.example\"]}]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"net.http\":[\"a.example\"]},{\"net.http\":[\"b.example\"]}]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[{\"net.http\":\"a.example\"}]}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));
}

test "a manifest claims file types, lowercase and dotted, and only with files" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.grib","abi":1,"capabilities":["files"],
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
        "{\"id\":\"x\",\"abi\":1,\"file_types\":[\".grib2\"]}",
        // Written any way but the way the routing compares it.
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[\".GRIB2\"]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[\"grib2\"]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[\".tar.gz\"]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[\".\"]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[\".grib 2\"]}",
        // Claiming nothing, written like a claim.
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[]}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":\".grib2\"}",
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[1]}",
        // The same type twice is a typo, not two claims.
        "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[\".grb\",\".grb\"]}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));

    // Nine types is past what a grant sentence can say.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    try many.appendSlice(a, "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"],\"file_types\":[");
    for (0..max_file_types + 1) |i| {
        if (i > 0) try many.append(a, ',');
        try many.print(a, "\".t{d}\"", .{i});
    }
    try many.appendSlice(a, "]}");
    try t.expectError(Error.BadManifest, parseManifest(a, many.items));

    // A manifest that claims nothing keeps an empty list, not a null one.
    var quiet = try parseManifest(a, "{\"id\":\"x\",\"abi\":1,\"capabilities\":[\"files\"]}");
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
    \\{"id":"org.beetlebug.ais","name":"AIS targets","abi":1,
    \\ "capabilities":["ais.read"],
    \\ "settings":[
    \\  {"key":"cpa_limit","label":"CPA limit","kind":"number","unit":"m","min":93,"max":9260,"default":926},
    \\  {"key":"cpa_alarm","label":"Collision alarm","kind":"toggle","default":true}]}
;

test "the start payload carries the ABI, and NMEA config only for nmea0183" {
    var vessels = try store.Store.init(t.allocator);
    defer vessels.deinit();
    var ais = aisstore.AisStore.init(t.allocator);
    defer ais.deinit();
    var br = broker.Broker.init(t.allocator, &vessels, &ais, .{});
    defer br.deinit();
    var h = Host.init(t.allocator, &br, .{ .nmea_host = "10.0.0.4", .nmea_port = 2000 });
    defer h.deinit();

    var nm = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.nmea0183\",\"abi\":1}");
    defer nm.deinit(t.allocator);
    const nmea = try h.startJson(&nm, &.{}, &.{});
    defer t.allocator.free(nmea);
    try t.expectEqualStrings("{\"abi\":1,\"config\":{\"host\":\"10.0.0.4\",\"port\":2000}}", nmea);

    var om = try parseManifest(t.allocator, "{\"id\":\"org.beetlebug.ownship\",\"abi\":1}");
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
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\"}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"slider\",\"default\":1}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"number\",\"min\":5,\"max\":5,\"default\":5}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"number\",\"min\":0,\"max\":5}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"toggle\",\"default\":1}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"toggle\",\"default\":true}," ++
            "{\"key\":\"a\",\"kind\":\"toggle\",\"default\":false}]}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":{}}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));

    // A default outside the range it declares is clamped, not refused.
    var clamped = try parseManifest(a,
        \\{"id":"x","abi":1,"settings":[{"key":"a","kind":"number","min":1,"max":10,"default":99}]}
    );
    defer clamped.deinit(a);
    try t.expectEqual(@as(f64, 10), clamped.settings[0].default_value);

    // v1 fields have no group and no tab of their own.
    try t.expectEqualStrings("", m.settings[0].desc);
    try t.expectEqualStrings("", m.settings[0].group);
    try t.expectEqual(Tab.advanced, m.settings[0].tab);
}

const v2_manifest =
    \\{"id":"org.beetlebug.ais","name":"AIS targets","abi":1,
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
        \\{"id":"x","abi":1,"settings":{"groups":[{"label":"G","tab":"weather",
        \\ "fields":[{"key":"a","kind":"toggle","default":true}]}]}}
    );
    defer unknown.deinit(a);
    try t.expectEqual(Tab.advanced, unknown.settings[0].tab);

    // A v2 block with no groups array, a group that is not an object, and a
    // group with no fields.
    const bad = [_][]const u8{
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"fields\":[]}}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[\"G\"]}}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"label\":\"G\"}]}}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));
}

const list_manifest =
    \\{"id":"org.beetlebug.nmea0183","name":"NMEA 0183","abi":1,
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
        "{\"id\":\"x\",\"abi\":1,\"settings\":[{\"key\":\"a\",\"kind\":\"text\"}]}",
        // A list with no key, and one with no columns.
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"list\":{\"item_fields\":[]}}]}}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"item_fields\":[]}}]}}",
        // A column called id would fight the one the host writes.
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"item_fields\":" ++
            "[{\"key\":\"id\",\"kind\":\"text\"}]}}]}}",
        // A switch naming a column the list does not have, and one naming a
        // column that is not a toggle: either leaves the shell with no switch.
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"switch_key\":\"nope\"," ++
            "\"item_fields\":[{\"key\":\"on\",\"kind\":\"toggle\",\"default\":true}]}}]}}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"switch_key\":\"h\"," ++
            "\"item_fields\":[{\"key\":\"h\",\"kind\":\"text\"}]}}]}}",
        // A list key that a field already uses, and two lists with one key.
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"fields\":[{\"key\":\"c\",\"kind\":\"toggle\",\"default\":true}]}," ++
            "{\"list\":{\"key\":\"c\",\"item_fields\":[{\"key\":\"h\",\"kind\":\"text\"}]}}]}}",
        "{\"id\":\"x\",\"abi\":1,\"settings\":{\"groups\":[{\"list\":{\"key\":\"c\",\"item_fields\":[{\"key\":\"h\",\"kind\":\"text\"}]}}," ++
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
