//  MarinerSettings.swift — Swift mirror of `tile57_mariner` + SwiftUI bindings.
//
//  A round-trippable model of the full S-52 mariner state. It keeps the ENGINE's
//  own struct as `raw` so fields we don't surface (device_scale, viewing_groups_
//  off, ignore_scamin, scamin_filter_gate) are preserved untouched; the exposed
//  fields are @Published so the settings Form binds to them directly.
//
//  Flow (see SettingsView): load(from: controller.getMariner()) on open, edit,
//  then controller.setMariner(toMariner()). Visibility changes apply live; the
//  emission-changing ones rebuild lazily on the next render.
//
//  Enum bridging: tile57's enums are plain C enums, imported by Swift as structs
//  with a UInt32 `rawValue` and an `init(_:)`. The Int raw values below match
//  tile57.h (verified): scheme 0/1/2, depth 0/1, boundary 0/1, category 0/1/2.
//  Everything crosses the boundary through the tiny helpers at the bottom, so if
//  the header's enums ever change shape, this is the one place to adjust.

import Foundation
import Combine

enum MarinerScheme: Int, CaseIterable, Identifiable {
    case day = 0, dusk = 1, night = 2
    var id: Int { rawValue }
    var label: String { ["Day", "Dusk", "Night"][rawValue] }
}

enum MarinerDepthUnit: Int, CaseIterable, Identifiable {
    case meters = 0, feet = 1
    var id: Int { rawValue }
    var label: String { ["Meters", "Feet"][rawValue] }
}

enum MarinerDisplayCategory: Int, CaseIterable, Identifiable {
    case base = 0, standard = 1, other = 2
    var id: Int { rawValue }
    var label: String { ["Base", "Standard", "Other"][rawValue] }
}

enum MarinerBoundaryStyle: Int, CaseIterable, Identifiable {
    case symbolized = 0, plain = 1
    var id: Int { rawValue }
    var label: String { ["Symbolized", "Plain"][rawValue] }
}

enum MarinerSoundings: Int, CaseIterable, Identifiable {
    case followCategory = 0, forceOn = 1, forceOff = 2
    var id: Int { rawValue }
    var label: String { ["Follow category", "Always on", "Always off"][rawValue] }
}

@MainActor
final class MarinerSettings: ObservableObject {
    /// The engine's struct verbatim; edited fields are overlaid in `toMariner()`.
    private var raw = tile57_mariner()
    private weak var controller: ChartController?
    private var applyCancellable: AnyCancellable?

    // Color scheme — live
    @Published var scheme: MarinerScheme = .day

    // Depth unit + contours — rebuild
    @Published var depthUnit: MarinerDepthUnit = .meters
    @Published var shallowContour = 2.0
    @Published var safetyContour = 10.0
    @Published var deepContour = 30.0
    @Published var safetyDepth = 10.0
    @Published var fourShadeWater = true

    // Display category (Base⊂Standard⊂Other) — live; soundings independent — live
    @Published var displayCategory: MarinerDisplayCategory = .standard
    @Published var soundings: MarinerSoundings = .followCategory

    // Text — live
    @Published var textNames = true
    @Published var showLightDescriptions = true
    @Published var textOther = true

    // Symbols — rebuild (point/boundary style)
    @Published var simplifiedPoints = false
    @Published var boundaryStyle: MarinerBoundaryStyle = .symbolized
    @Published var showFullSectorLines = false

    // Safety & quality — mostly rebuild
    @Published var dataQuality = false
    @Published var showIsolatedDangersShallow = false
    @Published var showInformCallouts = false
    @Published var showMetaBounds = false
    @Published var showOverscale = true

    // Sizing — rebuild
    @Published var sizeScale = 1.0
    @Published var textSizeScale = 1.0
    @Published var soundingSizeScale = 1.0

    // Dates — rebuild
    @Published var dateDependent = true
    @Published var highlightDateDependent = false
    @Published var dateView = ""   // "YYYYMMDD" or "" (today)

    // MARK: - Binding

