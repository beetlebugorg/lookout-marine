//  ScaleParser.swift — what the mariner may type into the scale entry.
//
//  The forms a chart scale is written in, and the range outside which a number
//  is not one. Pure, so it is checked directly. See ScaleParserTests.

import Foundation

/// The scale parser. It accepts "25000", "25,000", "1:25000", "25k" and
/// "1:2.5M".
enum ScaleParser {
    static func parse(_ raw: String) -> Double? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // In "1:25k", the text before the colon is the 1.
        if let colon = s.lastIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        s = s.filter { !$0.isWhitespace && $0 != "," }
        var multiplier = 1.0
        if s.hasSuffix("k") { multiplier = 1_000; s.removeLast() }
        else if s.hasSuffix("m") { multiplier = 1_000_000; s.removeLast() }
        guard let n = Double(s), n.isFinite else { return nil }
        let denominator = n * multiplier
        // A value outside this range is not a chart scale.
        guard denominator >= 100, denominator <= 100_000_000 else { return nil }
        return denominator
    }
}
