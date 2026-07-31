// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#include "chartview.h"

#include <QDir>
#include <QFileInfo>
#include <QPainter>
#include <QWheelEvent>
#include <algorithm>
#include <cmath>

#include "coordformat.h"
#include "s57.h"

namespace {
constexpr int kTilePx = 512;
// One ring of tiles beyond the viewport, so a slow pan has something to show
// before the next column arrives.
constexpr int kMargin = 1;
// A pan settles into the core after this long, and tiles are asked for then.
// Long enough that a drag does not queue a render per frame, short enough that
// letting go feels immediate against an e-ink refresh.
constexpr int kRequestDebounceMs = 120;
constexpr int kPaintCoalesceMs = 60;
} // namespace

ChartView::ChartView(QQuickItem* parent) : QQuickPaintedItem(parent) {
    setFlag(ItemHasContents, true);
    setAcceptedMouseButtons(Qt::AllButtons);
    // The chart is opaque and fills the item; no blending underneath it.
    setOpaquePainting(true);
    // ~64 MB of 512-px tiles. The pyramid is the app's whole working set on a
    // device with no swap, so it is bounded by bytes, not by tile count.
    m_cache.setMaxCost(64 * 1024 * 1024);

    m_worker = new RenderWorker;
    // Antialiasing off, which is what the panel wants: a hard edge beats a grey
    // fringe it would have to dither, and it rasterizes faster. LOOKOUT_AA=1
    // turns it on for a desktop build, where the difference is worth seeing.
    m_worker->setAntialias(qEnvironmentVariableIsSet("LOOKOUT_AA"));
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(m_worker, &RenderWorker::opened, this, &ChartView::onOpened);
    connect(m_worker, &RenderWorker::tileRendered, this, &ChartView::onTileRendered);
    connect(m_worker, &RenderWorker::viewChanged, this, &ChartView::onViewChanged);
    m_thread.start();

    m_requestTimer.setSingleShot(true);
    m_requestTimer.setInterval(kRequestDebounceMs);
    connect(&m_requestTimer, &QTimer::timeout, this, &ChartView::requestVisibleTiles);

    // Coalesce repaints as tiles stream in: one e-ink refresh per settle, not
    // one per tile.
    m_paintTimer.setSingleShot(true);
    m_paintTimer.setInterval(kPaintCoalesceMs);
    connect(&m_paintTimer, &QTimer::timeout, this, [this] { update(); });
}

ChartView::~ChartView() {
    // Close on the worker's own thread — the handle belongs to it — then stop.
    QMetaObject::invokeMethod(m_worker, "closeChart", Qt::BlockingQueuedConnection);
    m_thread.quit();
    m_thread.wait();
}

void ChartView::setSettings(MarinerSettings* s) {
    if (m_settings == s)
        return;
    if (m_settings)
        disconnect(m_settings, nullptr, this, nullptr);
    m_settings = s;
    if (m_settings)
        connect(m_settings, &MarinerSettings::changed, this, &ChartView::onSettingsChanged);
    emit settingsChanged();
    applyMariner();
}

void ChartView::setPixelPitchMm(double v) {
    if (v <= 0 || qFuzzyCompare(v, m_pixelPitchMm))
        return;
    m_pixelPitchMm = v;
    emit pixelPitchChanged();
    emit viewChanged(); // the scale readout and the bar are derived from it
}

double ChartView::physicalScale() const {
    return merc::scaleDenominatorPhysical(m_view.zoom, m_view.lat, m_pixelPitchMm);
}

QString ChartView::band() const {
    // From the ENGINE's display scale, not the panel's: the band is a property
    // of the chart. See CoordFormat::band.
    return CoordFormat::band(m_scaleDenominator);
}

// ---- opening ---------------------------------------------------------------

