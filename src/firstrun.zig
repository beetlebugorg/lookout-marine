//! Setup: which step is on screen, what the primary action and Back do, and
//! whether setup comes up. Pure state with no I/O. The C ABI is in
//! capi/setup.zig, and the words each step shows stay in the shells.
//!
//! The shells hand in the facts they observe (Facts) and the mariner's
//! actions (Action). Everything else follows from those.

const std = @import("std");
const owned = @import("owned");

pub const Step = enum(u8) { welcome, source, coverage, online, importing, depths };

/// Where the first charts come from.
pub const Source = enum(u8) { noaa, online, files };

pub const Action = enum(u8) {
    /// Raise setup on the step in the action's argument.
    begin,
    /// Raise one step on its own, such as the coverage picker opened from the
    /// Charts pane. Back is off, and Continue on the import finishes.
    begin_picker,
    /// The primary action. The argument is the source picked on the source
    /// step.
    advance,
    back,
    /// NOAA's terms accepted: on to the coverage step.
    agree,
    /// NOAA's terms dismissed: the source step stays.
    decline,
    /// Set Up Later, Cancel, and the end of a run that finished.
    later,
};

/// lookout_noaa_state.outcome.
pub const outcome_none: u8 = 0;
pub const outcome_running: u8 = 1;
pub const outcome_finished: u8 = 2;
pub const outcome_empty: u8 = 3;
pub const outcome_cancelled: u8 = 4;
pub const outcome_failed: u8 = 5;
pub const outcome_refused: u8 = 6;

/// What the shell observes. Every field is 0 or 1 unless stated.
pub const Facts = extern struct {
    /// NOAA's catalog is loaded.
    catalog_ready: u8 = 0,
    /// The coverage pick holds at least one region.
    picked: u8 = 0,
    /// A chart link is selected and draws as the chart.
    on_link: u8 = 0,
    /// The app has settled on having no chart to draw.
    nothing_to_draw: u8 = 0,
    /// A switched-on chart set holds something to draw. This is read from the
    /// sets themselves, because nothing_to_draw is also 0 while the first scan
    /// of a launch runs.
    has_charts: u8 = 0,
    /// A bake, a scan or a NOAA prepare runs.
    work_running: u8 = 0,
    /// A NOAA transfer runs.
    downloading: u8 = 0,
    /// A chart with cells in it is open.
    chart_open: u8 = 0,
    /// lookout_noaa_state.outcome.
    noaa_outcome: u8 = outcome_none,
    /// lookout_noaa_state.run.
    noaa_run: u32 = 0,
    /// What Download orders, as the shell prices the pick.
    pick_charts: u32 = 0,
    pick_bytes: u64 = 0,
};

/// What the views read.
pub const State = extern struct {
    step: u8 = @intFromEnum(Step.welcome),
    showing: u8 = 0,
    /// Setup is down and has a reason to come up. The shell begins it.
    should_run: u8 = 0,
    can_go_back: u8 = 0,
    primary_enabled: u8 = 0,
    /// NOAA's terms are up over the source step.
    terms_showing: u8 = 0,
    picker_only: u8 = 0,
    /// A NOAA download was ordered from the coverage step in this run of
    /// setup.
    ordered: u8 = 0,
    /// The order ended with no chart to continue to. The import step shows
    /// the end and offers Back.
    import_ended: u8 = 0,
    /// Work was seen on the import step. An import yet to start and one that
    /// has finished both have no work running, and this separates them.
    saw_work: u8 = 0,
    /// The order as it was placed. The transfer's own counters are for the
    /// transfer, and the step outlives it.
    order_charts: u32 = 0,
    order_bytes: u64 = 0,
};

