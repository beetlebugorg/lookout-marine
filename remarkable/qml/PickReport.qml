// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// The cursor pick report: one object at a time, with its S-57 attributes as the
// cell states them — the Apple shell's `PickReportPanel`.
//
// What is reported, and in what order, is NOT decided here. lookout_pick_ranked
// decides it in the core: it drops the meta objects that answer every pick with
// nothing to read, drops a feature the cell gave no attributes, and puts the
// most specific object first. So this report lists the same objects in the same
// order as the Mac's, and neither shell had to invent the rules.
Panel {
    id: root

    property var view: null
    property var features: []      // from ChartView.pick()
    property int index: 0
    signal closed()
    signal pictureRequested(string name, string dataUrl)

    readonly property var feature: (features && index >= 0 && index < features.length)
                                   ? features[index] : null
    readonly property var rows: feature ? feature.rows : []

    opaque: true
    visible: feature !== null
    width: Theme.reportWidth
    height: Math.min(column.implicitHeight, Theme.reportMaxHeight)

    Column {
        id: column
        width: parent.width

        // ---- header: drags the whole report --------------------------------
        Item {
            width: parent.width
            height: headerRow.implicitHeight + Math.round(32 * Theme.ui)

            MouseArea {
                anchors.fill: parent
                drag.target: root
                drag.axis: Drag.XAndYAxis
                // The whole header drags, not just the dots: a report that grew
                // past the screen has to be movable by whatever part you reach.
                drag.minimumX: -root.width + Theme.margin * 4
                drag.maximumX: root.parent ? root.parent.width - Theme.margin * 4 : 0
                drag.minimumY: 0
                drag.maximumY: root.parent ? root.parent.height - Theme.touch : 0
            }

            Row {
                id: headerRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.margin
                anchors.rightMargin: Theme.margin
                spacing: Math.round(10 * Theme.ui)

                // The six dots of the reference design.
                Grid {
                    anchors.verticalCenter: parent.verticalCenter
                    columns: 2
                    spacing: Math.round(3 * Theme.ui)
                    Repeater {
                        model: 6
                        Rectangle {
                            width: Math.round(3 * Theme.ui); height: width
                            radius: width / 2
                            color: Theme.muted
                            opacity: 0.6
                            antialiasing: true
                        }
                    }
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Math.round(200 * Theme.ui)
                    spacing: Math.round(5 * Theme.ui)

                    Text {
                        width: parent.width
                        text: root.feature ? root.feature.cls : ""
                        color: Theme.ink
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontTitle
                        font.bold: true
                        elide: Text.ElideRight
                    }
                    Row {
                        spacing: Math.round(5 * Theme.ui)
                        GlyphIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.round(Theme.fontSmall); height: width
                            name: "square.grid.3x3"
                            color: Theme.muted
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.feature ? root.feature.chart : ""
                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSmall
                        }
                    }
                }

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Math.round(6 * Theme.ui)

                    FlatButton {
                        visible: root.features.length > 1
                        icon: "chevron.left"
                        enabled: root.index > 0
                        resting: Qt.rgba(0, 0, 0, 0.06)
                        radius: Math.round(6 * Theme.ui)
                        onClicked: root.index--
                    }
                    Text {
                        visible: root.features.length > 1
                        anchors.verticalCenter: parent.verticalCenter
                        text: (root.index + 1) + " / " + root.features.length
                        color: Theme.muted
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontSmall
                    }
                    FlatButton {
                        visible: root.features.length > 1
                        icon: "chevron.right"
                        enabled: root.index < root.features.length - 1
                        resting: Qt.rgba(0, 0, 0, 0.06)
                        radius: Math.round(6 * Theme.ui)
                        onClicked: root.index++
                    }
                    FlatButton {
                        icon: "xmark"
                        radius: Math.round(6 * Theme.ui)
                        onClicked: root.closed()
                    }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.rule }

        // ---- attributes -----------------------------------------------------
        Text {
            visible: root.rows.length === 0
            width: parent.width - Theme.margin * 2
            x: Theme.margin
            topPadding: Math.round(18 * Theme.ui)
            bottomPadding: Math.round(18 * Theme.ui)
            text: qsTr("The cell carries no attributes for this object.")
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontLabel
            wrapMode: Text.WordWrap
        }

        // A short report keeps its natural height; a long one scrolls. The
        // Flickable is only greedy once the rows pass the maximum.
        Flickable {
            visible: root.rows.length > 0
            width: parent.width
            height: Math.min(table.implicitHeight,
                             Theme.reportMaxHeight - Math.round(80 * Theme.ui))
            contentHeight: table.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: table
                width: parent.width

                Repeater {
                    model: root.rows
                    delegate: Column {
                        required property var modelData
                        required property int index
                        width: table.width

                        Item {
                            width: parent.width
                            height: rowContent.implicitHeight + Math.round(24 * Theme.ui)

                            Row {
                                id: rowContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.margin
                                                    + modelData.depth * Math.round(12 * Theme.ui)
                                anchors.rightMargin: Theme.margin
                                spacing: Math.round(12 * Theme.ui)

                                // A complex attribute becomes a heading with its
                                // parts indented under it, so the name column
                                // narrows as the rows nest.
                                Text {
                                    width: Math.round(104 * Theme.ui)
                                           - modelData.depth * Math.round(12 * Theme.ui)
                                    text: modelData.value === ""
                                          ? modelData.name : modelData.name + ":"
                                    color: modelData.value === "" ? Theme.ink : Theme.muted
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSmall
                                    font.bold: modelData.value === ""
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                }

                                AuxFile {
                                    visible: modelData.fileReference
                                    width: parent.width - Math.round(116 * Theme.ui)
                                    view: root.view
                                    cell: root.feature ? root.feature.chart : ""
                                    name: modelData.value
                                    isPicture: modelData.isPicture
                                    onPictureRequested: (n, u) => root.pictureRequested(n, u)
                                }

                                Text {
                                    visible: !modelData.fileReference
                                    width: parent.width - Math.round(116 * Theme.ui)
                                    text: modelData.value
                                    color: Theme.ink
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontBody
                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                }
                            }
                        }

                        Rectangle {
                            visible: index < root.rows.length - 1
                            x: Theme.margin
                            width: parent.width - Theme.margin
                            height: 1
                            color: Theme.rule
                            opacity: 0.6
                        }
                    }
                }
            }
        }
    }

    // A new pick starts at the top of the list.
    onFeaturesChanged: index = 0
}
