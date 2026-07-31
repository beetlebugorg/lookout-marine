// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// The mariner's S-52 display options, bindable from QML and projected onto a
// tile57_mariner for the core.
//
// The property set and its grouping follow the Apple shell's settings
// (macos/LookoutMarine/SettingsView.swift + MarinerSettings.swift): Display,
// Depths, Text & Symbols, Charts, Advanced. The mariner thinks in those groups
// on every platform, so the panel is arranged the same way here.
//
// The state is SEEDED FROM THE CORE (loadFrom, called with lookout_get_mariner's
// answer) rather than hardcoded, exactly as the Apple panel's bind() does. The
// core opens with a considered set — the look of a traditional paper chart — and
// a shell that overwrote it with its own defaults would silently disagree with
// every other shell. Only what the e-ink panel forces is adjusted on top.

#include <QList>
#include <QObject>
#include <QQmlEngine>

#include "tile57.h"

class MarinerSettings : public QObject {
    Q_OBJECT
    QML_ELEMENT

public:
    enum class Scheme { Day, Dusk, Night };
    Q_ENUM(Scheme)
    enum class DepthUnit { Meters, Feet };
    Q_ENUM(DepthUnit)
    // S-52 §10.2 display category: cumulative Base < Standard < Other.
    enum class DetailLevel { Base, Standard, Other };
    Q_ENUM(DetailLevel)
    enum class BoundaryStyle { Symbolized, Plain };
    Q_ENUM(BoundaryStyle)
    // Spot soundings switch independently of the display category.
    enum class Soundings { FollowCategory, Always, Never };
    Q_ENUM(Soundings)

    Q_PROPERTY(Scheme scheme READ scheme WRITE setScheme NOTIFY changed)
    Q_PROPERTY(DetailLevel detailLevel READ detailLevel WRITE setDetailLevel NOTIFY changed)
    Q_PROPERTY(Soundings soundings READ soundings WRITE setSoundings NOTIFY changed)

    Q_PROPERTY(DepthUnit depthUnit READ depthUnit WRITE setDepthUnit NOTIFY changed)
    Q_PROPERTY(bool fourShadeWater READ fourShadeWater WRITE setFourShadeWater NOTIFY changed)
    Q_PROPERTY(double shallowContour READ shallowContour WRITE setShallowContour NOTIFY changed)
    Q_PROPERTY(double safetyContour READ safetyContour WRITE setSafetyContour NOTIFY changed)
    Q_PROPERTY(double deepContour READ deepContour WRITE setDeepContour NOTIFY changed)
    Q_PROPERTY(double safetyDepth READ safetyDepth WRITE setSafetyDepth NOTIFY changed)

    Q_PROPERTY(bool textNames READ textNames WRITE setTextNames NOTIFY changed)
    Q_PROPERTY(bool showLightDescriptions READ showLightDescriptions WRITE setShowLightDescriptions NOTIFY changed)
    Q_PROPERTY(bool textOther READ textOther WRITE setTextOther NOTIFY changed)
    Q_PROPERTY(BoundaryStyle boundaryStyle READ boundaryStyle WRITE setBoundaryStyle NOTIFY changed)
    Q_PROPERTY(bool simplifiedPoints READ simplifiedPoints WRITE setSimplifiedPoints NOTIFY changed)
    Q_PROPERTY(bool showFullSectorLines READ showFullSectorLines WRITE setShowFullSectorLines NOTIFY changed)
    Q_PROPERTY(double sizeScale READ sizeScale WRITE setSizeScale NOTIFY changed)

    Q_PROPERTY(bool showIsolatedDangersShallow READ showIsolatedDangersShallow WRITE setShowIsolatedDangersShallow NOTIFY changed)
    Q_PROPERTY(bool dataQuality READ dataQuality WRITE setDataQuality NOTIFY changed)
    Q_PROPERTY(bool showOverscale READ showOverscale WRITE setShowOverscale NOTIFY changed)
    Q_PROPERTY(bool showMetaBounds READ showMetaBounds WRITE setShowMetaBounds NOTIFY changed)
    Q_PROPERTY(bool showInformCallouts READ showInformCallouts WRITE setShowInformCallouts NOTIFY changed)
    Q_PROPERTY(bool highlightDateDependent READ highlightDateDependent WRITE setHighlightDateDependent NOTIFY changed)
    Q_PROPERTY(bool dateDependent READ dateDependent WRITE setDateDependent NOTIFY changed)
    Q_PROPERTY(bool ignoreScamin READ ignoreScamin WRITE setIgnoreScamin NOTIFY changed)

    // Area-overlay declutter: each toggle shows or hides a group of S-52 area
    // features through viewing groups. Off = hidden, for a readable e-ink view.
    Q_PROPERTY(bool showCautionAreas READ showCautionAreas WRITE setShowCautionAreas NOTIFY changed)
    Q_PROPERTY(bool showAnchorages READ showAnchorages WRITE setShowAnchorages NOTIFY changed)
    Q_PROPERTY(bool showRestrictedAreas READ showRestrictedAreas WRITE setShowRestrictedAreas NOTIFY changed)
    Q_PROPERTY(bool showCablesPipelines READ showCablesPipelines WRITE setShowCablesPipelines NOTIFY changed)
    Q_PROPERTY(bool showMarineFarms READ showMarineFarms WRITE setShowMarineFarms NOTIFY changed)

