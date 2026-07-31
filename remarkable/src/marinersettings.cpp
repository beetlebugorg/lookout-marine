// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#include "marinersettings.h"

MarinerSettings::MarinerSettings(QObject* parent) : QObject(parent) {}

// Assign, and emit changed() only on a real change, so a QML binding writing
// back the value it already holds does not trigger a re-render of every tile.
#define LK_SET(member, value)  \
    do {                       \
        if ((member) == (value)) \
            return;            \
        (member) = (value);    \
        emit changed();        \
    } while (0)

void MarinerSettings::setScheme(Scheme v) { LK_SET(m_scheme, v); }
void MarinerSettings::setDetailLevel(DetailLevel v) { LK_SET(m_detailLevel, v); }
void MarinerSettings::setSoundings(Soundings v) { LK_SET(m_soundings, v); }
void MarinerSettings::setDepthUnit(DepthUnit v) { LK_SET(m_depthUnit, v); }
void MarinerSettings::setFourShadeWater(bool v) { LK_SET(m_fourShadeWater, v); }
void MarinerSettings::setShallowContour(double v) { LK_SET(m_shallowContour, v); }
void MarinerSettings::setSafetyContour(double v) { LK_SET(m_safetyContour, v); }
void MarinerSettings::setDeepContour(double v) { LK_SET(m_deepContour, v); }
void MarinerSettings::setSafetyDepth(double v) { LK_SET(m_safetyDepth, v); }
void MarinerSettings::setTextNames(bool v) { LK_SET(m_textNames, v); }
void MarinerSettings::setShowLightDescriptions(bool v) { LK_SET(m_showLightDescriptions, v); }
void MarinerSettings::setTextOther(bool v) { LK_SET(m_textOther, v); }
void MarinerSettings::setBoundaryStyle(BoundaryStyle v) { LK_SET(m_boundaryStyle, v); }
void MarinerSettings::setSimplifiedPoints(bool v) { LK_SET(m_simplifiedPoints, v); }
void MarinerSettings::setShowFullSectorLines(bool v) { LK_SET(m_showFullSectorLines, v); }
void MarinerSettings::setSizeScale(double v) { LK_SET(m_sizeScale, v); }
void MarinerSettings::setShowIsolatedDangersShallow(bool v) { LK_SET(m_showIsolatedDangersShallow, v); }
void MarinerSettings::setDataQuality(bool v) { LK_SET(m_dataQuality, v); }
void MarinerSettings::setShowOverscale(bool v) { LK_SET(m_showOverscale, v); }
void MarinerSettings::setShowMetaBounds(bool v) { LK_SET(m_showMetaBounds, v); }
void MarinerSettings::setShowInformCallouts(bool v) { LK_SET(m_showInformCallouts, v); }
void MarinerSettings::setHighlightDateDependent(bool v) { LK_SET(m_highlightDateDependent, v); }
void MarinerSettings::setDateDependent(bool v) { LK_SET(m_dateDependent, v); }
void MarinerSettings::setIgnoreScamin(bool v) { LK_SET(m_ignoreScamin, v); }
void MarinerSettings::setShowCautionAreas(bool v) { LK_SET(m_showCautionAreas, v); }
void MarinerSettings::setShowAnchorages(bool v) { LK_SET(m_showAnchorages, v); }
void MarinerSettings::setShowRestrictedAreas(bool v) { LK_SET(m_showRestrictedAreas, v); }
void MarinerSettings::setShowCablesPipelines(bool v) { LK_SET(m_showCablesPipelines, v); }
void MarinerSettings::setShowMarineFarms(bool v) { LK_SET(m_showMarineFarms, v); }

#undef LK_SET