void ChartView::openChart(const QString& path) {
    if (path.isEmpty())
        return;
    const QFileInfo fi(path);
    QStringList paths;
    if (fi.isDir()) {
        // A folder of baked cells opens as one seamless library, as it does on
        // every other shell. The core composes them; we only enumerate.
        QDir dir(fi.absoluteFilePath());
        const QStringList names =
            dir.entryList({QStringLiteral("*.pmtiles")}, QDir::Files, QDir::Name);
        paths.reserve(names.size());
        for (const QString& n : names)
            paths << dir.absoluteFilePath(n);
        m_chartName = fi.fileName();
    } else {
        paths << fi.absoluteFilePath();
        m_chartName = fi.completeBaseName();
    }
    if (paths.isEmpty()) {
        setError(QStringLiteral("No baked charts (.pmtiles) in that folder."));
        return;
    }

    m_loading = true;
    m_loadingStatus = paths.size() > 1
                          ? QStringLiteral("Opening %1 cells…").arg(paths.size())
                          : QStringLiteral("Opening the chart…");
    m_errorString.clear();
    emit loadingChanged();
    emit errorChanged();
    emit chartChanged();

    QMetaObject::invokeMethod(m_worker, "open", Qt::QueuedConnection,
                              Q_ARG(QStringList, paths));
}

void ChartView::onOpened(ChartOpening result) {
    m_loading = false;
    m_loadingStatus.clear();
    emit loadingChanged();

    if (!result.ok) {
        m_hasChart = false;
        emit chartChanged();
        setError(result.error.isEmpty() ? QStringLiteral("The chart could not be opened.")
                                        : result.error);
        return;
    }

    m_hasChart = true;
    m_chartCount = result.chartCount;
    m_fitView = result.fit;
    emit chartChanged();

    // Size the core's camera to the item, then take its opening view. That
    // policy lives in the core (lookout_default_view) so every shell agrees.
    QMetaObject::invokeMethod(m_worker, "resize", Qt::QueuedConnection,
                              Q_ARG(int, int(width())), Q_ARG(int, int(height())));
    applyMariner();
    lookout_view v = result.opening;
    // LOOKOUT_VIEW=lon,lat,zoom[,rot] pins the first camera position, as it does
    // on every other host — it is what lets the screenshot protocol compare this
    // shell frame to frame with the Mac. The rotation field is accepted and
    // ignored here: this view is always north-up (see the header).
    const QString wanted = qEnvironmentVariable("LOOKOUT_VIEW");
    if (!wanted.isEmpty()) {
        const QStringList parts = wanted.split(QLatin1Char(','));
        if (parts.size() >= 3) {
            bool okLon = false, okLat = false, okZoom = false;
            const double lon = parts[0].toDouble(&okLon);
            const double lat = parts[1].toDouble(&okLat);
            const double zoom = parts[2].toDouble(&okZoom);
            if (okLon && okLat && okZoom) {
                v.lon = lon;
                v.lat = lat;
                v.zoom = zoom;
            }
        }
    }
    v.zoom = std::round(v.zoom); // whole levels; see the header
    v.rotation_deg = 0;
    m_view = v;
    QMetaObject::invokeMethod(m_worker, "setView", Qt::QueuedConnection, Q_ARG(lookout_view, v));
    invalidateTiles();
    scheduleTileRequest();
    emit viewChanged();
}

void ChartView::setError(const QString& msg) {
    m_errorString = msg;
    emit errorChanged();
}

// ---- settings --------------------------------------------------------------

void ChartView::applyMariner() {
    if (!m_settings)
        return;
    QMetaObject::invokeMethod(m_worker, "applyMariner", Qt::QueuedConnection,
                              Q_ARG(tile57_mariner, m_settings->toStruct()),
                              Q_ARG(QList<qint32>, m_settings->hiddenViewingGroups()));
}

void ChartView::onSettingsChanged() {
    applyMariner();
    // Every cached tile was portrayed under the old style.
    invalidateTiles();
    scheduleTileRequest();
}

void ChartView::invalidateTiles() {
    m_cache.clear();
    ++m_styleGen;
    m_pendingTiles = 0;
    emit settlingChanged();
    update();
}

