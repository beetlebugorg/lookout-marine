//! The plugin half of the C ABI (see include/lookout-plugins.h): the registry,
//! install and consent, tables, alerts, the overlay and the files a plugin
//! claims.
//!
//! Every entry point here exists in a build with no plugin host and returns the
//! empty answer, so one shell binary serves both builds.

const std = @import("std");

const lk = @import("../root.zig");
const capi = @import("../capi.zig");
const pl = @import("plugins");

const lookout = capi.lookout;
const gpa = capi.gpa;
const locked = capi.locked;
const capi_io = capi.capi_io;
const plugins_enabled = capi.plugins_enabled;
const phost = capi.phost;

/// Load and start the wasm plugins in `dir` — every `<id>.manifest.json` with
/// an `<id>.wasm` beside it. 0 on success, -1 if the directory is unreadable
/// or this build has no plugin host. A plugin that fails to load is logged and
/// skipped; the others still run, so 0 does not mean every module started.
///
/// Setting LOOKOUT_PLUGINS before opening does the same thing without a call.
export fn lookout_plugins_load(h: ?*lookout, dir: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.loadPlugins(std.mem.span(dir)) catch return -1;
    return 0;
}

/// 1 while a plugin layer is running. A render-on-demand shell needs this: a
/// plugin posts geometry from its own thread with no gesture behind it, so a
/// loop that only wakes on input must keep polling `lookout_needs_redraw` at a
/// low rate while plugins are up, instead of sleeping until the mariner
/// touches something.
export fn lookout_plugins_active(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.pluginsActive()) 1 else 0;
}

/// Every loaded plugin with its settings schema and the values in force, as
/// JSON. A shell renders a settings pane from this and needs to know nothing
/// about what any plugin does. Borrowed until the next plugin query; NULL when
/// no plugin layer is up.
export fn lookout_plugins_json(h: ?*lookout, out_len: ?*usize) ?[*]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.pluginsJson() orelse return null;
    if (out_len) |p| p.* = s.len;
    return s.ptr;
}

/// One plugin's settings object. Borrowed until the next plugin query; NULL
/// when the id is not loaded.
export fn lookout_plugin_config_get(h: ?*lookout, id: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.pluginConfig(std.mem.span(id)) orelse return null;
    if (out_len) |p| p.* = s.len;
    return s.ptr;
}

/// Change one plugin's settings, applied at once. `json` is an object of the
/// keys the schema declares; anything else in it is ignored and a number
/// outside its range is clamped. 0 on success, -1 when the id is unknown, the
/// plugin has no settings, or the JSON is not an object.
export fn lookout_plugin_config_set(h: ?*lookout, id: [*:0]const u8, json: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.setPluginConfig(std.mem.span(id), std.mem.span(json)) catch return -1;
    return 0;
}

/// Load the INSTALLED plugin set — what lookout_plugin_install put under the
/// per-user plugin directory — creating the plugin layer if nothing has yet.
/// Idempotent: an id already loaded is skipped, so the shell calls it once
/// after open and again whenever it likes. 0 when the layer is up afterwards.
export fn lookout_plugins_load_installed(h: ?*lookout) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    return if (ensureInstalledPlugins(l)) 0 else -1;
}

/// Name the per-user plugin directory, for platforms whose environment cannot
/// (Android: the app's files dir has no path in the environment; every other
/// platform resolves a default and never needs this). Call before any other
/// plugin call — the layer reads it once at creation. 0 on success, -1 once
/// the layer is already up.
export fn lookout_plugins_install_root(h: ?*lookout, path: [*:0]const u8) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    l.setPluginInstallRoot(std.mem.span(path)) catch return -1;
    return 0;
}

