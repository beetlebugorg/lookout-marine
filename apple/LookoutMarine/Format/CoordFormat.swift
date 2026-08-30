//  CoordFormat.swift — the strings every shell prints.
//
//  A position, a scale and a scale band are read off four platforms and have to
//  read the same on all of them. This is the Apple side of that contract; the
//  others are `lkw::FormatCoord` and `lkw::BandForDenom`
//  (windows/src/lk_format.cpp), `lk_coord_format_dm` (linux/src/lk-hud.c) and
//  `dm` in Hud.kt (Android).
//
//  Nothing here touches the engine or a view, so it is checked directly. See
//  CoordFormatTests.

import Foundation

/// Readout formatting for both platforms. It agrees with `lkw::FormatCoord` and
/// `lkw::BandForDenom` (windows/src/lk_format.cpp), `lk_coord_format_dm`
/// (linux/src/lk-hud.c) and Hud.kt (Android). Each host prints the same string.
enum CoordFormat {
    /// Degrees and DECIMAL MINUTES with a hemisphere: `38°58.580'N`. The
    /// longitude has three degree digits, so a pair keeps its column width.
    ///
    /// WHY NOT DEGREES, MINUTES AND SECONDS. Decimal minutes is what a mariner
    /// works in: it is what a GPS and a chartplotter show, what goes in the
    /// deck log, and what is passed over the radio. One minute of latitude is
    /// one nautical mile, so a decimal minute reads as distance directly —
    /// 0.1' is a cable. Seconds break that and belong to surveying.
    ///
    /// Three decimals is about 1.9 m, finer than any chart's own accuracy.
    static func dm(_ value: Double, isLat: Bool) -> String {
        let hemi = isLat ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W")
        let a = abs(value)
        var deg = Int(a)
        var mins = (a - Double(deg)) * 60
        // Carry the rounding. 59.9996' prints as 60.000', which is the next degree.
        if (mins * 1000).rounded() >= 60_000 { mins = 0; deg += 1 }
        return String(format: isLat ? "%02d°%06.3f'%@" : "%03d°%06.3f'%@",
                      deg, mins, hemi)
    }

    /// A full position: `38°58.580'N 076°28.920'W`.
    static func position(lat: Double, lon: Double) -> String {
        "\(dm(lat, isLat: true)) \(dm(lon, isLat: false))"
    }

    /// OWN SHIP's position, or nothing at all.
    ///
    /// Never the map centre and never the cursor. A coordinate with no boat
    /// behind it is the ambiguity the readout exists to remove, and the caller
    /// hands nil for every state but a live fix. The coordinates of a PLACE
    /// come from the chart menu, on demand, at the point the mariner asked
    /// about.
    static func ownShip(lat: Double?, lon: Double?) -> String {
        guard let lat, let lon else { return "" }
        return position(lat: lat, lon: lon)
    }

    /// The full scale with group separators, as in the WinUI 3 shell: `1:13,267`.
    static func scale(_ denominator: Double) -> String {
        guard denominator > 0 else { return "1:—" }
        return "1:\(Int(denominator.rounded()).formatted(.number))"
    }

    /// The S-52 navigational purpose band for a display scale.
    static func band(_ denominator: Double) -> String {
        switch denominator {
        case ..<0.001:      return "—"
        case ..<5_000:      return "Berthing"
        case ..<25_000:     return "Harbor"
        case ..<75_000:     return "Approach"
        case ..<300_000:    return "Coastal"
        case ..<1_500_000:  return "General"
        default:            return "Overview"
        }
    }
}
