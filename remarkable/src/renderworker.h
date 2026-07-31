// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// RenderWorker owns the lookout handle and makes ALL core calls — open, render,
// pick, aux — on its own thread.
//
// The core locks its own API, so this is not about safety; it is about latency.
// A canvas render holds that lock for as long as it takes to paint a 512-px
// tile, which on an i.MX7 is tens of milliseconds. Confining the handle to one
// thread keeps the GUI thread out of that lock entirely: it posts the tiles it
// wants and paints whatever has arrived.
//
// The chart is a raster tile pyramid. The worker paints one 512-px tile at a
// time — the view centred on that tile, at the core zoom the level corresponds
// to (mercator.h) — and hands the finished QImage back. The GUI posts the set it
// wants (visible plus a margin, centre-out) through setJobs(); the worker paints
// them one per event-loop turn so an open or a pick can interleave, and drops
// any whose style generation went stale under a settings change.

#include <QHash>
#include <QImage>
#include <QMutex>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>

#include "lookoutchart.h"

// A pyramid tile address. `level` is the PYRAMID's level, not the core's zoom;
// mercator.h converts (a 512-px tile sits one level up from the core's 256-px
// world tile). Naming it `level` is what keeps the two apart at every call site.
struct TileKey {
    int level = 0;
    int x = 0;
    int y = 0;
};
inline bool operator==(const TileKey& a, const TileKey& b) {
    return a.level == b.level && a.x == b.x && a.y == b.y;
}
inline size_t qHash(const TileKey& k, size_t seed = 0) {
    return qHashMulti(seed, k.level, k.x, k.y);
}
Q_DECLARE_METATYPE(TileKey)
// Both cross the GUI/worker boundary through queued calls, so Qt has to know
// them by name. They are plain C structs from the core's header.
Q_DECLARE_METATYPE(lookout_view)
Q_DECLARE_METATYPE(tile57_mariner)

// What the GUI needs to know about a chart once it is open.
struct ChartOpening {
    bool ok = false;
    int chartCount = 0;
    QString error;
    lookout_view fit{};     // the view holding the whole coverage
    lookout_view opening{}; // where to start when nothing is saved
};
Q_DECLARE_METATYPE(ChartOpening)

class RenderWorker : public QObject {
    Q_OBJECT

public:
    explicit RenderWorker(QObject* parent = nullptr);

    // Replace the job queue with `tiles` (painted in the given order) and tag
    // them `styleGen`, which the GUI bumps when a mariner setting changes so
    // tiles portrayed under the old style are dropped on arrival. Thread-safe:
    // called from the GUI thread; wakes the worker.
    void setJobs(const QVector<TileKey>& tiles, quint64 styleGen);

    // Antialiasing for every subsequent tile. Off on the panel: crisper and
    // faster, and an e-ink screen has no grey to spend on a fringe.
    void setAntialias(bool on);

public slots:
    // Open a chart file, or a directory of them composed into one library.
    void open(const QStringList& paths);
    void closeChart();

    // The camera lives in the core, so it is driven from here too. Each of
    // these returns the resulting view through viewChanged().
    void resize(int width, int height);
    void pan(double dxPx, double dyPx);
    void setView(lookout_view v);
    void fitChart();

    // Apply the full S-52 state. The worker owns the hidden-group list's
    // lifetime through Chart::setMariner.
    void applyMariner(tile57_mariner m, QList<qint32> hiddenGroups);

    // The ranked pick at a geographic point, as report rows for QML. Invoked
    // with a BlockingQueuedConnection so a tap reads synchronously; taps are
    // deliberate and rare, so the brief wait behind an in-flight tile is fine.
    QVariantList pickRanked(double lon, double lat);

    // A file a picked feature points at. Blocking, like pickRanked.
    QVariantMap auxFile(QString cell, QString name);

signals:
    void opened(ChartOpening result);
    void tileRendered(TileKey key, QImage image, quint64 styleGen);
    // The camera after a core call moved it: pose, scale, overscale.
    void viewChanged(lookout_view v, double scaleDenominator, double overscale);

private slots:
    void processJobs();

private:
    void publishView();

    lookout::Chart m_chart;
    bool m_antialias = false;

    QMutex m_mutex;
    QVector<TileKey> m_jobs; // guarded by m_mutex
    quint64 m_styleGen = 0;  // guarded by m_mutex
};
