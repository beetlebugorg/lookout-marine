//  ChartFixture.swift — the chart the UI tests open.
//
//  These tests used to name one developer's home directory. Anywhere else that
//  path is not there, the app falls through to its next candidate, and the test
//  asserts against a chart it did not choose instead of failing.
//
//  The order here is: whatever $LOOKOUT_TEST_CHART names, else the baked cell
//  this repository carries for the Android build, else skip. The simulator runs
//  on the host filesystem, so a host path reaches it.

import XCTest

enum ChartFixture {
    /// The baked Annapolis cell, US5MD1MC. Skips when there is none.
    static func chart(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        if let named = ProcessInfo.processInfo.environment["LOOKOUT_TEST_CHART"],
           FileManager.default.fileExists(atPath: named) {
            return named
        }
        let inRepo = repository
            .appendingPathComponent("android/app/src/main/assets/charts/US5MD1MC.pmtiles")
        if FileManager.default.fileExists(atPath: inRepo.path) { return inRepo.path }
        throw XCTSkip("no chart to open: set LOOKOUT_TEST_CHART, or run from a checkout")
    }

    /// The repository, from this source file's own path.
    static var repository: URL {
        URL(fileURLWithPath: #filePath)      // apple/LookoutMarine-iOS/UITests/ChartFixture.swift
            .deletingLastPathComponent()     // UITests
            .deletingLastPathComponent()     // LookoutMarine-iOS
            .deletingLastPathComponent()     // macos
            .deletingLastPathComponent()     // the repository
    }
}

extension XCUIApplication {
    /// Launch on `chart`, framed where the test expects it.
    func launch(chart: String, view: String) {
        launchEnvironment["LOOKOUT_OPEN"] = chart
        launchEnvironment["LOOKOUT_VIEW"] = view
        launch()
    }
}
