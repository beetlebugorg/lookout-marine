//  MarinerSettingsTests.swift — the S-52 mariner state, as the form holds it.
//
//  Saving it is the ENGINE's: lookout_set_store hands it the shell's store and
//  it writes every field. src/root.zig asserts the round trip, the zero-scale
//  rule and what a missing key does. What is left here is the fixed
//  date_view[9] array and the form's own mappings.

import XCTest
@testable import LookoutMarine

final class MarinerSettingsTests: ShellTestCase {

    private func defaults() -> tile57_mariner {
        var m = tile57_mariner()
        lookout_mariner_defaults(&m)
        return m
    }

    // MARK: The fixed date_view[9] array

    func testTheDateIsWrittenAndReadBack() {
        var m = defaults()
        m.setDateView("20260401")
        XCTAssertEqual(m.dateViewString, "20260401")
    }

    /// Empty is today, which is what the form's footer says.
    func testAnEmptyDateIsEmpty() {
        var m = defaults()
        m.setDateView("20260401")
        m.setDateView("")
        XCTAssertEqual(m.dateViewString, "")
    }

    /// The array is nine bytes, eight of them the date. Anything longer is cut
    /// rather than running off the end.
    func testALongerDateIsCutToEight() {
        var m = defaults()
        m.setDateView("2026040112345")
        XCTAssertEqual(m.dateViewString, "20260401")
    }

    // MARK: The model the form binds to

    /// Base is always on, standard implies base, other implies standard.
    @MainActor func testTheDisplayCategoryImplications() {
        let s = MarinerSettings()
        s.load(from: defaults())

        s.displayCategory = .base
        var m = s.toMariner()
        XCTAssertTrue(m.display_base)
        XCTAssertFalse(m.display_standard)
        XCTAssertFalse(m.display_other)

        s.displayCategory = .standard
        m = s.toMariner()
        XCTAssertTrue(m.display_base)
        XCTAssertTrue(m.display_standard)
        XCTAssertFalse(m.display_other)

        s.displayCategory = .other
        m = s.toMariner()
        XCTAssertTrue(m.display_base)
        XCTAssertTrue(m.display_standard)
        XCTAssertTrue(m.display_other)
    }

    @MainActor func testTheCategoryIsReadBackFromTheThreeFlags() {
        let s = MarinerSettings()
        var m = defaults()
        m.display_base = true; m.display_standard = false; m.display_other = false
        s.load(from: m)
        XCTAssertEqual(s.displayCategory, .base)
        m.display_standard = true
        s.load(from: m)
        XCTAssertEqual(s.displayCategory, .standard)
        m.display_other = true
        s.load(from: m)
        XCTAssertEqual(s.displayCategory, .other)
    }

    /// The engine struct has fields the form does not show. They survive a
    /// round trip through the model rather than being zeroed.
    @MainActor func testUnshownFieldsSurviveARoundTrip() {
        let s = MarinerSettings()
        var m = defaults()
        m.device_scale = 2.0
        m.ignore_scamin = true
        s.load(from: m)
        let out = s.toMariner()
        XCTAssertEqual(out.device_scale, 2.0)
        XCTAssertTrue(out.ignore_scamin)
    }

    /// A zero from the engine means "not set", and the form shows 1x.
    @MainActor func testAZeroScaleLoadsAsOne() {
        let s = MarinerSettings()
        var m = defaults()
        m.size_scale = 0; m.text_size_scale = 0; m.sounding_size_scale = 0
        s.load(from: m)
        XCTAssertEqual(s.sizeScale, 1)
        XCTAssertEqual(s.textSizeScale, 1)
        XCTAssertEqual(s.soundingSizeScale, 1)
    }

    /// Every label is indexed by the raw value, so a mismatch is an index out
    /// of range rather than a wrong word.
    func testEveryEnumHasALabelForEveryCase() {
        XCTAssertEqual(MarinerScheme.allCases.map(\.label), ["Day", "Dusk", "Night"])
        XCTAssertEqual(MarinerDepthUnit.allCases.map(\.label), ["Meters", "Feet"])
        XCTAssertEqual(MarinerDisplayCategory.allCases.map(\.label),
                       ["Base", "Standard", "Other"])
        XCTAssertEqual(MarinerBoundaryStyle.allCases.map(\.label), ["Symbolized", "Plain"])
        XCTAssertEqual(MarinerSoundings.allCases.map(\.label),
                       ["Follow category", "Always on", "Always off"])
        XCTAssertTrue(MarinerDisplayCategory.allCases.allSatisfy { !$0.desc.isEmpty })
        XCTAssertTrue(MarinerSoundings.allCases.allSatisfy { !$0.desc.isEmpty })
    }
}
