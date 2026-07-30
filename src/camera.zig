//! Camera math in web-mercator [0,1] space (the tile57 GPU scene's world
//! space). The camera is NEVER baked into vertex data; every frame we
//! rebuild a single MVP from the camera state and hand it to the vertex shader.
//! Geometry is stored camera-relative to a fixed `origin` so f32 precision holds
//! even when zoomed into a harbor.
const std = @import("std");

pub const Vec2 = struct { x: f64, y: f64 };

/// Wrap a world x into [0,1) — longitude is cyclic (the antimeridian).
pub fn wrapX(x: f64) f64 {
    return x - std.math.floor(x);
}

/// The SHORT-WAY difference a - b of two world x's, in [-0.5, 0.5): the delta
/// that crosses the antimeridian when that is nearer.
pub fn wrapDx(a: f64, b: f64) f64 {
    const d = a - b;
    return d - std.math.round(d);
}

/// lon/lat (degrees) -> normalized web-mercator [0,1], y down.
pub fn lonLatToWorld(lon: f64, lat: f64) Vec2 {
    const x = wrapX((lon + 180.0) / 360.0);
    const s = std.math.sin(lat * std.math.pi / 180.0);
    const y = 0.5 - std.math.log(f64, std.math.e, (1.0 + s) / (1.0 - s)) / (4.0 * std.math.pi);
    return .{ .x = x, .y = y };
}

/// normalized world [0,1] -> lon/lat degrees ([-180, 180)).
pub fn worldToLonLat(w: Vec2) Vec2 {
    const lon = wrapX(w.x) * 360.0 - 180.0;
    const n = std.math.pi - 2.0 * std.math.pi * w.y;
    const lat = (180.0 / std.math.pi) * std.math.atan(0.5 * (std.math.exp(n) - std.math.exp(-n)));
    return .{ .x = lon, .y = lat };
}