// ---- camera ----------------------------------------------------------------
//
// The core is authoritative: it clamps the zoom to the levels the library
// actually serves, and it answers for the display scale and the overscale. But
// a drag cannot wait on it — the core's API lock is held for as long as a tile
// takes to paint. So a gesture moves a LOCAL mirror of the pose for the next
// paint, and the core is told after it settles; when the core answers, its view
// wins. A pan is an exact translation in world pixels, so the mirror and the
// core cannot disagree about anything but a clamp.

merc::PixelPoint ChartView::viewOrigin() const {
    const merc::PixelPoint c = merc::project({m_view.lon, m_view.lat}, m_view.zoom);
    return {c.x - width() / 2.0, c.y - height() / 2.0};
}

void ChartView::panBy(double dxPx, double dyPx) {
    if (!m_hasChart)
        return;
    merc::PixelPoint o = viewOrigin();
    o.x -= dxPx;
    o.y -= dyPx;
    const merc::LonLat c =
        merc::unproject({o.x + width() / 2.0, o.y + height() / 2.0}, m_view.zoom);
    m_view.lon = c.lon;
    m_view.lat = c.lat;
    emit viewChanged();
    update();
    scheduleTileRequest();
}

void ChartView::setZoomLevel(int coreZoom, double anchorX, double anchorY) {
    if (!m_hasChart)
        return;
    const int want = std::clamp(coreZoom, 1, 24);
    if (want == int(std::lround(m_view.zoom)))
        return;
    // Keep the ground under the anchor where it is, as zoom-to-cursor does on
    // every other shell.
    const merc::PixelPoint o = viewOrigin();
    const merc::LonLat under = merc::unproject({o.x + anchorX, o.y + anchorY}, m_view.zoom);
    m_view.zoom = want;
    const merc::PixelPoint p = merc::project(under, m_view.zoom);
    const merc::LonLat c =
        merc::unproject({p.x - anchorX + width() / 2.0, p.y - anchorY + height() / 2.0},
                        m_view.zoom);
    m_view.lon = c.lon;
    m_view.lat = c.lat;

    lookout_view v = m_view;
    QMetaObject::invokeMethod(m_worker, "setView", Qt::QueuedConnection, Q_ARG(lookout_view, v));
    emit viewChanged();
    update();
    scheduleTileRequest();
}

void ChartView::zoomIn() {
    setZoomLevel(int(std::lround(m_view.zoom)) + 1, width() / 2.0, height() / 2.0);
}

void ChartView::zoomOut() {
    setZoomLevel(int(std::lround(m_view.zoom)) - 1, width() / 2.0, height() / 2.0);
}

void ChartView::zoomToScale(double denominator) {
    if (!m_hasChart || denominator <= 0)
        return;
    // Invert the engine's own display-scale definition (96 dpi, latitude
    // adjusted) so "zoom to 1:25,000" means the same number here as on the Mac.
    const double c = 559082264.029 * std::cos(m_view.lat * merc::kPi / 180.0);
    const double z = std::log2(c / denominator);
    setZoomLevel(int(std::lround(z)), width() / 2.0, height() / 2.0);
}

void ChartView::fitChart() {
    if (!m_hasChart)
        return;
    m_view.lon = m_fitView.lon;
    m_view.lat = m_fitView.lat;
    m_view.zoom = std::round(m_fitView.zoom);
    lookout_view v = m_view;
    QMetaObject::invokeMethod(m_worker, "setView", Qt::QueuedConnection, Q_ARG(lookout_view, v));
    emit viewChanged();
    invalidateTiles();
    scheduleTileRequest();
}

void ChartView::updatePinch(double scale, double cx, double cy) {
    if (!m_hasChart || scale <= 0)
        return;
    m_pinching = true;
    m_pinchScale = scale;
    m_pinchCenter = QPointF(cx, cy);
    update(); // a scaled preview of what is already cached
}

void ChartView::commitPinch() {
    if (!m_pinching)
        return;
    const double steps = std::log2(m_pinchScale);
    const int want = int(std::lround(m_view.zoom + steps));
    m_pinching = false;
    m_pinchScale = 1.0;
    setZoomLevel(want, m_pinchCenter.x(), m_pinchCenter.y());
    update();
}

