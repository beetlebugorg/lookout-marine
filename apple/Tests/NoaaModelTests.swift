//  NoaaModelTests.swift — the catalog line, the region record, and what a
//  removal deletes.
//
//  These run against FakeEngine, so the catalog, what a region costs and the
//  cells it names are whatever the test sets. The region table comes from the
//  core, so the ids here are the real ones.

import XCTest
@testable import LookoutMarine

@MainActor
final class NoaaModelTests: ShellTestCase {

    /// The engine is held by the test. The model's reference is weak, as the
    /// chart view owns the controller.
    private var engine = FakeEngine()

    /// A model reading a loaded catalog, with d1 and d5 priced.
    ///
    /// Only priced regions reach regionState, so the other seven stay out of
    /// the way of what each test asserts.
    private func model(cells: [String: [String]]) -> (NoaaModel, FakeEngine) {
        engine = FakeEngine()
        engine.noaa.phase = .ready
        engine.noaa.haveCatalog = true
        engine.noaa.catalogCells = 7318
        engine.noaa.date = "20260915"
        engine.noaaCells = cells
        for id in cells.keys { engine.noaaCosts[id] = NoaaCost() }
        let m = NoaaModel()
        m.engine = engine
        m.poll()
        return (m, engine)
    }

    // MARK: The catalog line

    func testAReadInProgressLeadsTheLine() {
        var s = NoaaState()
        s.phase = .readingCatalog
        s.haveCatalog = true
        s.error = "could not read NOAA's chart catalog"
        XCTAssertEqual(s.catalogLine, .reading)
    }

    func testACleanReadIsTheSummaryAlone() {
        var s = NoaaState()
        s.phase = .ready
        s.haveCatalog = true
        s.catalogCells = 7318
        s.date = "20260915"
        XCTAssertEqual(s.catalogLine,
                       .summary("7318 charts published, catalog dated 20260915."))
    }

    /// The picker prices and removes water from the catalog it holds, so a
    /// read that failed goes under the summary rather than in place of it.
    func testAFailedReadDoesNotHideTheCatalog() {
        var s = NoaaState()
        s.phase = .ready
        s.haveCatalog = true
        s.catalogCells = 7318
        s.date = "20260915"
        s.error = "could not read NOAA's chart catalog"
        XCTAssertEqual(
            s.catalogLine,
            .summaryThenError(summary: "7318 charts published, catalog dated 20260915.",
                              error: "could not read NOAA's chart catalog"))
    }

    func testWithNoCatalogTheErrorIsTheWholeLine() {
        var s = NoaaState()
        s.phase = .ready
        s.error = "could not read NOAA's chart catalog"
        XCTAssertEqual(s.catalogLine, .error("could not read NOAA's chart catalog"))
    }

    func testNoCatalogAndNoErrorLeavesTheLineBlank() {
        XCTAssertEqual(NoaaState().catalogLine, .blank)
    }

    // MARK: The region record

    /// A library downloaded before the record existed opens ticked.
    func testADeviceWithNoRecordAdoptsTheWaterItHolds() {
        let (m, _) = model(cells: ["d1": ["US1NE01", "US2NE02"],
                                   "d5": ["US1MA01", "US2MA02"]])
        m.noteManaged(["US1NE01", "US2NE02"])
        XCTAssertFalse(m.hasRecord)

        m.pickInstalled()

        XCTAssertEqual(m.picked, ["d1"])
    }

    /// Giving back the last region leaves a record that is empty and written.
    /// Read back as a device that never recorded, it ticks the water straight
    /// back, because the cells are still on the disk.
    func testAnEmptyRecordThatWasWrittenStaysEmpty() {
        let held = ["US1NE01", "US2NE02"]
        let (first, _) = model(cells: ["d1": held])
        first.noteManaged(held)
        first.recordPicked(["d1"])
        first.dropRecorded(["d1"])
        XCTAssertTrue(first.recorded.isEmpty)

        // A relaunch: a second model reads the record off the same store.
        let next = NoaaModel()
        next.engine = engine
        next.poll()
        next.noteManaged(held)
        XCTAssertTrue(next.hasRecord)

        next.pickInstalled()

        XCTAssertEqual(next.picked, [])
    }

    /// A region the device no longer holds whole goes out of the record, which
    /// heals a library whose charts went by another route.
    func testARegionNoLongerHeldWholeIsDropped() {
        let (m, _) = model(cells: ["d1": ["US1NE01", "US2NE02"]])
        m.noteManaged(["US1NE01", "US2NE02"])
        m.recordPicked(["d1"])

        // The charts went, so the region is no longer complete.
        m.noteManaged([])
        m.pickInstalled()

        XCTAssertEqual(m.picked, [])
        XCTAssertTrue(m.recorded.isEmpty)
    }

