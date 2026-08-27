//! Vessels: what to call a navigation status and a ship type.
//!
//! Pure — `std` only — so `zig test vessel.zig` runs it natively.
//!
//! Both are display strings the pick payload shows to the mariner, in the
//! wording ITU-R M.1371 gives the fields of a type 1 and a type 5 report.

const std = @import("std");

/// The 15 navigation statuses, indexed by the 4-bit code a class A position
/// report carries. 15 is "undefined" and never arrives: it is dropped where
/// the message is decoded, which is what tells "not said" from "said nothing".
const statuses = [15][]const u8{
    "Under way using engine",
    "At anchor",
    "Not under command",
    "Restricted manoeuvrability",
    "Constrained by draught",
    "Moored",
    "Aground",
    "Fishing",
    "Under way sailing",
    // 9 and 10 mean different cargo in different waters, and 11 through 13
    // were re-cut for towing in 2018 and are still not universal. Saying
    // which would be guessing at the transponder's vintage.
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "AIS-SART",
};

/// What to call a navigation status, or null when the vessel has not said.
pub fn statusName(code: ?u8) ?[]const u8 {
    const c = code orelse return null;
    return if (c < statuses.len) statuses[c] else null;
}

/// The second digit of a cargo vessel's type: what she is carrying, when she
/// carries something the mariner alongside would want to know about.
fn cargo(digit: u8) []const u8 {
    return switch (digit) {
        1 => ", hazardous A",
        2 => ", hazardous B",
        3 => ", hazardous C",
        4 => ", hazardous D",
        else => "",
    };
}

/// What to call a ship and cargo type, written into `buf`. Null when the
/// vessel has not said, or said a code the format does not define.
///
/// The 30s and 50s are one name a code; the 20s, 40s, 60s, 70s, 80s and 90s
/// are a class in the first digit and a qualifier in the second, and only the
/// cargo qualifier is worth the mariner's eye. `buf` needs 32 bytes.
pub fn typeName(code: ?u8, buf: []u8) ?[]const u8 {
    const c = code orelse return null;
    const base: []const u8 = switch (c) {
        20...29 => "Wing in ground",
        30 => "Fishing",
        31, 32 => "Towing",
        33 => "Dredging or underwater ops",
        34 => "Diving ops",
        35 => "Military ops",
        36 => "Sailing",
        37 => "Pleasure craft",
        40...49 => "High-speed craft",
        50 => "Pilot vessel",
        51 => "Search and rescue",
        52 => "Tug",
        53 => "Port tender",
        54 => "Anti-pollution",
        55 => "Law enforcement",
        58 => "Medical transport",
        59 => "Non-combatant",
        60...69 => "Passenger",
        70...79 => "Cargo",
        80...89 => "Tanker",
        90...99 => "Other",
        else => return null,
    };
    // A tow says how big the tow is, not what it carries, and a passenger
    // ship's second digit is a reserved qualifier. Only cargo and tankers
    // spell out a hazard, which is the one thing worth the extra words.
    const suffix = switch (c) {
        70...89 => cargo(c % 10),
        else => "",
    };
    if (suffix.len == 0) return base;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix }) catch base;
}

/// Which class the target last reported on, or null before one has said.
pub fn className(class_b: ?bool) ?[]const u8 {
    const b = class_b orelse return null;
    return if (b) "B" else "A";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "a status is named, and one nobody sent is not" {
    try t.expectEqualStrings("At anchor", statusName(1).?);
    try t.expectEqualStrings("Constrained by draught", statusName(4).?);
    try t.expectEqualStrings("AIS-SART", statusName(14).?);
    try t.expect(statusName(null) == null);
    // 15 is dropped at the decoder; anything above it is off the format.
    try t.expect(statusName(15) == null);
    try t.expect(statusName(200) == null);
}

test "a ship type is named, and a cargo says what it is carrying" {
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("Sailing", typeName(36, &buf).?);
    try t.expectEqualStrings("Pleasure craft", typeName(37, &buf).?);
    try t.expectEqualStrings("Tug", typeName(52, &buf).?);
    try t.expectEqualStrings("High-speed craft", typeName(44, &buf).?);
    try t.expectEqualStrings("Passenger", typeName(69, &buf).?);
    // The hazard is the second digit, and only a cargo or a tanker has one.
    try t.expectEqualStrings("Cargo", typeName(70, &buf).?);
    try t.expectEqualStrings("Cargo, hazardous A", typeName(71, &buf).?);
    try t.expectEqualStrings("Tanker, hazardous C", typeName(83, &buf).?);
    try t.expectEqualStrings("Tanker", typeName(89, &buf).?);
    // A code the format leaves undefined loses the row, not the target.
    try t.expect(typeName(null, &buf) == null);
    try t.expect(typeName(0, &buf) == null);
    try t.expect(typeName(19, &buf) == null);
    try t.expect(typeName(56, &buf) == null);
}

test "the every-name pass never overruns a 32-byte buffer" {
    var buf: [32]u8 = undefined;
    var code: u8 = 0;
    while (code < 100) : (code += 1) {
        // bufPrint falls back to the bare name rather than truncating, so the
        // only way to catch a name that outgrew the buffer is to check that
        // a hazardous cargo still says so.
        if (code >= 70 and code <= 89 and code % 10 >= 1 and code % 10 <= 4) {
            const name = typeName(code, &buf).?;
            try t.expect(std.mem.indexOf(u8, name, "hazardous") != null);
        } else {
            _ = typeName(code, &buf);
        }
    }
}

test "a class is named only once the target has reported one" {
    try t.expectEqualStrings("A", className(false).?);
    try t.expectEqualStrings("B", className(true).?);
    try t.expect(className(null) == null);
}
