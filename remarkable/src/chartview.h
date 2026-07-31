// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// The chart surface: a QQuickPaintedItem showing the chart as a raster tile
// pyramid, and the model the QML chrome binds to.
//
// It plays the part AppModel plays on Apple (macos/LookoutMarine/AppModel.swift):
// the chrome reads its properties and calls its methods, and it is the only
// thing that talks to the core. The camera itself lives in the CORE — pan,
// zoom-at and screen-to-geo are lookout.h calls, so this shell's idea of where
// it is looking cannot drift from the Mac's.
//
// Two things differ from the Apple shell, and both are the panel's doing:
//
//   * Zoom snaps to whole levels. A tile pyramid is only sharp at its own
//     levels, and an e-ink screen cannot animate the in-between anyway. A pinch
//     shows a scaled preview and settles on the nearest level.
//   * There is no rotation, and so no north bubble. Tiles are axis-aligned;
//     turning the view would re-render every one of them on a CPU that takes
//     tens of milliseconds each. The core still holds the rotation — it just
//     stays at north-up here.
//
// Everything else the Apple chrome does, this carries: the same readouts, the
// same ranked pick report with its notes and diagrams, the same settings.

#include <QCache>
#include <QElapsedTimer>
#include <QImage>
#include <QPointF>
#include <QQuickPaintedItem>
#include <QSet>
#include <QStringList>
#include <QThread>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include "marinersettings.h"
#include "mercator.h"
#include "renderworker.h"

class ChartView : public QQuickPaintedItem {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(MarinerSettings* settings READ settings WRITE setSettings NOTIFY settingsChanged)