    /// The Mac window builds a new picker, and seeds it again, each time it
    /// opens. A tick abandoned with Cancel is dropped, and a region downloaded
    /// since the last open is ticked.
    func testASecondSeedReadsTheLibraryAsItIsNow() {
        let (m, _) = model(cells: ["d1": ["US1NE01"], "d5": ["US1MA01"]])
        m.noteManaged(["US1NE01"])
        m.recordPicked(["d1"])
        m.pickInstalled()
        m.toggle("d5")
        XCTAssertEqual(m.picked, ["d1", "d5"])

        // Cancelled, and opened again.
        m.pickInstalled()
        XCTAssertEqual(m.picked, ["d1"])

        // A download of d5 finishes, and the picker opens again.
        m.recordPicked(["d5"])
        m.noteManaged(["US1NE01", "US1MA01"])
        m.pickInstalled()
        XCTAssertEqual(m.picked, ["d1", "d5"])
    }

    func testTheRecordSurvivesARelaunch() {
        let (m, _) = model(cells: ["d1": ["US1NE01"]])
        m.recordPicked(["d1", "d5"])

        let next = NoaaModel()
        XCTAssertEqual(next.recorded, ["d1", "d5"])
        XCTAssertTrue(next.hasRecord)
    }

    // MARK: Reissued charts

    func testACheckCountsWhatTheCatalogReissued() {
        let (m, fake) = model(cells: ["d1": ["US1NE01"]])
        fake.noaaOutdatedCount = 721
        fake.noaaDue = true

        m.considerUpdateCheck()

        XCTAssertFalse(m.checking)
        XCTAssertEqual(m.outdated, 721)
    }

    /// The check waits on the catalog read, and counts when it ends.
    func testACheckCountsWhenTheCatalogReadEnds() {
        let (m, fake) = model(cells: ["d1": ["US1NE01"]])
        fake.noaaOutdatedCount = 721
        fake.noaaDue = true
        fake.noaa.phase = .readingCatalog

        m.considerUpdateCheck()
        XCTAssertTrue(m.checking)
        XCTAssertEqual(m.outdated, 0)

        fake.noaa.phase = .ready
        m.poll()
        XCTAssertFalse(m.checking)
        XCTAssertEqual(m.outdated, 721)
    }

    /// The count follows the library. An update that baked leaves the cells
    /// at the editions the catalog holds, and the line on the charts page
    /// goes with the count.
    func testACountAfterAnUpdateClears() {
        let (m, fake) = model(cells: ["d1": ["US1NE01"]])
        fake.noaaOutdatedCount = 721
        fake.noaaDue = true
        m.considerUpdateCheck()
        XCTAssertEqual(m.outdated, 721)

        // The newer edition is in the library now.
        fake.noaaOutdatedCount = 0
        m.recount()

        XCTAssertEqual(m.outdated, 0)
    }

    /// A check the core does not find due leaves the count alone.
    func testACheckThatIsNotDueDoesNotCount() {
        let (m, fake) = model(cells: ["d1": ["US1NE01"]])
        fake.noaaOutdatedCount = 721

        m.considerUpdateCheck()
        m.recount()

        XCTAssertEqual(m.outdated, 0)
        XCTAssertFalse(fake.calls.contains("noaaOutdated"))
    }

    // MARK: What a removal deletes

    /// NOAA files a cell under one district that covers another's water. The
    /// cells to delete are the unpicked regions' minus every cell a region
    /// still picked names, or unticking one region deletes charts under water
    /// the mariner is keeping.
    func testASharedCellSurvivesUntickingItsNeighbour() {
        let (m, _) = model(cells: ["d1": ["US1NE01", "US5SHARED"],
                                   "d5": ["US1MA01", "US5SHARED"]])
        m.picked = ["d5"]

        let gone = m.regions.filter { $0.id == "d1" }
        XCTAssertEqual(m.cellsToRemove(unpicking: gone), ["US1NE01"])
    }

    func testUntickingTheLastRegionRemovesAllItsCells() {
        let (m, _) = model(cells: ["d1": ["US1NE01", "US5SHARED"],
                                   "d5": ["US1MA01", "US5SHARED"]])
        m.picked = []

        let gone = m.regions.filter { $0.id == "d1" }
        XCTAssertEqual(m.cellsToRemove(unpicking: gone), ["US1NE01", "US5SHARED"])
    }

    func testRemovedRegionsAreTheOnesUnticked() {
        let (m, _) = model(cells: ["d1": ["US1NE01"], "d5": ["US1MA01"]])
        m.picked = ["d5"]

        XCTAssertEqual(m.removedRegions(from: ["d1", "d5"]).map(\.id), ["d1"])
        XCTAssertEqual(m.removedRegions(from: ["d5"]).map(\.id), [])
    }
}