/// Read a .lkplug without installing it: everything the consent sheet shows,
/// as JSON. `{"id":..,"name":..,"version":..,"sentences":[..]}`, plus
/// `"installed":{"version":..,"origin":..,"adds":[..],"drops":[..],
/// "downgrade":bool}` when the id is already loaded, so the sheet calls out
/// the grant delta. A refused package answers `{"error":"<sentence>"}`.
/// Borrowed until the next plugin query; NULL only when no layer can come up.
export fn lookout_plugin_inspect(h: ?*lookout, path: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    if (!ensureInstalledPlugins(l)) return null;
    const ps = l.plugins.?;
    ps.json.clearRetainingCapacity();
    ps.host.inspectPackage(std.mem.span(path), &ps.json) catch return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// Install a .lkplug: unpack, validate — the zip must hold exactly
/// manifest.json and the manifest's <id>.wasm — place it under the per-user
/// plugin directory and load it hot. Call after the mariner consented on the
/// sheet lookout_plugin_inspect fed.
///
/// NULL on success. Otherwise one borrowed sentence saying why, ready to
/// show: "The package holds notes.txt; a plugin package holds only
/// manifest.json and its module." Valid until the next install or inspect.
export fn lookout_plugin_install(h: ?*lookout, path: [*:0]const u8) ?[*:0]const u8 {
    if (comptime !plugins_enabled) return "This build has no plugin host.";
    const l = locked(h);
    defer l.apiUnlock();
    if (!ensureInstalledPlugins(l)) return "The plugin layer could not start.";
    const ps = l.plugins.?;
    ps.host.installPackage(std.mem.span(path)) catch |e| return ps.host.installErrorText(e).ptr;
    return null;
}

/// Remove an installed plugin: its instance, its overlay objects, its store
/// contributions, its saved storage and its directory. 0 on success; -1 for
/// an unknown id or a bundled/developer plugin, which install never wrote and
/// uninstall will not touch.
export fn lookout_plugin_uninstall(h: ?*lookout, id: [*:0]const u8) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    ps.host.uninstall(std.mem.span(id)) catch return -1;
    return 0;
}

/// Switch one of a plugin's granted capabilities on or off, live: the broker
/// checks per call, so a revoked capability answers -1 to the plugin and
/// counts denied exactly as if the manifest never asked for it. The change
/// persists beside the plugin's wasm and is read back at every load. 0 on
/// success; -1 for an unknown id, an unknown capability name, or a
/// capability the manifest never asked for (a grant can never exceed the
/// manifest).
export fn lookout_plugin_grant_set(h: ?*lookout, id: [*:0]const u8, cap: [*:0]const u8, on: c_int) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    ps.host.grantSet(std.mem.span(id), std.mem.span(cap), on != 0) catch return -1;
    return 0;
}

/// Every table the loaded plugins declare, as JSON. A shell builds the menu
/// item and the columns from this and knows nothing about what any plugin
/// does. Borrowed until the next plugin query; NULL when no layer is up.
export fn lookout_plugin_tables_json(h: ?*lookout, out_len: ?*usize) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    ps.json.clearRetainingCapacity();
    ps.br.tablesJson(&ps.json) catch return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// One table's rows, already in the order they are to be shown: the plugin's
/// bands first, then `sort_key` within each band, then arrival. `sort_key`
/// NULL or empty takes the declared default sort. Borrowed until the next
/// plugin query; NULL when the plugin or the table is unknown.
export fn lookout_plugin_table_rows(
    h: ?*lookout,
    id: [*:0]const u8,
    key: [*:0]const u8,
    sort_key: ?[*:0]const u8,
    ascending: c_int,
    out_len: ?*usize,
) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    ps.json.clearRetainingCapacity();
    const want: []const u8 = if (sort_key) |s| std.mem.span(s) else "";
    const found = ps.br.tableRowsJson(
        std.mem.span(id),
        std.mem.span(key),
        want,
        ascending != 0,
        &ps.json,
    ) catch return null;
    if (!found) return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// Tell the plugin its table is on screen, or is not. 0 on success, -1 when
/// the plugin or the table is unknown.
export fn lookout_plugin_table_open(h: ?*lookout, id: [*:0]const u8, key: [*:0]const u8, open: c_int) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    return if (ps.br.setTableOpen(std.mem.span(id), std.mem.span(key), open != 0)) 0 else -1;
}

/// Every alert the plugins have raised and the mariner has not seen off, most
/// urgent first, as JSON. The shell shows them and sounds the alarms. Borrowed
/// until the next plugin query; NULL when no layer is up.
export fn lookout_plugin_alerts_json(h: ?*lookout, out_len: ?*usize) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    ps.json.clearRetainingCapacity();
    ps.br.alertsJson(&ps.json) catch return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// Acknowledge one alert: the alarm stops sounding and the alert stays listed
