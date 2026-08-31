//  ScaleParser.swift — what the mariner may type into the scale entry.
//
//  A wrapper over the core's scale parser (lookout-shell.h). See
//  ScaleParserTests.

import Foundation

/// The scale parser. It accepts "25000", "25,000", "1:25000", "25k" and
/// "1:2.5M".
enum ScaleParser {
    static func parse(_ raw: String) -> Double? {
        var denominator = 0.0
        guard lookout_parse_scale(raw, &denominator) != 0 else { return nil }
        return denominator
    }
}
