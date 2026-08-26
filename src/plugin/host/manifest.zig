//! The manifest a plugin ships beside its module, and the parser that reads it:
//! the capabilities a grant is made of, the settings schema a shell renders,
//! the file types the plugin claims and the tables it declares.
//!
//! A manifest is refused whole rather than half-read. An unknown capability, a
//! range that is not one, a repeated key: each returns `Error.BadManifest`. A
//! plugin that silently loses a permission or a control at sea is worse than
//! one that does not load.

const std = @import("std");

const host = @import("../host.zig");
const broker = @import("../broker.zig");
const testing = @import("testing.zig");

const Error = host.Error;
const max_version_bytes = host.max_version_bytes;

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
pub const max_text_bytes = 512;

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
    /// What a shell browses the boat's network for on this list's behalf.
    discover: []Discover = &.{},
};

/// One DNS-SD service a shell offers as a row ready to add. The host browses
/// nothing itself: a mariner's network is reached through the platform's own
/// Bonjour API, which is the shell's to call.
pub const Discover = struct {
    /// The service type, for example "_signalk-ws._tcp".
    service: []u8,
    /// The columns a discovered row takes beyond its name, address and port,
    /// as a JSON object. Empty when the address is all a row needs. Every key
    /// names a column of this list, and every value is that column's kind.
    set: []u8 = &.{},
};

/// Most services one list may browse for. A list that wants five service types
/// is a list that has not decided what it connects to.
pub const max_discover = 4;

