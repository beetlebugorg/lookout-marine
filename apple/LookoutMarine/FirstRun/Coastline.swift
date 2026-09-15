//  Coastline.swift: the coastline the coverage picker draws.
//
//  Baked from vendor/gshhg/coastline.geojson.gz, the same GSHHG data the
//  engine's basemap is baked from, clipped to the waters the picker shows and
//  simplified to 0.02 degrees. Coastline.bin holds it.
//
//  The picker draws this rather than photographing the chart. A picture of the
//  chart has to be taken at a view the camera has visited, because tiles load
//  on the frame loop, and it then needs the projection it was taken under
//  carried alongside it. This is a static array and a projection the picker
//  owns, so it draws the same on the first frame every time.

import CoreGraphics
import Foundation

enum Coastline {
    /// GSHHG level: land is 1 and a lake is 2. A lake is its own polygon
    /// rather than a hole, so it draws over the land.
    struct Ring {
        let level: UInt8
        let points: [CGPoint]   // x is longitude, y is latitude
    }

    /// Read once, on first use.
    static let rings: [Ring] = load()

    private static func load() -> [Ring] {
        guard let url = Bundle.main.url(forResource: "Coastline", withExtension: "bin"),
              let data = try? Data(contentsOf: url), data.count >= 4 else {
            lkLog("coverage map: Coastline.bin is missing")
            return []
        }
        return data.withUnsafeBytes { raw -> [Ring] in
            var at = 0
            func u32() -> UInt32? {
                guard at + 4 <= raw.count else { return nil }
                defer { at += 4 }
                return raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)
            }
            func u8() -> UInt8? {
                guard at + 1 <= raw.count else { return nil }
                defer { at += 1 }
                return raw.loadUnaligned(fromByteOffset: at, as: UInt8.self)
            }
            func f32() -> Float? {
                guard at + 4 <= raw.count else { return nil }
                defer { at += 4 }
                return raw.loadUnaligned(fromByteOffset: at, as: Float.self)
            }
            guard let count = u32() else { return [] }
            var out: [Ring] = []
            out.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let level = u8(), let n = u32() else { break }
                var pts: [CGPoint] = []
                pts.reserveCapacity(Int(n))
                var ok = true
                for _ in 0..<n {
                    guard let x = f32(), let y = f32() else { ok = false; break }
                    pts.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                }
                if !ok { break }
                out.append(Ring(level: level, points: pts))
            }
            return out
        }
    }
}


/// A lon/lat window, and the flat rectangle it draws into.
///
/// Mercator, the projection the chart draws, so a coastline here has the
/// shape a mariner sees on the chart.
///
/// Longitude maps straight through. Wrapping it put every point west of the
/// window far to the east, which drew a ring that leaves the frame as a band
/// across the whole map.
struct MapWindow {
    let west, east, south, north: Double

    var lonSpan: Double { east - west }

    /// Width over height for this window.
    var aspect: CGFloat {
        let h = Self.mercator(north) - Self.mercator(south)
        guard h > 0 else { return 1 }
        return CGFloat(lonSpan * .pi / 180 / h)
    }

    func point(lon: Double, lat: Double, in size: CGSize) -> CGPoint {
        let top = Self.mercator(north), bottom = Self.mercator(south)
        let h = top - bottom
        let dy = h == 0 ? 0 : (top - Self.mercator(lat)) / h
        return CGPoint(x: (lon - west) / lonSpan * size.width, y: dy * size.height)
    }

    /// True when any part of this box reaches into the window.
    func intersects(west w: Double, east e: Double,
                    south s: Double, north n: Double) -> Bool {
        e >= west && w <= east && n >= south && s <= north
    }

    /// Mercator y, clamped clear of the poles.
    static func mercator(_ lat: Double) -> Double {
        let phi = max(-85.05, min(85.05, lat)) * .pi / 180
        return log(tan(.pi / 4 + phi / 2))
    }
}
