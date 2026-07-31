// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// The floating panel surface — the Apple shell's `panelSurface()`: the pick
// report, the scale entry, the settings, the empty state.
//
// `opaque` is the report's: a table of numbers with the chart showing through
// makes both hard to read. On e-ink every panel is opaque anyway, since there is
// no compositing to soften a translucent fill — the difference here is only the
// fill colour, white against the panel grey.
//
// The Apple version carries a drop shadow. A soft shadow on e-ink dithers into a
// visible band, so the border does the lifting instead.
Rectangle {
    property bool opaque: false

    color: opaque ? Theme.surface : Theme.panel
    radius: Theme.radiusLg
    border.width: 1
    border.color: Theme.edge
    antialiasing: true
}