/// until the condition clears. One alert, not one class of them. 0 on success,
/// -1 when no alert holds that id.
export fn lookout_plugin_alert_ack(h: ?*lookout, id: u64) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    return if (ps.br.ackAlert(id)) 0 else -1;
}

/// The plugin layer with the installed set loaded, created on first need.
/// True when the layer is up afterwards. The install root is created empty
/// rather than treated as an error: a first install has nothing yet.
fn ensureInstalledPlugins(l: *lk.Lookout) bool {
    if (comptime !plugins_enabled) return false;
    const root: []u8 = if (l.plugin_install_root) |r|
        gpa.dupe(u8, r) catch return l.plugins != null
    else
        phost.installRootAlloc(gpa) orelse return l.plugins != null;
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(capi_io, root) catch {};
    l.loadPlugins(root) catch return l.plugins != null;
    return l.plugins != null;
}

/// Offer a file the mariner opened to the plugins: 1 when one claimed the file
/// type and now holds it, 0 when none does, -1 when the file was claimed and
/// could not be given. Charts always answer 0. See lookout.h.
export fn lookout_open_file(h: ?*lookout, path: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const taken = l.openFileForPlugins(std.mem.span(path)) catch return -1;
    return if (taken) 1 else 0;
}

/// What the plugin overlay says about the symbol nearest a LOGICAL point, as
/// JSON: `{"title":"...","rows":[["key","value"],...]}`. NULL when no symbol
/// with a payload is within about 14 pt of it.
///
/// Borrowed: valid until the next `lookout_overlay_at`. `*out_len` (NULL to
/// ignore) receives the length. The core copies the payload out from under the
/// plugin's own thread, so the pointer stays good even if the plugin redraws
/// that target in the meantime.
export fn lookout_overlay_at(h: ?*lookout, x_pt: f32, y_pt: f32, out_len: ?*usize) ?[*]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.overlayAt(x_pt, y_pt) orelse return null;
    if (out_len) |p| p.* = s.len;
    return s.ptr;
}

/// One overlay object, as a hit test or an id lookup answers. `id` is
/// NUL-terminated and can go straight back to `lookout_overlay_info`; `info`
/// is the pick payload, NULL when the object carries none. `lon`/`lat` are
/// where the object draws NOW. Every pointer is borrowed until the next
/// overlay call.
pub const lookout_overlay_obj = extern struct {
    id: ?[*:0]const u8,
    id_len: usize,
    info: ?[*]const u8,
    info_len: usize,
    lon: f64,
    lat: f64,
};

fn fillObj(out: *lookout_overlay_obj, hit: lk.OverlayHit) void {
    out.* = .{
        .id = hit.id.ptr,
        .id_len = hit.id.len,
        .info = if (hit.info.len > 0) hit.info.ptr else null,
        .info_len = hit.info.len,
        .lon = hit.at[0],
        .lat = hit.at[1],
    };
}

/// The overlay symbol nearest a LOGICAL point, with its id and anchor: 1 when
/// one answers, 0 when none is within about 14 pt. A shell pins an info bubble
/// to that id and follows it with lookout_overlay_info.
export fn lookout_overlay_hit(h: ?*lookout, x_pt: f32, y_pt: f32, out: *lookout_overlay_obj) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const hit = l.overlayHit(x_pt, y_pt) orelse return 0;
    fillObj(out, hit);
    return 1;
}

/// What that object says now: 1 while it exists, 0 once it is gone (the
/// target aged out, or its plugin stopped). The payload and the anchor are
/// current, so a pinned bubble re-reads both every render tick.
export fn lookout_overlay_info(h: ?*lookout, id: [*:0]const u8, out: *lookout_overlay_obj) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const hit = l.overlayInfo(std.mem.span(id)) orelse return 0;
    fillObj(out, hit);
    return 1;
}

// ---- reading the plugins ------------------------------------------------------
// The shapes are src/plugins.zig's; see include/lookout-plugins.h for what a
// shell reads out of them. Every collection is one call that returns a borrowed
// array and its length.

pub const lookout_plugins = pl.Read;
pub const lookout_plugin = pl.Plugin;
pub const lookout_plugin_capability = pl.Capability;
pub const lookout_plugin_setting = pl.Setting;
pub const lookout_plugin_item = pl.Item;
pub const lookout_plugin_value = pl.Value;
pub const lookout_plugin_service = pl.Service;