    Q_PROPERTY(bool hasChart READ hasChart NOTIFY chartChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(QString loadingStatus READ loadingStatus NOTIFY loadingChanged)
    Q_PROPERTY(QString chartName READ chartName NOTIFY chartChanged)
    Q_PROPERTY(int chartCount READ chartCount NOTIFY chartChanged)
    Q_PROPERTY(QString errorString READ errorString NOTIFY errorChanged)

    Q_PROPERTY(double centerLon READ centerLon NOTIFY viewChanged)
    Q_PROPERTY(double centerLat READ centerLat NOTIFY viewChanged)
    Q_PROPERTY(double zoom READ zoom NOTIFY viewChanged)
    // The engine's S-52 display scale (96 dpi). The band comes from this one.
    Q_PROPERTY(double scaleDenominator READ scaleDenominator NOTIFY viewChanged)
    // What a divider on the glass would measure, at this panel's pixel pitch.
    Q_PROPERTY(double physicalScale READ physicalScale NOTIFY viewChanged)
    Q_PROPERTY(QString band READ band NOTIFY viewChanged)
    Q_PROPERTY(double overscale READ overscale NOTIFY viewChanged)
    Q_PROPERTY(bool canZoomIn READ canZoomIn NOTIFY viewChanged)
    Q_PROPERTY(bool canZoomOut READ canZoomOut NOTIFY viewChanged)
    // True while tiles for the current view are still arriving.
    Q_PROPERTY(bool settling READ settling NOTIFY settlingChanged)

    // Physical pixel pitch of the panel (mm), for the scale readout and the
    // scale bar. The rM2 is ~226 dpi; the Paper Pro is ~0.111.
    Q_PROPERTY(double pixelPitchMm READ pixelPitchMm WRITE setPixelPitchMm NOTIFY pixelPitchChanged)

public:
    explicit ChartView(QQuickItem* parent = nullptr);
    ~ChartView() override;

    void paint(QPainter* painter) override;

    MarinerSettings* settings() const { return m_settings; }
    void setSettings(MarinerSettings* s);

    bool hasChart() const { return m_hasChart; }
    bool loading() const { return m_loading; }
    QString loadingStatus() const { return m_loadingStatus; }
    QString chartName() const { return m_chartName; }
    int chartCount() const { return m_chartCount; }
    QString errorString() const { return m_errorString; }

    double centerLon() const { return m_view.lon; }
    double centerLat() const { return m_view.lat; }
    double zoom() const { return m_view.zoom; }
    double scaleDenominator() const { return m_scaleDenominator; }
    double physicalScale() const;
    QString band() const;
    double overscale() const { return m_overscale; }
    bool canZoomIn() const { return m_hasChart && m_zoomedIn; }
    bool canZoomOut() const { return m_hasChart && m_zoomedOut; }
    bool settling() const { return m_pendingTiles > 0; }

    double pixelPitchMm() const { return m_pixelPitchMm; }
    void setPixelPitchMm(double v);

    // ---- the chrome's verbs (AppModel's, in the same words) -----------------
    Q_INVOKABLE void openChart(const QString& path);
    Q_INVOKABLE void zoomIn();
    Q_INVOKABLE void zoomOut();
    Q_INVOKABLE void zoomToScale(double denominator);
    Q_INVOKABLE void fitChart();
    Q_INVOKABLE void panBy(double dxPx, double dyPx);

    // A pinch shows a live scaled preview about its centre; commitPinch()
    // settles on the nearest whole level.
    Q_INVOKABLE void updatePinch(double scale, double cx, double cy);
    Q_INVOKABLE void commitPinch();

    // The ranked pick under a screen point: the objects worth reporting, best
    // first, each with its attribute rows already parsed for the report.
    Q_INVOKABLE QVariantList pick(double px, double py);
    // A file a picked feature points at: {ok, mime, bytes}.
    Q_INVOKABLE QVariantMap auxFile(const QString& cell, const QString& name);
    // The position under a screen point, formatted as the other shells print it.
    Q_INVOKABLE QString positionAt(double px, double py);

signals:
    void settingsChanged();
    void chartChanged();
    void loadingChanged();
    void errorChanged();
    void viewChanged();
    void settlingChanged();
    void pixelPitchChanged();

private slots:
    void onOpened(ChartOpening result);
    void onTileRendered(TileKey key, QImage image, quint64 styleGen);
    void onViewChanged(lookout_view v, double scaleDenominator, double overscale);
    void onSettingsChanged();

protected:
    void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;
    void wheelEvent(QWheelEvent* event) override;

private:
    void applyMariner();
    void invalidateTiles();     // drop the cache and bump the style generation
    void scheduleTileRequest(); // debounced requestVisibleTiles()
    void requestVisibleTiles();
    void setZoomLevel(int level, double anchorX, double anchorY);
    void setError(const QString& msg);
    // Top-left of the viewport in world pixels at the current core zoom.
    merc::PixelPoint viewOrigin() const;
    int level() const { return merc::tileLevel(int(qRound(m_view.zoom))); }

    RenderWorker* m_worker = nullptr;
    QThread m_thread;

    MarinerSettings* m_settings = nullptr;
    QString m_chartName;
    QString m_errorString;
    QString m_loadingStatus;
    bool m_hasChart = false;
    bool m_loading = false;
    int m_chartCount = 0;

    lookout_view m_view{};
    lookout_view m_fitView{};
    double m_scaleDenominator = 0;
    double m_overscale = 1.0;
    bool m_zoomedIn = true;  // another level in is available
    bool m_zoomedOut = true; // another level out is available
    double m_pixelPitchMm = 0.1124; // reMarkable 2, ~226 dpi

    // Transient pinch preview (visual only; settles on release).
    bool m_pinching = false;
    double m_pinchScale = 1.0;
    QPointF m_pinchCenter;

    QCache<TileKey, QImage> m_cache;
    quint64 m_styleGen = 0;
    int m_pendingTiles = 0;

    QTimer m_requestTimer; // debounce handing the worker a new tile set
    QTimer m_paintTimer;   // coalesce repaints as tiles stream in
};
