// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// The shell's one door to the chart core: a C++ handle over include/lookout.h.
//
// Every other shell in this repo drives the same header — SwiftUI on Apple, GTK4
// on Linux, WinUI 3 on Windows, Java on Android — and none of them reaches past
// it into tile57. This one does not either. It differs from the rest only in HOW
// it gets pixels: the reMarkable's e-ink panel ships no Vulkan driver, so
// instead of handing the core a surface to present into, it asks for the view as
// pixel-space draw calls (lookout_render_view_canvas) and paints them with
// QPainter. The core is built -Dbackend=none for exactly this.
//
// Threading: the core locks its own API, but a canvas render holds that lock for
// as long as it takes to paint a tile. Confine this object to the render thread
// (see RenderWorker) so a tap never waits behind a tile.

#include <QByteArray>
#include <QImage>
#include <QList>
#include <QPointF>
#include <QString>
#include <QStringList>
#include <QVector>

#include "lookout.h"

namespace lookout {

// One object under the cursor, as lookout_pick_ranked reports it: the S-57
// class acronym, its full attribute payload as JSON, and the cell it came from.
struct PickedFeature {
    QString cls;
    QString s57;
    QString chart;
};

QString version();

class Chart {
public:
    Chart() = default;
    ~Chart();
    Chart(const Chart&) = delete;
    Chart& operator=(const Chart&) = delete;

    // Open one baked .pmtiles, or many composed into a seamless library. The
    // handle is headless: no window, no MSAA, no GPU device (see -Dbackend=none).
    // width/height size the core's camera, which is what pan, zoom-at and
    // screen<->geo are all defined against.
    bool open(const QStringList& paths, int width, int height);
    void close();
    bool isOpen() const { return m_h != nullptr; }
    int chartCount() const { return m_chartCount; }
    QString lastError() const { return m_error; }

    // ---- camera (the core owns it) -----------------------------------------
    lookout_view view() const;
    void setView(const lookout_view& v);
    lookout_view fitView() const;     // the view that holds the whole coverage
    lookout_view defaultView() const; // the opening view, when nothing is saved
    void resize(int width, int height);
    void pan(double dxPx, double dyPx);
    void zoomAt(double dzoom, double xPx, double yPx);
    void screenToGeo(double xPx, double yPx, double* lon, double* lat) const;
    QPointF geoToScreen(double lon, double lat) const;
    // The S-52 display-scale denominator (96 dpi) — the number the band and the
    // SCAMIN gate are defined against, NOT the panel's physical scale.
    double scaleDenominator() const;
    double overscale() const;

    // ---- mariner ------------------------------------------------------------
    static tile57_mariner marinerDefaults();
    tile57_mariner mariner() const;
    // Apply the full S-52 state. `hiddenGroups` are the viewing groups to
    // suppress; the core keeps the POINTER, not a copy, so this object owns the
    // list for as long as the state is set — pass it here rather than filling
    // the struct's viewing_groups_off yourself.
    void setMariner(const tile57_mariner& m, const QList<qint32>& hiddenGroups);

    // ---- draw ---------------------------------------------------------------
    // The view at (lon, lat, zoom) painted into a fresh image. `zoom` is the
    // CORE's zoom (a 256-px world tile — see mercator.h), the same number the
    // camera carries. Antialiasing off is what an e-ink panel wants: crisper
    // and faster, with no grey fringe for the panel to dither.
    QImage renderView(double lon, double lat, double zoom, int width, int height,
                      bool antialias);

    // ---- pick ---------------------------------------------------------------
    // The objects under a geographic point, best first. This is the RANKED pick:
    // the core drops what a report should not show and orders what is left, so
    // this shell shows the same objects in the same order as the Mac.
    QVector<PickedFeature> pickRanked(double lon, double lat);

    // A file the picked feature points at rather than carries: TXTDSC and NTXTDS
    // name a text file, PICREP a picture. False when the chart carries no such
    // file. The bytes are copied out — the core's copy belongs to the handle.
    bool auxFile(const QString& cell, const QString& name, QByteArray* bytes, QString* mime);

private:
    lookout* m_h = nullptr;
    int m_chartCount = 0;
    QString m_error;
    // Backing store for the mariner's viewing_groups_off pointer; see setMariner.
    QList<qint32> m_hidden;
};

} // namespace lookout