pub const Camera = struct {
    origin: Vec2, // fixed reference point (build view center) in world [0,1]
    center: Vec2, // current view center in world [0,1]
    zoom: f64, // fractional web-mercator zoom
    rotation: f64 = 0, // view rotation, radians CW (course-up); 0 = north-up
    vw: f32, // viewport width px
    vh: f32, // viewport height px
    min_zoom: f64 = 0, // clamp range (the chart's own zoom band)
    max_zoom: f64 = 24,

    // ---- animation state (advanced by tick each frame) ----
    /// The zoom `zoom` eases toward; wheel/pinch set this, not `zoom` directly, so
    /// a small scroll animates instead of snapping. Keep in sync with `zoom` when
    /// the view is set programmatically (setTarget).
    target_zoom: f64 = 0,
    zfocus: Vec2 = .{ .x = 0, .y = 0 }, // world point kept under the cursor while zooming
    zfx: f32 = 0, // cursor px the zoom pivots about
    zfy: f32 = 0,
    vel_x: f64 = 0, // fling velocity, logical px/sec (decays each tick)
    vel_y: f64 = 0,

    /// px-per-world-unit at the current zoom (256 px per tile).
    pub fn worldToPx(self: Camera) f64 {
        return 256.0 * std.math.pow(f64, 2.0, self.zoom);
    }

    /// Keep the viewport on the map vertically: y clamps so the view can't
    /// scroll past the mercator top/bottom (x, by contrast, wraps). When the
    /// whole world is shorter than the viewport, center it.
    pub fn clampY(self: *Camera) void {
        const hh = @as(f64, self.vh) * 0.5 / self.worldToPx();
        self.center.y = if (hh >= 0.5) 0.5 else std.math.clamp(self.center.y, hh, 1.0 - hh);
    }

    /// Column-major mat4 mapping camera-relative world (world - origin, as f32)
    /// to Vulkan clip space: translate to center, rotate (course-up), scale to
    /// clip, flip y. Small (world-origin) values keep f32 exact.
    pub fn mvp(self: Camera) [16]f32 {
        return self.mvpOrigin(self.origin);
    }

    /// Like mvp() but for geometry stored relative to an arbitrary `origin`
    /// (each cached tile stores its verts relative to its own NW corner, so f32
    /// stays exact anywhere on earth).
    pub fn mvpOrigin(self: Camera, origin: Vec2) [16]f32 {
        const s = self.worldToPx();
        const a: f64 = 2.0 * s / @as(f64, self.vw);
        const b: f64 = 2.0 * s / @as(f64, self.vh);
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        const dx = origin.x - self.center.x; // added before rotate/scale
        const dy = origin.y - self.center.y;
        var m = [_]f32{0} ** 16;
        m[0] = @floatCast(a * c);
        m[1] = @floatCast(-b * sn);
        m[4] = @floatCast(-a * sn);
        m[5] = @floatCast(-b * c);
        m[10] = 0.0;
        m[12] = @floatCast(a * (c * dx - sn * dy));
        m[13] = @floatCast(-b * (sn * dx + c * dy));
        m[14] = 0.5; // clip z = 0.5 (inside Vulkan [0,1])
        m[15] = 1.0;
        return m;
    }

    /// reference-px -> clip-space delta (for constant-screen-size marks).
    pub fn pxToClip(self: Camera) [2]f32 {
        return .{ 2.0 / self.vw, -2.0 / self.vh };
    }
    /// (sin, cos) of the view rotation, for MAP-aligned marks in the shader.
    pub fn rotSinCos(self: Camera) [2]f32 {
        return .{ @floatCast(std.math.sin(self.rotation)), @floatCast(std.math.cos(self.rotation)) };
    }

    /// screen px (y down, origin top-left) -> world (x wrapped to [0,1)),
    /// rotation-aware.
    pub fn screenToWorld(self: Camera, px: f32, py: f32) Vec2 {
        const s = self.worldToPx();
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        const ex = (@as(f64, px) - @as(f64, self.vw) * 0.5);
        const ey = (@as(f64, py) - @as(f64, self.vh) * 0.5);
        // inverse rotation R(-theta)
        const wx = (c * ex + sn * ey) / s;
        const wy = (-sn * ex + c * ey) / s;
        return .{ .x = wrapX(self.center.x + wx), .y = self.center.y + wy };
    }

    /// world [0,1] -> screen px (rotation-aware). The x delta takes the SHORT
    /// way around the antimeridian, so a feature just across the seam maps to
    /// the near instance instead of a world-width away.
    pub fn worldToScreen(self: Camera, w: Vec2) Vec2 {
        const s = self.worldToPx();
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        const rx = wrapDx(w.x, self.center.x) * s;
        const ry = (w.y - self.center.y) * s;
        return .{
            .x = (c * rx - sn * ry) + @as(f64, self.vw) * 0.5,
            .y = (sn * rx + c * ry) + @as(f64, self.vh) * 0.5,
        };
    }

    /// Zoom by dz keeping the world point under (px,py) fixed on screen.
    pub fn zoomAbout(self: *Camera, dz: f64, px: f32, py: f32) void {
        const before = self.screenToWorld(px, py);
        self.zoom = std.math.clamp(self.zoom + dz, self.min_zoom, self.max_zoom);
        const after = self.screenToWorld(px, py);
        self.center.x = wrapX(self.center.x + wrapDx(before.x, after.x));
        self.center.y += before.y - after.y;
        self.clampY();
    }

    // Animation time constants (seconds).
    const ZOOM_TAU = 0.085; // zoom ease — small enough to feel immediate, smooth
    const FLING_TAU = 0.32; // fling decay
    const FLING_MIN = 12.0; // px/s: below this the fling stops

    /// Pin `target_zoom` to `zoom` — call after a programmatic view set so the
    /// next scroll eases from the actual zoom, not a stale target.
    pub fn setTarget(self: *Camera) void {
        self.target_zoom = self.zoom;
        self.vel_x = 0;
        self.vel_y = 0;
    }

    /// Request a zoom of `dz` about (px,py): eases there over the next frames,
    /// keeping the world point under the cursor fixed the whole way.
    pub fn zoomToward(self: *Camera, dz: f64, px: f32, py: f32) void {
        self.target_zoom = std.math.clamp(self.target_zoom + dz, self.min_zoom, self.max_zoom);
        self.zfocus = self.screenToWorld(px, py);
        self.zfx = px;
        self.zfy = py;
    }

    /// Begin a fling with the given logical-px/sec velocity (0,0 stops one).
    pub fn flingStart(self: *Camera, vx: f64, vy: f64) void {
        self.vel_x = vx;
        self.vel_y = vy;
    }

    /// True while a zoom ease or fling is still in progress.
    pub fn animating(self: Camera) bool {
        return @abs(self.target_zoom - self.zoom) > 1e-4 or
            @abs(self.vel_x) > FLING_MIN or @abs(self.vel_y) > FLING_MIN;
    }

    /// Advance the zoom ease and fling by `dt` seconds.
    pub fn tick(self: *Camera, dt: f64) void {
        if (@abs(self.target_zoom - self.zoom) > 1e-4) {
            const k = 1.0 - @exp(-dt / ZOOM_TAU);
            self.zoom += (self.target_zoom - self.zoom) * k;
            if (@abs(self.target_zoom - self.zoom) < 1e-4) self.zoom = self.target_zoom;
            // Keep the pivot world point under its cursor px as the zoom changes.
            const after = self.screenToWorld(self.zfx, self.zfy);
            self.center.x = wrapX(self.center.x + wrapDx(self.zfocus.x, after.x));
            self.center.y += self.zfocus.y - after.y;
            self.clampY();
        }
        if (@abs(self.vel_x) > FLING_MIN or @abs(self.vel_y) > FLING_MIN) {
            self.panPx(@floatCast(self.vel_x * dt), @floatCast(self.vel_y * dt));
            const decay = @exp(-dt / FLING_TAU);
            self.vel_x *= decay;
            self.vel_y *= decay;
        } else {
            self.vel_x = 0;
            self.vel_y = 0;
        }
    }

    /// Pan by a screen-px delta (rotation-aware). x wraps at the antimeridian.
    pub fn panPx(self: *Camera, dx: f32, dy: f32) void {
        const s = self.worldToPx();
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        // move the world opposite the drag, un-rotating the screen delta
        self.center.x = wrapX(self.center.x - (c * @as(f64, dx) + sn * @as(f64, dy)) / s);
        self.center.y -= (-sn * @as(f64, dx) + c * @as(f64, dy)) / s;
        self.clampY();
    }

    /// Viewport half-extents in world units at the current zoom. The extents
    /// are those of the AXIS-ALIGNED box that holds the rotated viewport: a
    /// turned view reaches past its own width and height, and a scene built to
    /// the width and height alone leaves the corners empty.
    pub fn halfExtents(self: Camera) Vec2 {
        const wp = self.worldToPx();
        const ext = rotatedExtent(@as(f64, self.vw), @as(f64, self.vh), self.rotation);
        return .{ .x = ext[0] * 0.5 / wp, .y = ext[1] * 0.5 / wp };
    }

    /// The S-52 display-scale denominator (1:N) for the current view — used to
    /// gate SCAMIN per frame. Standard web-mercator scale at 96dpi, latitude
    /// adjusted. Not exact vs the engine's cutoff (prototype); tune C if needed.
    pub fn displayScale(self: Camera) f32 {
        return displayScaleAt(self.zoom, worldToLonLat(self.center).y);
    }
};

