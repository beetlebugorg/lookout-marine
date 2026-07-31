// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#include "lookoutchart.h"

#include <QBrush>
#include <QColor>
#include <QFile>
#include <QPainter>
#include <QPainterPath>
#include <QPen>
#include <vector>

namespace lookout {
namespace {

// ---- the canvas sink -------------------------------------------------------
// lookout_render_view_canvas streams the view as pixel-space draw calls in
// paint order; we paint them straight into a QImage with QPainter. Nothing here
// interprets the chart — the engine has already resolved every colour for the
// active palette and put the calls in the order they must be drawn.

// A resolved colour arrives packed 0xRRGGBBAA in a uint32, NOT as a struct: a
// small extern struct passed by value across a callconv(.c) boundary is
// miscompiled by zig on aarch64 in optimized builds, which reached hosts as
// fully transparent fills. Unpack with the header's macros and nothing else.
inline QColor col(tile57_color c) {
    return QColor(TILE57_COLOR_R(c), TILE57_COLOR_G(c), TILE57_COLOR_B(c), TILE57_COLOR_A(c));
}

QPainterPath buildPath(const tile57_rings* r, bool close) {
    QPainterPath path;
    for (uint32_t k = 0; k < r->ring_count; ++k) {
        const uint32_t start = r->ring_starts[k];
        const uint32_t end = (k + 1 < r->ring_count) ? r->ring_starts[k + 1] : r->n;
        if (end <= start)
            continue;
        path.moveTo(r->pts[start].x, r->pts[start].y);
        for (uint32_t i = start + 1; i < end; ++i)
            path.lineTo(r->pts[i].x, r->pts[i].y);
        if (close)
            path.closeSubpath();
    }
    return path;
}

inline bool empty(const tile57_rings* r) {
    return !r || r->n == 0 || r->ring_count == 0 || !r->pts || !r->ring_starts;
}

void cbFillPath(void* ctx, const tile57_rings* r, tile57_color color, int evenOdd) {
    if (empty(r))
        return;
    auto* p = static_cast<QPainter*>(ctx);
    QPainterPath path = buildPath(r, true);
    path.setFillRule(evenOdd ? Qt::OddEvenFill : Qt::WindingFill);
    p->fillPath(path, col(color));
}

void cbStrokePath(void* ctx, const tile57_rings* r, float widthPx, float dashOn, float dashOff,
                  tile57_color color) {
    if (empty(r))
        return;
    auto* p = static_cast<QPainter*>(ctx);
    QPen pen(col(color));
    pen.setWidthF(widthPx > 0 ? widthPx : 1.0);
    pen.setCapStyle(Qt::RoundCap);
    pen.setJoinStyle(Qt::RoundJoin);
    if (dashOn > 0 || dashOff > 0) {
        // Qt's dash pattern is in pen widths, the engine's is in pixels.
        const qreal w = pen.widthF() > 0 ? pen.widthF() : 1.0;
        pen.setDashPattern({dashOn / w, dashOff / w});
    }
    p->strokePath(buildPath(r, false), pen);
}

void cbFillPattern(void* ctx, const tile57_rings* r, uint32_t pw, uint32_t ph,
                   const uint8_t* rgba) {
    if (empty(r))
        return;
    // No pattern cell to tile (the overscale hatch, when it could not be
    // rasterized). Skip it rather than blanking the area with an opaque grey,
    // which otherwise smears whole overscaled tiles.
    if (pw == 0 || ph == 0 || !rgba)
        return;
    auto* p = static_cast<QPainter*>(ctx);
    // The cell bytes are transient — copy into the brush's own image.
    const QImage cell(rgba, int(pw), int(ph), int(pw) * 4, QImage::Format_RGBA8888);
    p->fillPath(buildPath(r, true), QBrush(cell.copy()));
}

void cbDrawGlyphs(void* ctx, const tile57_rings* r, tile57_color color, tile57_color halo,
                  float haloPx) {
    if (empty(r))
        return;
    auto* p = static_cast<QPainter*>(ctx);
    QPainterPath path = buildPath(r, true);
    path.setFillRule(Qt::OddEvenFill);
    if (TILE57_COLOR_A(halo) != 0 && haloPx > 0) {
        QPen hp(col(halo));
        hp.setWidthF(haloPx * 2.0);
        hp.setJoinStyle(Qt::RoundJoin);
        p->strokePath(path, hp);
    }
    p->fillPath(path, col(color));
}

// ---- pick collection -------------------------------------------------------
struct PickSink {
    QVector<PickedFeature> features;
};

QString take(const char* p, size_t n) {
    return (p && n) ? QString::fromUtf8(p, int(n)) : QString();
}

void cbFeature(void* ctx, const char* cls, size_t clsLen, const char* s57, size_t s57Len,
               const char* chart, size_t chartLen) {
    auto* sink = static_cast<PickSink*>(ctx);
    if (!sink)
        return;
    sink->features.append({take(cls, clsLen), take(s57, s57Len), take(chart, chartLen)});
}

} // namespace

QString version() {
    return QString::fromUtf8(tile57_version());
}

Chart::~Chart() {
    close();
}

bool Chart::open(const QStringList& paths, int width, int height) {
    close();
    m_error.clear();
    if (paths.isEmpty()) {
        m_error = QStringLiteral("No chart to open.");
        return false;
    }
    // Keep the encoded paths alive across the call — the array is borrowed.
    std::vector<QByteArray> stored;
    std::vector<const char*> argv;
    stored.reserve(size_t(paths.size()));
    argv.reserve(size_t(paths.size()));
    for (const QString& p : paths) {
        stored.push_back(QFile::encodeName(p));
        argv.push_back(stored.back().constData());
    }
    // Headless: no window and no MSAA. On -Dbackend=none the core makes no GPU
    // device at all, and asking for a window would be refused.
    m_h = lookout_open_charts(argv.data(), argv.size(), uint32_t(qMax(1, width)),
                              uint32_t(qMax(1, height)), /*want_window=*/0, /*want_msaa=*/0);
    if (!m_h) {
        m_error = QStringLiteral("The chart could not be opened.");
        return false;
    }
    m_chartCount = int(paths.size());
    return true;
}

void Chart::close() {
    if (m_h) {
        lookout_close(m_h);
        m_h = nullptr;
    }
    m_chartCount = 0;
    m_hidden.clear();
}

lookout_view Chart::view() const {
    lookout_view v{};
    if (m_h)
        lookout_get_view(m_h, &v);
    return v;
}

void Chart::setView(const lookout_view& v) {
    if (m_h)
        lookout_set_view(m_h, &v);
}

lookout_view Chart::fitView() const {
    lookout_view v{};
    if (m_h)
        lookout_fit_chart(m_h, &v);
    return v;
}

lookout_view Chart::defaultView() const {
    lookout_view v{};
    if (m_h)
        lookout_default_view(m_h, &v);
    return v;
}

void Chart::resize(int width, int height) {
    if (m_h)
        lookout_resize(m_h, uint32_t(qMax(1, width)), uint32_t(qMax(1, height)));
}

void Chart::pan(double dxPx, double dyPx) {
    if (m_h)
        lookout_pan(m_h, float(dxPx), float(dyPx));
}

void Chart::zoomAt(double dzoom, double xPx, double yPx) {
    if (m_h)
        lookout_zoom_at(m_h, dzoom, float(xPx), float(yPx));
}

void Chart::screenToGeo(double xPx, double yPx, double* lon, double* lat) const {
    if (m_h)
        lookout_screen_to_geo(m_h, float(xPx), float(yPx), lon, lat);
}

QPointF Chart::geoToScreen(double lon, double lat) const {
    float x = 0, y = 0;
    if (m_h)
        lookout_geo_to_screen(m_h, lon, lat, &x, &y);
    return QPointF(x, y);
}

double Chart::scaleDenominator() const {
    return m_h ? lookout_scale_denominator(m_h) : 0.0;
}

double Chart::overscale() const {
    return m_h ? lookout_overscale(m_h) : 1.0;
}

tile57_mariner Chart::marinerDefaults() {
    tile57_mariner m{};
    lookout_mariner_defaults(&m);
    return m;
}

tile57_mariner Chart::mariner() const {
    tile57_mariner m{};
    if (m_h)
        lookout_get_mariner(m_h, &m);
    else
        lookout_mariner_defaults(&m);
    return m;
}

void Chart::setMariner(const tile57_mariner& m, const QList<qint32>& hiddenGroups) {
    if (!m_h)
        return;
    // The core keeps the pointer, not the contents, so the list has to outlive
    // the call — it lives here until the next setMariner or close().
    m_hidden = hiddenGroups;
    tile57_mariner mm = m;
    mm.viewing_groups_off = m_hidden.isEmpty() ? nullptr : m_hidden.constData();
    mm.viewing_groups_off_len = uint32_t(m_hidden.size());
    lookout_set_mariner(m_h, &mm);
}

QImage Chart::renderView(double lon, double lat, double zoom, int width, int height,
                         bool antialias) {
    if (!m_h || width <= 0 || height <= 0)
        return QImage();
    QImage img(width, height, QImage::Format_ARGB32_Premultiplied);
    if (img.isNull())
        return img;
    // Paper. The engine paints the chart's own background over everything it
    // covers; this only shows through where the library has no cell at all,
    // and on an e-ink panel unsurveyed ground reading as blank paper is right.
    img.fill(Qt::white);

    QPainter painter(&img);
    painter.setRenderHint(QPainter::Antialiasing, antialias);
    painter.setRenderHint(QPainter::TextAntialiasing, antialias);
    painter.setRenderHint(QPainter::SmoothPixmapTransform, antialias);

    tile57_canvas_cb cb{};
    cb.ctx = &painter;
    cb.fill_path = cbFillPath;
    cb.stroke_path = cbStrokePath;
    cb.fill_pattern = cbFillPattern;
    cb.draw_glyphs = cbDrawGlyphs;

    const int rc = lookout_render_view_canvas(m_h, lon, lat, zoom, uint32_t(width),
                                              uint32_t(height), &cb);
    painter.end();
    if (rc != 0)
        return QImage();
    return img;
}

QVector<PickedFeature> Chart::pickRanked(double lon, double lat) {
    PickSink sink;
    if (!m_h)
        return sink.features;
    tile57_query_cb cb{};
    cb.ctx = &sink;
    cb.feature = cbFeature;
    lookout_pick_ranked(m_h, lon, lat, &cb);
    return sink.features;
}

bool Chart::auxFile(const QString& cell, const QString& name, QByteArray* bytes, QString* mime) {
    if (bytes)
        bytes->clear();
    if (mime)
        mime->clear();
    if (!m_h || name.isEmpty())
        return false;
    const QByteArray cellUtf8 = cell.toUtf8();
    const QByteArray nameUtf8 = name.toUtf8();
    const uint8_t* data = nullptr;
    size_t len = 0;
    const char* mimeStr = nullptr;
    lookout_aux_file(m_h, cellUtf8.constData(), nameUtf8.constData(), &data, &len, &mimeStr);
    if (!data || len == 0)
        return false;
    // Copy out: the core's bytes belong to the handle and die with it.
    if (bytes)
        *bytes = QByteArray(reinterpret_cast<const char*>(data), int(len));
    if (mime)
        *mime = mimeStr ? QString::fromUtf8(mimeStr) : QString();
    return true;
}

} // namespace lookout
