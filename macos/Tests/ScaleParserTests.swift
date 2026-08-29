//  ScaleParserTests.swift — what the scale entry accepts, and what it refuses.

import XCTest
@testable import LookoutMarine

final class ScaleParserTests: XCTestCase {
    func testAPlainNumber() {
        XCTAssertEqual(ScaleParser.parse("25000"), 25_000)
    }

    func testGroupSeparatorsAndSpacesAreIgnored() {
        XCTAssertEqual(ScaleParser.parse("25,000"), 25_000)
        XCTAssertEqual(ScaleParser.parse(" 25 000 "), 25_000)
    }

    /// In "1:25000" the text before the colon is the 1.
    func testTheRatioForm() {
        XCTAssertEqual(ScaleParser.parse("1:25000"), 25_000)
        XCTAssertEqual(ScaleParser.parse("1:25k"), 25_000)
    }

    func testTheThousandAndMillionSuffixes() {
        XCTAssertEqual(ScaleParser.parse("25k"), 25_000)
        XCTAssertEqual(ScaleParser.parse("25K"), 25_000)
        XCTAssertEqual(ScaleParser.parse("1:2.5M"), 2_500_000)
        XCTAssertEqual(ScaleParser.parse("2.5m"), 2_500_000)
    }

    /// A value outside this range is not a chart scale. 1:5 is a floor plan.
    func testTheSanityRange() {
        XCTAssertNil(ScaleParser.parse("1:5"))
        XCTAssertNil(ScaleParser.parse("99"))
        XCTAssertEqual(ScaleParser.parse("100"), 100)
        XCTAssertEqual(ScaleParser.parse("100000000"), 100_000_000)
        XCTAssertNil(ScaleParser.parse("100000001"))
    }

    func testWhatIsNotAScale() {
        XCTAssertNil(ScaleParser.parse(""))
        XCTAssertNil(ScaleParser.parse("harbour"))
        XCTAssertNil(ScaleParser.parse("1:"))
        XCTAssertNil(ScaleParser.parse("k"))
    }
}
