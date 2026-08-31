//  MarinerSettingsTests.swift — the S-52 mariner state, saved and put back.
//
//  Saved field by field, not as raw struct bytes: the engine struct's layout is
//  an ABI detail that changes, and a versioned dictionary survives that.

import XCTest
@testable import LookoutMarine

final class MarinerSettingsTests: ShellTestCase {

    private func defaults() -> tile57_mariner {
        var m = tile57_mariner()
        lookout_mariner_defaults(&m)
        return m
    }

    func testNothingSavedLeavesTheEngineDefaults() {
        var m = defaults()
        let before = m
        MarinerSettings.applySavedOverlay(&m)
        XCTAssertEqual(m.safety_contour, before.safety_contour)
        XCTAssertEqual(m.scheme.rawValue, before.scheme.rawValue)
    }

    func testEveryFieldRoundTrips() {
        var saved = defaults()
        saved.scheme = tile57_scheme(2)
        saved.depth_unit = tile57_depth_unit(1)
        saved.shallow_contour = 3
        saved.safety_contour = 7
        saved.deep_contour = 22
        saved.safety_depth = 6
        saved.four_shade_water = false
        saved.display_base = true
        saved.display_standard = true
        saved.display_other = true
        saved.soundings = 2
        saved.text_names = false
        saved.show_light_descriptions = false
        saved.text_other = false
        saved.simplified_points = true
        saved.boundary_style = tile57_boundary_style(1)
        saved.show_full_sector_lines = true
        saved.data_quality = true
        saved.show_isolated_dangers_shallow = true
        saved.show_inform_callouts = true
        saved.show_meta_bounds = true
        saved.show_overscale = false
        saved.size_scale = 1.25
        saved.text_size_scale = 0.75
        saved.sounding_size_scale = 1.5
        saved.date_dependent = false
        saved.highlight_date_dependent = true
        saved.setDateView("20260401")
        MarinerSettings.save(saved)

        var m = defaults()
        MarinerSettings.applySavedOverlay(&m)
        XCTAssertEqual(m.scheme.rawValue, 2)
        XCTAssertEqual(m.depth_unit.rawValue, 1)
        XCTAssertEqual(m.shallow_contour, 3)
        XCTAssertEqual(m.safety_contour, 7)
        XCTAssertEqual(m.deep_contour, 22)
        XCTAssertEqual(m.safety_depth, 6)
        XCTAssertFalse(m.four_shade_water)
        XCTAssertTrue(m.display_other)
        XCTAssertEqual(m.soundings, 2)
        XCTAssertFalse(m.text_names)
        XCTAssertFalse(m.show_light_descriptions)
        XCTAssertFalse(m.text_other)
        XCTAssertTrue(m.simplified_points)
        XCTAssertEqual(m.boundary_style.rawValue, 1)
        XCTAssertTrue(m.show_full_sector_lines)
        XCTAssertTrue(m.data_quality)
        XCTAssertTrue(m.show_isolated_dangers_shallow)
        XCTAssertTrue(m.show_inform_callouts)
        XCTAssertTrue(m.show_meta_bounds)
        XCTAssertFalse(m.show_overscale)
        XCTAssertEqual(m.size_scale, 1.25)
        XCTAssertEqual(m.text_size_scale, 0.75)
        XCTAssertEqual(m.sounding_size_scale, 1.5)
        XCTAssertFalse(m.date_dependent)
        XCTAssertTrue(m.highlight_date_dependent)
        XCTAssertEqual(m.dateViewString, "20260401")
    }

    /// A zero size scale would draw nothing. A saved zero is ignored rather
    /// than applied.
    func testAZeroSizeScaleIsIgnored() {
        var saved = defaults()
        saved.size_scale = 0
        saved.text_size_scale = 0
        saved.sounding_size_scale = 0
        MarinerSettings.save(saved)
        var m = defaults()
        m.size_scale = 1
        m.text_size_scale = 1
        m.sounding_size_scale = 1
        MarinerSettings.applySavedOverlay(&m)
        XCTAssertEqual(m.size_scale, 1)
        XCTAssertEqual(m.text_size_scale, 1)
        XCTAssertEqual(m.sounding_size_scale, 1)
    }

    /// A key this build does not know about leaves the field alone.
    func testAnUnknownKeyChangesNothing() {
        Store.shared.set(1, Store.Group.mariner, "scheme")
        Store.shared.set(9, Store.Group.mariner, "not_a_field")
        var m = defaults()
        MarinerSettings.applySavedOverlay(&m)
        XCTAssertEqual(m.scheme.rawValue, 1)
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
