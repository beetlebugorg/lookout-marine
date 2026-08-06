//! How lookout-plugin-dev cuts a NMEA 0183 log into per-second groups and
//! decides when each one is due on the wire.
//!
//! A recorded log carries its own clock in the RMC sentences, so the replay
//! follows that clock rather than a line rate: every line from one RMC up to
//! (not including) the next belongs to the same second, and that second is
//! read out of the RMC's UTC field. A log whose RMCs have no usable time — or
//! no RMCs at all — falls back to one group per second, which is the pacing
//! PROTOTYPE.md calls sufficient.
//!
//! Pure: std only, no I/O, no allocation. `zig test src/plugin_dev_replay.zig`.

const std = @import("std");

/// One second of the log.
pub const Group = struct {
    /// The lines, newlines included, exactly as they must go on the wire.
    text: []const u8,
    /// Seconds since the first timed RMC in the file.
    second: u32,
};

/// True for `$xxRMC,...`. Talker id is two characters by the standard, and
/// nothing else in the prototype's logs starts a second.
pub fn isRmc(line: []const u8) bool {
    return line.len >= 6 and line[0] == '$' and std.mem.eql(u8, line[3..6], "RMC");
}

/// Seconds since midnight out of an RMC's first field (`hhmmss[.sss]`), or
/// null when the field is empty or malformed — a fix-less RMC has it blank.
pub fn secondOfDay(line: []const u8) ?u32 {
    const comma = std.mem.indexOfScalar(u8, line, ',') orelse return null;
    var f = line[comma + 1 ..];
    if (std.mem.indexOfScalar(u8, f, ',')) |end| f = f[0..end];
    if (std.mem.indexOfScalar(u8, f, '.')) |dot| f = f[0..dot];
    if (f.len != 6) return null;
    for (f) |c| if (c < '0' or c > '9') return null;
    const hh = (f[0] - '0') * @as(u32, 10) + (f[1] - '0');
    const mm = (f[2] - '0') * @as(u32, 10) + (f[3] - '0');
    const ss = (f[4] - '0') * @as(u32, 10) + (f[5] - '0');
    if (hh > 23 or mm > 59 or ss > 60) return null;
    return hh * 3600 + mm * 60 + ss;
}

const day_seconds: u32 = 24 * 60 * 60;

/// Walks a log text and hands back one `Group` per second.
pub const Splitter = struct {
    data: []const u8,
    pos: usize = 0,
    /// The first RMC's second of day; every group's second is measured from it.
    base: ?u32 = null,
    /// Second of the group last returned — what a group with no time inherits.
    last: u32 = 0,
    /// Groups returned so far, the fallback clock when no RMC carries a time.
    index: u32 = 0,
    timed: bool = false,

    pub fn init(data: []const u8) Splitter {
        return .{ .data = data };
    }

    /// The next second of the log, or null at the end. A group runs from its
    /// first line up to the line before the next RMC, so the AIVDM and
    /// instrument sentences that follow an RMC travel with it.
    pub fn next(self: *Splitter) ?Group {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        var second: ?u32 = null;

        // The group's own first line, then every following line up to the next
        // RMC.
        while (self.pos < self.data.len) {
            const line = self.lineAt(self.pos);
            if (second == null and isRmc(line.text)) second = self.stamp(line.text);
            self.pos = line.next;
            if (self.pos >= self.data.len) break;
            if (isRmc(self.lineAt(self.pos).text)) break;
        }

        const s = second orelse (if (self.timed) self.last else self.index);
        self.last = s;
        self.index += 1;
        return .{ .text = self.data[start..self.pos], .second = s };
    }

    /// The replay second an RMC's time field means. Sets the base on the first
    /// one and wraps across midnight rather than going backwards.
    fn stamp(self: *Splitter, line: []const u8) ?u32 {
        const sod = secondOfDay(line) orelse return null;
        self.timed = true;
        const base = self.base orelse {
            self.base = sod;
            return 0;
        };
        return (sod + day_seconds - base) % day_seconds;
    }

    const Line = struct { text: []const u8, next: usize };

    fn lineAt(self: *Splitter, at: usize) Line {
        const nl = std.mem.indexOfScalarPos(u8, self.data, at, '\n') orelse
            return .{ .text = trimCr(self.data[at..]), .next = self.data.len };
        return .{ .text = trimCr(self.data[at..nl]), .next = nl + 1 };
    }

    fn trimCr(s: []const u8) []const u8 {
        return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
    }
};

/// When a group is due, in milliseconds after the replay started, at `rate`x
/// real time. Rate 0 or below means "as fast as the socket takes it".
pub fn dueMs(second: u32, rate: f64) i64 {
    if (!(rate > 0)) return 0;
    const ms = @as(f64, @floatFromInt(second)) * 1000.0 / rate;
    return @intFromFloat(@min(ms, @as(f64, std.math.maxInt(i32))));
}

// ---- tests -------------------------------------------------------------------

const t = std.testing;