pub const Setup = struct {
    facts: Facts = .{},
    step: Step = .welcome,
    showing: bool = false,
    terms_showing: bool = false,
    picker_only: bool = false,

    /// Set Up Later, or a finished run. It holds for the life of the handle.
    put_away: bool = false,
    /// A library with charts in it was seen since setup last came up. A
    /// mariner who removes every chart then has setup back, and one whose
    /// library never held charts keeps Set Up Later.
    had_charts: bool = false,

    saw_work: bool = false,
    ordered: bool = false,
    /// lookout_noaa_state.run as it was when Download was pressed. The order's
    /// own run is the next one.
    order_run: u32 = 0,
    order_charts: u32 = 0,
    order_bytes: u64 = 0,

    pub fn note(self: *Setup, f: Facts) void {
        self.facts = f;
        if (f.has_charts != 0) self.had_charts = true;
        if (!self.showing or self.step != .importing) return;
        if (f.work_running != 0) self.saw_work = true;
        // A prepare of a cell or two can end between two notes. A finished
        // order had work, seen or not.
        if (self.orderEnded() and f.noaa_outcome == outcome_finished) self.saw_work = true;
    }

    pub fn shouldRun(self: *const Setup) bool {
        const f = self.facts;
        if (self.showing) return false;
        // A linked chart is a chart.
        if (f.on_link != 0) return false;
        if (self.put_away and !self.had_charts) return false;
        return f.nothing_to_draw != 0 and f.work_running == 0;
    }

    /// Returns the source the shell acts on after the action, if any: NOAA to
    /// start the download, online for the picked link, files to raise its
    /// picker.
    pub fn act(self: *Setup, action: Action, arg: i32) ?Source {
        switch (action) {
            .begin => self.begin(stepOf(arg), false),
            .begin_picker => self.begin(stepOf(arg), true),
            .advance => return self.advance(sourceOf(arg)),
            .back => self.back(),
            .agree => {
                self.terms_showing = false;
                if (self.showing and self.step == .source) self.step = .coverage;
            },
            .decline => self.terms_showing = false,
            .later => self.finish(),
        }
        return null;
    }

    fn begin(self: *Setup, step: Step, picker: bool) void {
        self.step = step;
        self.showing = true;
        self.picker_only = picker;
        self.terms_showing = false;
        self.resetImport();
        // The latch restarts here. A Set Up Later from this run of setup
        // stands until the library holds charts again.
        if (!picker) self.had_charts = self.facts.has_charts != 0;
    }

    fn resetImport(self: *Setup) void {
        self.saw_work = false;
        self.ordered = false;
        self.order_run = 0;
        self.order_charts = 0;
        self.order_bytes = 0;
    }

    fn finish(self: *Setup) void {
        self.put_away = true;
        self.showing = false;
        self.step = .welcome;
        self.picker_only = false;
        self.terms_showing = false;
    }

    fn advance(self: *Setup, source: ?Source) ?Source {
        if (!self.showing) return null;
        switch (self.step) {
            .welcome => self.step = .source,
            .source => switch (source orelse return null) {
                // NOAA's terms apply to NOAA's charts, so they are asked where
                // those charts are chosen. Agree moves the step.
                .noaa => self.terms_showing = true,
                .online => self.step = .online,
                .files => {
                    self.finish();
                    return .files;
                },
            },
            .coverage => {
                self.step = .importing;
                self.resetImport();
                self.ordered = true;
                self.order_run = self.facts.noaa_run;
                self.order_charts = self.facts.pick_charts;
                self.order_bytes = self.facts.pick_bytes;
                return .noaa;
            },
            .online => {
                self.step = .depths;
                return .online;
            },
            // A step opened on its own ends here. The depths were set when
            // the app was first set up.
            .importing => if (self.picker_only) self.finish() else {
                self.step = .depths;
            },
            .depths => self.finish(),
        }
        return null;
    }

    fn back(self: *Setup) void {
        if (!self.canGoBack()) return;
        switch (self.step) {
            .source => self.step = .welcome,
            .coverage, .online => self.step = .source,
            // The pick stands, so the coverage step opens on it and Download
            // runs again.
            .importing => {
                self.resetImport();
                self.step = .coverage;
            },
            .welcome, .depths => {},
        }
    }

    /// The welcome step offers Set Up Later instead. The depth step follows
    /// charts that are already in.
    pub fn canGoBack(self: *const Setup) bool {
        if (!self.showing) return false;
        return switch (self.step) {
            .welcome, .depths => false,
            .source, .coverage, .online => !self.picker_only,
            .importing => self.importEnded(),
        };
    }

    pub fn primaryEnabled(self: *const Setup) bool {
        const f = self.facts;
        return switch (self.step) {
            .welcome, .source, .depths => true,
            .online => f.on_link != 0,
            .coverage => f.catalog_ready != 0 and f.picked != 0,
            // The chart opens once the import finishes, and Continue waits
            // for it.
            .importing => self.saw_work and f.downloading == 0 and
                f.work_running == 0 and f.chart_open != 0,
        };
    }

    /// The order's own run has ended.
    fn orderEnded(self: *const Setup) bool {
        const f = self.facts;
        return self.ordered and f.noaa_run != self.order_run and
            f.noaa_outcome != outcome_none and f.noaa_outcome != outcome_running;
    }

    /// The order ended short of a chart to continue to: it failed, the core
    /// refused it, it had no chart to fetch or prepare, or the mariner stopped
    /// it before a chart was prepared.
    pub fn importEnded(self: *const Setup) bool {
        const f = self.facts;
        return self.showing and self.step == .importing and self.orderEnded() and
            f.noaa_outcome != outcome_finished and f.work_running == 0 and
            f.downloading == 0 and !self.primaryEnabled();
    }

    pub fn state(self: *const Setup) State {
        return .{
            .step = @intFromEnum(self.step),
            .showing = @intFromBool(self.showing),
            .should_run = @intFromBool(self.shouldRun()),
            .can_go_back = @intFromBool(self.canGoBack()),
            .primary_enabled = @intFromBool(self.showing and self.primaryEnabled()),
            .terms_showing = @intFromBool(self.terms_showing),
            .picker_only = @intFromBool(self.picker_only),
            .ordered = @intFromBool(self.ordered),
            .import_ended = @intFromBool(self.importEnded()),
            .saw_work = @intFromBool(self.saw_work),
            .order_charts = self.order_charts,
            .order_bytes = self.order_bytes,
        };
    }

    /// The state, written to a shell's struct with its padding zeroed. A null
    /// setup writes the default state.
    pub fn read(self: ?*const Setup, out: *State) void {
        owned.fill(State, out, if (self) |s| s.state() else .{});
    }
};

