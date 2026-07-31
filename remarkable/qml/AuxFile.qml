// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// A file a feature points at rather than carries, read through the core and
// shown here: the text of a caution note, or the diagram itself. The Apple
// shell's `AuxFileView`.
//
// A cell names it in TXTDSC, NTXTDS or PICREP (S-101 puts the same in a
// fileReference), the bake stores it beside the chart, and lookout_aux_file
// reads it back. A chart baked before that carries the name alone, which is why
// there is a "does not carry" state rather than an error.
Column {
    id: root

    property var view: null
    property string cell: ""
    property string name: ""
    property bool isPicture: false
    signal pictureRequested(string name, string dataUrl)

    property var loaded: null
    property bool tried: false

    spacing: Math.round(6 * Theme.ui)

    function load() {
        if (tried || !view || name === "")
            return
        tried = true
        const r = view.auxFile(cell, name)
        loaded = (r && r.ok) ? r : null
    }

    Component.onCompleted: load()
    onNameChanged: { tried = false; loaded = null; load() }

    Row {
        spacing: Math.round(6 * Theme.ui)
        GlyphIcon {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(Theme.fontSmall * 1.1); height: width
            name: root.isPicture ? "photo" : "doc.text"
            color: Theme.accent
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.name
            color: Theme.ink
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBody
        }
    }

    // A diagram. Tap it for full size — 340pt of a chart plan is unreadable.
    Rectangle {
        visible: root.loaded !== null && root.loaded.isPicture && picture.status === Image.Ready
        width: root.width
        height: Math.min(picture.implicitHeight * (width / Math.max(1, picture.implicitWidth)),
                         Math.round(340 * Theme.ui))
        color: "transparent"
        border.width: 1
        border.color: Theme.edge
        radius: Math.round(6 * Theme.ui)
        clip: true

        Image {
            id: picture
            anchors.fill: parent
            anchors.margins: 1
            source: (root.loaded && root.loaded.isPicture) ? root.loaded.dataUrl : ""
            fillMode: Image.PreserveAspectFit
            smooth: false // e-ink: no interpolation, keep the hard edges
            asynchronous: true
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.pictureRequested(root.name, root.loaded.dataUrl)
        }
    }

    // A caution or a port description. No scroller here — the report itself
    // scrolls, and a note inside its own little scroller fights the one around
    // it. A caution is worth reading in full.
    Rectangle {
        visible: root.loaded !== null && !root.loaded.isPicture
                 && root.loaded.text !== undefined && root.loaded.text !== ""
        width: root.width
        height: note.implicitHeight + Math.round(16 * Theme.ui)
        color: Qt.rgba(0, 0, 0, 0.05)
        radius: Math.round(6 * Theme.ui)

        Text {
            id: note
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Math.round(8 * Theme.ui)
            text: root.loaded ? root.loaded.text : ""
            color: Theme.ink
            font.family: Theme.fontMono
            font.pixelSize: Theme.fontTiny
            wrapMode: Text.WordWrap
        }
    }

    // The picture came back but Qt could not decode it. An ENC usually carries
    // TIFF, and the device's Qt may ship no plugin for it; say so rather than
    // leaving an empty box.
    Text {
        visible: root.loaded !== null && root.loaded.isPicture
                 && picture.status === Image.Error
        text: qsTr("This diagram is in a format the tablet cannot show.")
        color: Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontTiny
    }

    Text {
        visible: root.loaded === null && root.tried
        text: qsTr("The chart does not carry this file.")
        color: Theme.muted
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontTiny
    }
}
