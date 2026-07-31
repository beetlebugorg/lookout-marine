// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#include "renderworker.h"

#include <QDebug>
#include <QVariantMap>

#include "mercator.h"
#include "s57.h"

// One tile side, in pixels. 512 is the pyramid's tile (mercator.h); the core's
// world tile is 256, which is why a tile's view renders at coreZoom(level).
static constexpr int kTilePx = 512;

RenderWorker::RenderWorker(QObject* parent) : QObject(parent) {
    qRegisterMetaType<TileKey>("TileKey");
    qRegisterMetaType<ChartOpening>("ChartOpening");
    qRegisterMetaType<lookout_view>("lookout_view");
    qRegisterMetaType<tile57_mariner>("tile57_mariner");
    qRegisterMetaType<QList<qint32>>("QList<qint32>");
}

void RenderWorker::setJobs(const QVector<TileKey>& tiles, quint64 styleGen) {
    {
        QMutexLocker lock(&m_mutex);
        m_jobs = tiles;
        m_styleGen = styleGen;
    }
    // Wake the worker; it runs after any in-flight tile returns.
    QMetaObject::invokeMethod(this, "processJobs", Qt::QueuedConnection);
}

void RenderWorker::setAntialias(bool on) {
    QMutexLocker lock(&m_mutex);
    m_antialias = on;
}

void RenderWorker::open(const QStringList& paths) {
    ChartOpening r;
    if (!m_chart.open(paths, kTilePx, kTilePx)) {
        r.error = m_chart.lastError();
        emit opened(r);
        return;
    }
    r.ok = true;
    r.chartCount = m_chart.chartCount();
    r.fit = m_chart.fitView();
    r.opening = m_chart.defaultView();
    emit opened(r);
}

void RenderWorker::closeChart() {
    {
        QMutexLocker lock(&m_mutex);
        m_jobs.clear();
    }
    m_chart.close();
}

void RenderWorker::resize(int width, int height) {
    m_chart.resize(width, height);
    publishView();
}

void RenderWorker::pan(double dxPx, double dyPx) {
    m_chart.pan(dxPx, dyPx);
    publishView();
}

void RenderWorker::setView(lookout_view v) {
    m_chart.setView(v);
    publishView();
}

void RenderWorker::fitChart() {
    m_chart.setView(m_chart.fitView());
    publishView();
}

void RenderWorker::applyMariner(tile57_mariner m, QList<qint32> hiddenGroups) {
    m_chart.setMariner(m, hiddenGroups);
}

void RenderWorker::publishView() {
    if (!m_chart.isOpen())
        return;
    emit viewChanged(m_chart.view(), m_chart.scaleDenominator(), m_chart.overscale());
}

void RenderWorker::processJobs() {
    TileKey key;
    quint64 styleGen;
    bool antialias;
    {
        QMutexLocker lock(&m_mutex);
        if (m_jobs.isEmpty())
            return;
        key = m_jobs.takeFirst();
        styleGen = m_styleGen;
        antialias = m_antialias;
    }

    const merc::LonLat c = merc::tileCenter(key.level, key.x, key.y);
    // The tile IS the 512-px view at the core zoom its level maps to, so it is
    // tile-aligned and seamless with its neighbours. Rendering at the level
    // number itself would cover twice the ground and every tile would overlap.
    const QImage img = m_chart.renderView(c.lon, c.lat, double(merc::coreZoom(key.level)), kTilePx,
                                          kTilePx, antialias);
    emit tileRendered(key, img, styleGen);

    // Next tile on a fresh turn, so an open, a pick or a newer setJobs() can
    // interleave between tiles.
    QMutexLocker lock(&m_mutex);
    if (!m_jobs.isEmpty())
        QMetaObject::invokeMethod(this, "processJobs", Qt::QueuedConnection);
}

QVariantList RenderWorker::pickRanked(double lon, double lat) {
    QVariantList out;
    for (const lookout::PickedFeature& f : m_chart.pickRanked(lon, lat)) {
        QVariantMap entry;
        entry[QStringLiteral("cls")] = f.cls;
        entry[QStringLiteral("chart")] = f.chart;
        entry[QStringLiteral("s57")] = f.s57;
        entry[QStringLiteral("rows")] = S57::attributeRows(f.s57);
        out.append(entry);
    }
    return out;
}

QVariantMap RenderWorker::auxFile(QString cell, QString name) {
    QVariantMap out;
    QByteArray bytes;
    QString mime;
    const bool ok = m_chart.auxFile(cell, name, &bytes, &mime);
    out[QStringLiteral("ok")] = ok;
    out[QStringLiteral("mime")] = mime;
    const bool picture = mime.startsWith(QStringLiteral("image/"));
    out[QStringLiteral("isPicture")] = picture;
    if (picture) {
        // A data: URL so QML's Image can show it without an image provider.
        // Whether it decodes is Qt's business: an ENC usually carries TIFF, and
        // the plugin for it may not be in the device's Qt. AuxFile.qml falls
        // back to naming the file when the load fails.
        out[QStringLiteral("dataUrl")] =
            QStringLiteral("data:") + mime + QStringLiteral(";base64,") +
            QString::fromLatin1(bytes.toBase64());
    } else {
        // A caution or a port description. The cells are not consistently UTF-8;
        // Latin-1 never fails and is what those files actually are.
        QString text = QString::fromUtf8(bytes);
        if (text.contains(QChar(QChar::ReplacementCharacter)))
            text = QString::fromLatin1(bytes);
        out[QStringLiteral("text")] = text.trimmed();
    }
    return out;
}
