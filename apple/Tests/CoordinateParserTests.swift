//  CoordinateParserTests.swift — what the search field accepts as a position.

import XCTest
@testable import LookoutMarine

final class CoordinateParserTests: XCTestCase {
    private let tol = 1e-9

    private func expect(_ raw: String, lat: Double, lon: Double,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard let got = CoordinateParser.parse(raw) else {
            return XCTFail("\(raw) did not parse", file: file, line: line)
        }
        XCTAssertEqual(got.lat, lat, accuracy: tol, file: file, line: line)
        XCTAssertEqual(got.lon, lon, accuracy: tol, file: file, line: line)
    }

    func testADecimalPair() {
        expect("38.98, -76.48", lat: 38.98, lon: -76.48)
        expect("38.98 -76.48", lat: 38.98, lon: -76.48)
        expect("  38.98 ,  -76.48  ", lat: 38.98, lon: -76.48)
    }

    /// Latitude first, as every chartplotter writes it.
    func testTheDecimalPairIsLatitudeFirst() {
        expect("0, 90", lat: 0, lon: 90)
    }

    func testDegreesAndDecimalMinutesWithHemispheres() {
        expect("38°58.8'N 076°29.0'W", lat: 38 + 58.8 / 60, lon: -(76 + 29.0 / 60))
    }

    func testDegreesMinutesAndSeconds() {
        expect("38 58 30 N, 76 29 W", lat: 38 + 58.0 / 60 + 30.0 / 3600,
               lon: -(76 + 29.0 / 60))
    }

    /// Either order, because a mariner writes what is in front of them.
    func testTheHemisphereFormMayLeadWithLongitude() {
        expect("076°29.0'W 38°58.8'N", lat: 38 + 58.8 / 60, lon: -(76 + 29.0 / 60))
    }

    func testOneHalfOfAPositionIsNotAPosition() {
        XCTAssertNil(CoordinateParser.parse("38°58.8'N"))
        XCTAssertNil(CoordinateParser.parse("38.98"))
    }

    /// The poles are the ends of the latitude axis, so there is no 91 degrees
    /// north to go to.
    func testALatitudePastThePoleIsRefused() {
        XCTAssertNil(CoordinateParser.parse("91, 0"))
        XCTAssertNil(CoordinateParser.parse("-91, 0"))
        XCTAssertNil(CoordinateParser.parse("91°N 0°E"))
        XCTAssertNotNil(CoordinateParser.parse("90°N 0°E"))
    }

    /// Longitude repeats every 360 degrees, so 181 east is 179 west. A plotter
    /// counting past the antimeridian writes it that way.
    func testALongitudePastTheAntimeridianWraps() {
        XCTAssertEqual(CoordinateParser.parse("0, 181")?.lon ?? 0, -179, accuracy: 1e-9)
        XCTAssertEqual(CoordinateParser.parse("0, -181")?.lon ?? 0, 179, accuracy: 1e-9)
        XCTAssertEqual(CoordinateParser.parse("0°N 181°E")?.lon ?? 0, -179, accuracy: 1e-9)
    }

    func testWhatIsNotAPosition() {
        XCTAssertNil(CoordinateParser.parse(""))
        XCTAssertNil(CoordinateParser.parse("   "))
        XCTAssertNil(CoordinateParser.parse("Annapolis"))
    }
}
