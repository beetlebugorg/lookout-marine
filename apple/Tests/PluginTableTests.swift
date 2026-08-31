//  PluginTableTests.swift — a plugin's declared table, its rows, and the units
//  the shell prints them in.
//
//  The plugin sends SI and the shell converts: distance metres, speed metres
//  per second, bearing degrees true, duration seconds.
//
//  The core hands the declaration and the rows over as structs, so the
//  fixtures here are the C structs a read holds.

import XCTest
@testable import LookoutMarine

#if os(macOS)

/// One column as the core hands it over.
private func column(_ key: String, _ label: String, _ type: lookout_column_type) -> PluginTableColumn {
    key.withCString { k in
        label.withCString { l in
            PluginTableColumn(lookout_table_column(key: k, label: l, type: type))
        }
    }
}

/// One declaration as the core hands it over. `atLat` empty is a table whose
/// rows have no position; the core sets both halves together.
private func spec(plugin: String = "p",
                  key: String = "k",
                  title: String = "T",
                  menu: String = "M",
                  sortKey: String = "",
                  sortAscending: Bool = true,
                  atLat: String = "",
                  atLon: String = "",
                  columns: [PluginTableColumn] = []) -> PluginTableSpec {
    plugin.withCString { p in
        key.withCString { k in
            title.withCString { ti in
                menu.withCString { m in
                    sortKey.withCString { s in
                        atLat.withCString { la in
                            atLon.withCString { lo in
                                PluginTableSpec(
                                    lookout_table(plugin: p, key: k, title: ti, menu: m,
                                                  sort_key: s,
                                                  sort_ascending: sortAscending ? 1 : 0,
                                                  at_lat: la, at_lon: lo,
                                                  open: 0, rows: 0, seq: 0),
                                    columns: columns)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// What a plugin sent for one cell, in the shape a read holds.
private enum Sent {
    case absent
    case number(Double)
    case text(String)
}

private func cell(_ sent: Sent, _ type: lookout_column_type = LOOKOUT_COLUMN_TEXT) -> PluginCell {
    switch sent {
    case .absent:
        return "".withCString { PluginCell(lookout_table_cell(type: type, kind: LOOKOUT_TABLE_CELL_ABSENT,
                                                              number: 0, text: $0)) }
    case .number(let v):
        return "".withCString { PluginCell(lookout_table_cell(type: type, kind: LOOKOUT_TABLE_CELL_NUMBER,
                                                              number: v, text: $0)) }
    case .text(let s):
        return s.withCString { PluginCell(lookout_table_cell(type: type, kind: LOOKOUT_TABLE_CELL_TEXT,
                                                             number: 0, text: $0)) }
    }
}

/// One row as the core hands it over. `columns` is the declaration's count,
/// and pads a short row.
private func row(id: String = "r",
                 band: Int32 = 0,
                 at: (lon: Double, lat: Double)? = nil,
                 cells: [PluginCell] = [],
                 columns: Int = 0) -> PluginTableRow {
    id.withCString { i in
        PluginTableRow(lookout_table_row(id: i,
                                         band: band,
                                         located: at != nil ? 1 : 0,
                                         lon: at?.lon ?? 0,
                                         lat: at?.lat ?? 0),
                       cells: cells, columns: columns)
    }
}

final class PluginTableSpecTests: XCTestCase {

    func testTheAisDeclarationFromTheCore() {
        let s = spec(plugin: "org.beetlebug.ais", key: "targets", title: "AIS Targets",
                     menu: "Vessels", sortKey: "cpa", sortAscending: true,
                     atLat: "lat", atLon: "lon",
                     columns: [column("name", "Vessel", LOOKOUT_COLUMN_TEXT),
                               column("mmsi", "MMSI", LOOKOUT_COLUMN_TEXT),
                               column("range", "Range", LOOKOUT_COLUMN_DISTANCE),
                               column("brg", "Bearing", LOOKOUT_COLUMN_BEARING),
                               column("sog", "SOG", LOOKOUT_COLUMN_SPEED),
                               column("cpa", "CPA", LOOKOUT_COLUMN_DISTANCE),
                               column("tcpa", "TCPA", LOOKOUT_COLUMN_DURATION),
                               column("state", "", LOOKOUT_COLUMN_FLAG)])
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
        XCTAssertEqual(s.columns.map(\.label).last, "")
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

    /// A table that declared no `at` has no row to find on the chart.
    func testATableWithNoPositionIsNotLocatable() {
        XCTAssertFalse(spec(columns: [column("c", "C", LOOKOUT_COLUMN_TEXT)]).locatable)
        XCTAssertTrue(spec(atLat: "lat", atLon: "lon").locatable)
    }

    /// A column type this build does not know shows as text rather than not
    /// showing. The core refuses a type it does not know itself, so this is a
    /// shell older than the core it is talking to.
    func testAColumnOfAnUnknownTypeReadsAsText() {
        let t = lookout_column_type(rawValue: 99)
        XCTAssertEqual(column("a", "A", t).type, .text)
    }
}

final class PluginTableRowTests: XCTestCase {

    func testTheWorkedExampleFromTheHeader() {
        let r = row(id: "899000101", band: 0, at: (lon: -76.46, lat: 38.97),
                    cells: [cell(.text("ANNE")),
                            cell(.text("899000101")),
                            cell(.number(1852), LOOKOUT_COLUMN_DISTANCE),
                            cell(.number(45), LOOKOUT_COLUMN_BEARING),
                            cell(.number(6.2), LOOKOUT_COLUMN_SPEED),
                            cell(.number(124), LOOKOUT_COLUMN_DISTANCE),
                            cell(.number(585), LOOKOUT_COLUMN_DURATION),
                            cell(.text("alarm"), LOOKOUT_COLUMN_FLAG)],
                    columns: 8)
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
        let r = row(cells: [cell(.text("a"))], columns: 4)
        XCTAssertEqual(r.cells.count, 4)
        if case .empty = r.cell(3) {} else { XCTFail("cell 3 is not empty") }
    }

    /// Reading past the end is empty, not a crash.
    func testReadingPastTheEndIsEmpty() {
        let r = row(cells: [cell(.text("a"))], columns: 1)
        if case .empty = r.cell(9) {} else { XCTFail("cell 9 is not empty") }
    }

    /// A cell the plugin did not send is not a zero.
    func testAnAbsentCellIsEmptyRatherThanZero() {
        let r = row(cells: [cell(.absent), cell(.number(0))], columns: 2)
        if case .empty = r.cell(0) {} else { XCTFail("absent is not empty") }
        if case .number(let v) = r.cell(1) { XCTAssertEqual(v, 0) }
        else { XCTFail("0 is not a number") }
    }

    /// A string in a numeric column stays a string: the shell shows what the
    /// plugin sent.
    func testAStringInANumericColumnStaysAString() {
        let r = row(cells: [cell(.text("n/a"), LOOKOUT_COLUMN_DISTANCE)], columns: 1)
        XCTAssertEqual(r.cell(0).string, "n/a")
    }

    /// A row the table has no position for is not on the chart.
    func testARowWithNoPositionHasNeitherHalf() {
        let r = row()
        XCTAssertNil(r.lat)
        XCTAssertNil(r.lon)
    }

    /// The band is the plugin's ordering policy and crosses over as it is.
    func testTheBandCrossesOver() {
        XCTAssertEqual(row(band: 3).band, 3)
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
}

#endif
