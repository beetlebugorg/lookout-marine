// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick
import Qt.labs.folderlistmodel

// Open a chart. The Apple shell hands this to the platform — NSOpenPanel on the
// Mac, the file importer on iOS — and neither exists on the tablet, so the
// browser is here. What it offers is the same choice they offer: one baked
// archive, or a FOLDER of them, which opens as one seamless library.
//
// Folders are listed first and can be opened as a chart in their own right; that
// is the row with the count beside it.
Panel {
    id: root

    property string folder: ""
    signal chartChosen(string path)
    signal closed()

    width: Theme.settingsWidth

    function up() {
        const s = folder.replace(/\/+$/, "")
        const i = s.lastIndexOf("/")
        if (i > 0)
            folder = s.substring(0, i)
    }

    Column {
        anchors.fill: parent

        Item {
            width: parent.width
            height: Theme.touch + Theme.margin

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.margin
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Open charts")
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

        // Where we are, and the way back up.
        Item {
            width: parent.width
            height: Theme.touch

            FlatButton {
                id: upButton
                anchors.left: parent.left
                anchors.leftMargin: Theme.margin
                anchors.verticalCenter: parent.verticalCenter
                icon: "chevron.left"
                text: qsTr("Up")
                radius: Math.round(6 * Theme.ui)
                onClicked: root.up()
            }
            Text {
                anchors.left: upButton.right
                anchors.right: parent.right
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.margin
                anchors.verticalCenter: parent.verticalCenter
                text: root.folder
                color: Theme.muted
                font.family: Theme.fontMono
                font.pixelSize: Theme.fontTiny
                elide: Text.ElideLeft
            }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.rule }

        // The folder itself, as a library. This is the row you want when a
        // folder holds a whole ENC_ROOT's worth of baked cells.
        Item {
            width: parent.width
            height: Theme.touch + Math.round(12 * Theme.ui)
            visible: folders.pmtilesCount > 0

            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.margin
                anchors.verticalCenter: parent.verticalCenter
                spacing: Math.round(10 * Theme.ui)
                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.round(20 * Theme.ui); height: width
                    name: "map"
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Open this folder — %1 cells as one chart")
                          .arg(folders.pmtilesCount)
                    color: Theme.ink
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontBody
                    font.bold: true
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: root.chartChosen(root.folder)
            }
        }

        Rectangle {
            width: parent.width; height: 1; color: Theme.rule
            visible: folders.pmtilesCount > 0
        }

        ListView {
            width: parent.width
            height: root.height - Theme.touch * 3 - Theme.margin
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            model: FolderListModel {
                id: folders
                folder: "file://" + root.folder
                showDirs: true
                showFiles: true
                showDotAndDotDot: false
                showOnlyReadable: true
                sortField: FolderListModel.Type
                nameFilters: ["*.pmtiles"]

                // How many baked cells are directly in this folder — what the
                // "open this folder" row above counts.
                property int pmtilesCount: {
                    let n = 0
                    for (let i = 0; i < count; ++i)
                        if (!get(i, "fileIsDir"))
                            ++n
                    return n
                }
            }

            delegate: Item {
                required property string fileName
                required property string filePath
                required property bool fileIsDir

                width: ListView.view.width
                height: Theme.touch + Math.round(8 * Theme.ui)

                Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.margin
                    anchors.rightMargin: Theme.margin
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Math.round(10 * Theme.ui)

                    GlyphIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.round(18 * Theme.ui); height: width
                        name: fileIsDir ? "chevron.right" : "map"
                        color: Theme.muted
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: fileName
                        color: Theme.ink
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontBody
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    x: Theme.margin
                    width: parent.width - Theme.margin * 2
                    height: 1
                    color: Theme.rule
                    opacity: 0.6
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (fileIsDir)
                            root.folder = filePath.replace("file://", "")
                        else
                            root.chartChosen(filePath.replace("file://", ""))
                    }
                }
            }
        }
    }
}
