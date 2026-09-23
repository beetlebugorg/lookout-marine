//  CoordFormat.swift: the strings the readouts and the chart panels print.
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

    /// The scale at the width a phone has for it: `1:4.80M` from 1,000,000
    /// up, the full number below that.
    ///
    /// The readouts do not fit one line on a phone once the denominator runs
    /// to seven digits, and the row then falls to two lines.
    static func scaleCompact(_ denominator: Double) -> String {
        coreString(LOOKOUT_SCALE_MAX) { lookout_fmt_scale_compact(denominator, $0, $1) }
    }

    /// A position at two decimals of minutes: `38°58.58'N 076°28.57'W`, for
    /// a phone's row.
    static func positionCompact(lat: Double, lon: Double) -> String {
        coreString(LOOKOUT_POSITION_MAX) { lookout_fmt_position_compact(lat, lon, $0, $1) }
    }

    /// The S-52 navigational purpose band for a display scale.
    static func band(_ denominator: Double) -> String {
        String(cString: lookout_band_name(denominator))
    }
}

/// Sizes, counts, times, depths and usage bands, from the core's format kit.
enum TextFormat {
    /// A size in megabytes or gigabytes: `226.5 MB`, `1.23 GB`.
    static func bytes(_ bytes: UInt64) -> String {
        coreString(LOOKOUT_BYTES_MAX) { lookout_fmt_bytes(bytes, $0, $1) }
    }

    /// A count grouped in threes: `7,214`.
    static func count<T: BinaryInteger>(_ n: T) -> String {
        coreString(LOOKOUT_COUNT_MAX) { lookout_fmt_count(UInt64(clamping: n), $0, $1) }
    }

    /// A countdown on a running job: `about 3 min left`.
    static func timeLeft(_ seconds: Double) -> String {
        coreString(LOOKOUT_DURATION_MAX) {
            lookout_fmt_duration(seconds, Int32(LOOKOUT_DURATION_LEFT), $0, $1)
        }
    }

    /// An estimate before a job starts: `about 3 minutes`.
    static func about(_ seconds: Double) -> String {
        coreString(LOOKOUT_DURATION_MAX) {
            lookout_fmt_duration(seconds, Int32(LOOKOUT_DURATION_ABOUT), $0, $1)
        }
    }

    /// A depth given in metres, in the unit on screen: `5 m`, `12 ft`. With
    /// `bare`, the number alone.
    static func depth(_ metres: Double, feet: Bool, bare: Bool = false) -> String {
        let unit = (feet ? LOOKOUT_DEPTH_FEET : LOOKOUT_DEPTH_METRES)
            | (bare ? LOOKOUT_DEPTH_BARE : 0)
        return coreString(LOOKOUT_DEPTH_MAX) { lookout_fmt_depth(metres, Int32(unit), $0, $1) }
    }

    /// The name of an S-57 usage band, 1 to 6.
    static func usageBand(_ band: Int) -> String {
        String(cString: lookout_usage_band_name(Int32(clamping: band)))
    }
}