void ChartView::wheelEvent(QWheelEvent* event) {
    if (!m_hasChart) {
        event->ignore();
        return;
    }
    const int dy = event->angleDelta().y();
    if (dy == 0) {
        event->ignore();
        return;
    }
    const QPointF p = event->position();
    setZoomLevel(int(std::lround(m_view.zoom)) + (dy > 0 ? 1 : -1), p.x(), p.y());
    event->accept();
}

void ChartView::onViewChanged(lookout_view v, double scaleDenominator, double overscale) {
    m_scaleDenominator = scaleDenominator;
    m_overscale = overscale;
    // The core clamps the zoom to what the library serves. If it came back at a
    // different level than we asked for, that direction is exhausted — which is
    // how the + and − buttons know to go grey, with no extra ABI to ask.
    const int want = int(std::lround(m_view.zoom));
    const int got = int(std::lround(v.zoom));
    if (got != want) {
        if (want > got)
            m_zoomedIn = false;
        else
            m_zoomedOut = false;
        m_view.zoom = v.zoom;
        m_view.lon = v.lon;
        m_view.lat = v.lat;
        invalidateTiles();
        scheduleTileRequest();
    } else {
        m_zoomedIn = true;
        m_zoomedOut = true;
    }
    emit viewChanged();
}

void ChartView::geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) {
    QQuickPaintedItem::geometryChange(newGeometry, oldGeometry);
    if (newGeometry.size() == oldGeometry.size())
        return;
    QMetaObject::invokeMethod(m_worker, "resize", Qt::QueuedConnection,
                              Q_ARG(int, int(newGeometry.width())),
                              Q_ARG(int, int(newGeometry.height())));
    scheduleTileRequest();
}

// ---- tiles -----------------------------------------------------------------

void ChartView::scheduleTileRequest() {
    m_requestTimer.start();
}

void ChartView::requestVisibleTiles() {
    if (!m_hasChart || width() <= 0 || height() <= 0)
        return;
    // Tell the core where we ended up, so its scale, overscale and clamping
    // answer for the view actually on screen.
    lookout_view v = m_view;
    QMetaObject::invokeMethod(m_worker, "setView", Qt::QueuedConnection, Q_ARG(lookout_view, v));

    const int lvl = level();
    const int across = merc::tilesAcross(lvl);
    const merc::PixelPoint o = viewOrigin();
    const int x0 = int(std::floor(o.x / kTilePx)) - kMargin;
    const int y0 = int(std::floor(o.y / kTilePx)) - kMargin;
    const int x1 = int(std::floor((o.x + width()) / kTilePx)) + kMargin;
    const int y1 = int(std::floor((o.y + height()) / kTilePx)) + kMargin;

    // Centre-out: what the eye is on arrives first.
    const double ccx = (o.x + width() / 2.0) / kTilePx;
    const double ccy = (o.y + height() / 2.0) / kTilePx;
    QVector<TileKey> wanted;
    int pending = 0;
    for (int y = y0; y <= y1; ++y) {
        for (int x = x0; x <= x1; ++x) {
            if (y < 0 || y >= across)
                continue; // off the top or bottom of the world
            // Longitude wraps; latitude does not.
            const int wx = ((x % across) + across) % across;
            const TileKey key{lvl, wx, y};
            if (m_cache.contains(key))
                continue;
            wanted.append(key);
            ++pending;
        }
    }
    std::sort(wanted.begin(), wanted.end(), [&](const TileKey& a, const TileKey& b) {
        const double da = std::hypot(a.x + 0.5 - ccx, a.y + 0.5 - ccy);
        const double db = std::hypot(b.x + 0.5 - ccx, b.y + 0.5 - ccy);
        return da < db;
    });

    m_pendingTiles = pending;
    emit settlingChanged();
    m_worker->setJobs(wanted, m_styleGen);
}

