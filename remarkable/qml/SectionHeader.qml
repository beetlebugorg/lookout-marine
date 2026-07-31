// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// A section heading in the settings, and the footer line under it that explains
// what the section does. The Apple panel's Section header / captionFooter — the
// explanations are worth carrying over verbatim: they are what stopped the
// four-shade water model being reported as a bug.
Column {
    property string text: ""
    property string footer: ""

    spacing: Math.round(4 * Theme.ui)
    topPadding: Math.round(18 * Theme.ui)
    bottomPadding: Math.round(6 * Theme.ui)

    Text {
        text: parent.text
        color: Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSmall
        font.bold: true
        font.capitalization: Font.AllUppercase
    }
    Text {
        visible: parent.footer !== ""
        width: parent.parent ? parent.parent.width : implicitWidth
        text: parent.footer
        color: Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontTiny
        wrapMode: Text.WordWrap
    }
}