fn count(out_n: ?*usize, n: usize) void {
    if (out_n) |p| p.* = n;
}

/// Read the plugins. See lookout-plugins.h.
export fn lookout_plugins_read(h: ?*lookout) ?*lookout_plugins {
    const l = locked(h);
    defer l.apiUnlock();
    return l.readPlugins();
}

/// Free a read and everything reached through it.
export fn lookout_plugins_free(p: ?*lookout_plugins) void {
    if (p) |x| x.free();
}

/// Every plugin loaded.
export fn lookout_plugins_all(p: ?*const lookout_plugins, out_n: ?*usize) ?[*]const *const lookout_plugin {
    const x = p orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.rows.len);
    return x.rows.ptr;
}

/// The plugin holding `id`, or null.
export fn lookout_plugins_find(p: ?*const lookout_plugins, id: ?[*:0]const u8) ?*const lookout_plugin {
    const x = p orelse return null;
    const want = std.mem.span(id orelse return null);
    for (x.rows) |row| {
        if (std.mem.eql(u8, std.mem.span(row.id), want)) return row;
    }
    return null;
}

/// Every capability this plugin's manifest asked for.
export fn lookout_plugin_capabilities(p: ?*const lookout_plugin, out_n: ?*usize) ?[*]const *const lookout_plugin_capability {
    const rec = pl.recOf(pl.PluginRec, p orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.capabilities_len);
    return rec.capabilities;
}

/// What the mariner consented to for this capability.
export fn lookout_plugin_capability_allows(c: ?*const lookout_plugin_capability, out_n: ?*usize) ?[*]const [*:0]const u8 {
    const rec = pl.recOf(pl.CapabilityRec, c orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.allows_len);
    return rec.allows;
}

/// Every setting this plugin declares, in declaration order.
export fn lookout_plugin_settings(p: ?*const lookout_plugin, out_n: ?*usize) ?[*]const *const lookout_plugin_setting {
    const rec = pl.recOf(pl.PluginRec, p orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.settings_len);
    return rec.settings;
}

/// The shape of one item of a list setting.
export fn lookout_plugin_setting_fields(s: ?*const lookout_plugin_setting, out_n: ?*usize) ?[*]const *const lookout_plugin_setting {
    const rec = pl.recOf(pl.SettingRec, s orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.fields_len);
    return rec.fields;
}

/// The items a list setting holds.
export fn lookout_plugin_setting_items(s: ?*const lookout_plugin_setting, out_n: ?*usize) ?[*]const *const lookout_plugin_item {
    const rec = pl.recOf(pl.SettingRec, s orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.items_len);
    return rec.items;
}

/// What to browse the boat's network for on a list setting's behalf.
export fn lookout_plugin_setting_services(s: ?*const lookout_plugin_setting, out_n: ?*usize) ?[*]const *const lookout_plugin_service {
    const rec = pl.recOf(pl.SettingRec, s orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.services_len);
    return rec.services;
}

/// One value per field of the item's list, in field order.
export fn lookout_plugin_item_values(it: ?*const lookout_plugin_item, out_n: ?*usize) ?[*]const *const lookout_plugin_value {
    const rec = pl.recOf(pl.ItemRec, it orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.values_len);
    return rec.values;
}

/// One item value by field key. 0 when the item holds no such field.
export fn lookout_plugin_item_number(it: ?*const lookout_plugin_item, key: ?[*:0]const u8) f64 {
    const v = pl.itemValue(it orelse return 0, std.mem.span(key orelse return 0)) orelse return 0;
    return v.number;
}

/// One item toggle by field key. 0 when the item holds no such field.
export fn lookout_plugin_item_flag(it: ?*const lookout_plugin_item, key: ?[*:0]const u8) c_int {
    const v = pl.itemValue(it orelse return 0, std.mem.span(key orelse return 0)) orelse return 0;
    return @intFromBool(v.number != 0);
}

/// One item string by field key. Empty when the item holds no such field.
export fn lookout_plugin_item_text(it: ?*const lookout_plugin_item, key: ?[*:0]const u8) [*:0]const u8 {
    const v = pl.itemValue(it orelse return "", std.mem.span(key orelse return "")) orelse return "";
    return v.text;
}

