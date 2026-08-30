//  PluginTableTests.swift — a plugin's declared table, its rows, and the units
//  the shell prints them in.
//
//  The plugin sends SI and the shell converts: distance metres, speed metres
//  per second, bearing degrees true, duration seconds.

import XCTest
@testable import LookoutMarine

#if os(macOS)

final class PluginTableSpecTests: XCTestCase {
    private func specs(_ text: String) -> [PluginTableSpec] {
        guard let data = text.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["tables"] as? [[String: Any]] else { return [] }
        return list.compactMap { PluginTableSpec($0) }
    }

    func testTheAisDeclarationFromTheCore() {
        guard let s = specs(Fixture.text("tables")).first else { return XCTFail("no table") }
        XCTAssertEqual(s.plugin, "org.beetlebug.ais")
        XCTAssertEqual(s.key, "targets")
        XCTAssertEqual(s.id, "org.beetlebug.ais/targets")
        XCTAssertEqual(s.title, "AIS Targets")
        XCTAssertEqual(s.menu, "Vessels")
        XCTAssertEqual(s.sortKey, "cpa")
        XCTAssertTrue(s.sortAscending)
        XCTAssertTrue(s.locatable)
        XCTAssertEqual(s.columns.map(\.key),
                       ["name", "mmsi", "range", "brg", "sog", "cpa", "tcpa", "state"])
        XCTAssertEqual(s.columns.map(\.type),
                       [.text, .text, .distance, .bearing, .speed, .distance, .duration, .flag])
    }

    /// A number column is right aligned and scanned down; text and a flag are not.
    func testWhichColumnsAreNumeric() {
        XCTAssertTrue(PluginColumnType.distance.numeric)
        XCTAssertTrue(PluginColumnType.speed.numeric)
        XCTAssertTrue(PluginColumnType.bearing.numeric)
        XCTAssertTrue(PluginColumnType.duration.numeric)
        XCTAssertTrue(PluginColumnType.number.numeric)
        XCTAssertFalse(PluginColumnType.text.numeric)
        XCTAssertFalse(PluginColumnType.flag.numeric)
    }

