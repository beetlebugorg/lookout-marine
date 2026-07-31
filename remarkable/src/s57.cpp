// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#include "s57.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QStringList>
#include <QVariantMap>
#include <cmath>

namespace S57 {
namespace {

// The attribute names that carry something to read.
const QStringList kInformational = {
    QStringLiteral("INFORM"),  QStringLiteral("NINFOM"), QStringLiteral("TXTDSC"),
    QStringLiteral("NTXTDS"),  QStringLiteral("PICREP"), QStringLiteral("fileReference"),
    QStringLiteral("text"),
};

const QStringList kFileRefNames = {
    QStringLiteral("TXTDSC"), QStringLiteral("NTXTDS"),
    QStringLiteral("PICREP"), QStringLiteral("fileReference"),
};

QString textOf(const QJsonValue& v) {
    switch (v.type()) {
    case QJsonValue::String:
        return v.toString();
    case QJsonValue::Double: {
        const double d = v.toDouble();
        // Whole numbers print without a trailing .0, as NSNumber.stringValue does.
        if (d == std::floor(d) && std::fabs(d) < 1e15)
            return QString::number(qlonglong(d));
        return QString::number(d);
    }
    case QJsonValue::Bool:
        return v.toBool() ? QStringLiteral("true") : QStringLiteral("false");
    case QJsonValue::Null:
        return QStringLiteral("null");
    default:
        return QString();
    }
}

// Walks the payload exactly as the Swift does: an object or an array with a
// name becomes a heading, and its parts indent under it.
void append(const QJsonValue& node, const QString& name, bool hasName, int depth,
            QVector<Row>& rows) {
    if (node.isObject()) {
        if (hasName)
            rows.append({name, QString(), depth});
        const QJsonObject obj = node.toObject();
        // QJsonObject keys are already sorted, matching `object.keys.sorted()`.
        for (const QString& key : obj.keys())
            append(obj.value(key), key, true, hasName ? depth + 1 : depth, rows);
        return;
    }
    if (node.isArray()) {
        if (hasName)
            rows.append({name, QString(), depth});
        const QJsonArray list = node.toArray();
        for (const QJsonValue& item : list)
            append(item, QString(), false, depth + 1, rows);
        return;
    }
    rows.append({hasName ? name : QString(), textOf(node), depth});
}

} // namespace

bool Row::fileReference() const {
    return kFileRefNames.contains(name) && !value.isEmpty();
}

bool Row::isPicture() const {
    const QString lower = value.toLower();
    return lower.endsWith(QStringLiteral(".tif")) || lower.endsWith(QStringLiteral(".tiff")) ||
           lower.endsWith(QStringLiteral(".jpg")) || lower.endsWith(QStringLiteral(".jpeg")) ||
           lower.endsWith(QStringLiteral(".png"));
}

QVector<Row> attributes(const QString& json) {
    QVector<Row> rows;
    if (json.isEmpty())
        return rows;
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (doc.isNull())
        return rows;
    append(doc.isArray() ? QJsonValue(doc.array()) : QJsonValue(doc.object()), QString(), false, 0,
           rows);
    return rows;
}

QVariantList attributeRows(const QString& json) {
    QVariantList out;
    const QVector<Row> rows = attributes(json);
    out.reserve(rows.size());
    for (const Row& r : rows) {
        QVariantMap m;
        m[QStringLiteral("name")] = r.name;
        m[QStringLiteral("value")] = r.value;
        m[QStringLiteral("depth")] = r.depth;
        m[QStringLiteral("fileReference")] = r.fileReference();
        m[QStringLiteral("isPicture")] = r.isPicture();
        out.append(m);
    }
    return out;
}

QString plainText(const QString& cls, const QString& chart, const QString& json) {
    QString text = cls + QStringLiteral("  ") + chart + QStringLiteral("\n");
    for (const Row& r : attributes(json)) {
        const QString indent(r.depth * 2, QLatin1Char(' '));
        text += r.value.isEmpty() ? indent + r.name + QStringLiteral(":\n")
                                  : indent + r.name + QStringLiteral(": ") + r.value +
                                        QStringLiteral("\n");
    }
    return text;
}

bool carriesInformation(const QString& json) {
    for (const Row& r : attributes(json)) {
        if (kInformational.contains(r.name) && !r.value.isEmpty())
            return true;
    }
    return false;
}

} // namespace S57