/// The values an item added from a find takes beyond its name, address and port.
export fn lookout_plugin_service_values(svc: ?*const lookout_plugin_service, out_n: ?*usize) ?[*]const *const lookout_plugin_value {
    const rec = pl.recOf(pl.ServiceRec, svc orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.values_len);
    return rec.values;
}

// ---- reading the alerts and the tables ----------------------------------------

pub const lookout_alerts = pl.Alerts;
pub const lookout_alert = pl.Alert;
pub const lookout_tables = pl.Tables;
pub const lookout_table = pl.Table;
pub const lookout_table_column = pl.Column;
pub const lookout_table_rows = pl.Rows;
pub const lookout_table_row = pl.Row;
pub const lookout_table_cell = pl.Cell;

/// Read the alerts. See lookout-plugins.h.
export fn lookout_alerts_read(h: ?*lookout) ?*lookout_alerts {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    const out = lookout_alerts.init(gpa) catch return null;
    ps.br.alertsRead(out) catch {
        out.free();
        return null;
    };
    return out;
}

export fn lookout_alerts_free(a: ?*lookout_alerts) void {
    if (a) |x| x.free();
}

/// Bumps on every change to the set. Re-read when it moves.
export fn lookout_alerts_seq(a: ?*const lookout_alerts) u64 {
    const x = a orelse return 0;
    return x.seq;
}

/// Every alert raised and not yet seen off, most urgent first.
export fn lookout_alerts_all(a: ?*const lookout_alerts, out_n: ?*usize) ?[*]const *const lookout_alert {
    const x = a orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.rows.len);
    return x.rows.ptr;
}

/// Read the tables the loaded plugins declare. See lookout-plugins.h.
export fn lookout_tables_read(h: ?*lookout) ?*lookout_tables {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    const out = lookout_tables.init(gpa) catch return null;
    ps.br.tablesRead(out) catch {
        out.free();
        return null;
    };
    return out;
}

export fn lookout_tables_free(t: ?*lookout_tables) void {
    if (t) |x| x.free();
}

/// Every table declared, in declaration order.
export fn lookout_tables_all(t: ?*const lookout_tables, out_n: ?*usize) ?[*]const *const lookout_table {
    const x = t orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.rows.len);
    return x.rows.ptr;
}

/// The columns one table declares, in declaration order.
export fn lookout_table_columns(t: ?*const lookout_table, out_n: ?*usize) ?[*]const *const lookout_table_column {
    const rec = pl.recOf(pl.TableRec, t orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.columns_len);
    return rec.columns;
}

/// Read one table's rows, already in order. NULL when the plugin or the table
/// is unknown. `sort_key` NULL or empty takes the declared default sort.
export fn lookout_table_rows_read(
    h: ?*lookout,
    id: ?[*:0]const u8,
    key: ?[*:0]const u8,
    sort_key: ?[*:0]const u8,
    ascending: c_int,
) ?*lookout_table_rows {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    const out = lookout_table_rows.init(gpa) catch return null;
    const want: []const u8 = if (sort_key) |x| std.mem.span(x) else "";
    const found = ps.br.tableRowsRead(
        std.mem.span(id orelse return null),
        std.mem.span(key orelse return null),
        want,
        ascending != 0,
        out,
    ) catch false;
    if (!found) {
        out.free();
        return null;
    }
    return out;
}

export fn lookout_table_rows_free(r: ?*lookout_table_rows) void {
    if (r) |x| x.free();
}

/// The table's batch sequence when these rows were read.
export fn lookout_table_rows_seq(r: ?*const lookout_table_rows) u64 {
    const x = r orelse return 0;
    return x.seq;
}

export fn lookout_table_rows_all(r: ?*const lookout_table_rows, out_n: ?*usize) ?[*]const *const lookout_table_row {
    const x = r orelse {
        count(out_n, 0);
        return null;
    };
    count(out_n, x.rows.len);
    return x.rows.ptr;
}

/// One cell per declared column, in declaration order.
export fn lookout_table_row_cells(row: ?*const lookout_table_row, out_n: ?*usize) ?[*]const *const lookout_table_cell {
    const rec = pl.recOf(pl.RowRec, row orelse {
        count(out_n, 0);
        return null;
    });
    count(out_n, rec.cells_len);
    return rec.cells;
}
