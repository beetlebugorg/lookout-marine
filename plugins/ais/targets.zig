//! The AIS targets table: one row per target the chart is drawing.
//!
//! The declaration is the whole contract. The shell builds the dialog from it,
//! opens it from the menu it names, sorts any column, and formats every value
//! for the mariner. This file sends SI and nothing else: metres, metres per
//! second, degrees true, seconds.
//!
//! THE ORDERING POLICY IS THIS PLUGIN'S. A target inside the danger gate rides
//! in band 0 and everything else in band 1, and the mariner's column sort
//! applies within a band and never across one. Sort by name and the alarmed
//! vessel is still the first line on the screen, which is the only place it
//! belongs.
//!
//! Rows are built only while the dialog is open (`Targets.isOpen`), so a boat
//! whose mariner never opens it pays nothing for it.

const std = @import("std");
const lk = @import("lk2");
const cpa = @import("cpa.zig");
const aton = @import("aton.zig");

/// The MMSI, as text: it is an identifier, not a quantity, and nobody wants it
/// with a thousands separator or sorted as a number.
const max_mmsi_text = 10;

pub const Targets = lk.table(.{
    .key = "targets",
    .title = "AIS Targets",
    .menu = "Vessels",
    .columns = &.{
        .{ .key = "name", .label = "Vessel", .type = .text },
        .{ .key = "mmsi", .label = "MMSI", .type = .text },
        .{ .key = "range", .label = "Range", .type = .distance },
        .{ .key = "brg", .label = "Bearing", .type = .bearing },
        .{ .key = "sog", .label = "SOG", .type = .speed },
        .{ .key = "cpa", .label = "CPA", .type = .distance },
        .{ .key = "tcpa", .label = "TCPA", .type = .duration },
        .{ .key = "state", .label = "", .type = .flag },
    },
    // The mariner opens this dialog to find out what is closing on the boat.
    .sort = .{ .key = "cpa", .ascending = true },
    .at = .{ .lat = "lat", .lon = "lon" },
});

/// One vessel. `sol` is null when own ship's fix would not allow a CPA, and
/// then both approach columns are dashes rather than zeroes: never solved and
/// solved as zero are different readings.
pub fn vessel(
    t: *const lk.Target,
    at: lk.Point,
    own: ?cpa.State,
    sol: ?cpa.Solution,
    in_gate: bool,
) void {
    var id_buf: [max_mmsi_text]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{t.mmsi}) catch return;

    // Only a closing target has a time to closest approach worth reading; a
    // solution that has already passed is history, not a warning.
    var cpa_m: ?f64 = null;
    var tcpa_s: ?f64 = null;
    if (sol) |s| {
        if (s.tcpa_s) |tc| {
            if (tc >= 0) {
                cpa_m = s.cpa_m;
                tcpa_s = tc;
            }
        }
    }

    Targets.upsert(.{
        .id = id,
        // The one ruling the shell may not overturn: an alarmed target holds
        // the top of the table whatever column the mariner sorted by.
        .band = @as(i32, if (in_gate) 0 else 1),
        .name = if (t.name().len > 0) t.name() else null,
        .mmsi = id,
        .range = rangeTo(own, at),
        .brg = bearingTo(own, at),
        .sog = t.sog_mps,
        .cpa = cpa_m,
        .tcpa = tcpa_s,
        .state = @as(?[]const u8, if (in_gate) "alarm" else null),
        .lat = at.lat,
        .lon = at.lon,
    });
}

/// One aid to navigation. It is in the set the chart draws, so it is in the
/// table; it is not going anywhere, so its speed and its approach are dashes.
pub fn aid(t: *const lk.Target, at: lk.Point, own: ?cpa.State) void {
    var id_buf: [max_mmsi_text]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{t.mmsi}) catch return;

    Targets.upsert(.{
        .id = id,
        .band = @as(i32, 1),
        .name = @as(?[]const u8, aton.navaidName(t.aton_type)),
        .mmsi = id,
        .range = rangeTo(own, at),
        .brg = bearingTo(own, at),
        // An aid that says it has drifted is worth a coloured row: it is in
        // the wrong place, and the mariner is steering by it.
        .state = @as(?[]const u8, if (t.off_position orelse false) "warning" else null),
        .lat = at.lat,
        .lon = at.lon,
    });
}

fn rangeTo(own: ?cpa.State, at: lk.Point) ?f64 {
    const o = own orelse return null;
    return (lk.Point{ .lat = o.lat, .lon = o.lon }).distanceTo(at);
}

fn bearingTo(own: ?cpa.State, at: lk.Point) ?f64 {
    const o = own orelse return null;
    return (lk.Point{ .lat = o.lat, .lon = o.lon }).bearingTo(at);
}
