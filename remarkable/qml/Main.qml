// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick
import QtQuick.Window
import LookoutMarine

// The window, the chart, and the chrome above it.
//
// The layout is the Apple shell's OverlayLayer: readouts capsule at the bottom
// centre, the scale bar at the bottom left, and the bubbles stacked at the
// bottom right with zoom above the chart-and-settings row. The pick report
// floats and is dragged by its header.
//
// The north bubble is the one Apple control missing here, and the reason is in
// ChartView's header: the chart is a tile pyramid of axis-aligned tiles, so a
// rotated view would re-render every tile on a CPU that takes tens of
// milliseconds each. The view stays north-up and the bubble would have nothing
// to say.
Window {
    id: window

    visible: true
    width: appScreenW > 0 ? appScreenW : 1404
    height: appScreenH > 0 ? appScreenH : 1872
    visibility: appFullscreen ? Window.FullScreen : Window.Windowed
    title: qsTr("Lookout Marine")
    color: Theme.surface

    // What the chrome is showing right now. Only one panel at a time: the panel
    // is most of the screen on a tablet this size.
    property bool showSettings: false
    property bool showPicker: false
    property bool showScaleEntry: false
    property var pickFeatures: []
    property point pickPoint: Qt.point(0, 0)
    property string pictureName: ""
    property string pictureUrl: ""

    MarinerSettings {
        id: mariner
    }

    ChartView {
        id: chart
        anchors.fill: parent
        settings: mariner

        Component.onCompleted: {
            if (appChartPath && appChartPath.length > 0)
                openChart(appChartPath)
            if (appOpenSettings)
                window.showSettings = true
        }
    }

    // ---- gestures ----------------------------------------------------------
    // A drag pans, a pinch zooms, and a press that did not move picks. The
    // threshold is what keeps a slightly smudged tap from being read as a pan
    // and losing the pick.
    PinchArea {
        anchors.fill: parent
        enabled: chart.hasChart && !window.anyPanelOpen

        onPinchUpdated: (pinch) => chart.updatePinch(pinch.scale, pinch.center.x, pinch.center.y)
        onPinchFinished: chart.commitPinch()

        MouseArea {
            id: drag
            anchors.fill: parent
            property real lastX: 0
            property real lastY: 0
            property real travelled: 0
            readonly property real tapSlop: Math.round(12 * Theme.ui)

            onPressed: (mouse) => {
                lastX = mouse.x
                lastY = mouse.y
                travelled = 0
            }
            onPositionChanged: (mouse) => {
                const dx = mouse.x - lastX
                const dy = mouse.y - lastY
                lastX = mouse.x
                lastY = mouse.y
                travelled += Math.abs(dx) + Math.abs(dy)
                if (travelled > tapSlop)
                    chart.panBy(dx, dy)
            }
            onReleased: (mouse) => {
                if (travelled <= tapSlop)
                    window.pickAt(mouse.x, mouse.y)
            }
        }
    }

    readonly property bool anyPanelOpen: showSettings || showPicker || pictureUrl !== ""

    function pickAt(x, y) {
        const results = chart.pick(x, y)
        pickPoint = Qt.point(x, y)
        pickFeatures = results
        // Put the report where it will not sit under the finger that opened it.
        report.x = Math.min(Math.max(Theme.margin, x - report.width / 2),
                            window.width - report.width - Theme.margin)
        report.y = y > window.height / 2
                   ? Theme.margin
                   : window.height - report.height - Theme.margin * 6
    }

    // ---- the mark on the chart under an open report -------------------------
    // The Apple shell rings it in S-52 magenta over a white halo. Here the ring
    // is black and the halo does the separating.
    Item {
        visible: window.pickFeatures.length > 0
        x: window.pickPoint.x - width / 2
        y: window.pickPoint.y - height / 2
        width: Theme.pickMarker
        height: width

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: Math.round(4 * Theme.ui)
            border.color: Theme.surface
            antialiasing: true
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: Math.round(2 * Theme.ui)
            radius: width / 2
            color: "transparent"
            border.width: Math.round(2 * Theme.ui)
            border.color: Theme.magenta
            antialiasing: true
        }
    }

    // ---- the empty state ----------------------------------------------------
    Panel {
        anchors.centerIn: parent
        visible: !chart.hasChart && !chart.loading
        width: Math.round(420 * Theme.ui)
        height: empty.implicitHeight + Theme.margin * 3

        Column {
            id: empty
            anchors.centerIn: parent
            width: parent.width - Theme.margin * 2
            spacing: Theme.gap

            Text {
                width: parent.width
                text: qsTr("No chart open")
                color: Theme.ink
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontTitle
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
            }
            Text {
                width: parent.width
                text: chart.errorString !== ""
                      ? chart.errorString
                      : qsTr("Open a baked .pmtiles archive, or a folder of them to quilt into one chart.")
                color: Theme.muted
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontLabel
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
            FlatButton {
                anchors.horizontalCenter: parent.horizontalCenter
                text: qsTr("Open charts…")
                icon: "map"
                resting: Qt.rgba(0, 0, 0, 0.06)
                radius: Math.round(10 * Theme.ui)
                onClicked: window.showPicker = true
            }
        }
    }

    // ---- loading ------------------------------------------------------------
    Panel {
        anchors.centerIn: parent
        visible: chart.loading
        width: Math.round(320 * Theme.ui)
        height: Theme.touch * 2

        Text {
            anchors.centerIn: parent
            text: chart.loadingStatus
            color: Theme.ink
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBody
        }
    }

    // ---- the scale bar, bottom left -----------------------------------------
    ScaleBar {
        visible: chart.hasChart && !window.anyPanelOpen
        view: chart
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: Theme.margin
        anchors.bottomMargin: Theme.margin + Theme.capsule + Theme.gap
    }

    // ---- the readouts, bottom centre ----------------------------------------
    ReadoutsCapsule {
        id: readouts
        visible: chart.hasChart && !window.anyPanelOpen
        view: chart
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.margin
        onScaleTapped: window.showScaleEntry = !window.showScaleEntry
    }

    // ---- the bubbles, bottom right ------------------------------------------
    Column {
        visible: !window.anyPanelOpen
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.margin
        anchors.bottomMargin: Theme.margin + Theme.capsule + Theme.gap
        spacing: Theme.gap

        ChromeBubble {
            icon: "plus"
            help: qsTr("Zoom in")
            enabled: chart.canZoomIn
            onClicked: chart.zoomIn()
        }
        ChromeBubble {
            icon: "minus"
            help: qsTr("Zoom out")
            enabled: chart.canZoomOut
            onClicked: chart.zoomOut()
        }
        ChromeBubble {
            icon: "arrow.up.left.and.arrow.down.right"
            help: qsTr("Fit the chart")
            enabled: chart.hasChart
            onClicked: chart.fitChart()
        }
        ChromeBubble {
            icon: "map"
            help: qsTr("Open charts")
            onClicked: window.showPicker = true
        }
        ChromeBubble {
            icon: "slider.horizontal.3"
            help: qsTr("Settings")
            onClicked: window.showSettings = true
        }
    }

    // ---- the scale entry ----------------------------------------------------
    ScaleEntry {
        visible: window.showScaleEntry && chart.hasChart && !window.anyPanelOpen
        view: chart
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: readouts.top
        anchors.bottomMargin: Theme.gap
        onClosed: window.showScaleEntry = false
    }

    // ---- the pick report ----------------------------------------------------
    PickReport {
        id: report
        view: chart
        features: window.pickFeatures
        visible: window.pickFeatures.length > 0 && !window.anyPanelOpen
        onClosed: window.pickFeatures = []
        onPictureRequested: (name, url) => {
            window.pictureName = name
            window.pictureUrl = url
        }
    }

    // ---- the panels ---------------------------------------------------------
    SettingsPanel {
        visible: window.showSettings
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: Theme.margin
        settings: mariner
        view: chart
        onClosed: window.showSettings = false
        onOpenChartRequested: {
            window.showSettings = false
            window.showPicker = true
        }
    }

    ChartPicker {
        visible: window.showPicker
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: Theme.margin
        folder: appChartsDir && appChartsDir.length > 0 ? appChartsDir : "/home/root"
        onClosed: window.showPicker = false
        onChartChosen: (path) => {
            window.showPicker = false
            window.pickFeatures = []
            chart.openChart(path)
        }
    }

    PictureViewer {
        anchors.fill: parent
        pictureName: window.pictureName
        dataUrl: window.pictureUrl
        onDismissed: {
            window.pictureUrl = ""
            window.pictureName = ""
        }
    }
}
