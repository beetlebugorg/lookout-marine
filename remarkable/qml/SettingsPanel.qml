// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// The S-52 mariner settings, in the Apple shell's five groups — Display, Depths,
// Text, Charts, Advanced (macos/LookoutMarine/SettingsView.swift). The mariner
// thinks in those groups on every platform, so the panel is arranged the same
// way and the footers explain the same things.
//
// The Depths section in particular keeps its explanation word for word: the
// single most-reported "bug" on the Mac was a safety-contour change not turning
// water white, which is four-shade semantics — white starts at the DEEP contour
// — plus chart-ladder snapping, and not a bug at all.
//
// Edits apply live. There is no Save: the core takes the whole state on every
// change and re-portrays what it must.
Panel {
    id: root

    property var settings: null
    property var view: null
    signal closed()
    signal openChartRequested()

    property int tab: 0
    readonly property var tabs: [qsTr("Display"), qsTr("Depths"), qsTr("Text"),
                                 qsTr("Charts"), qsTr("Advanced")]
    readonly property bool feet: settings && settings.depthUnit === MarinerSettings.Feet
    readonly property string unit: feet ? qsTr("ft") : qsTr("m")

    // The engine always takes metres; feet is a display conversion only.
    function toDisplay(metres) { return feet ? Math.round(metres * 3.28084) : metres }
    function fromDisplay(v) { return feet ? v / 3.28084 : v }

    width: Theme.settingsWidth

    Column {
        anchors.fill: parent

        // ---- title + tabs ---------------------------------------------------
        Item {
            width: parent.width
            height: Theme.touch + Theme.margin

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.margin
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Settings")
                color: Theme.ink
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontTitle
                font.bold: true
            }
            FlatButton {
                anchors.right: parent.right
                anchors.rightMargin: Theme.margin
                anchors.verticalCenter: parent.verticalCenter
                icon: "xmark"
                radius: Math.round(6 * Theme.ui)
                onClicked: root.closed()
            }
        }

        Row {
            width: parent.width
            Repeater {
                model: root.tabs
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: root.width / root.tabs.length
                    height: Theme.touch

                    Rectangle {
                        anchors.fill: parent
                        color: index === root.tab ? Theme.surface : "transparent"
                    }
                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: Theme.ink
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontLabel
                        font.bold: index === root.tab
                    }
                    // The selected tab is underlined; on e-ink a rule reads
                    // faster than a fill change.
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: index === root.tab ? Math.round(3 * Theme.ui) : 1
                        color: index === root.tab ? Theme.ink : Theme.rule
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.tab = index
                    }
                }
            }
        }

        // ---- the pages ------------------------------------------------------
        Flickable {
            width: parent.width
            height: root.height - Theme.touch * 2 - Theme.margin
            contentHeight: pages.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: pages
                x: Theme.margin
                width: parent.width - Theme.margin * 2

                // ---- Display ---------------------------------------------
                Column {
                    width: parent.width
                    visible: root.tab === 0

                    SectionHeader {
                        text: qsTr("Palette")
                        footer: qsTr("Day, dusk and night palettes switch instantly. On this panel the chart is recoloured through the monochrome ink profile, so the three differ only in contrast.")
                    }
                    SegmentedRow {
                        label: qsTr("Colour scheme")
                        options: [qsTr("Day"), qsTr("Dusk"), qsTr("Night")]
                        currentIndex: root.settings ? root.settings.scheme : 0
                        onSelected: (i) => root.settings.scheme = i
                    }

                    SectionHeader {
                        text: qsTr("Detail")
                        footer: qsTr("Base ⊂ Standard ⊂ Other. Spot soundings switch independently of the category.")
                    }
                    SegmentedRow {
                        label: qsTr("Display category")
                        options: [qsTr("Base"), qsTr("Standard"), qsTr("Other")]
                        currentIndex: root.settings ? root.settings.detailLevel : 1
                        onSelected: (i) => root.settings.detailLevel = i
                    }
                    SegmentedRow {
                        label: qsTr("Soundings")
                        options: [qsTr("Category"), qsTr("Always"), qsTr("Never")]
                        currentIndex: root.settings ? root.settings.soundings : 1
                        onSelected: (i) => root.settings.soundings = i
                    }
                }

                // ---- Depths ------------------------------------------------
                Column {
                    width: parent.width
                    visible: root.tab === 1

                    SectionHeader {
                        text: qsTr("Water")
                        footer: root.settings && root.settings.fourShadeWater
                            ? qsTr("Four shades: white (safe) water starts at the DEEP contour; the safety contour separates the two middle blues.")
                            : qsTr("Two shades: water deeper than the safety contour is white (safe), everything shallower is blue.")
                    }
                    SegmentedRow {
                        label: qsTr("Depth unit")
                        options: [qsTr("Metres"), qsTr("Feet")]
                        currentIndex: root.settings ? root.settings.depthUnit : 0
                        onSelected: (i) => root.settings.depthUnit = i
                    }
                    SegmentedRow {
                        label: qsTr("Water shading")
                        options: [qsTr("Two shades"), qsTr("Four shades")]
                        currentIndex: root.settings && root.settings.fourShadeWater ? 1 : 0
                        onSelected: (i) => root.settings.fourShadeWater = (i === 1)
                    }

                    SectionHeader {
                        text: qsTr("Contours")
                        footer: qsTr("Shading follows the depth areas in the chart: the effective safety contour is the next DEEPER contour available in the data, drawn bold.")
                    }
                    NumberRow {
                        label: qsTr("Shallow contour")
                        value: root.settings ? root.toDisplay(root.settings.shallowContour) : 0
                        step: root.feet ? 1 : 0.5
                        maximum: root.feet ? 300 : 100
                        decimals: root.feet ? 0 : 1
                        suffix: root.unit
                        onEdited: (v) => root.settings.shallowContour = root.fromDisplay(v)
                    }
                    NumberRow {
                        label: qsTr("Safety contour")
                        value: root.settings ? root.toDisplay(root.settings.safetyContour) : 0
                        step: root.feet ? 1 : 0.5
                        maximum: root.feet ? 300 : 100
                        decimals: root.feet ? 0 : 1
                        suffix: root.unit
                        onEdited: (v) => root.settings.safetyContour = root.fromDisplay(v)
                    }
                    NumberRow {
                        label: qsTr("Deep contour")
                        value: root.settings ? root.toDisplay(root.settings.deepContour) : 0
                        step: root.feet ? 1 : 0.5
                        maximum: root.feet ? 600 : 200
                        decimals: root.feet ? 0 : 1
                        suffix: root.unit
                        onEdited: (v) => root.settings.deepContour = root.fromDisplay(v)
                    }
                    NumberRow {
                        label: qsTr("Safety depth")
                        value: root.settings ? root.toDisplay(root.settings.safetyDepth) : 0
                        step: root.feet ? 1 : 0.5
                        maximum: root.feet ? 300 : 100
                        decimals: root.feet ? 0 : 1
                        suffix: root.unit
                        onEdited: (v) => root.settings.safetyDepth = root.fromDisplay(v)
                    }
                }

                // ---- Text & symbols ----------------------------------------
                Column {
                    width: parent.width
                    visible: root.tab === 2

                    SectionHeader { text: qsTr("Text") }
                    ToggleRow {
                        label: qsTr("Place and object names")
                        checked: root.settings ? root.settings.textNames : true
                        onToggled: (v) => root.settings.textNames = v
                    }
                    ToggleRow {
                        label: qsTr("Light descriptions")
                        detail: qsTr("The character, period, height and range beside each light.")
                        checked: root.settings ? root.settings.showLightDescriptions : true
                        onToggled: (v) => root.settings.showLightDescriptions = v
                    }
                    ToggleRow {
                        label: qsTr("Other text")
                        detail: qsTr("Notes, seabed, magnetic variation, heights.")
                        checked: root.settings ? root.settings.textOther : false
                        onToggled: (v) => root.settings.textOther = v
                    }

                    SectionHeader {
                        text: qsTr("Symbols")
                        footer: qsTr("Symbol size is set for this panel's 226 dpi, not to taste: at 1.0 every symbol would draw half the size S-52 intends.")
                    }
                    SegmentedRow {
                        label: qsTr("Area boundaries")
                        options: [qsTr("Symbolized"), qsTr("Plain")]
                        currentIndex: root.settings ? root.settings.boundaryStyle : 0
                        onSelected: (i) => root.settings.boundaryStyle = i
                    }
                    ToggleRow {
                        label: qsTr("Simplified point symbols")
                        checked: root.settings ? root.settings.simplifiedPoints : false
                        onToggled: (v) => root.settings.simplifiedPoints = v
                    }
                    ToggleRow {
                        label: qsTr("Full light sector lines")
                        checked: root.settings ? root.settings.showFullSectorLines : false
                        onToggled: (v) => root.settings.showFullSectorLines = v
                    }
                    NumberRow {
                        label: qsTr("Symbol size")
                        value: root.settings ? root.settings.sizeScale : 1.6
                        step: 0.1
                        minimum: 0.5
                        maximum: 3.0
                        decimals: 1
                        suffix: "×"
                        onEdited: (v) => root.settings.sizeScale = v
                    }
                }

                // ---- Charts -------------------------------------------------
                Column {
                    width: parent.width
                    visible: root.tab === 3

                    SectionHeader {
                        text: qsTr("Open")
                        footer: qsTr("A folder of baked cells opens as one seamless library.")
                    }
                    Text {
                        width: parent.width
                        text: root.view && root.view.hasChart
                              ? root.view.chartName
                                + (root.view.chartCount > 1
                                   ? qsTr(" — %1 cells").arg(root.view.chartCount) : "")
                              : qsTr("No chart open")
                        color: root.view && root.view.hasChart ? Theme.ink : Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontBody
                        wrapMode: Text.WordWrap
                        topPadding: Math.round(6 * Theme.ui)
                        bottomPadding: Math.round(12 * Theme.ui)
                    }
                    FlatButton {
                        text: qsTr("Open charts…")
                        icon: "map"
                        resting: Qt.rgba(0, 0, 0, 0.06)
                        radius: Math.round(10 * Theme.ui)
                        onClicked: root.openChartRequested()
                    }

                    SectionHeader {
                        text: qsTr("Declutter")
                        footer: qsTr("Area overlays are hidden by default; each one shows a group of S-52 areas.")
                    }
                    ToggleRow {
                        label: qsTr("Caution and precautionary areas")
                        checked: root.settings ? root.settings.showCautionAreas : false
                        onToggled: (v) => root.settings.showCautionAreas = v
                    }
                    ToggleRow {
                        label: qsTr("Anchorages")
                        checked: root.settings ? root.settings.showAnchorages : false
                        onToggled: (v) => root.settings.showAnchorages = v
                    }
                    ToggleRow {
                        label: qsTr("Restricted and military areas")
                        checked: root.settings ? root.settings.showRestrictedAreas : false
                        onToggled: (v) => root.settings.showRestrictedAreas = v
                    }
                    ToggleRow {
                        label: qsTr("Cables and pipelines")
                        checked: root.settings ? root.settings.showCablesPipelines : false
                        onToggled: (v) => root.settings.showCablesPipelines = v
                    }
                    ToggleRow {
                        label: qsTr("Marine farms")
                        checked: root.settings ? root.settings.showMarineFarms : false
                        onToggled: (v) => root.settings.showMarineFarms = v
                    }
                }

                // ---- Advanced ------------------------------------------------
                Column {
                    width: parent.width
                    visible: root.tab === 4

                    SectionHeader { text: qsTr("Dangers and quality") }
                    ToggleRow {
                        label: qsTr("Isolated dangers in shallow water")
                        checked: root.settings ? root.settings.showIsolatedDangersShallow : false
                        onToggled: (v) => root.settings.showIsolatedDangersShallow = v
                    }
                    ToggleRow {
                        label: qsTr("Data quality (zones of confidence)")
                        checked: root.settings ? root.settings.dataQuality : false
                        onToggled: (v) => root.settings.dataQuality = v
                    }

                    SectionHeader {
                        text: qsTr("Boundaries and callouts")
                        footer: qsTr("The overscale hatch is an ECDIS artifact; a paper chart never carries one. The readout already says ×N when the view is magnified past the survey.")
                    }
                    ToggleRow {
                        label: qsTr("Overscale hatch")
                        checked: root.settings ? root.settings.showOverscale : false
                        onToggled: (v) => root.settings.showOverscale = v
                    }
                    ToggleRow {
                        label: qsTr("Meta-object boundaries")
                        checked: root.settings ? root.settings.showMetaBounds : false
                        onToggled: (v) => root.settings.showMetaBounds = v
                    }
                    ToggleRow {
                        label: qsTr("Information callouts")
                        checked: root.settings ? root.settings.showInformCallouts : false
                        onToggled: (v) => root.settings.showInformCallouts = v
                    }
                    ToggleRow {
                        label: qsTr("Highlight date-dependent objects")
                        checked: root.settings ? root.settings.highlightDateDependent : false
                        onToggled: (v) => root.settings.highlightDateDependent = v
                    }

                    SectionHeader {
                        text: qsTr("Advanced")
                        footer: qsTr("SCAMIN is the chart's own rule about when an object is too small to draw. Ignoring it shows everything at every zoom, and clutters.")
                    }
                    ToggleRow {
                        label: qsTr("Apply seasonal dates")
                        checked: root.settings ? root.settings.dateDependent : true
                        onToggled: (v) => root.settings.dateDependent = v
                    }
                    ToggleRow {
                        label: qsTr("Ignore SCAMIN")
                        checked: root.settings ? root.settings.ignoreScamin : false
                        onToggled: (v) => root.settings.ignoreScamin = v
                    }

                    SectionHeader { text: qsTr("About") }
                    Text {
                        width: parent.width
                        text: qsTr("Lookout Marine — tile57 %1").arg(appVersion)
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontTiny
                        bottomPadding: Theme.margin
                    }
                }
            }
        }
    }
}
