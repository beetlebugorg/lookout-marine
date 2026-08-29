//  CoordFormatTests.swift — the string contract the four shells share.
//
//  `CoordFormat`'s own comment claims it agrees with `lkw::FormatCoord`
//  (windows/src/lk_format.cpp), `lk_coord_format_dm` (linux/src/lk-hud.c) and
//  `dm` in Hud.kt. Nothing checked that on any platform. This is the first
//  shell to check its own half.

import XCTest
@testable import LookoutMarine

final class CoordFormatTests: XCTestCase {

    // MARK: Degrees and decimal minutes

    func testLatitudeShowsItsHemisphere() {
        XCTAssertEqual(CoordFormat.dm(38.9763, isLat: true), "38°58.578'N")
        XCTAssertEqual(CoordFormat.dm(-38.9763, isLat: true), "38°58.578'S")
    }

    func testLongitudeShowsItsHemisphere() {
        XCTAssertEqual(CoordFormat.dm(-76.482, isLat: false), "076°28.920'W")
        XCTAssertEqual(CoordFormat.dm(76.482, isLat: false), "076°28.920'E")
    }

    /// Zero is north and east, not south and west. A boat on the equator or the
    /// prime meridian must not read as though it were on the other side.
    func testZeroIsNorthAndEast() {
        XCTAssertEqual(CoordFormat.dm(0, isLat: true), "00°00.000'N")
        XCTAssertEqual(CoordFormat.dm(0, isLat: false), "000°00.000'E")
    }

    /// A longitude keeps three degree digits, so a pair holds its column.
    func testLongitudeKeepsThreeDegreeDigits() {
        XCTAssertEqual(CoordFormat.dm(9.5, isLat: false), "009°30.000'E")
        XCTAssertEqual(CoordFormat.dm(179.5, isLat: false), "179°30.000'E")
    }

    /// A latitude keeps two.
    func testLatitudeKeepsTwoDegreeDigits() {
        XCTAssertEqual(CoordFormat.dm(9.5, isLat: true), "09°30.000'N")
    }

    /// 59.9996' rounds to 60.000', which is the next degree. Printing it as
    /// "38°60.000'N" would be a position no chart has.
    func testTheRoundingCarriesIntoTheDegree() {
        XCTAssertEqual(CoordFormat.dm(38 + 59.9996 / 60, isLat: true), "39°00.000'N")
        XCTAssertEqual(CoordFormat.dm(-(76 + 59.9996 / 60), isLat: false), "077°00.000'W")
    }

    /// Just under the carry it still prints minutes.
    func testJustUnderTheCarryStaysInTheDegree() {
        XCTAssertEqual(CoordFormat.dm(38 + 59.9994 / 60, isLat: true), "38°59.999'N")
    }

    /// Three decimals of a minute is about 1.9 m, finer than any chart.
    func testMinutesKeepThreeDecimals() {
        let s = CoordFormat.dm(38.5, isLat: true)
        XCTAssertEqual(s, "38°30.000'N")
        XCTAssertEqual(s.split(separator: ".").last?.dropLast(2).count, 3)
    }

    func testAPositionIsLatitudeThenLongitude() {
        XCTAssertEqual(CoordFormat.position(lat: 38.9763, lon: -76.482),
                       "38°58.578'N 076°28.920'W")
    }

    // MARK: Scale

    /// A denominator that is not a scale reads as no scale, never as 1:0.
    func testAnAbsentScaleIsADash() {
        XCTAssertEqual(CoordFormat.scale(0), "1:—")
        XCTAssertEqual(CoordFormat.scale(-1), "1:—")
    }

    /// The digits are grouped. The separator is the reader's own, so the test
    /// strips whatever this locale uses rather than pinning one.
    func testTheScaleIsGrouped() {
        let s = CoordFormat.scale(13267.4)
        XCTAssertTrue(s.hasPrefix("1:"), s)
        let digits = s.dropFirst(2).filter { $0.isNumber }
        XCTAssertEqual(String(digits), "13267")
        XCTAssertGreaterThan(s.count, "1:13267".count, "no group separator in \(s)")
    }

    func testAShortScaleHasNoSeparator() {
        XCTAssertEqual(CoordFormat.scale(500), "1:500")
    }

    func testTheScaleRoundsRatherThanTruncating() {
        XCTAssertEqual(CoordFormat.scale(499.6), "1:500")
    }

    // MARK: Band

    /// The S-52 navigational purpose bands, at each boundary. A band is named
    /// from the denominator BELOW its ceiling.
    func testEveryBandBoundary() {
        XCTAssertEqual(CoordFormat.band(0), "—")
        XCTAssertEqual(CoordFormat.band(0.0009), "—")
        XCTAssertEqual(CoordFormat.band(0.001), "Berthing")
        XCTAssertEqual(CoordFormat.band(4_999), "Berthing")
        XCTAssertEqual(CoordFormat.band(5_000), "Harbor")
        XCTAssertEqual(CoordFormat.band(24_999), "Harbor")
        XCTAssertEqual(CoordFormat.band(25_000), "Approach")
        XCTAssertEqual(CoordFormat.band(74_999), "Approach")
        XCTAssertEqual(CoordFormat.band(75_000), "Coastal")
        XCTAssertEqual(CoordFormat.band(299_999), "Coastal")
        XCTAssertEqual(CoordFormat.band(300_000), "General")
        XCTAssertEqual(CoordFormat.band(1_499_999), "General")
        XCTAssertEqual(CoordFormat.band(1_500_000), "Overview")
        XCTAssertEqual(CoordFormat.band(50_000_000), "Overview")
    }
}