void MarinerSettings::loadFrom(const tile57_mariner& m) {
    switch (m.scheme) {
    case TILE57_SCHEME_NIGHT: m_scheme = Scheme::Night; break;
    case TILE57_SCHEME_DUSK:  m_scheme = Scheme::Dusk; break;
    default:                  m_scheme = Scheme::Day; break;
    }
    // Cumulative: Other implies Standard implies Base.
    m_detailLevel = m.display_other ? DetailLevel::Other
                  : m.display_standard ? DetailLevel::Standard
                                       : DetailLevel::Base;
    m_soundings = m.soundings == 1 ? Soundings::Always
                : m.soundings == 2 ? Soundings::Never
                                   : Soundings::FollowCategory;
    m_depthUnit = (m.depth_unit == TILE57_DEPTH_FEET) ? DepthUnit::Feet : DepthUnit::Meters;
    m_fourShadeWater = m.four_shade_water;
    m_shallowContour = m.shallow_contour;
    m_safetyContour = m.safety_contour;
    m_deepContour = m.deep_contour;
    m_safetyDepth = m.safety_depth;
    m_textNames = m.text_names;
    m_showLightDescriptions = m.show_light_descriptions;
    m_textOther = m.text_other;
    m_boundaryStyle = (m.boundary_style == TILE57_BOUNDARY_PLAIN) ? BoundaryStyle::Plain
                                                                  : BoundaryStyle::Symbolized;
    m_simplifiedPoints = m.simplified_points;
    m_showFullSectorLines = m.show_full_sector_lines;
    m_showIsolatedDangersShallow = m.show_isolated_dangers_shallow;
    m_dataQuality = m.data_quality;
    m_showOverscale = m.show_overscale;
    m_showMetaBounds = m.show_meta_bounds;
    m_showInformCallouts = m.show_inform_callouts;
    m_highlightDateDependent = m.highlight_date_dependent;
    m_dateDependent = m.date_dependent;
    m_ignoreScamin = m.ignore_scamin;
    // size_scale is NOT taken from the core: it is the panel's density, not the
    // mariner's preference, and this shell's default already accounts for the
    // rM2's ~226 dpi. A zeroed field would also read as "no scale" and shrink
    // every symbol to half its readable size here.
    emit changed();
}

// S-52 viewing-group ids per declutter toggle (from the S-101 portrayal
// catalogue): each group is suppressed while its toggle is OFF.
QList<qint32> MarinerSettings::hiddenViewingGroups() const {
    QList<qint32> off;
    if (!m_showCautionAreas)
        off << 26150 << 25010; // CautionArea, PrecautionaryArea
    if (!m_showAnchorages)
        off << 26220; // AnchorageArea, AnchorBerth
    if (!m_showRestrictedAreas)
        off << 26010 << 26040; // RestrictedArea, MilitaryPracticeArea
    if (!m_showCablesPipelines)
        off << 12210 << 24010 << 34030 << 34070; // cables & pipelines
    if (!m_showMarineFarms)
        off << 26210; // MarineFarmCulture
    return off;
}

tile57_mariner MarinerSettings::toStruct() const {
    tile57_mariner m{};
    tile57_mariner_defaults(&m);

    switch (m_scheme) {
    case Scheme::Day:   m.scheme = TILE57_SCHEME_DAY; break;
    case Scheme::Dusk:  m.scheme = TILE57_SCHEME_DUSK; break;
    case Scheme::Night: m.scheme = TILE57_SCHEME_NIGHT; break;
    }

    // Display category is cumulative: Base is always on.
    m.display_base = true;
    m.display_standard = (m_detailLevel != DetailLevel::Base);
    m.display_other = (m_detailLevel == DetailLevel::Other);
    m.soundings = m_soundings == Soundings::Always  ? 1
                : m_soundings == Soundings::Never   ? 2
                                                    : 0;

    m.depth_unit = (m_depthUnit == DepthUnit::Feet) ? TILE57_DEPTH_FEET : TILE57_DEPTH_METERS;
    m.four_shade_water = m_fourShadeWater;
    m.shallow_contour = m_shallowContour;
    m.safety_contour = m_safetyContour;
    m.deep_contour = m_deepContour;
    m.safety_depth = m_safetyDepth;

    m.text_names = m_textNames;
    m.show_light_descriptions = m_showLightDescriptions;
    m.text_other = m_textOther;
    m.boundary_style = (m_boundaryStyle == BoundaryStyle::Plain) ? TILE57_BOUNDARY_PLAIN
                                                                 : TILE57_BOUNDARY_SYMBOLIZED;
    m.simplified_points = m_simplifiedPoints;
    m.show_full_sector_lines = m_showFullSectorLines;
    m.size_scale = m_sizeScale;

    m.show_isolated_dangers_shallow = m_showIsolatedDangersShallow;
    m.data_quality = m_dataQuality;
    m.show_overscale = m_showOverscale;
    m.show_meta_bounds = m_showMetaBounds;
    m.show_inform_callouts = m_showInformCallouts;
    m.highlight_date_dependent = m_highlightDateDependent;
    m.date_dependent = m_dateDependent;
    m.ignore_scamin = m_ignoreScamin;

    // Filled by lookout::Chart::setMariner, which owns the list's lifetime.
    m.viewing_groups_off = nullptr;
    m.viewing_groups_off_len = 0;
    return m;
}
