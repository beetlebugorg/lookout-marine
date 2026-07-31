// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

pragma Singleton
import QtQuick

// The chrome's sizes and colours, from the Apple shell's `Chrome`
// (macos/LookoutMarine/Chrome.swift) — which in turn takes them from the WinUI 3
// shell, because the Mac, the iPad and the PC must look the same. The reMarkable
// joins that set, with two adaptations the panel forces and nothing else.
//
// ADAPTATION 1 — SIZE. Apple's numbers are in points, at the iPad's 132 ppi
// point density. The rM2's panel is 226 ppi, so a 48pt bubble drawn 48 px wide
// would measure 5.4 mm instead of 9.2 mm — too small to hit. `ui` is the ratio
// 226/132, so every metric below comes out the same PHYSICAL size as on the
// iPad. It is a property of the glass, not a taste knob.
//
// ADAPTATION 2 — COLOUR. There is none. The accent blue, the amber dot and the
// overscale orange all carry meaning on a colour screen; here they become
// weight, fill and inversion. Each one is noted where it is defined.
QtObject {
    // 226 ppi panel / 132 ppi point. Everything scales through this one number.
    readonly property real ui: 226 / 132

    // ---- ink ---------------------------------------------------------------
    readonly property color ink: "#1a1a1a"       // Chrome.ink
    readonly property color muted: "#6b6b6b"     // Chrome.muted
    readonly property color surface: "#ffffff"   // Chrome.surface
    readonly property color panel: "#f8f8f8"     // Chrome.panel
    readonly property color rule: "#dddddd"      // Chrome.rule (hairline separators)
    readonly property color edge: "#33000000"    // Chrome.edge (panel border, 20% black)

    // Chrome.accent is #1B49C4 — the scale readout and a file reference. On a
    // panel with no colour, the same emphasis has to come from weight, so the
    // accent is ink and the type carries it.
    readonly property color accent: "#1a1a1a"
    // Chrome.amber marks the readout capsule's leading dot. A filled black dot
    // reads the same way against white paper.
    readonly property color amber: "#1a1a1a"
    // Chrome.overscale is #D83B01. The badge inverts instead: white on black.
    readonly property color overscale: "#000000"
    // Chrome.magenta rings the picked object. Black, over a white halo, is what
    // survives on e-ink.
    readonly property color magenta: "#000000"

    readonly property color pressedFill: "#dedede"
    readonly property color hoverFill: "#f2f2f2"

    // ---- metrics (Chrome's, x ui) ------------------------------------------
    readonly property int bubble: Math.round(48 * ui)   // Chrome.bubble
    readonly property int gap: Math.round(10 * ui)      // Chrome.gap
    readonly property int margin: Math.round(16 * ui)   // Chrome.margin
    readonly property int capsule: Math.round(44 * ui)  // Chrome.capsule
    readonly property int radius: Math.round(8 * ui)
    readonly property int radiusLg: Math.round(12 * ui)
    readonly property int pickMarker: Math.round(34 * ui) // PickMarker.size

    // The pick report: PickReportPanel.width / .maxHeight.
    readonly property int reportWidth: Math.round(420 * ui)
    readonly property int reportMaxHeight: Math.round(460 * ui)
    // ScaleEntryPanel is a fixed 340pt wide.
    readonly property int scaleEntryWidth: Math.round(340 * ui)
    // The settings panel is a sheet on iOS; here it is a fixed column.
    readonly property int settingsWidth: Math.round(560 * ui)

    // A touch target no smaller than this. The Apple bubbles already clear it;
    // the rows inside the panels are sized to it.
    readonly property int touch: Math.round(44 * ui)

    // ---- type --------------------------------------------------------------
    // The Apple chrome uses the system font at these sizes.
    readonly property string fontFamily: "Noto Sans"
    readonly property string fontMono: "Noto Sans Mono"
    readonly property int fontTitle: Math.round(16 * ui)   // report class name
    readonly property int fontBody: Math.round(14 * ui)    // readouts, values
    readonly property int fontLabel: Math.round(13 * ui)
    readonly property int fontSmall: Math.round(12 * ui)   // attribute names, chart
    readonly property int fontTiny: Math.round(11 * ui)

    // An e-ink panel cannot animate; every frame is a full refresh. Bind
    // durations to this so the whole UI is still with one switch.
    readonly property int anim: 0
}
