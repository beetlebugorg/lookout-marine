//
//  The instruments beside the chart.
//
//  A chart table has the boat's instruments next to it, and this is that row:
//  where the boat is, what it is doing, and what the chart under it is showing.
//
//  Position comes from own ship's overlay object rather than lookout_own_ship,
//  which can still be answering no while the boat is drawn. Speed, course and
//  heading come from the payload the own ship plugin publishes on that same
//  object, so every number here is what drew the boat.
//

import Foundation

struct Readouts {
    var position: String = ""
    var sog: String = ""
    var cog: String = ""
    var heading: String = ""
    var scale: String = ""
    /// Set while the chart is drawn past the scale its data supports.
    var overscaled = false

    var hasFix: Bool { !position.isEmpty }

    init() {}

    /// Degrees and decimal minutes, which is what a mariner reads off a GPS
    /// and writes in a log.
    static func latLon(lon: Double, lat: Double) -> String {
        func part(_ v: Double, _ positive: String, _ negative: String, degreeWidth: Int) -> String {
            let d = abs(v)
            let degrees = Int(d)
            let minutes = (d - Double(degrees)) * 60
            let hemisphere = v >= 0 ? positive : negative
            return String(format: "%0\(degreeWidth)d°%06.3f′%@", degrees, minutes, hemisphere)
        }
        return part(lat, "N", "S", degreeWidth: 2) + "  " + part(lon, "E", "W", degreeWidth: 3)
    }
}