fn stepOf(arg: i32) Step {
    return std.enums.fromInt(Step, arg) orelse .welcome;
}

fn sourceOf(arg: i32) ?Source {
    return std.enums.fromInt(Source, arg);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

/// An empty library, settled.
const empty: Facts = .{ .nothing_to_draw = 1 };
/// A library with a chart open.
const library: Facts = .{ .has_charts = 1, .chart_open = 1 };

fn shown(step: Step) Setup {
    var s: Setup = .{};
    s.note(empty);
    _ = s.act(.begin, @intFromEnum(step));
    return s;
}

test "setup runs on an empty library and stays down over charts or a link" {
    var s: Setup = .{};
    try testing.expect(!s.shouldRun());
    s.note(empty);
    try testing.expect(s.shouldRun());
    s.note(library);
    try testing.expect(!s.shouldRun());
    s.note(.{ .nothing_to_draw = 1, .on_link = 1 });
    try testing.expect(!s.shouldRun());
    // The library still being read.
    s.note(.{ .nothing_to_draw = 1, .work_running = 1 });
    try testing.expect(!s.shouldRun());
}

test "setup is down while it shows" {
    const s = shown(.welcome);
    try testing.expect(!s.shouldRun());
    try testing.expectEqual(@as(u8, 1), s.state().showing);
}

test "begin opens on the step it names" {
    var s: Setup = .{};
    _ = s.act(.begin, @intFromEnum(Step.coverage));
    try testing.expectEqual(Step.coverage, s.step);
    _ = s.act(.begin, 99);
    try testing.expectEqual(Step.welcome, s.step);
}

test "welcome continues to the source step and offers no Back" {
    var s = shown(.welcome);
    try testing.expect(!s.canGoBack());
    try testing.expect(s.primaryEnabled());
    try testing.expectEqual(@as(?Source, null), s.act(.advance, -1));
    try testing.expectEqual(Step.source, s.step);
    try testing.expect(s.canGoBack());
    _ = s.act(.back, 0);
    try testing.expectEqual(Step.welcome, s.step);
}

test "NOAA raises the terms, and only agreeing moves on" {
    var s = shown(.source);
    try testing.expectEqual(@as(?Source, null), s.act(.advance, @intFromEnum(Source.noaa)));
    try testing.expectEqual(Step.source, s.step);
    try testing.expect(s.terms_showing);
    _ = s.act(.decline, 0);
    try testing.expect(!s.terms_showing);
    try testing.expectEqual(Step.source, s.step);

    _ = s.act(.advance, @intFromEnum(Source.noaa));
    _ = s.act(.agree, 0);
    try testing.expect(!s.terms_showing);
    try testing.expectEqual(Step.coverage, s.step);
    _ = s.act(.back, 0);
    try testing.expectEqual(Step.source, s.step);
}

test "the source step needs a source" {
    var s = shown(.source);
    try testing.expectEqual(@as(?Source, null), s.act(.advance, 7));
    try testing.expectEqual(Step.source, s.step);
}

test "files ends setup and hands the shell its picker" {
    var s = shown(.source);
    try testing.expectEqual(@as(?Source, .files), s.act(.advance, @intFromEnum(Source.files)));
    try testing.expect(!s.showing);
    try testing.expect(s.put_away);
    try testing.expectEqual(Step.welcome, s.step);
}

test "the online step needs a picked link and continues to depths" {
    var s = shown(.source);
    _ = s.act(.advance, @intFromEnum(Source.online));
    try testing.expectEqual(Step.online, s.step);
    try testing.expect(!s.primaryEnabled());
    s.note(.{ .nothing_to_draw = 1, .on_link = 1 });
    try testing.expect(s.primaryEnabled());
    try testing.expectEqual(@as(?Source, .online), s.act(.advance, -1));
    try testing.expectEqual(Step.depths, s.step);

    var t = shown(.online);
    _ = t.act(.back, 0);
    try testing.expectEqual(Step.source, t.step);
}

test "coverage needs a catalog and a pick, and Download records the order" {
    var s = shown(.coverage);
    try testing.expect(!s.primaryEnabled());
    s.note(.{ .nothing_to_draw = 1, .catalog_ready = 1 });
    try testing.expect(!s.primaryEnabled());
    s.note(.{ .nothing_to_draw = 1, .catalog_ready = 1, .picked = 1, .noaa_run = 3, .pick_charts = 12, .pick_bytes = 1000 });
    try testing.expect(s.primaryEnabled());
    try testing.expectEqual(@as(?Source, .noaa), s.act(.advance, -1));
    try testing.expectEqual(Step.importing, s.step);
    const st = s.state();
    try testing.expectEqual(@as(u8, 1), st.ordered);
    try testing.expectEqual(@as(u32, 12), st.order_charts);
    try testing.expectEqual(@as(u64, 1000), st.order_bytes);
    try testing.expectEqual(@as(u32, 3), s.order_run);
}

test "depths finishes setup and offers no Back" {
    var s = shown(.depths);
    try testing.expect(!s.canGoBack());
    _ = s.act(.back, 0);
    try testing.expectEqual(Step.depths, s.step);
    try testing.expectEqual(@as(?Source, null), s.act(.advance, -1));
    try testing.expect(!s.showing);
    try testing.expect(s.put_away);
}

/// On the import step with an order out, run 1 being the order's.
fn ordered() Setup {
    var s = shown(.coverage);
    s.note(.{ .nothing_to_draw = 1, .catalog_ready = 1, .picked = 1 });
    _ = s.act(.advance, -1);
    return s;
}

test "the import holds while charts arrive and are prepared" {
    var s = ordered();
    s.note(.{ .downloading = 1, .noaa_run = 1, .noaa_outcome = outcome_running });
    try testing.expect(!s.canGoBack());
    try testing.expect(!s.primaryEnabled());
    _ = s.act(.back, 0);
    try testing.expectEqual(Step.importing, s.step);

    s.note(.{ .work_running = 1, .noaa_run = 1, .noaa_outcome = outcome_running });
    try testing.expect(s.saw_work);
    try testing.expect(!s.primaryEnabled());
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_finished, .has_charts = 1 });
    // Continue waits for the chart to open.
    try testing.expect(!s.primaryEnabled());
    try testing.expect(!s.importEnded());
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_finished, .has_charts = 1, .chart_open = 1 });
    try testing.expect(s.primaryEnabled());
    try testing.expect(!s.canGoBack());
    _ = s.act(.advance, -1);
    try testing.expectEqual(Step.depths, s.step);
}

