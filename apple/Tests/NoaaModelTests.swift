//  NoaaModelTests.swift: the catalog line, the ticks the picker opens with,
//  and the pick handed to the core.
//
//  These run against FakeEngine, so the catalog, what a region costs and what
//  the core counts of it are whatever the test sets. The region table comes
//  from the core, so the ids here are the real ones.

import XCTest
@testable import LookoutMarine

@MainActor
final class NoaaModelTests: ShellTestCase {

    /// The engine is held by the test. The model's reference is weak, as the
    /// chart view owns the controller.
    private var engine = FakeEngine()

    /// A model reading a loaded catalog, with the regions the core counts.
    private func model(regions: [String: NoaaRegionState] = [:]) -> (NoaaModel, FakeEngine) {
        engine = FakeEngine()
        engine.noaa.phase = .ready
        engine.noaa.haveCatalog = true
        engine.noaa.catalogCells = 7318
        engine.noaa.date = "20260915"
        engine.noaaRegions = regions
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

    // MARK: The ticks the picker opens with

    /// The core ticks what it recorded and still holds whole. A region held
    /// whole that the record leaves out stays unticked.
    func testThePickerOpensOnTheWaterTheCoreRecorded() {
        let (m, _) = model(regions: [
            "d1": NoaaRegionState(cells: 2, held: 2, allHeld: true, recorded: true),
            "d5": NoaaRegionState(cells: 2, held: 2, allHeld: true, recorded: false),
        ])

        m.pickRecorded()

        XCTAssertEqual(m.picked, ["d1"])
        XCTAssertEqual(m.regionState["d5"]?.allHeld, true)
    }

    /// The Mac window builds a new picker, and seeds it again, each time it
    /// opens. A tick abandoned with Cancel is dropped.
    func testASecondSeedDropsAnAbandonedTick() {
        let (m, _) = model(regions: [
            "d1": NoaaRegionState(cells: 1, held: 1, allHeld: true, recorded: true),
        ])
        m.pickRecorded()
        m.toggle("d5")
        XCTAssertEqual(m.picked, ["d1", "d5"])

        m.pickRecorded()
        XCTAssertEqual(m.picked, ["d1"])
    }

    // MARK: Reissued charts

    func testACheckCountsWhatTheCatalogReissued() {
        let (m, fake) = model()
        fake.noaaOutdatedCount = 721
        fake.noaaDue = true
        fake.noaa.updateCheckedAt = Date()

        m.considerUpdateCheck()

        XCTAssertFalse(m.checking)
        XCTAssertEqual(m.outdated, 721)
    }

    /// The check waits on the catalog read, and counts when the core records
    /// it.
    func testACheckCountsWhenTheCoreRecordsIt() {
        let (m, fake) = model()
        fake.noaaOutdatedCount = 721
        fake.noaaDue = true
        fake.noaa.updateChecking = true

        m.considerUpdateCheck()
        XCTAssertTrue(m.checking)
        XCTAssertEqual(m.outdated, 0)

        fake.noaa.updateChecking = false
        fake.noaa.updateCheckedAt = Date()
        m.poll()
        XCTAssertFalse(m.checking)
        XCTAssertEqual(m.outdated, 721)
    }

    /// The cadence is the core's.
    func testTheCadenceIsTheCores() {
        let (m, fake) = model()
        XCTAssertEqual(m.updateCheck, .daily)
        m.updateCheck = .never
        XCTAssertEqual(fake.noaaCadence, 0)
        XCTAssertEqual(m.updateCheck, .never)
    }

    /// The count follows the library. An update that baked leaves the cells
    /// at the editions the catalog holds, and the line on the charts page
    /// goes with the count.
    func testACountAfterAnUpdateClears() {
        let (m, fake) = model()
        fake.noaaOutdatedCount = 721
        fake.noaaDue = true
        fake.noaa.updateCheckedAt = Date()
        m.considerUpdateCheck()
        XCTAssertEqual(m.outdated, 721)

        // The newer edition is in the library now.
        fake.noaaOutdatedCount = 0
        m.recount()

        XCTAssertEqual(m.outdated, 0)
    }

    /// A check the core does not find due leaves the count alone.
    func testACheckThatIsNotDueDoesNotCount() {
        let (m, fake) = model()
        fake.noaaOutdatedCount = 721

        m.considerUpdateCheck()
        m.recount()

        XCTAssertEqual(m.outdated, 0)
        XCTAssertFalse(fake.calls.contains("noaaOutdated"))
    }

    // MARK: Apply

    /// Apply hands the whole pick to the core in one call, an empty one
    /// included, and returns what the core took out.
    func testApplyHandsThePickToTheCore() {
        let (m, fake) = model()
        fake.noaaMoved = 4
        m.picked = ["d5", "d1"]

        XCTAssertEqual(m.apply(to: "/charts/NOAA"), 4)

        m.picked = []
        _ = m.apply(to: "/charts/NOAA")
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("noaaApply") },
                       ["noaaApply(d1,d5, /charts/NOAA, again: false)",
                        "noaaApply(, /charts/NOAA, again: false)"])
    }
}