test "an RMC line is recognised by talker-independent sentence id" {
    try t.expect(isRmc("$GPRMC,140000,A,3858.5780,N,07628.6020,W,5.0,30.0,050826,11.0,W,A*12"));
    try t.expect(isRmc("$GNRMC,140000,V,,,,,,,050826,,,N*67"));
    try t.expect(!isRmc("$HEHDT,30.0,T*1C"));
    try t.expect(!isRmc("!AIVDM,1,1,,A,15N7KvPP1@JR1QLFCLdKf9H00000,0*62"));
    try t.expect(!isRmc("$GP"));
    try t.expect(!isRmc(""));
}

test "the RMC time field reads as seconds since midnight" {
    try t.expectEqual(@as(?u32, 14 * 3600), secondOfDay("$GPRMC,140000,A,3858.5780,N"));
    try t.expectEqual(@as(?u32, 14 * 3600 + 61), secondOfDay("$GPRMC,140101,A,3858.5780,N"));
    // Fractional seconds are truncated, not rejected.
    try t.expectEqual(@as(?u32, 86399), secondOfDay("$GPRMC,235959.50,A,x"));
    // A fix-less receiver sends the field empty; junk is junk.
    try t.expectEqual(@as(?u32, null), secondOfDay("$GPRMC,,V,,,,,,,050826,,,N*67"));
    try t.expectEqual(@as(?u32, null), secondOfDay("$GPRMC,14000,A,x"));
    try t.expectEqual(@as(?u32, null), secondOfDay("$GPRMC,1400xx,A,x"));
    try t.expectEqual(@as(?u32, null), secondOfDay("$GPRMC,254000,A,x"));
    try t.expectEqual(@as(?u32, null), secondOfDay("no commas here"));
}

test "a group runs from one RMC to the next and carries its second" {
    const log =
        "$GPRMC,140000,A,3858.5780,N,07628.6020,W,5.0,30.0,050826,11.0,W,A*12\n" ++
        "$HEHDT,30.0,T*1C\n" ++
        "!AIVDM,1,1,,A,15N7KvPP1@JR1QLFCLdKf9H00000,0*62\n" ++
        "$GPRMC,140001,A,3858.5792,N,07628.6011,W,5.0,30.5,050826,11.0,W,A*17\n" ++
        "$HEHDT,30.5,T*1C\n";
    var s = Splitter.init(log);

    const g0 = s.next().?;
    try t.expectEqual(@as(u32, 0), g0.second);
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, g0.text, "\n"));
    try t.expect(std.mem.startsWith(u8, g0.text, "$GPRMC,140000"));

    const g1 = s.next().?;
    try t.expectEqual(@as(u32, 1), g1.second);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, g1.text, "\n"));
    try t.expect(s.next() == null);

    // The groups partition the file: nothing dropped, nothing duplicated.
    try t.expectEqual(log.len, g0.text.len + g1.text.len);
}

test "lines before the first RMC are one group, and a gap in the log is a gap in time" {
    const log =
        "$SDDPT,9.0,0.30,*41\n" ++
        "$WIMWD,220.0,T,231.0,M,12.0,N,6.2,M*6D\n" ++
        "$GPRMC,140000,A,x*00\n" ++
        "$GPRMC,140010,A,x*00\n";
    var s = Splitter.init(log);
    const pre = s.next().?;
    try t.expectEqual(@as(u32, 0), pre.second);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, pre.text, "\n"));
    try t.expectEqual(@as(u32, 0), s.next().?.second);
    try t.expectEqual(@as(u32, 10), s.next().?.second);
    try t.expect(s.next() == null);
}

test "a log that crosses midnight keeps going forward" {
    const log =
        "$GPRMC,235959,A,x*00\n" ++
        "$GPRMC,000000,A,x*00\n" ++
        "$GPRMC,000001,A,x*00\n";
    var s = Splitter.init(log);
    try t.expectEqual(@as(u32, 0), s.next().?.second);
    try t.expectEqual(@as(u32, 1), s.next().?.second);
    try t.expectEqual(@as(u32, 2), s.next().?.second);
}

test "with no usable RMC time the clock falls back to one group per second" {
    const log =
        "$GPRMC,,V,,,,,,,050826,,,N*67\n" ++
        "$HEHDT,30.0,T*1C\n" ++
        "$GPRMC,,V,,,,,,,050826,,,N*67\n";
    var s = Splitter.init(log);
    try t.expectEqual(@as(u32, 0), s.next().?.second);
    try t.expectEqual(@as(u32, 1), s.next().?.second);
    try t.expect(s.next() == null);
}

test "a file with no trailing newline still yields its last line" {
    var s = Splitter.init("$GPRMC,140000,A,x*00\n$HEHDT,30.0,T*1C");
    const g = s.next().?;
    try t.expect(std.mem.endsWith(u8, g.text, "$HEHDT,30.0,T*1C"));
    try t.expect(s.next() == null);
}

test "due time scales with the replay rate" {
    try t.expectEqual(@as(i64, 400_000), dueMs(400, 1));
    try t.expectEqual(@as(i64, 20_000), dueMs(400, 20));
    try t.expectEqual(@as(i64, 0), dueMs(0, 20));
    // Rate 0 means unpaced: everything is due at once.
    try t.expectEqual(@as(i64, 0), dueMs(400, 0));
}
