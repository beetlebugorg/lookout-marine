//! Camera math in web-mercator [0,1] space (the Surface interface's world space —
//! see NOTES.md §4). The camera is NEVER baked into vertex data; every frame we
//! rebuild a single MVP from the camera state and hand it to the vertex shader.
//! Geometry is stored camera-relative to a fixed `origin` so f32 precision holds
//! even when zoomed into a harbor.
const std = @import("std");

pub const Vec2 = struct { x: f64, y: f64 };

/// lon/lat (degrees) -> normalized web-mercator [0,1], y down.
pub fn lonLatToWorld(lon: f64, lat: f64) Vec2 {
    const x = (lon + 180.0) / 360.0;
    const s = std.math.sin(lat * std.math.pi / 180.0);
    const y = 0.5 - std.math.log(f64, std.math.e, (1.0 + s) / (1.0 - s)) / (4.0 * std.math.pi);
    return .{ .x = x, .y = y };
}

/// normalized world [0,1] -> lon/lat degrees.
pub fn worldToLonLat(w: Vec2) Vec2 {
    const lon = w.x * 360.0 - 180.0;
    const n = std.math.pi - 2.0 * std.math.pi * w.y;
    const lat = (180.0 / std.math.pi) * std.math.atan(0.5 * (std.math.exp(n) - std.math.exp(-n)));
    return .{ .x = lon, .y = lat };
}

pub const Camera = struct {
    origin: Vec2, // fixed reference point (build view center) in world [0,1]
    center: Vec2, // current view center in world [0,1]
    zoom: f64, // fractional web-mercator zoom
    vw: f32, // viewport width px
    vh: f32, // viewport height px

    /// px-per-world-unit at the current zoom (256 px per tile).
    pub fn worldToPx(self: Camera) f64 {
        return 256.0 * std.math.pow(f64, 2.0, self.zoom);
    }

    /// Column-major mat4 mapping camera-relative world (world - origin, as f32)
    /// to Vulkan clip space. Small (world-origin) values keep f32 exact.
    pub fn mvp(self: Camera) [16]f32 {
        const s = self.worldToPx();
        const sx: f64 = 2.0 * s / @as(f64, self.vw);
        const sy: f64 = -2.0 * s / @as(f64, self.vh); // world y down -> clip y up
        const dx = self.origin.x - self.center.x; // add before scale
        const dy = self.origin.y - self.center.y;
        var m = [_]f32{0} ** 16;
        m[0] = @floatCast(sx);
        m[5] = @floatCast(sy);
        m[10] = 0.0; // z constant
        m[12] = @floatCast(dx * sx);
        m[13] = @floatCast(dy * sy);
        m[14] = 0.5; // put every vertex at clip z = 0.5 (inside Vulkan [0,1])
        m[15] = 1.0;
        return m;
    }

    /// reference-px -> clip-space delta (for constant-screen-size marks).
    pub fn pxToClip(self: Camera) [2]f32 {
        return .{ 2.0 / self.vw, -2.0 / self.vh };
    }

    /// screen px (y down, origin top-left) -> world [0,1].
    pub fn screenToWorld(self: Camera, px: f32, py: f32) Vec2 {
        const s = self.worldToPx();
        return .{
            .x = self.center.x + (@as(f64, px) - @as(f64, self.vw) * 0.5) / s,
            .y = self.center.y + (@as(f64, py) - @as(f64, self.vh) * 0.5) / s,
        };
    }

    /// world [0,1] -> screen px.
    pub fn worldToScreen(self: Camera, w: Vec2) Vec2 {
        const s = self.worldToPx();
        return .{
            .x = (w.x - self.center.x) * s + @as(f64, self.vw) * 0.5,
            .y = (w.y - self.center.y) * s + @as(f64, self.vh) * 0.5,
        };
    }

    /// Zoom by dz keeping the world point under (px,py) fixed on screen.
    pub fn zoomAbout(self: *Camera, dz: f64, px: f32, py: f32) void {
        const before = self.screenToWorld(px, py);
        self.zoom = std.math.clamp(self.zoom + dz, 0.0, 24.0);
        const after = self.screenToWorld(px, py);
        self.center.x += before.x - after.x;
        self.center.y += before.y - after.y;
    }

    /// Pan by a screen-px delta.
    pub fn panPx(self: *Camera, dx: f32, dy: f32) void {
        const s = self.worldToPx();
        self.center.x -= @as(f64, dx) / s;
        self.center.y -= @as(f64, dy) / s;
    }

    /// The S-52 display-scale denominator (1:N) for the current view — used to
    /// gate SCAMIN per frame. Standard web-mercator scale at 96dpi, latitude
    /// adjusted. Not exact vs the engine's cutoff (prototype); tune C if needed.
    pub fn displayScale(self: Camera) f32 {
        const lat = worldToLonLat(self.center).y;
        const C: f64 = 559082264.029; // OSM scale denom at z0, equator, 96dpi
        const denom = C * std.math.cos(lat * std.math.pi / 180.0) / std.math.pow(f64, 2.0, self.zoom);
        return @floatCast(denom);
    }
};
