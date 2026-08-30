//  Fixture.swift — reading the documents the core hands the shell.
//
//  See Fixtures/README.md for which of these are captured from the core and
//  which are the worked examples in include/lookout.h.

import Foundation
import XCTest

enum Fixture {
    /// One fixture as a string, or a failure naming it. The bundle is the test
    /// bundle, not the host app's.
    static func text(_ name: String,
                     file: StaticString = #filePath, line: UInt = #line) -> String {
        let bundle = Bundle(for: FixtureAnchor.self)
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("no fixture named \(name).json in the test bundle", file: file, line: line)
            return ""
        }
        return text
    }
}

/// Names the test bundle for `Bundle(for:)`. A Swift enum has no class to point at.
private final class FixtureAnchor {}