    /// Bind to the live chart: load its current state, then auto-apply edits
    /// (debounced so text/slider drags don't thrash the engine). Call on appear.
    func bind(to controller: ChartController?) {
        applyCancellable = nil                       // don't echo the load below
        self.controller = controller
        load(from: controller?.getMariner() ?? defaultMariner())
        applyCancellable = objectWillChange
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.controller?.setMariner(self.toMariner())
            }
    }

    private func defaultMariner() -> tile57_mariner {
        var m = tile57_mariner()
        lookout_mariner_defaults(&m)
        return m
    }

    // MARK: - Load / apply

    func load(from m: tile57_mariner) {
        raw = m
        scheme = MarinerScheme(rawValue: Int(m.scheme.rawValue)) ?? .day
        depthUnit = MarinerDepthUnit(rawValue: Int(m.depth_unit.rawValue)) ?? .meters
        shallowContour = m.shallow_contour
        safetyContour = m.safety_contour
        deepContour = m.deep_contour
        safetyDepth = m.safety_depth
        fourShadeWater = m.four_shade_water
        displayCategory = Self.category(base: m.display_base, standard: m.display_standard, other: m.display_other)
        soundings = MarinerSoundings(rawValue: Int(m.soundings)) ?? .followCategory
        textNames = m.text_names
        showLightDescriptions = m.show_light_descriptions
        textOther = m.text_other
        simplifiedPoints = m.simplified_points
        boundaryStyle = MarinerBoundaryStyle(rawValue: Int(m.boundary_style.rawValue)) ?? .symbolized
        showFullSectorLines = m.show_full_sector_lines
        dataQuality = m.data_quality
        showIsolatedDangersShallow = m.show_isolated_dangers_shallow
        showInformCallouts = m.show_inform_callouts
        showMetaBounds = m.show_meta_bounds
        showOverscale = m.show_overscale
        sizeScale = m.size_scale == 0 ? 1.0 : m.size_scale
        textSizeScale = m.text_size_scale == 0 ? 1.0 : m.text_size_scale
        soundingSizeScale = m.sounding_size_scale == 0 ? 1.0 : m.sounding_size_scale
        dateDependent = m.date_dependent
        highlightDateDependent = m.highlight_date_dependent
        dateView = m.dateViewString
    }

    /// The full struct to hand back to the engine: `raw` with the exposed fields
    /// overlaid (so device_scale, viewing_groups_off, … survive round-trips).
    func toMariner() -> tile57_mariner {
        var m = raw
        m.scheme = tile57_scheme(UInt32(scheme.rawValue))
        m.depth_unit = tile57_depth_unit(UInt32(depthUnit.rawValue))
        m.shallow_contour = shallowContour
        m.safety_contour = safetyContour
        m.deep_contour = deepContour
        m.safety_depth = safetyDepth
        m.four_shade_water = fourShadeWater
        // Base⊂Standard⊂Other: standard implies base, other implies standard.
        m.display_base = true
        m.display_standard = displayCategory != .base
        m.display_other = displayCategory == .other
        m.soundings = UInt8(soundings.rawValue)
        m.text_names = textNames
        m.show_light_descriptions = showLightDescriptions
        m.text_other = textOther
        m.simplified_points = simplifiedPoints
        m.boundary_style = tile57_boundary_style(UInt32(boundaryStyle.rawValue))
        m.show_full_sector_lines = showFullSectorLines
        m.data_quality = dataQuality
        m.show_isolated_dangers_shallow = showIsolatedDangersShallow
        m.show_inform_callouts = showInformCallouts
        m.show_meta_bounds = showMetaBounds
        m.show_overscale = showOverscale
        m.size_scale = sizeScale
        m.text_size_scale = textSizeScale
        m.sounding_size_scale = soundingSizeScale
        m.date_dependent = dateDependent
        m.highlight_date_dependent = highlightDateDependent
        m.setDateView(dateView)
        return m
    }

    private static func category(base: Bool, standard: Bool, other: Bool) -> MarinerDisplayCategory {
        if other { return .other }
        if standard { return .standard }
        return .base
    }
}

// MARK: - date_view[9] <-> String (fixed C char array is a Swift tuple)

extension tile57_mariner {
    var dateViewString: String {
        var copy = date_view
        return withUnsafeBytes(of: &copy) { raw in
            let p = raw.bindMemory(to: CChar.self)
            var bytes: [UInt8] = []
            for c in p { if c == 0 { break }; bytes.append(UInt8(bitPattern: c)) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
    mutating func setDateView(_ s: String) {
        let utf8 = Array(s.utf8.prefix(8))
        withUnsafeMutableBytes(of: &date_view) { raw in
            let p = raw.bindMemory(to: CChar.self)
            for i in 0..<raw.count { p[i] = 0 }
            for (i, b) in utf8.enumerated() { p[i] = CChar(bitPattern: b) }
        }
    }
}
