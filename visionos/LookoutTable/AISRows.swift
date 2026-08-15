//
//  The AIS plugin's table and overlay payload, read.
//
//  Foundation only, and no RealityKit: this is the part of the traffic layer
//  that can be run and checked away from a headset, and visionos/tests does
//  exactly that against the plugin's real output.
//
//  The shapes both come from the core's ABI:
//
//    rows    {"key":"targets","seq":42,"open":true,
//             "rows":[{"id":"899000101","band":0,"at":[-76.46,38.97],
//                      "cells":["ANNE","899000101",1852,45,6.2,124,585,"alarm"]}]}
//    payload {"title":"...","rows":[["MMSI","899000101"],["SOG","5.1 kn"]]}
//
//  "cells" is one value per declared column in declaration order, and null for
//  a value the plugin never heard.
//

import Foundation

/// One AIS target, as the plugin's table reports it.
struct AISRow: Equatable {
    var mmsi: String
    var name: String
    var lon: Double
    var lat: Double
    var sogMps: Double?
    var cpaM: Double?
    var tcpaS: Double?
    var alarm: Bool

    /// An AIS aid to navigation reports no speed and takes an MMSI in the
    /// 99xxxxxxx block. It is a buoy, not a vessel, and stands still.
    var isAid: Bool { mmsi.hasPrefix("99") }

    /// What the flag over this target says. Name on the first line, then
    /// speed, and the approach when the plugin has called this one a threat.
    ///
    /// Speed is rounded to half a knot and the approach to ten seconds. The
    /// label's text mesh is rebuilt whenever these words change, so a vessel
    /// reporting 6.21 then 6.19 knots would otherwise rebuild it every few
    /// seconds for a difference nobody can read.
    var flagLabel: String {
        var lines = [name]
        if let sog = sogMps, sog > 0.05 {
            let knots = (sog * 1.9438445 * 2).rounded() / 2
            lines.append(String(format: "%.1f kn", knots))
        } else if !isAid {
            lines.append("stopped")
        }
        if alarm, let cpa = cpaM, let tcpa = tcpaS {
            let minutes = (tcpa / 60).rounded()
            lines.append(String(format: "CPA %.0f m in %.0f min", (cpa / 10).rounded() * 10, minutes))
        }
        return lines.joined(separator: "\n")
    }
}

enum AISRows {
    static let plugin = "org.beetlebug.ais"
    static let table = "targets"

    /// The overlay id of a target's symbol. The plugin names it "t" and the
    /// MMSI, and the core namespaces every overlay object by the plugin that
    /// drew it, so the id to ask about is the pair.
    static func overlayID(mmsi: String) -> String { "\(plugin)/t\(mmsi)" }

    /// The declared column order of the AIS targets table.
    private enum Col: Int {
        case name = 0, mmsi, range, brg, sog, cpa, tcpa, state
    }

    /// Every locatable target in a rows payload. A row without a position
    /// cannot be placed on a sheet and is dropped.
    static func decode(_ data: Data) -> [AISRow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["rows"] as? [[String: Any]]
        else { return [] }
        var out: [AISRow] = []
        out.reserveCapacity(rows.count)
        for r in rows {
            guard let cells = r["cells"] as? [Any] else { continue }
            func cell(_ c: Col) -> Any? {
                let i = c.rawValue
                guard i < cells.count, !(cells[i] is NSNull) else { return nil }
                return cells[i]
            }
            guard let at = r["at"] as? [Double], at.count == 2 else { continue }
            let mmsi = (cell(.mmsi) as? String) ?? (r["id"] as? String) ?? ""
            guard !mmsi.isEmpty else { continue }
            out.append(AISRow(
                mmsi: mmsi,
                name: (cell(.name) as? String) ?? mmsi,
                lon: at[0],
                lat: at[1],
                sogMps: (cell(.sog) as? NSNumber)?.doubleValue,
                cpaM: (cell(.cpa) as? NSNumber)?.doubleValue,
                tcpaS: (cell(.tcpa) as? NSNumber)?.doubleValue,
                alarm: (cell(.state) as? String) == "alarm"))
        }
        return out
    }

    /// The heading out of an overlay payload. Heading is where the hull points;
    /// course over ground is where the target is going, and it stands in when
    /// no heading is reported. Values arrive formatted for a hover, so the
    /// number is read off the front of the string.
    static func heading(payload: String) -> Double? {
        guard let data = payload.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["rows"] as? [[String]]
        else { return nil }
        var cog: Double?
        for row in rows where row.count == 2 {
            let digits = row[1].prefix { $0.isNumber || $0 == "." || $0 == "-" }
            guard let v = Double(digits) else { continue }
            if row[0] == "HDG" { return v }
            if row[0] == "COG" { cog = v }
        }
        return cog
    }
}
