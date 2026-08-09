//! Aids to navigation: what to call one, and when one is worth a warning.
//!
//! Pure — `std` only — so `zig test aton.zig` runs it natively.
//!
//! The names are the navaid types ITU-R M.1371 assigns to the 5-bit field of a
//! type 21 report, in the wording the AIVDM/AIVDO decoding guide prints. They
//! are display strings: the pick payload shows one to the mariner.

const std = @import("std");

/// The 32 navaid types, indexed by the code the message carries. 1..15 are
/// fixed aids and 16..31 floating ones.
const names = [32][]const u8{
    "Aid to navigation", // 0: type not specified
    "Reference point",
    "RACON",
    "Fixed offshore structure",
    "Reserved",
    "Light",
    "Light with sectors",
    "Leading light front",
    "Leading light rear",
    "Beacon, cardinal N",
    "Beacon, cardinal E",
    "Beacon, cardinal S",
    "Beacon, cardinal W",
    "Beacon, port hand",
    "Beacon, starboard hand",
    "Beacon, preferred channel port hand",
    "Beacon, preferred channel starboard hand",
    "Beacon, isolated danger",
    "Beacon, safe water",
    "Beacon, special mark",
    "Cardinal mark N",
    "Cardinal mark E",
    "Cardinal mark S",
    "Cardinal mark W",
    "Port hand mark",
    "Starboard hand mark",
    "Preferred channel port hand",
    "Preferred channel starboard hand",
    "Isolated danger",
    "Safe water",
    "Special mark",
    "Light vessel, LANBY or rig",
};

/// What to call the aid. An unknown code, and the code that means "not
/// specified", both read as the generic name: a mariner is told what it is,
/// never a number they cannot look up.
pub fn navaidName(code: ?u8) []const u8 {
    const c = code orelse return names[0];
    return if (c < names.len) names[c] else names[0];
}

/// True when this report should raise the off-position warning.
///
/// A VIRTUAL aid cannot be off position: there is nothing in the water to
/// drift, and the flag is meaningless on one. An aid that has never reported
/// the flag with a usable timestamp says nothing either way. The warning goes
/// out once and re-arms only when the aid reports itself back on station.
pub fn wantsWarning(virtual_aid: bool, off_position: ?bool, already_warned: bool) bool {
    if (virtual_aid) return false;
    const off = off_position orelse return false;
    return off and !already_warned;
}

/// True when a warning already raised should be re-armed: the aid is back on
/// station, so the next time it drifts the mariner hears about it again.
pub fn rearm(off_position: ?bool) bool {
    return (off_position orelse return false) == false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "navaid names cover the whole 5-bit field" {
    try t.expectEqualStrings("Isolated danger", navaidName(28));
    try t.expectEqualStrings("Starboard hand mark", navaidName(25));
    try t.expectEqualStrings("Cardinal mark N", navaidName(20));
    try t.expectEqualStrings("Light vessel, LANBY or rig", navaidName(31));
    // Unspecified, absent and impossible all give the generic name.
    try t.expectEqualStrings("Aid to navigation", navaidName(0));
    try t.expectEqualStrings("Aid to navigation", navaidName(null));
    try t.expectEqualStrings("Aid to navigation", navaidName(200));
    for (0..32) |i| try t.expect(navaidName(@intCast(i)).len > 0);
}

test "only a physical aid that says it is off station warns, and only once" {
    try t.expect(wantsWarning(false, true, false));
    // The second report of the same drift is not a second warning.
    try t.expect(!wantsWarning(false, true, true));
    // On station, unknown, and virtual: nothing to say.
    try t.expect(!wantsWarning(false, false, false));
    try t.expect(!wantsWarning(false, null, false));
    try t.expect(!wantsWarning(true, true, false));

    // Back on station re-arms; nothing else does.
    try t.expect(rearm(false));
    try t.expect(!rearm(true));
    try t.expect(!rearm(null));
}
