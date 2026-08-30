//  RasterPill.swift — what the raster pill says.
//
//  A picture chart under the survey is a real reduction in what the chart is
//  telling the mariner: with one on, the ENC drops its opaque water and land
//  fills to let the picture through. The pill exists so that is never mistaken
//  for the full chart, and it must therefore be right about which picture and
//  in what state.
//
//  Pure, so it is checked directly. See RasterPillTests.

import SwiftUI

struct RasterPill: Equatable {
    enum State: Equatable {
        /// The named set is drawn, under the ENC.
        case on
        /// It covers this water and is not drawn.
        case off
        /// It is drawn, and the ENC above it is hidden.
        case chartOff
    }

    /// The sets covering this view. The pill appears only for these: a control
    /// that is useless here is noise.
    let inView: [ChartController.RasterSet]
    /// The set the pill NAMES: the drawn one when it is in view, otherwise the
    /// first one that is. Naming one set and reporting the state of another is
    /// how the pill came to read "NAVIONICS | OFF" while Navionics was drawn.
    let name: String
    let state: State

    init(inView: [ChartController.RasterSet], active: Int, chartHidden: Bool) {
        self.inView = inView
        let named = inView.first { $0.id == active } ?? inView.first
        name = named?.name ?? ""
        // Read from the set the pill names, so the two can never disagree.
        if let named, named.id == active {
            state = chartHidden ? .chartOff : .on
        } else {
            state = .off
        }
    }

    /// True when there is anything to show. No coverage, no pill.
    var isShown: Bool { !inView.isEmpty }

    /// The colour reports THE RASTER CHART, not the ENC: blue while the picture
    /// is drawn, amber while one is here and off. Hiding the ENC above it does
    /// not change the colour, because the picture is still drawn. The "ENC OFF"
    /// text carries that, and a warning colour there would say the picture was
    /// off when it is the only thing on screen.
    var tint: Color { state == .off ? Chrome.amber : Chrome.accent }

    /// The state as one stable word, for assistive technology and for the UI
    /// tests. The help text reads well and changes wording freely; this does
    /// not, so a test can rely on it.
    var stateName: String {
        switch state {
        case .on: return "drawn"
        case .off: return "off"
        case .chartOff: return "drawn, ENC hidden"
        }
    }

    var help: String {
        let more = inView.count > 1
            ? " \(inView.count) raster charts cover this view; right-click to choose." : ""
        switch state {
        case .off: return "\(name) is here but off. Click to choose it." + more
        case .chartOff: return "\(name), with the ENC hidden above it. Click to choose another." + more
        case .on: return "\(name) below the ENC. Click to choose another." + more
        }
    }
}