test "a finished order counts as work when the prepare was never seen" {
    var s = ordered();
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_finished, .has_charts = 1, .chart_open = 1 });
    try testing.expect(s.saw_work);
    try testing.expect(s.primaryEnabled());
}

test "an earlier run's end is not the order's end" {
    var s = shown(.coverage);
    s.note(.{ .noaa_run = 4, .noaa_outcome = outcome_failed });
    _ = s.act(.advance, -1);
    s.note(.{ .noaa_run = 4, .noaa_outcome = outcome_failed });
    try testing.expect(!s.importEnded());
    try testing.expect(!s.canGoBack());
}

test "Back from Preparing after each ended outcome" {
    const ends = [_]u8{ outcome_failed, outcome_refused, outcome_empty, outcome_cancelled };
    for (ends) |o| {
        var s = ordered();
        s.note(.{ .noaa_run = 1, .noaa_outcome = o });
        try testing.expect(s.importEnded());
        try testing.expect(s.canGoBack());
        try testing.expectEqual(@as(u8, 1), s.state().import_ended);
        _ = s.act(.back, 0);
        try testing.expectEqual(Step.coverage, s.step);
        try testing.expect(!s.ordered);
        try testing.expect(!s.saw_work);
        try testing.expect(!s.importEnded());
    }
}

