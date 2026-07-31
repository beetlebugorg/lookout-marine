// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// The attribute payload of a picked feature, turned into report rows.
//
// A port of `enum S57` in macos/LookoutMarine/HUDOverlay.swift, so the pick
// report reads the same here as on the Mac and the iPad.
//
// An S-57 cell gives a flat object of acronym and value. S-101 does not: a
// complex attribute carries sub-attributes, so a value can be an object or an
// array. Rows therefore carry a depth, and a complex attribute becomes a
// heading with its parts indented under it.

#include <QString>
#include <QVariantList>
#include <QVector>

namespace S57 {

struct Row {
    QString name;
    QString value;
    int depth = 0;

    // A cell can point at a text file or a picture beside it, such as
    // US348MDE.TXT. S-57 names it in TXTDSC, NTXTDS or PICREP; S-101 puts it in
    // a fileReference. lookout_aux_file reads it back out of the archive.
    bool fileReference() const;
    bool isPicture() const;
};

// The rows of an attribute JSON payload, in report order.
QVector<Row> attributes(const QString& json);

// The same, as QML sees it: {name, value, depth, fileReference, isPicture}.
QVariantList attributeRows(const QString& json);

// The report as plain text, for the clipboard.
QString plainText(const QString& cls, const QString& chart, const QString& json);

// True when the payload holds a note or a reference. It is what keeps a meta
// object in the report: M_NPUB carries the chart's cautions, M_QUAL carries
// nothing a mariner reads. (The core applies this rule in lookout_pick_ranked;
// it is here too because the report still marks WHICH rows are the reading.)
bool carriesInformation(const QString& json);

} // namespace S57