void ChartView::onTileRendered(TileKey key, QImage image, quint64 styleGen) {
    if (styleGen != m_styleGen)
        return; // portrayed under a style we have since left
    if (!image.isNull())
        m_cache.insert(key, new QImage(image), std::max(1, int(image.sizeInBytes())));
    if (key.level != level())
        return; // for a level we have since left

    if (m_pendingTiles > 0) {
        --m_pendingTiles;
        if (m_pendingTiles == 0)
            emit settlingChanged();
    }
    // One refresh per settle: the panel cannot show more than that anyway.
    if (!m_paintTimer.isActive())
        m_paintTimer.start();
}

// ---- painting --------------------------------------------------------------

void ChartView::paint(QPainter* painter) {
    painter->fillRect(QRectF(0, 0, width(), height()), Qt::white);
    if (!m_hasChart)
        return;

    painter->save();
    if (m_pinching && !qFuzzyCompare(m_pinchScale, 1.0)) {
        // A live pinch scales what is already on screen about its centre. The
        // sharp tiles arrive after it settles.
        painter->translate(m_pinchCenter);
        painter->scale(m_pinchScale, m_pinchScale);
        painter->translate(-m_pinchCenter);
    }

    const int lvl = level();
    const int across = merc::tilesAcross(lvl);
    const merc::PixelPoint o = viewOrigin();
    const int x0 = int(std::floor(o.x / kTilePx));
    const int y0 = int(std::floor(o.y / kTilePx));
    const int x1 = int(std::floor((o.x + width()) / kTilePx));
    const int y1 = int(std::floor((o.y + height()) / kTilePx));

    for (int y = y0; y <= y1; ++y) {
        if (y < 0 || y >= across)
            continue;
        for (int x = x0; x <= x1; ++x) {
            const int wx = ((x % across) + across) % across;
            const QRectF dest(x * double(kTilePx) - o.x, y * double(kTilePx) - o.y, kTilePx,
                              kTilePx);
            if (const QImage* img = m_cache.object({lvl, wx, y})) {
                painter->drawImage(dest, *img);
                continue;
            }
            // Nothing sharp yet: show the matching piece of a coarser ancestor,
            // scaled up. Blurry beats blank, and it means a zoom never flashes
            // white before the panel has refreshed.
            for (int up = 1; up <= 4; ++up) {
                const int alvl = lvl - up;
                if (alvl < 0)
                    break;
                const int shift = 1 << up;
                const TileKey akey{alvl, wx / shift, y / shift};
                const QImage* anc = m_cache.object(akey);
                if (!anc)
                    continue;
                const double part = double(kTilePx) / shift;
                const QRectF src((wx % shift) * part, (y % shift) * part, part, part);
                painter->drawImage(dest, *anc, src);
                break;
            }
        }
    }
    painter->restore();
}

// ---- pick ------------------------------------------------------------------

QVariantList ChartView::pick(double px, double py) {
    if (!m_hasChart)
        return {};
    const merc::PixelPoint o = viewOrigin();
    const merc::LonLat c = merc::unproject({o.x + px, o.y + py}, m_view.zoom);
    QVariantList out;
    // Blocking: a tap is deliberate and rare, so waiting behind an in-flight
    // tile is fine, and the report must not appear before its contents.
    QMetaObject::invokeMethod(m_worker, "pickRanked", Qt::BlockingQueuedConnection,
                              Q_RETURN_ARG(QVariantList, out), Q_ARG(double, c.lon),
                              Q_ARG(double, c.lat));
    return out;
}

QVariantMap ChartView::auxFile(const QString& cell, const QString& name) {
    QVariantMap out;
    if (!m_hasChart)
        return out;
    QMetaObject::invokeMethod(m_worker, "auxFile", Qt::BlockingQueuedConnection,
                              Q_RETURN_ARG(QVariantMap, out), Q_ARG(QString, cell),
                              Q_ARG(QString, name));
    return out;
}

QString ChartView::positionAt(double px, double py) {
    const merc::PixelPoint o = viewOrigin();
    const merc::LonLat c = merc::unproject({o.x + px, o.y + py}, m_view.zoom);
    return CoordFormat::position(c.lat, c.lon);
}
