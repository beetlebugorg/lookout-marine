//  PickReportTests.swift — the pick report, as the core hands it over.
//
//  lookout_picks_read gives one struct per feature: the page tile57_s57_report
//  composed, its notes and rows, and the payload the cell states flattened into
//  the source fold. The shell copies it out and lays it out. The fixtures here
//  are the C structs a read holds.

import XCTest
@testable import LookoutMarine

/// One row as the core hands it over. The strings live only for the call that
/// reads them out, the same borrow a real read gives the shell.
private func row(_ label: String, _ value: String, depth: Int32 = 0,
                 file: Bool = false, picture: Bool = false) -> PickDecoded.Row {
    label.withCString { l in
        value.withCString { v in
            PickDecoded.Row(lookout_pick_row(label: l, value: v, depth: depth,
                                             file: file ? 1 : 0,
                                             picture: picture ? 1 : 0))
        }
    }
}

/// One feature as the core hands it over, with its collections already read.
private func decoded(cls: String = "LIGHTS",
                     chart: String = "US5MD1MC",
                     title: String = "Fl G 4s 5m 4M",
                     subtitle: String = "Light",
                     chip: String = "LIGHTS",
                     footnote: String = "US5MD1MC · edition 27",
                     empty: lookout_pick_empty = LOOKOUT_PICK_READS,
                     raw: String = "{}",
                     notes: [String] = [],
                     rows: [PickDecoded.Row] = [],
                     source: [PickDecoded.Row] = []) -> PickDecoded {
    cls.withCString { c in
        chart.withCString { ch in
            title.withCString { t in
                subtitle.withCString { sub in
                    chip.withCString { chp in
                        footnote.withCString { f in
                            raw.withCString { r in
                                PickDecoded(
                                    lookout_pick_feature(cls: c, chart: ch, title: t,
                                                         subtitle: sub, chip: chp,
                                                         footnote: f, empty: empty, raw: r),
                                    notes: notes, rows: rows, source: source)
                            }
                        }
                    }
                }
            }
        }
    }
}

final class PickDecodedTests: XCTestCase {

    func testThePageCrossesOverWhole() {
        let d = decoded(notes: ["Reported destroyed 2019."],
                        rows: [row("Characteristic", "Fl G 4s"),
                               row("Chart note", "US348MDE.TXT", file: true),
                               row("Sector", ""),
                               row("From", "045°", depth: 1)])
        XCTAssertEqual(d.cls, "LIGHTS")
        XCTAssertEqual(d.chart, "US5MD1MC")
        XCTAssertEqual(d.title, "Fl G 4s 5m 4M")
        XCTAssertEqual(d.subtitle, "Light")
        XCTAssertEqual(d.chip, "LIGHTS")
        XCTAssertEqual(d.notes, ["Reported destroyed 2019."])
        XCTAssertEqual(d.footnote, "US5MD1MC · edition 27")
        XCTAssertNil(d.empty)
        XCTAssertEqual(d.reportRows.map(\.label),
                       ["Characteristic", "Chart note", "Sector", "From"])
        XCTAssertEqual(d.reportRows.map(\.depth), [0, 0, 0, 1])
        XCTAssertTrue(d.reportRows[1].file)
        XCTAssertFalse(d.reportRows[1].picture)
        XCTAssertFalse(d.reportRows[0].file)
    }

    /// The header reserves the subtitle line even when there is none, so an
    /// empty one has to read as absent rather than as a blank string.
    func testAPageWithNoSubtitleHasNone() {
        XCTAssertNil(decoded(subtitle: "").subtitle)
    }

    /// The fold shows the cell's own words. The core sorts and indents it, so
    /// the shell only copies.
    func testTheFoldCrossesOverInOrder() {
        let d = decoded(source: [row("COLOUR", "1"),
                                 row("LITCHR", "2"),
                                 row("OBJL", "75")])
        XCTAssertEqual(d.rawRows.map(\.label), ["COLOUR", "LITCHR", "OBJL"])
        XCTAssertEqual(d.rawRows.map(\.value), ["1", "2", "75"])
    }

    /// The core's verdict when the body has nothing to read. A blank body
    /// reads as a defect, so the report states which kind it is.
    func testTheTwoEmptyKinds() {
        XCTAssertEqual(decoded(empty: LOOKOUT_PICK_NO_ATTRIBUTES).empty, .noAttributes)
        XCTAssertEqual(decoded(empty: LOOKOUT_PICK_SOURCE_ONLY).empty, .sourceOnly)
        XCTAssertNil(decoded(empty: LOOKOUT_PICK_READS).empty)
        XCTAssertNil(decoded(empty: lookout_pick_empty(rawValue: 99)).empty)
    }

    // MARK: The clipboard

    /// The copy is how a chart problem gets reported, so it is the one string
    /// here read by someone other than the mariner.
    func testThePlainTextIsTheClassTheCellAndTheFold() {
        let d = decoded(source: [row("COLOUR", "1"), row("OBJL", "75")])
        XCTAssertEqual(d.plainText, """
        LIGHTS  US5MD1MC
        COLOUR: 1
        OBJL: 75

        """)
    }

    /// A heading has no value of its own, so it pastes with a bare colon and
    /// its parts indent under it.
    func testAHeadingPastesWithNoValueAndItsPartsIndent() {
        let d = decoded(cls: "SBDARE",
                        source: [row("NATSUR", ""),
                                 row("", "1", depth: 1),
                                 row("", "2", depth: 1)])
        XCTAssertEqual(d.plainText, """
        SBDARE  US5MD1MC
        NATSUR:
          : 1
          : 2

        """)
    }
}