/// Most rows one list may hold, and the longest row id kept. Eight NMEA
/// gateways is already more than any boat this prototype targets.
pub const max_list_rows = 8;
pub const max_row_id = 32;

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
///
/// It declares its TABLES the same way: `"tables":[{"key":"targets",…}]`. Only
/// the keys are kept here — the columns are the runtime declaration's business
/// — and a key the manifest does not carry is a table the host refuses.
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
    /// The addresses `net.tcp-client` named, same rule. `local` stands for the
    /// boat's own network, which is the whole grant a gateway plugin needs.
    tcp_addrs: [][]u8 = &.{},
    /// The ports `net.udp` named, same rule.
    udp_ports: []u16 = &.{},
    /// The topics `bus.publish` and `bus.read` named, same rule. An OPEN
    /// vocabulary: the host checks the shape of a topic name and never its
    /// meaning, so a manifest may name a topic nothing else knows yet.
    pub_topics: [][]u8 = &.{},
    sub_topics: [][]u8 = &.{},
    /// The file extensions this plugin claims, each lowercase and with the
    /// leading dot. Empty unless the manifest declares some, and never
    /// non-empty without the `files` capability.
    file_types: [][]u8 = &.{},
    /// The keys of the tables this plugin declared, in manifest order. Empty
    /// when it declared none, which is a plugin that may declare none at run
    /// time either.
    tables: [][]u8 = &.{},
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
        freeStrings(alloc, self.tcp_addrs);
        if (self.udp_ports.len > 0) alloc.free(self.udp_ports);
        freeStrings(alloc, self.pub_topics);
        freeStrings(alloc, self.sub_topics);
        freeStrings(alloc, self.file_types);
        freeStrings(alloc, self.tables);
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

    /// True when the manifest declared a table under this key. The runtime
    /// declaration is checked against it, so a plugin can only put on screen
    /// what the mariner saw when the plugin was installed.
    pub fn declaresTable(self: *const Manifest, key: []const u8) bool {
        for (self.tables) |declared| {
            if (std.mem.eql(u8, declared, key)) return true;
        }
        return false;
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

pub fn jsonNumber(v: ?std.json.Value) ?f64 {
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

    // A capability is a NAME, or a one-key object whose value is the list the
    // grant covers: `{"net.http":["nomads.ncep.noaa.gov"]}`, or
    // `{"net.tcp-client":["local"]}`, or `{"net.udp":[10110]}`. The object
    // form exists because "may reach the internet" is not a permission a
    // mariner can weigh, and "may reach the boat's own network" is.
    var caps = broker.Caps.initEmpty();
    var http_hosts: [][]u8 = &.{};
    var ws_hosts: [][]u8 = &.{};
    var tcp_addrs: [][]u8 = &.{};
    var udp_ports: []u16 = &.{};
    var pub_topics: [][]u8 = &.{};
    var sub_topics: [][]u8 = &.{};
    var file_types: [][]u8 = &.{};
    var table_keys: [][]u8 = &.{};
    errdefer freeStrings(alloc, http_hosts);
    errdefer freeStrings(alloc, ws_hosts);
    errdefer freeStrings(alloc, tcp_addrs);
    errdefer if (udp_ports.len > 0) alloc.free(udp_ports);
    errdefer freeStrings(alloc, pub_topics);
    errdefer freeStrings(alloc, sub_topics);
    errdefer freeStrings(alloc, file_types);
    errdefer freeStrings(alloc, table_keys);
    if (o.get("capabilities")) |c| {
        if (c != .array) return Error.BadManifest;
        for (c.array.items) |item| switch (item) {
            .string => |text| {
                const cap = broker.Cap.fromName(text) orelse return Error.BadManifest;
                // A grant that carries its reach may not be written bare: the
                // bare name is "may reach anything", which no manifest asks.
                if (cap.carries() != .nothing) return Error.BadManifest;
                caps.insert(cap);
            },
            .object => |entry| {
                if (entry.count() != 1) return Error.BadManifest;
                var it = entry.iterator();
                const kv = it.next().?;
                const cap = broker.Cap.fromName(kv.key_ptr.*) orelse return Error.BadManifest;
                switch (cap.carries()) {
                    .nothing => return Error.BadManifest,
                    .ports => {
                        if (udp_ports.len > 0) return Error.BadManifest;
                        udp_ports = try parsePorts(alloc, kv.value_ptr.*);
                    },
                    .addresses => {
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
                            .net_tcp_client => {
                                if (tcp_addrs.len > 0) return Error.BadManifest;
                                tcp_addrs = hosts;
                            },
                            else => unreachable,
                        }
                    },
                    .topics => {
                        const topics = try parseTopics(alloc, kv.value_ptr.*);
                        errdefer freeStrings(alloc, topics);
                        switch (cap) {
                            .bus_publish => {
                                if (pub_topics.len > 0) return Error.BadManifest;
                                pub_topics = topics;
                            },
                            .bus_read => {
                                if (sub_topics.len > 0) return Error.BadManifest;
                                sub_topics = topics;
                            },
                            else => unreachable,
                        }
                    },
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

    // The tables the plugin declared. The columns are not kept: this list is
    // what `declareTable` measures a runtime declaration against.
    if (o.get("tables")) |v| table_keys = try parseTableKeys(alloc, v);

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
        .tcp_addrs = tcp_addrs,
        .udp_ports = udp_ports,
        .pub_topics = pub_topics,
        .sub_topics = sub_topics,
        .file_types = file_types,
        .tables = table_keys,
        .settings = fields,
        .lists = lists,
    };
}

/// The keys of a `"tables":[{"key":"targets",…}]` block, in declaration order.
///
/// Only the keys. Everything else about a table — its columns, its title, the
/// menu it hangs from — is the runtime declaration's, and the SDK generates
/// both from one comptime source so the two cannot drift. What the host needs
/// from the manifest is the answer to one question: did the mariner consent to
/// this table when they installed the plugin?
///
/// An empty list refuses the manifest, like `file_types`: it is the same claim
/// as not asking, written in a way that looks like asking. So does a duplicate
/// key, which would make one of the two declarations unreachable.
fn parseTableKeys(alloc: std.mem.Allocator, v: std.json.Value) ![][]u8 {
    if (v != .array) return Error.BadManifest;
    const items = v.array.items;
    if (items.len == 0 or items.len > broker.max_tables) return Error.BadManifest;
    const out = try alloc.alloc([]u8, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |k| alloc.free(k);
        alloc.free(out);
    }
    for (items) |item| {
        if (item != .object) return Error.BadManifest;
        const key = switch (item.object.get("key") orelse return Error.BadManifest) {
            .string => |s| s,
            else => return Error.BadManifest,
        };
        if (key.len == 0 or key.len > broker.max_table_key) return Error.BadManifest;
        for (out[0..built]) |seen| {
            if (std.mem.eql(u8, seen, key)) return Error.BadManifest;
        }
        out[built] = try alloc.dupe(u8, key);
        built += 1;
    }
    return out;
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
pub const chart_extensions = [_][]const u8{ ".pmtiles", ".mbtiles" };

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
/// plugin nobody can read the grant sentence for. The same cap serves the
/// ports a `net.udp` grant lists, for the same reason.
pub const max_hosts = 8;

/// The ports a `{"net.udp":[10110]}` entry names. Numbers, not strings, and
/// each a real port: an empty list refuses the manifest exactly as an empty
/// host list does, and so does a duplicate, which is a grant written twice.
fn parsePorts(alloc: std.mem.Allocator, v: std.json.Value) ![]u16 {
    if (v != .array) return Error.BadManifest;
    const items = v.array.items;
    if (items.len == 0 or items.len > max_hosts) return Error.BadManifest;
    const out = try alloc.alloc(u16, items.len);
    errdefer alloc.free(out);
    for (items, 0..) |item, i| {
        const n = switch (item) {
            .integer => |x| x,
            else => return Error.BadManifest,
        };
        if (n < 1 or n > 65535) return Error.BadManifest;
        out[i] = @intCast(n);
        for (out[0..i]) |seen| {
            if (seen == out[i]) return Error.BadManifest;
        }
    }
    return out;
}

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

/// Longest bus topic name, and how many one grant may carry.
pub const max_topic_len = 32;
pub const max_topics = 8;

/// The topics a `{"bus.publish":[…]}` or `{"bus.read":[…]}` entry names. The
/// vocabulary is OPEN — any name of the right shape is accepted, so a new
/// topic never needs a host change — but the shape is fixed: lowercase
/// letters, digits, `.`, `_` and `-`, compared exactly. An empty list refuses
/// the manifest for the same reason an empty host list does.
fn parseTopics(alloc: std.mem.Allocator, v: std.json.Value) ![][]u8 {
    if (v != .array) return Error.BadManifest;
    const items = v.array.items;
    if (items.len == 0 or items.len > max_topics) return Error.BadManifest;
    const out = try alloc.alloc([]u8, items.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |s| alloc.free(s);
        alloc.free(out);
    }
    for (items) |item| {
        const text = switch (item) {
            .string => |s| s,
            else => return Error.BadManifest,
        };
        if (text.len == 0 or text.len > max_topic_len) return Error.BadManifest;
        for (text) |c| switch (c) {
            'a'...'z', '0'...'9', '.', '_', '-' => {},
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

/// The owned string lists a manifest holds: hosts, topics, and file types.
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
    l.discover = try parseDiscover(alloc, o.get("discover"), items);
    return l;
}

/// The services this list is browsed for. Absent is the ordinary case: a list
/// of waypoints has nothing to find on a network.
fn parseDiscover(
    alloc: std.mem.Allocator,
    v: ?std.json.Value,
    items: []const Field,
) ![]Discover {
    const raw = switch (v orelse return &.{}) {
        .array => |a| a.items,
        else => return Error.BadManifest,
    };
    if (raw.len == 0 or raw.len > max_discover) return Error.BadManifest;

    const out = try alloc.alloc(Discover, raw.len);
    var built: usize = 0;
    errdefer freeDiscover(alloc, out, built);
    for (raw) |entry| {
        if (entry != .object) return Error.BadManifest;
        const eo = entry.object;
        const service = switch (eo.get("service") orelse return Error.BadManifest) {
            .string => |x| x,
            else => return Error.BadManifest,
        };
        if (!isServiceType(service)) return Error.BadManifest;
        var d = Discover{ .service = try alloc.dupe(u8, service) };
        errdefer alloc.free(d.service);
        d.set = try discoverSet(alloc, eo.get("set"), items);
        out[built] = d;
        built += 1;
    }
    return out;
}

/// A DNS-SD service type: `_signalk-ws._tcp`. Checked because the shell hands
/// it to the platform's browser as it stands.
fn isServiceType(s: []const u8) bool {
    if (s.len == 0 or s.len > 64 or s[0] != '_') return false;
    if (!std.mem.endsWith(u8, s, "._tcp") and !std.mem.endsWith(u8, s, "._udp")) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

/// The columns a discovered row takes beyond its address, checked against the
/// list and written back as the JSON the shell applies. A key naming no column
/// of this list, or a value that is not that column's kind, refuses the
/// manifest: the alternative is a row the mariner adds that quietly never
/// connects.
fn discoverSet(alloc: std.mem.Allocator, v: ?std.json.Value, items: []const Field) ![]u8 {
    const writeJsonString = @import("settings_json.zig").writeJsonString;
    const o = switch (v orelse return &.{}) {
        .object => |x| x,
        else => return Error.BadManifest,
    };
    if (o.count() == 0) return Error.BadManifest;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '{');
    var it = o.iterator();
    while (it.next()) |e| {
        const at = fieldIndex(items, e.key_ptr.*) orelse return Error.BadManifest;
        const f = items[at];
        if (out.items.len > 1) try out.append(alloc, ',');
        try writeJsonString(&out, alloc, f.key);
        try out.append(alloc, ':');
        switch (f.kind) {
            .toggle => switch (e.value_ptr.*) {
                .bool => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
                else => return Error.BadManifest,
            },
            .number => {
                const n = jsonNumber(e.value_ptr.*) orelse return Error.BadManifest;
                if (n < f.min or n > f.max) return Error.BadManifest;
                try out.print(alloc, "{d}", .{n});
            },
            .text => switch (e.value_ptr.*) {
                .string => |x| {
                    if (x.len > max_text_bytes) return Error.BadManifest;
                    try writeJsonString(&out, alloc, x);
                },
                else => return Error.BadManifest,
            },
        }
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
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

fn freeDiscover(alloc: std.mem.Allocator, ds: []Discover, built: usize) void {
    for (ds[0..built]) |d| {
        alloc.free(d.service);
        alloc.free(d.set);
    }
    if (ds.len > 0) alloc.free(ds);
}

fn freeLists(alloc: std.mem.Allocator, lists: []List, built: usize) void {
    for (lists[0..built]) |l| {
        alloc.free(l.key);
        alloc.free(l.group);
        alloc.free(l.footer);
        alloc.free(l.empty);
        alloc.free(l.add_label);
        alloc.free(l.switch_key);
        freeDiscover(alloc, l.discover, l.discover.len);
        freeFields(alloc, l.items, l.items.len);
    }
    if (lists.len > 0) alloc.free(lists);
}

// ---- tests -------------------------------------------------------------------

const t = std.testing;
const ais_settings_manifest = testing.ais_settings_manifest;
const v2_manifest = testing.v2_manifest;

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

test "every outward grant carries its reach, and a bare one is refused" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.grib","api":1,"capabilities":[
        \\  {"net.http":["nomads.ncep.noaa.gov","opendap.nasa.gov"]},
        \\  {"net.ws":["demo.signalk.org"]},
        \\  {"net.tcp-client":["local","gateway.example.com"]},
        \\  {"net.udp":[10110,4001]},
        \\  "storage","files"]}
    );
    defer m.deinit(a);
    try t.expect(m.caps.contains(.net_http));
    try t.expect(m.caps.contains(.net_ws));
    try t.expect(m.caps.contains(.net_tcp_client));
    try t.expect(m.caps.contains(.net_udp));
    try t.expect(m.caps.contains(.storage));
    try t.expect(m.caps.contains(.files));
    try t.expectEqual(@as(usize, 2), m.http_hosts.len);
    try t.expectEqualStrings("nomads.ncep.noaa.gov", m.http_hosts[0]);
    try t.expectEqualStrings("opendap.nasa.gov", m.http_hosts[1]);
    try t.expectEqual(@as(usize, 1), m.ws_hosts.len);
    try t.expectEqualStrings("demo.signalk.org", m.ws_hosts[0]);
    try t.expectEqual(@as(usize, 2), m.tcp_addrs.len);
    try t.expectEqualStrings("local", m.tcp_addrs[0]);
    try t.expectEqualStrings("gateway.example.com", m.tcp_addrs[1]);
    try t.expectEqualSlices(u16, &.{ 10110, 4001 }, m.udp_ports);

    const bad = [_][]const u8{
        // A bare grant is "may reach anything", which no manifest may ask
        // for, and an empty list is the same grant written longer.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"net.http\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"net.ws\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"net.tcp-client\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"net.udp\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.tcp-client\":[]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.udp\":[]}]}",
        // A capability that reaches nothing outward takes no list.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"storage\":[\"a.example\"]}]}",
        // A URL, a wildcard and a path are not hostnames.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"https://a.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"*.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"a.example/x\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.tcp-client\":[\"tcp://a.example\"]}]}",
        // A port list holds numbers, each of them a real port, each once.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.udp\":[\"10110\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.udp\":[0]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.udp\":[65536]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.udp\":[10110,10110]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.udp\":10110}]}",
        // One entry, one capability; and one list per capability.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"a.example\"],\"net.ws\":[\"b.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":[\"a.example\"]},{\"net.http\":[\"b.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.tcp-client\":[\"a.example\"]},{\"net.tcp-client\":[\"b.example\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.udp\":[10110]},{\"net.udp\":[4001]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"net.http\":\"a.example\"}]}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));
}

test "a bus grant names its topics, any topic of the right shape" {
    const a = t.allocator;
    // The vocabulary is open: `to-be-invented` is nothing any plugin speaks
    // yet, and it parses like any other well-shaped name.
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.recorder","api":1,"capabilities":[
        \\  {"bus.publish":["nmea0183"]},
        \\  {"bus.read":["nmea0183","mob","to-be-invented"]}]}
    );
    defer m.deinit(a);
    try t.expect(m.caps.contains(.bus_publish));
    try t.expect(m.caps.contains(.bus_read));
    try t.expectEqual(@as(usize, 1), m.pub_topics.len);
    try t.expectEqualStrings("nmea0183", m.pub_topics[0]);
    try t.expectEqual(@as(usize, 3), m.sub_topics.len);
    try t.expectEqualStrings("mob", m.sub_topics[1]);

    const bad = [_][]const u8{
        // Bare and empty are the same over-broad grant the net caps refuse.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"bus.publish\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[\"bus.read\"]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"bus.read\":[]}]}",
        // The shape is fixed even though the vocabulary is open: lowercase,
        // 32 bytes, no spaces, no duplicates, strings only.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"bus.read\":[\"NMEA\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"bus.read\":[\"a topic\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"bus.read\":[\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"bus.read\":[\"a\",\"a\"]}]}",
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"bus.read\":[7]}]}",
        // One list per capability, like the net grants.
        "{\"id\":\"x\",\"api\":1,\"capabilities\":[{\"bus.read\":[\"a\"]},{\"bus.read\":[\"b\"]}]}",
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

test "a manifest declares its table keys, and the runtime declaration is held to them" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"org.beetlebug.ais","api":1,"capabilities":["ais.read"],
        \\ "tables":[{"key":"targets","title":"AIS Targets","menu":"Vessels",
        \\   "columns":[{"key":"mmsi","label":"MMSI","type":"text"}]}]}
    );
    defer m.deinit(a);
    try t.expectEqual(@as(usize, 1), m.tables.len);
    try t.expectEqualStrings("targets", m.tables[0]);
    try t.expect(m.declaresTable("targets"));
    try t.expect(!m.declaresTable("smuggled"));

    const bad = [_][]const u8{
        // Declaring nothing, written like a declaration.
        "{\"id\":\"x\",\"api\":1,\"tables\":[]}",
        "{\"id\":\"x\",\"api\":1,\"tables\":{\"key\":\"targets\"}}",
        // An entry the check could never match against a runtime key.
        "{\"id\":\"x\",\"api\":1,\"tables\":[\"targets\"]}",
        "{\"id\":\"x\",\"api\":1,\"tables\":[{\"title\":\"No key\"}]}",
        "{\"id\":\"x\",\"api\":1,\"tables\":[{\"key\":\"\"}]}",
        "{\"id\":\"x\",\"api\":1,\"tables\":[{\"key\":7}]}",
        // The same key twice would leave one of the two unreachable.
        "{\"id\":\"x\",\"api\":1,\"tables\":[{\"key\":\"a\"},{\"key\":\"a\"}]}",
    };
    for (bad) |json| try t.expectError(Error.BadManifest, parseManifest(a, json));

    // One more than a plugin may have on screen.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    try many.appendSlice(a, "{\"id\":\"x\",\"api\":1,\"tables\":[");
    for (0..broker.max_tables + 1) |i| {
        if (i > 0) try many.append(a, ',');
        try many.print(a, "{{\"key\":\"t{d}\"}}", .{i});
    }
    try many.appendSlice(a, "]}");
    try t.expectError(Error.BadManifest, parseManifest(a, many.items));

    // A manifest that declares none keeps an empty list, and that plugin may
    // declare no table at run time either.
    var quiet = try parseManifest(a, "{\"id\":\"x\",\"api\":1}");
    defer quiet.deinit(a);
    try t.expectEqual(@as(usize, 0), quiet.tables.len);
    try t.expect(!quiet.declaresTable("targets"));
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

test "a list says what to browse the network for, and refuses a set it cannot fill" {
    const a = t.allocator;
    var m = try parseManifest(a,
        \\{"id":"x","api":1,"settings":{"groups":[{"label":"C","tab":"connections",
        \\ "list":{"key":"c","discover":[{"service":"_signalk-ws._tcp","set":{"ws":true}},
        \\                               {"service":"_nmea-0183._tcp"}],
        \\  "item_fields":[{"key":"host","kind":"text","default":""},
        \\                 {"key":"ws","kind":"toggle","default":false}]}}]}}
    );
    defer m.deinit(a);
    const d = m.lists[0].discover;
    try t.expectEqual(@as(usize, 2), d.len);
    try t.expectEqualStrings("_signalk-ws._tcp", d[0].service);
    // The set is written back as the shell applies it, over the column
    // defaults, when the mariner adds what the browse found.
    try t.expectEqualStrings("{\"ws\":true}", d[0].set);
    // A service that needs nothing beyond the address carries no set.
    try t.expectEqualStrings("", d[1].set);

    // A list that declares none browses for nothing, which is every list that
    // is not a connection.
    var quiet = try parseManifest(a,
        \\{"id":"x","api":1,"settings":{"groups":[{"label":"C","list":{"key":"c",
        \\ "item_fields":[{"key":"host","kind":"text","default":""}]}}]}}
    );
    defer quiet.deinit(a);
    try t.expectEqual(@as(usize, 0), quiet.lists[0].discover.len);

    const head =
        "{\"id\":\"x\",\"api\":1,\"settings\":{\"groups\":[{\"label\":\"C\",\"list\":{\"key\":\"c\",\"discover\":";
    const tail =
        ",\"item_fields\":[{\"key\":\"host\",\"kind\":\"text\",\"default\":\"\"}," ++
        "{\"key\":\"port\",\"kind\":\"number\",\"min\":1,\"max\":65535,\"default\":80}," ++
        "{\"key\":\"ws\",\"kind\":\"toggle\",\"default\":false}]}}]}}";
    const bad = [_][]const u8{
        // Not an array, and an array with nothing in it: both are the claim
        // that this list is browsable written by someone who meant nothing.
        "\"_signalk-ws._tcp\"",
        "[]",
        // A service type the platform's browser would refuse: no leading
        // underscore, no transport, a space in it.
        "[{\"service\":\"signalk-ws._tcp\"}]",
        "[{\"service\":\"_signalk-ws\"}]",
        "[{\"service\":\"_signal k._tcp\"}]",
        "[{}]",
        // A set that names no column of this list, or holds a value that is
        // not that column's kind, or a port outside the column's range: each
        // one adds a row that looks filled in and never connects.
        "[{\"service\":\"_x._tcp\",\"set\":{\"secure\":true}}]",
        "[{\"service\":\"_x._tcp\",\"set\":{\"ws\":\"yes\"}}]",
        "[{\"service\":\"_x._tcp\",\"set\":{\"port\":99999}}]",
        "[{\"service\":\"_x._tcp\",\"set\":{}}]",
        "[{\"service\":\"_x._tcp\",\"set\":[\"ws\"]}]",
    };
    for (bad) |mid| {
        const json = try std.mem.concat(a, u8, &.{ head, mid, tail });
        defer a.free(json);
        try t.expectError(Error.BadManifest, parseManifest(a, json));
    }

    // More service types than a list has any business browsing for.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    try many.appendSlice(a, "[");
    for (0..max_discover + 1) |i| {
        if (i > 0) try many.append(a, ',');
        try many.print(a, "{{\"service\":\"_s{d}._tcp\"}}", .{i});
    }
    try many.appendSlice(a, "]");
    const json = try std.mem.concat(a, u8, &.{ head, many.items, tail });
    defer a.free(json);
    try t.expectError(Error.BadManifest, parseManifest(a, json));
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