test "an ended order that still prepares waits for the prepare" {
    var s = ordered();
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_cancelled, .work_running = 1 });
    try testing.expect(!s.importEnded());
    try testing.expect(!s.canGoBack());
}

test "a stop that kept charts continues" {
    var s = ordered();
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_running, .work_running = 1 });
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_cancelled, .has_charts = 1, .chart_open = 1 });
    try testing.expect(!s.importEnded());
    try testing.expect(s.primaryEnabled());
}

test "a prepare that refused every chart offers Back" {
    var s = ordered();
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_running, .work_running = 1 });
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_empty, .nothing_to_draw = 1 });
    try testing.expect(s.saw_work);
    try testing.expect(s.importEnded());
    try testing.expect(s.canGoBack());
}

test "an import opened with no order offers no Back" {
    var s = shown(.importing);
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_failed });
    try testing.expect(!s.importEnded());
    try testing.expect(!s.canGoBack());
}

test "beginning again forgets the last order" {
    var s = ordered();
    s.note(.{ .noaa_run = 1, .noaa_outcome = outcome_running, .work_running = 1 });
    _ = s.act(.later, 0);
    _ = s.act(.begin, 0);
    try testing.expect(!s.saw_work);
    try testing.expect(!s.ordered);
    try testing.expectEqual(@as(u32, 0), s.state().order_charts);
}

test "Set Up Later keeps setup down over a library that never had charts" {
    var s = shown(.welcome);
    _ = s.act(.later, 0);
    try testing.expect(!s.showing);
    s.note(empty);
    try testing.expect(!s.shouldRun());
    // The first scan of a launch reads as something to draw.
    s.note(.{ .work_running = 1 });
    s.note(empty);
    try testing.expect(!s.shouldRun());
}

