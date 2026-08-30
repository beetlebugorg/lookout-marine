//  PickReportTests.swift — the pick report, as the core composes it.
//
//  The engine writes the decoded page: `{"report":{…},"s57":{…}}` per feature,
//  the shape tile57_s57_report documents. The shell only reads it. A payload
//  with no envelope is a raw object, which is the core's fallback when a
//  compose fails, and the fold still shows everything.

import XCTest
@testable import LookoutMarine

final class PickDecodedTests: XCTestCase {

    private func feature(_ s57: String, cls: String = "LIGHTS",
                         chart: String = "US5MD1MC") -> PickFeature {
        PickFeature(cls: cls, chart: chart, s57: s57)
    }

    private static let envelope = """
    {"report":{"title":"Fl G 4s 5m 4M","subtitle":"Light","chip":"LIGHTS",
               "notes":["Reported destroyed 2019."],
               "rows":[{"label":"Characteristic","value":"Fl G 4s","depth":0},
                       {"label":"Chart note","value":"US348MDE.TXT","depth":0,"file":true},
                       {"label":"Sector","value":"","depth":0},
                       {"label":"From","value":"045°","depth":1}],
               "footnote":"US5MD1MC · edition 27"},
     "s57":{"OBJL":75,"COLOUR":"1","LITCHR":"2"}}
    """

    func testTheDecodedPageComesFromTheEnvelope() {
        let d = PickDecoded(feature(Self.envelope))
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
        XCTAssertFalse(d.reportRows[0].file)
    }

    /// The fold shows the cell's own words, out of the envelope.
    func testTheFoldShowsTheRawPayload() {
        let d = PickDecoded(feature(Self.envelope))
        XCTAssertEqual(d.rawRows.map(\.name), ["COLOUR", "LITCHR", "OBJL"])
        XCTAssertEqual(d.rawRows.map(\.value), ["1", "2", "75"])
    }