/// The width and height of the axis-aligned box that holds a `w` x `h`
/// viewport turned by `rotation` radians. At 45 degrees a square viewport needs
/// a box 1.41 times its side.
pub fn rotatedExtent(w: f64, h: f64, rotation: f64) [2]f64 {
    const c = @abs(std.math.cos(rotation));
    const s = @abs(std.math.sin(rotation));
    return .{ c * w + s * h, s * w + c * h };
}

/// S-52 display-scale denominator (1:N) for a zoom + latitude (degrees).
pub fn displayScaleAt(zoom: f64, lat_deg: f64) f32 {
    const C: f64 = 559082264.029; // OSM scale denom at z0, equator, 96dpi
    return @floatCast(C * std.math.cos(lat_deg * std.math.pi / 180.0) / std.math.pow(f64, 2.0, zoom));
}

// Zoom-to-cursor: the world point under a screen point stays under it across a
// zoom. This is the anchor math both platforms share (macOS wheel/pinch, iOS
// pinch/double-tap all funnel through zoomAbout) — so it verifies "zoom to
// cursor" deterministically, no UI or GPU.
test "zoomAbout keeps the point under the cursor fixed" {
    const std_testing = std.testing;
    const origin = lonLatToWorld(-76.48, 38.98);
    inline for (.{ .{ 300.0, 200.0, 2.0 }, .{ 1180.0, 60.0, 1.3 }, .{ 20.0, 860.0, -1.7 } }) |cfg| {
        const px: f32 = cfg[0];
        const py: f32 = cfg[1];
        const dz: f64 = cfg[2];
        var cam = Camera{ .origin = origin, .center = origin, .zoom = 12, .target_zoom = 12, .vw = 1200, .vh = 900, .min_zoom = 2, .max_zoom = 22 };
        const w_before = cam.screenToWorld(px, py);
        cam.zoomAbout(dz, px, py);
        const w_after = cam.screenToWorld(px, py);
        // Same world point under the same screen point, to sub-pixel world units.
        try std_testing.expectApproxEqAbs(w_before.x, w_after.x, 1e-9);
        try std_testing.expectApproxEqAbs(w_before.y, w_after.y, 1e-9);
    }
}

// A rotated view reaches past its own width and height. The scene is built
// axis-aligned in world space, so the corners of a turned viewport fell outside
// the build and drew as empty wedges.
test "halfExtents holds the corners of a rotated viewport" {
    const std_testing = std.testing;
    const origin = lonLatToWorld(-76.48, 38.98);
    const vw: f32 = 1264;
    const vh: f32 = 730;
    inline for (.{ 0.0, 30.0, 45.0, 90.0, 137.0, 215.0 }) |deg| {
        var cam = Camera{
            .origin = origin,
            .center = origin,
            .zoom = 13.7,
            .target_zoom = 13.7,
            .rotation = deg * std.math.pi / 180.0,
            .vw = vw,
            .vh = vh,
            .min_zoom = 2,
            .max_zoom = 22,
        };
        const he = cam.halfExtents();
        inline for (.{ .{ 0.0, 0.0 }, .{ 1264.0, 0.0 }, .{ 0.0, 730.0 }, .{ 1264.0, 730.0 } }) |corner| {
            const px: f32 = corner[0];
            const py: f32 = corner[1];
            const w = cam.screenToWorld(px, py);
            try std_testing.expect(@abs(w.x - cam.center.x) <= he.x + 1e-9);
            try std_testing.expect(@abs(w.y - cam.center.y) <= he.y + 1e-9);
        }
    }
}