test "setup returns when a library that had charts is emptied" {
    var s = shown(.welcome);
    _ = s.act(.later, 0);
    s.note(library);
    try testing.expect(!s.shouldRun());
    s.note(empty);
    try testing.expect(s.shouldRun());

    // Set Up Later on the setup that returned keeps it down.
    _ = s.act(.begin, 0);
    _ = s.act(.later, 0);
    s.note(empty);
    try testing.expect(!s.shouldRun());
    // Charts again, then none: back once more.
    s.note(library);
    s.note(empty);
    try testing.expect(s.shouldRun());
}

test "a finished run returns once its charts are removed" {
    var s = shown(.depths);
    s.note(library);
    _ = s.act(.advance, -1);
    try testing.expect(!s.shouldRun());
    s.note(empty);
    try testing.expect(s.shouldRun());
}

test "the picker opens one step with no Back and ends at the import" {
    var s: Setup = .{};
    s.note(library);
    _ = s.act(.begin_picker, @intFromEnum(Step.coverage));
    try testing.expect(s.showing);
    try testing.expect(s.picker_only);
    try testing.expectEqual(Step.coverage, s.step);
    try testing.expect(!s.canGoBack());
    _ = s.act(.back, 0);
    try testing.expectEqual(Step.coverage, s.step);

    s.note(.{ .has_charts = 1, .chart_open = 1, .catalog_ready = 1, .picked = 1 });
    try testing.expectEqual(@as(?Source, .noaa), s.act(.advance, -1));
    try testing.expectEqual(Step.importing, s.step);
    s.note(.{ .has_charts = 1, .chart_open = 1, .noaa_run = 1, .noaa_outcome = outcome_finished });
    try testing.expect(s.primaryEnabled());
    _ = s.act(.advance, -1);
    try testing.expect(!s.showing);
    try testing.expect(!s.picker_only);
}

test "the picker offers Back from an ended import" {
    var s: Setup = .{};
    s.note(library);
    _ = s.act(.begin_picker, @intFromEnum(Step.coverage));
    _ = s.act(.advance, -1);
    s.note(.{ .has_charts = 1, .noaa_run = 1, .noaa_outcome = outcome_refused });
    try testing.expect(s.canGoBack());
    _ = s.act(.back, 0);
    try testing.expectEqual(Step.coverage, s.step);
    try testing.expect(s.picker_only);
}

test "the picker emptying a library that had charts brings setup back" {
    var s: Setup = .{};
    s.note(library);
    _ = s.act(.begin_picker, @intFromEnum(Step.coverage));
    _ = s.act(.later, 0);
    s.note(empty);
    try testing.expect(s.shouldRun());
}

test "actions on a hidden setup leave it as it was" {
    var s: Setup = .{};
    try testing.expectEqual(@as(?Source, null), s.act(.advance, 0));
    _ = s.act(.agree, 0);
    _ = s.act(.back, 0);
    try testing.expectEqual(Step.welcome, s.step);
    try testing.expect(!s.showing);
    try testing.expectEqual(@as(u8, 0), s.state().primary_enabled);
}

test "the state layout matches lookout-library.h" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(Facts));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Facts, "noaa_run"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Facts, "pick_charts"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Facts, "pick_bytes"));
    try testing.expectEqual(@as(usize, 24), @sizeOf(State));
    try testing.expectEqual(@as(usize, 12), @offsetOf(State, "order_charts"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(State, "order_bytes"));
}

test "two reads of the same facts match byte for byte" {
    var a: State = undefined;
    var b: State = undefined;
    @memset(std.mem.asBytes(&a), 0xAA);
    @memset(std.mem.asBytes(&b), 0xAA);
    const facts: Facts = .{ .catalog_ready = 1, .picked = 1, .nothing_to_draw = 1, .pick_charts = 3, .pick_bytes = 9000 };
    var one: Setup = .{};
    one.note(facts);
    _ = one.act(.begin, @intFromEnum(Step.coverage));
    Setup.read(&one, &a);
    var two: Setup = .{};
    two.note(facts);
    _ = two.act(.begin, @intFromEnum(Step.coverage));
    Setup.read(&two, &b);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
    // The two bytes between saw_work and order_charts.
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, std.mem.asBytes(&a)[10..12]);
}
