//  NoaaModelTests.swift — the catalog line, and what a removal deletes.
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
