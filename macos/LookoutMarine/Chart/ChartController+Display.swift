//  ChartController+Display.swift — what the chart draws, and how big.
//
//  The scheme, the text, the soundings, the other-category layer and the safety
//  contour. Each is one call and a kick: the core owns the setting, and the
//  mariner settings form saves what it reads back.

import Foundation

@MainActor
extension ChartController {
    func cycleScheme()        { guard let h = handle else { return }; lookout_cycle_scheme(h); kick(); pushReadouts() }
    func toggleText()         { guard let h = handle else { return }; lookout_toggle_text(h); kick() }
    func toggleSoundings()    { guard let h = handle else { return }; lookout_toggle_soundings(h); kick() }
    func toggleOtherCategory(){ guard let h = handle else { return }; lookout_toggle_other_category(h); kick() }
    func nudgeSafetyContour(_ d: Double) { guard let h = handle else { return }; lookout_nudge_safety_contour(h, d); kick() }
    func adjustSize(_ f: Float) { guard let h = handle else { return }; lookout_adjust_size(h, f); kick() }

    var scaleDenominator: Double {
        guard let h = handle else { return 0 }
        return lookout_scale_denominator(h)
    }
}
