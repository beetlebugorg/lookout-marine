//  CoordinateParser.swift — what the mariner may type into the search field.
//
//  A decimal pair, or degrees and minutes and seconds with hemispheres. Pure,
//  so it is checked directly. See CoordinateParserTests.

import Foundation

/// Tolerant lat/lon parser: decimal pairs ("38.98, -76.48") and DMS with
/// hemispheres ("38°58.8'N 076°29.0'W", "38 58 30 N, 76 29 W").
enum CoordinateParser {
    static func parse(_ raw: String) -> (lat: Double, lon: Double)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.uppercased().contains(where: { "NSEW".contains($0) }) {
            return parseHemispheres(s)
        }
        // Decimal pair, comma- or whitespace-separated (lat first).
        let parts = s.split { $0 == "," || $0 == " " }.map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }

    private static func parseHemispheres(_ s: String) -> (lat: Double, lon: Double)? {
        // deg [min [sec]] hemisphere — minutes/seconds optional.
        let pattern = #"(\d+(?:\.\d+)?)\s*[°\s]\s*(?:(\d+(?:\.\d+)?)\s*['′\s]\s*)?(?:(\d+(?:\.\d+)?)\s*["″\s]\s*)?([NSEW])"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var lat: Double?, lon: Double?
        for m in matches {
            func grp(_ i: Int) -> Double? {
                let r = m.range(at: i); guard r.location != NSNotFound else { return nil }
                return Double(ns.substring(with: r))
            }
            guard let deg = grp(1) else { continue }
            var value = deg + (grp(2) ?? 0) / 60 + (grp(3) ?? 0) / 3600
            let hemi = ns.substring(with: m.range(at: 4)).uppercased()
            if hemi == "S" || hemi == "W" { value = -value }
            if hemi == "N" || hemi == "S" { lat = value } else { lon = value }
        }
        if let lat, let lon { return (lat, lon) }
        return nil
    }
}
