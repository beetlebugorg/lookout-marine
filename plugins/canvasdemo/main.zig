//! Canvasdemo: a wind bezel around own ship, drawn with the canvas API.
//!
//! The canvas feature's worked example: a ring with an open window in the
//! middle so the boat and the chart under it stay visible, tick marks and
//! bold cardinal letters on the band, a pointer riding the band where the
//! true wind blows from, and a text readout on a plate under the ring. The
//! band is a thick stroked circle because canvas fills carry no holes; the
//! library gates the draw on fresh wind and position, and the whole ring
//! rides own ship's display position between fixes.
//!
//! It is also the worked example for the two alignments. The card turns with
//! the chart, so its N points at true north like a real rose; the readout is
//! screenAligned, so the plate and the number stay level and readable however
//! far the mariner has turned the view.

const std = @import("std");
const lk = @import("lk2");

comptime {
    lk.plugin(@This());
}

pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
};

/// Outer and inner radius of the band, screen points. The canvas is
/// points-at-anchor, so the ring holds this size at every zoom; everything
/// inside `r0` is open water and boat.
const R = 68.0;
const r0 = 42.0;

pub fn draw(c: *lk.Chart) void {
    const at = inputs.boat.get();
    const twd = lk.normalizeDeg(inputs.twd.get());

    var cv = c.canvas("winddial", .{ .at = at, .anchor = .ownship, .space = .points });

    // The band: one flat translucent plate with the middle open, a thick
    // stroked circle because canvas fills carry no holes. Flat, not shaded:
    // an instrument reads as chrome, not as a charted feature.
    cv.strokeStyle(.{ .rgba = .{ 0.94, 0.96, 0.98, 0.88 } });
    cv.lineWidth(R - r0);
    cv.beginPath();
    cv.arc(0, 0, (R + r0) / 2, 0, 360, false);
    cv.stroke();

    // The band's two edges, hairline.
    cv.strokeStyle(.{ .rgba = .{ 0.35, 0.41, 0.49, 0.9 } });
    cv.lineWidth(1);
    cv.beginPath();
    cv.arc(0, 0, R, 0, 360, false);
    cv.stroke();
    cv.beginPath();
    cv.arc(0, 0, r0, 0, 360, false);
    cv.stroke();

    // Ticks on the band: majors every 30 degrees, minors every 10.
    cv.strokeStyle(.{ .rgba = .{ 0.20, 0.26, 0.34, 0.9 } });
    cv.lineWidth(2);
    cv.beginPath();
    ticks(&cv, 30, r0 + 4, false);
    cv.stroke();
    cv.lineWidth(1);
    cv.beginPath();
    ticks(&cv, 10, R - 12, true);
    cv.stroke();

    // Cardinal letters and degree numerals on the band, centred between its
    // edges. Numerals sit at the 30 degree steps the cardinals do not take.
    cv.fillStyle(.{ .rgba = .{ 0.12, 0.16, 0.22, 1 } });
    cv.font(13, .bold);
    cv.textAlign(.center);
    const mid = (R + r0) / 2;
    cv.fillText("N", 0, -mid + 5);
    cv.fillText("E", mid, 5);
    cv.fillText("S", 0, mid + 5);
    cv.fillText("W", -mid, 5);

    // 10 pt regular is the floor for on-chart text at 1x: below that the
    // stems go sub-pixel and the numerals read as ghosts.
    cv.font(10, .regular);
    var deg: f64 = 30;
    while (deg < 360) : (deg += 30) {
        if (@mod(deg, 90.0) == 0) continue;
        const rad = std.math.degreesToRadians(deg);
        var nbuf: [4]u8 = undefined;
        const n = std.fmt.bufPrint(&nbuf, "{d:0>3.0}", .{deg}) catch continue;
        cv.fillText(n, @sin(rad) * mid, -@cos(rad) * mid + 3);
    }

    // The pointer rides the band where the wind blows FROM: apex at the
    // inner edge, base at the outer, on the recorded rotation. The window
    // stays clear; there is no hub and no needle across the boat.
    cv.save();
    cv.rotate(twd);
    cv.fillStyle(.{ .linear = .{ .from = .{ 0, -(R - 4) }, .to = .{ 0, -(r0 + 2) }, .stops = &.{
        .{ .t = 0, .color = .{ .rgba = .{ 0.45, 0.09, 0.09, 0.9 } } },
        .{ .t = 1, .color = .{ .token = .target_danger } },
    } } });
    cv.beginPath();
    cv.moveTo(0, -(r0 + 2));
    cv.lineTo(6, -(R - 4));
    cv.lineTo(-6, -(R - 4));
    cv.closePath();
    cv.fill();
    cv.restore();

    // The readout, under the ring: a plate and the number on it, both held
    // LEVEL ON SCREEN. Everything above turns with the chart because that is
    // what a rose does — north stays north. A number that turns with it goes
    // on its side and stops being a number, so screenAligned turns the frame
    // back for the plate and the text together, and save/restore keeps that
    // to this run.
    var buf: [16]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "TWD {d:0>3.0}", .{twd}) catch "TWD ---";
    cv.save();
    cv.screenAligned(true);
    cv.fillStyle(.{ .rgba = .{ 0.94, 0.96, 0.98, 0.88 } });
    cv.strokeStyle(.{ .rgba = .{ 0.35, 0.41, 0.49, 0.9 } });
    cv.lineWidth(1);
    plate(&cv);
    cv.fill();
    cv.stroke();
    cv.fillStyle(.{ .rgba = .{ 0.12, 0.16, 0.22, 1 } });
    cv.font(12, .regular);
    cv.fillText(label, 0, R + 19);
    cv.restore();

    cv.done();
    c.status("wind dial: TWD {d:.0}", .{twd});
}

/// The readout plate: a rounded rectangle under the ring, left as the current
/// path so the caller fills it and strokes its edge from the one recording.
fn plate(cv: *lk.Canvas) void {
    const x0 = -36.0;
    const y0 = R + 4;
    const x1 = 36.0;
    const y1 = R + 26;
    const r = 4.0;
    cv.beginPath();
    cv.moveTo(x0 + r, y0);
    cv.lineTo(x1 - r, y0);
    cv.quadTo(x1, y0, x1, y0 + r);
    cv.lineTo(x1, y1 - r);
    cv.quadTo(x1, y1, x1 - r, y1);
    cv.lineTo(x0 + r, y1);
    cv.quadTo(x0, y1, x0, y1 - r);
    cv.lineTo(x0, y0 + r);
    cv.quadTo(x0, y0, x0 + r, y0);
    cv.closePath();
}

/// One tick line per `step_deg`, from radius R in to `inner`, as subpaths of
/// the open path. `skip_major` leaves out the positions the major pass drew.
fn ticks(cv: *lk.Canvas, step_deg: f64, inner: f64, skip_major: bool) void {
    var deg: f64 = 0;
    while (deg < 360) : (deg += step_deg) {
        if (skip_major and @mod(deg, 30.0) == 0) continue;
        const rad = std.math.degreesToRadians(deg);
        const sx = @sin(rad);
        const cy = -@cos(rad); // 0 degrees is north, and y runs down
        cv.moveTo(sx * (R - 2), cy * (R - 2));
        cv.lineTo(sx * inner, cy * inner);
    }
}