    explicit MarinerSettings(QObject* parent = nullptr);

    // Seed every property from the core's current state. Emits changed() once.
    void loadFrom(const tile57_mariner& m);
    // The state to hand the core. Does NOT fill viewing_groups_off — that
    // pointer's lifetime belongs to lookout::Chart::setMariner.
    tile57_mariner toStruct() const;
    // The S-52 viewing-group ids to suppress (the union of the OFF toggles).
    QList<qint32> hiddenViewingGroups() const;

    Scheme scheme() const { return m_scheme; }
    DetailLevel detailLevel() const { return m_detailLevel; }
    Soundings soundings() const { return m_soundings; }
    DepthUnit depthUnit() const { return m_depthUnit; }
    bool fourShadeWater() const { return m_fourShadeWater; }
    double shallowContour() const { return m_shallowContour; }
    double safetyContour() const { return m_safetyContour; }
    double deepContour() const { return m_deepContour; }
    double safetyDepth() const { return m_safetyDepth; }
    bool textNames() const { return m_textNames; }
    bool showLightDescriptions() const { return m_showLightDescriptions; }
    bool textOther() const { return m_textOther; }
    BoundaryStyle boundaryStyle() const { return m_boundaryStyle; }
    bool simplifiedPoints() const { return m_simplifiedPoints; }
    bool showFullSectorLines() const { return m_showFullSectorLines; }
    double sizeScale() const { return m_sizeScale; }
    bool showIsolatedDangersShallow() const { return m_showIsolatedDangersShallow; }
    bool dataQuality() const { return m_dataQuality; }
    bool showOverscale() const { return m_showOverscale; }
    bool showMetaBounds() const { return m_showMetaBounds; }
    bool showInformCallouts() const { return m_showInformCallouts; }
    bool highlightDateDependent() const { return m_highlightDateDependent; }
    bool dateDependent() const { return m_dateDependent; }
    bool ignoreScamin() const { return m_ignoreScamin; }
    bool showCautionAreas() const { return m_showCautionAreas; }
    bool showAnchorages() const { return m_showAnchorages; }
    bool showRestrictedAreas() const { return m_showRestrictedAreas; }
    bool showCablesPipelines() const { return m_showCablesPipelines; }
    bool showMarineFarms() const { return m_showMarineFarms; }

public slots:
    void setScheme(Scheme v);
    void setDetailLevel(DetailLevel v);
    void setSoundings(Soundings v);
    void setDepthUnit(DepthUnit v);
    void setFourShadeWater(bool v);
    void setShallowContour(double v);
    void setSafetyContour(double v);
    void setDeepContour(double v);
    void setSafetyDepth(double v);
    void setTextNames(bool v);
    void setShowLightDescriptions(bool v);
    void setTextOther(bool v);
    void setBoundaryStyle(BoundaryStyle v);
    void setSimplifiedPoints(bool v);
    void setShowFullSectorLines(bool v);
    void setSizeScale(double v);
    void setShowIsolatedDangersShallow(bool v);
    void setDataQuality(bool v);
    void setShowOverscale(bool v);
    void setShowMetaBounds(bool v);
    void setShowInformCallouts(bool v);
    void setHighlightDateDependent(bool v);
    void setDateDependent(bool v);
    void setIgnoreScamin(bool v);
    void setShowCautionAreas(bool v);
    void setShowAnchorages(bool v);
    void setShowRestrictedAreas(bool v);
    void setShowCablesPipelines(bool v);
    void setShowMarineFarms(bool v);

signals:
    void changed();

private:
    Scheme m_scheme = Scheme::Day;
    DetailLevel m_detailLevel = DetailLevel::Standard;
    Soundings m_soundings = Soundings::Always;
    DepthUnit m_depthUnit = DepthUnit::Meters;
    bool m_fourShadeWater = true;
    double m_shallowContour = 2.0;
    double m_safetyContour = 3.0;
    double m_deepContour = 6.0;
    double m_safetyDepth = 5.0;
    bool m_textNames = true;
    bool m_showLightDescriptions = true;
    bool m_textOther = false;
    BoundaryStyle m_boundaryStyle = BoundaryStyle::Symbolized;
    bool m_simplifiedPoints = false;
    bool m_showFullSectorLines = false;
    // The rM2's panel is ~226 dpi, about twice the S-52 reference density, so
    // symbols, line widths and labels come out half-size at 1.0. This is the one
    // default that departs from the core's, and it is a property of the glass,
    // not of the mariner's taste.
    double m_sizeScale = 1.6;
    bool m_showIsolatedDangersShallow = false;
    bool m_dataQuality = false;
    bool m_showOverscale = false;
    bool m_showMetaBounds = false;
    bool m_showInformCallouts = false;
    bool m_highlightDateDependent = false;
    bool m_dateDependent = true;
    bool m_ignoreScamin = false;

    bool m_showCautionAreas = false;
    bool m_showAnchorages = false;
    bool m_showRestrictedAreas = false;
    bool m_showCablesPipelines = false;
    bool m_showMarineFarms = false;
};