    /// A payload with no envelope is the core's fallback when a compose fails.
    /// The title falls back to the class, the footnote to the cell, and the
    /// fold still shows everything.
    func testAPayloadWithNoEnvelopeFallsBackToTheClassAndCell() {
        let d = PickDecoded(feature(#"{"OBJL":42,"VALSOU":"5.4 m"}"#, cls: "SOUNDG"))
        XCTAssertEqual(d.title, "SOUNDG")
        XCTAssertNil(d.subtitle)
        XCTAssertEqual(d.chip, "SOUNDG")
        XCTAssertEqual(d.footnote, "US5MD1MC")
        XCTAssertTrue(d.reportRows.isEmpty)
        XCTAssertEqual(d.rawRows.map(\.name), ["OBJL", "VALSOU"])
    }

    func testAPayloadThatIsNotJsonIsStillAReport() {
        let d = PickDecoded(feature("<not json>", cls: "DEPARE"))
        XCTAssertEqual(d.title, "DEPARE")
        XCTAssertTrue(d.rawRows.isEmpty)
    }

    /// The engine's verdict when there is nothing to read. A blank body reads
    /// as a defect, so the report says which kind of nothing it found.
    func testTheTwoEmptyKinds() {
        XCTAssertEqual(PickDecoded(feature(#"{"report":{"empty":"none"}}"#)).empty,
                       .noAttributes)
        XCTAssertEqual(PickDecoded(feature(#"{"report":{"empty":"source"}}"#)).empty,
                       .sourceOnly)
        XCTAssertNil(PickDecoded(feature(#"{"report":{"empty":"other"}}"#)).empty)
        XCTAssertNil(PickDecoded(feature(#"{"report":{}}"#)).empty)
    }
}

final class S57Tests: XCTestCase {

    /// S-57 gives a flat object. S-101 does not: a complex attribute has
    /// sub-attributes, so a value can be an object or an array and the rows
    /// have a depth.
    func testAComplexAttributeBecomesAHeadingAndItsParts() {
        let rows = S57.attributes(of: #"{"sector":{"from":"045","to":"090"},"COLOUR":"1"}"#)
        XCTAssertEqual(rows.map(\.name), ["COLOUR", "sector", "from", "to"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1])
        XCTAssertEqual(rows.first(where: { $0.name == "sector" })?.value, "")
    }

    /// Keys are sorted, so two picks of the same object read the same.
    func testKeysAreSorted() {
        XCTAssertEqual(S57.attributes(of: #"{"z":1,"a":2,"m":3}"#).map(\.name), ["a", "m", "z"])
    }

    func testAListMemberHasNoNameOfItsOwn() {
        let rows = S57.attributes(of: #"{"NATSUR":[1,2]}"#)
        XCTAssertEqual(rows.map(\.name), ["NATSUR", "", ""])
        XCTAssertEqual(rows.map(\.value), ["", "1", "2"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
    }

    func testWhatIsNotJsonHasNoRows() {
        XCTAssertTrue(S57.attributes(of: "").isEmpty)
        XCTAssertTrue(S57.attributes(of: "<not json>").isEmpty)
        XCTAssertTrue(S57.rows(of: nil).isEmpty)
    }

    /// An attribute that names a file beside the chart. The report marks it so
    /// the row can open it.
    func testWhichAttributesNameAFile() {
        let file = { (name: String, value: String) in
            S57.Row(name: name, value: value, depth: 0).fileReference
        }
        XCTAssertTrue(file("TXTDSC", "US348MDE.TXT"))
        XCTAssertTrue(file("NTXTDS", "US348MDE.TXT"))
        XCTAssertTrue(file("PICREP", "chart.tif"))
        XCTAssertTrue(file("fileReference", "note.txt"))
        XCTAssertFalse(file("TXTDSC", ""))
        XCTAssertFalse(file("COLOUR", "1"))
    }

    func testWhichFilesArePictures() {
        let pic = { (value: String) in S57.Row(name: "PICREP", value: value, depth: 0).isPicture }
        XCTAssertTrue(pic("chart.tif"))
        XCTAssertTrue(pic("CHART.TIFF"))
        XCTAssertTrue(pic("a.jpg"))
        XCTAssertTrue(pic("a.JPEG"))
        XCTAssertTrue(pic("a.png"))
        XCTAssertFalse(pic("note.txt"))
    }

    /// M_NPUB holds the chart's cautions and stays in the report; M_QUAL
    /// answers every pick and says nothing.
    func testAMetaObjectStaysOnlyWhenItHasSomethingToRead() {
        XCTAssertTrue(S57.carriesInformation(#"{"INFORM":"Anchoring prohibited."}"#))
        XCTAssertTrue(S57.carriesInformation(#"{"TXTDSC":"US348MDE.TXT"}"#))
        XCTAssertFalse(S57.carriesInformation(#"{"INFORM":""}"#))
        XCTAssertFalse(S57.carriesInformation(#"{"CATZOC":"2","POSACC":"10"}"#))
    }

    // MARK: The clipboard

    /// The copy is how a chart problem gets reported, so it is the one string
    /// here read by someone other than the mariner.
    func testThePlainTextIsTheClassTheCellAndTheRawRows() {
        let f = PickFeature(cls: "LIGHTS", chart: "US5MD1MC",
                            s57: #"{"report":{"title":"t"},"s57":{"COLOUR":"1","OBJL":75}}"#)
        XCTAssertEqual(S57.plainText(f), """
        LIGHTS  US5MD1MC
        COLOUR: 1
        OBJL: 75

        """)
    }

    func testThePlainTextOfARawPayloadIsThePayload() {
        let f = PickFeature(cls: "SOUNDG", chart: "US5MD1MC", s57: #"{"VALSOU":"5.4 m"}"#)
        XCTAssertEqual(S57.plainText(f), "SOUNDG  US5MD1MC\nVALSOU: 5.4 m\n")
    }

    /// A list member has no name, so it pastes with a bare colon. Pinned here
    /// rather than changed: what the clipboard should say for a nameless row
    /// is a decision for every shell, not one.
    func testANamelessRowPastesWithABareColon() {
        let f = PickFeature(cls: "SBDARE", chart: "US5MD1MC", s57: #"{"NATSUR":[1,2]}"#)
        XCTAssertEqual(S57.plainText(f), """
        SBDARE  US5MD1MC
        NATSUR:
          : 1
          : 2

        """)
    }
}
