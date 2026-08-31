//  CoordFormat.swift — the strings the readouts print.
//
//  Wrappers over the core's format kit (lookout-shell.h). See CoordFormatTests.

import Foundation

/// Run one of the core's writers into a buffer of `capacity` bytes.
private func coreString(_ capacity: Int32,
                        _ write: (UnsafeMutablePointer<CChar>, Int) -> Int) -> String {
    var buf = [CChar](repeating: 0, count: Int(capacity))
    return buf.withUnsafeMutableBufferPointer { p in
        let n = write(p.baseAddress!, p.count)
        return String(decoding: UnsafeRawBufferPointer(start: p.baseAddress!, count: n),
                      as: UTF8.self)
    }
}

/// Readout formatting.
enum CoordFormat {
    /// Degrees and decimal minutes with a hemisphere: `38°58.580'N`.
    static func dm(_ value: Double, isLat: Bool) -> String {
        coreString(LOOKOUT_COORD_MAX) {
            lookout_fmt_coord_dm(value, isLat ? 1 : 0, $0, $1)
        }
    }

    /// A full position: `38°58.580'N 076°28.920'W`.
    static func position(lat: Double, lon: Double) -> String {
        coreString(LOOKOUT_POSITION_MAX) { lookout_fmt_position(lat, lon, $0, $1) }
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

    /// The full scale with group separators: `1:13,267`.
    static func scale(_ denominator: Double) -> String {
        coreString(LOOKOUT_SCALE_MAX) { lookout_fmt_scale(denominator, $0, $1) }
    }

    /// The S-52 navigational purpose band for a display scale.
    static func band(_ denominator: Double) -> String {
        String(cString: lookout_band_name(denominator))
    }
}