    /// A table with no columns is not a table.
    func testADeclarationWithNoColumnsIsDropped() {
        XCTAssertTrue(specs(#"{"tables":[{"plugin":"p","key":"k","columns":[]}]}"#).isEmpty)
        XCTAssertTrue(specs(#"{"tables":[{"plugin":"p","key":"k"}]}"#).isEmpty)
    }

    /// A table that declared no `at` has no row to find on the chart.
    func testATableWithNoPositionIsNotLocatable() {
        let s = specs(#"{"tables":[{"plugin":"p","key":"k","columns":[{"key":"c","type":"text"}]}]}"#)
        XCTAssertEqual(s.count, 1)
        XCTAssertFalse(s[0].locatable)
        XCTAssertEqual(s[0].title, "k")
        XCTAssertEqual(s[0].menu, "Window")
    }

    /// A column of a type this build does not know is dropped, and the rest of
    /// the table still shows.
    func testAColumnOfAnUnknownTypeIsDropped() {
        let s = specs("""
            {"tables":[{"plugin":"p","key":"k","columns":[
              {"key":"a","type":"colour"},{"key":"b","type":"text"}]}]}
            """)
        XCTAssertEqual(s.first?.columns.map(\.key), ["b"])
    }
}

final class PluginTableRowTests: XCTestCase {
    private func rows(_ text: String, columns: Int) -> (seq: Int, rows: [PluginTableRow]) {
        guard let data = text.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["rows"] as? [[String: Any]] else { return (0, []) }
        return (top["seq"] as? Int ?? 0, list.compactMap { PluginTableRow($0, columns: columns) })
    }

    func testTheWorkedExampleFromTheHeader() {
        let got = rows(Fixture.text("table-rows"), columns: 8)
        XCTAssertEqual(got.seq, 42)
        guard let r = got.rows.first else { return XCTFail("no row") }
        XCTAssertEqual(r.id, "899000101")
        XCTAssertEqual(r.band, 0)
        XCTAssertEqual(r.lon ?? 0, -76.46, accuracy: 1e-9)
        XCTAssertEqual(r.lat ?? 0, 38.97, accuracy: 1e-9)
        XCTAssertEqual(r.cell(0).string, "ANNE")
        XCTAssertEqual(r.cell(7).string, "alarm")
    }

    /// A row shorter than the declared column count is padded, so it still
    /// lines up under the headings.
    func testAShortRowIsPadded() {
        let got = rows(#"{"rows":[{"id":"r","cells":["a"]}]}"#, columns: 4)
        XCTAssertEqual(got.rows.first?.cells.count, 4)
        if case .empty = got.rows.first!.cell(3) {} else { XCTFail("cell 3 is not empty") }
    }

    /// Reading past the end is empty, not a crash.
    func testReadingPastTheEndIsEmpty() {
        let got = rows(#"{"rows":[{"id":"r","cells":["a"]}]}"#, columns: 1)
        if case .empty = got.rows.first!.cell(9) {} else { XCTFail("cell 9 is not empty") }
    }

    /// A cell the plugin did not send is not a zero.
    func testANullCellIsEmptyRatherThanZero() {
        let got = rows(#"{"rows":[{"id":"r","cells":[null,0]}]}"#, columns: 2)
        if case .empty = got.rows.first!.cell(0) {} else { XCTFail("null is not empty") }
        if case .number(let v) = got.rows.first!.cell(1) { XCTAssertEqual(v, 0) }
        else { XCTFail("0 is not a number") }
    }

    func testARowWithNoIdIsDropped() {
        XCTAssertTrue(rows(#"{"rows":[{"cells":["a"]}]}"#, columns: 1).rows.isEmpty)
    }

    /// A position needs both halves.
    func testAHalfPositionIsNoPosition() {
        let got = rows(#"{"rows":[{"id":"r","at":[-76.46]}]}"#, columns: 0)
        XCTAssertNil(got.rows.first?.lat)
        XCTAssertNil(got.rows.first?.lon)
    }
}

final class PluginTableFormatTests: XCTestCase {
    private func text(_ cell: PluginCell, _ type: PluginColumnType) -> String {
        PluginTableFormat.text(cell, type)
    }

    /// Under a tenth of a mile the metres are what matters: a CPA of "0.07 nm"
    /// tells a mariner far less than "124 m".
    func testDistanceIsMetresUpCloseAndMilesBeyond() {
        XCTAssertEqual(text(.number(124), .distance), "124 m")
        XCTAssertEqual(text(.number(185.1), .distance), "185 m")
        XCTAssertEqual(text(.number(185.2), .distance), "0.10 nm")
        XCTAssertEqual(text(.number(1852), .distance), "1.00 nm")
        XCTAssertEqual(text(.number(9260), .distance), "5.00 nm")
    }

    /// The plugin sends metres per second; the mariner reads knots.
    func testSpeedIsKnots() {
        XCTAssertEqual(text(.number(0), .speed), "0.0 kn")
        XCTAssertEqual(text(.number(1852.0 / 3600), .speed), "1.0 kn")
        XCTAssertEqual(text(.number(6.2), .speed), "12.1 kn")
    }

    /// Three digits, and wrapped into 0 to 359.
    func testBearingIsThreeDigitsTrue() {
        XCTAssertEqual(text(.number(45), .bearing), "045°")
        XCTAssertEqual(text(.number(5), .bearing), "005°")
        XCTAssertEqual(text(.number(359.6), .bearing), "360°")
        XCTAssertEqual(text(.number(370), .bearing), "010°")
        XCTAssertEqual(text(.number(-10), .bearing), "350°")
    }

    /// Minutes and seconds, and hours once there are any.
    func testDurationCountsDownTheWayAMarinerDoes() {
        XCTAssertEqual(PluginTableFormat.duration(0), "0:00")
        XCTAssertEqual(PluginTableFormat.duration(45), "0:45")
        XCTAssertEqual(PluginTableFormat.duration(585), "9:45")
        XCTAssertEqual(PluginTableFormat.duration(3599), "59:59")
        XCTAssertEqual(PluginTableFormat.duration(3600), "1:00:00")
        XCTAssertEqual(PluginTableFormat.duration(-90), "-1:30")
    }

    /// Never heard and heard as zero are different values.
    func testAMissingCellIsADash() {
        XCTAssertEqual(text(.empty, .distance), "—")
        XCTAssertEqual(text(.empty, .text), "—")
        XCTAssertEqual(text(.empty, .flag), "—")
        XCTAssertEqual(text(.number(0), .distance), "0 m")
    }

    /// A number the plugin sent as an infinity or a NaN is not a value.
    func testANumberThatIsNotFiniteIsADash() {
        XCTAssertEqual(text(.number(.infinity), .distance), "—")
        XCTAssertEqual(text(.number(.nan), .duration), "—")
    }

    func testAFlagIsUppercased() {
        XCTAssertEqual(text(.text("alarm"), .flag), "ALARM")
        XCTAssertEqual(text(.text("alarm"), .text), "alarm")
    }

    /// JSONSerialization gives booleans as NSNumber. A cell is never a boolean,
    /// so anything numeric reads as a number.
    func testABooleanReadsAsANumber() {
        if case .number(let v) = PluginCell(true) { XCTAssertEqual(v, 1) }
        else { XCTFail("a bool is not a number") }
    }

    func testAnUnknownJsonTypeIsEmpty() {
        if case .empty = PluginCell(["a": 1]) {} else { XCTFail("a dict is not empty") }
        if case .empty = PluginCell(nil) {} else { XCTFail("nil is not empty") }
    }
}

#endif
