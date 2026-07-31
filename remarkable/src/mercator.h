// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// Web-Mercator math for the tile pyramid, in THE CORE'S zoom convention.
//
// The core's camera (src/camera.zig) and every zoom that crosses lookout.h use
// a 256-px world tile: the whole earth is 256 * 2^zoom pixels across, which is
// the convention behind its 1:N display scale (559082264.029 at z0, 96 dpi).
// The pyramid below paints 512-px tiles, so at core zoom Z the world is
// 2^(Z-1) tiles across and a tile is exactly the 512-px view at core zoom Z
// centred on it — tile-aligned and seamless with its neighbours.
//
// Getting this wrong is an off-by-one-level bug that still LOOKS like a chart,
// so the two are named apart everywhere below: `zoom` is always the core's,
// `level` is always the pyramid's, and tileLevel()/coreZoom() convert.
//
// The camera itself lives in the core — lookout_pan, lookout_zoom_at and
// lookout_screen_to_geo own it. What is left here is what the core has no
// reason to know: which tiles cover the viewport, and what the scale reads as
// on a physical panel.

#include <cmath>

namespace merc {

inline constexpr double kTilePx = 512.0;    // one pyramid tile
inline constexpr double kWorldPxZ0 = 256.0; // the core's world tile
inline constexpr double kPi = 3.14159265358979323846;
inline constexpr double kEquatorM = 40075016.686;

struct PixelPoint {
    double x = 0.0;
    double y = 0.0;
};

struct LonLat {
    double lon = 0.0;
    double lat = 0.0;
};

// The pyramid level that paints at a core zoom, and back. A 512-px tile covers
// twice the ground of the core's 256-px world tile, so it sits one level up.
inline int tileLevel(int coreZoom) { return coreZoom - 1; }
inline int coreZoom(int tileLevel) { return tileLevel + 1; }

// World size in pixels (whole earth) at a fractional CORE zoom.
inline double worldSize(double zoom) {
    return kWorldPxZ0 * std::pow(2.0, zoom);
}

// The fractional (0..1) vertical mercator position of a latitude — zoom
// independent, so a latitude *span* is (yFraction(n) - yFraction(s)).
inline double yFraction(double latDeg) {
    double lat = latDeg * kPi / 180.0;
    double s = std::sin(lat);
    if (s > 0.99999) s = 0.99999;
    if (s < -0.99999) s = -0.99999;
    return 0.5 - std::log((1.0 + s) / (1.0 - s)) / (4.0 * kPi);
}

inline PixelPoint project(const LonLat& ll, double zoom) {
    const double size = worldSize(zoom);
    return {
        (ll.lon + 180.0) / 360.0 * size,
        yFraction(ll.lat) * size,
    };
}

inline LonLat unproject(const PixelPoint& p, double zoom) {
    const double size = worldSize(zoom);
    const double lon = p.x / size * 360.0 - 180.0;
    const double n = kPi - 2.0 * kPi * p.y / size;
    const double lat = 180.0 / kPi * std::atan(std::sinh(n));
    return {lon, lat};
}

// The centre of pyramid tile (level, x, y) — the point to render its view at.
inline LonLat tileCenter(int level, int x, int y) {
    const double z = coreZoom(level);
    return unproject({(double(x) + 0.5) * kTilePx, (double(y) + 0.5) * kTilePx}, z);
}

// How many tiles span the world at a pyramid level.
inline int tilesAcross(int level) {
    return level <= 0 ? 1 : (1 << level);
}

// Ground metres per screen pixel at the view centre.
inline double metresPerPixel(double zoom, double latDeg) {
    return kEquatorM * std::cos(latDeg * kPi / 180.0) / worldSize(zoom);
}

// The "ruler on the glass" scale denominator: 1:N as it measures on a panel of
// a given physical pixel pitch (mm).
//
// NOT the same number as lookout_scale_denominator, and deliberately so: the
// core's is the S-52 DISPLAY scale, fixed at 96 dpi, because that is what SCAMIN
// and the overscale indicator are defined against. The reMarkable's panel is
// ~226 dpi, so a chart feature measures about 2.35x smaller on the glass than
// the S-52 number says. The HUD shows this one, because it is the one a divider
// on the screen would agree with.
inline double scaleDenominatorPhysical(double zoom, double latDeg, double pixelPitchMm) {
    const double mPerPx = metresPerPixel(zoom, latDeg);
    return mPerPx / (pixelPitchMm / 1000.0);
}

} // namespace merc
