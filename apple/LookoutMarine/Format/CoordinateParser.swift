//  CoordinateParser.swift — what the mariner may type into the search field.
//
//  A wrapper over the core's position parser (lookout-shell.h). See
//  CoordinateParserTests.

import Foundation

/// Tolerant lat/lon parser: decimal pairs ("38.98, -76.48") and DMS with
/// hemispheres ("38°58.8'N 076°29.0'W", "38 58 30 N, 76 29 W").
enum CoordinateParser {
    static func parse(_ raw: String) -> (lat: Double, lon: Double)? {
        var lat = 0.0
        var lon = 0.0
        guard lookout_parse_position(raw, &lat, &lon) != 0 else { return nil }
        return (lat, lon)
    }
}
