# SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.21)

project(lookout-marine-remarkable
    VERSION 0.1.0
    DESCRIPTION "Nautical charts on the reMarkable, over the lookout chart core"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# ---------------------------------------------------------------------------
# The chart core. This shell links liblookout_marine.a and reaches the engine
# ONLY through include/lookout.h, like every other shell in this repo — it never
# links or includes tile57 directly. libtile57.a comes along because the core's
# archive references it (an ELF linker will not unpack a nested archive), and
# tile57.h because lookout.h includes it for tile57_mariner and the callbacks.
#
# Build them first, from the repo root, with NO GPU backend:
#
#   zig build lib -Dbackend=none                                  # host
#   zig build lib -Dbackend=none \
#       -Dtarget=arm-linux-gnueabihf.2.31 -Dcpu=cortex_a7 \
#       -p zig-out-rm2                                            # the rM2
#
# LOOKOUT_ROOT points at the install prefix holding include/ and lib/.
# ---------------------------------------------------------------------------
set(LOOKOUT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../zig-out" CACHE PATH
    "Install prefix of the chart core (contains include/lookout.h and lib/liblookout_marine.a)")

get_filename_component(LOOKOUT_ROOT "${LOOKOUT_ROOT}" ABSOLUTE)

# NO_CMAKE_FIND_ROOT_PATH so a cross build still looks outside the target sysroot.
find_path(LOOKOUT_INCLUDE_DIR lookout.h
    HINTS "${LOOKOUT_ROOT}/include" "${LOOKOUT_ROOT}"
    NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)

find_library(LOOKOUT_LIBRARY
    NAMES lookout_marine liblookout_marine
    HINTS "${LOOKOUT_ROOT}/lib" "${LOOKOUT_ROOT}"
    NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)

find_library(TILE57_LIBRARY
    NAMES tile57 libtile57
    HINTS "${LOOKOUT_ROOT}/lib" "${LOOKOUT_ROOT}"
    NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)

if(NOT LOOKOUT_INCLUDE_DIR OR NOT LOOKOUT_LIBRARY OR NOT TILE57_LIBRARY)
    message(FATAL_ERROR
        "Could not find the chart core. Build it first:\n"
        "  (cd ${CMAKE_CURRENT_SOURCE_DIR}/.. && zig build lib -Dbackend=none)\n"
        "or set -DLOOKOUT_ROOT=/path/to/prefix.\n"
        "  include: ${LOOKOUT_INCLUDE_DIR}\n"
        "  core:    ${LOOKOUT_LIBRARY}\n"
        "  engine:  ${TILE57_LIBRARY}")
endif()

message(STATUS "lookout include: ${LOOKOUT_INCLUDE_DIR}")
message(STATUS "lookout core:    ${LOOKOUT_LIBRARY}")
message(STATUS "tile57 engine:   ${TILE57_LIBRARY}")

add_library(lookout::core STATIC IMPORTED)
set_target_properties(lookout::core PROPERTIES
    IMPORTED_LOCATION "${LOOKOUT_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${LOOKOUT_INCLUDE_DIR}")

add_library(lookout::tile57 STATIC IMPORTED)
set_target_properties(lookout::tile57 PROPERTIES
    IMPORTED_LOCATION "${TILE57_LIBRARY}")

# ---------------------------------------------------------------------------
# Qt 6 (Quick UI for the e-ink chrome).
# ---------------------------------------------------------------------------
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick QuickControls2)

# 6.4 is Debian bookworm's Qt6 (the containerised cross build); a newer host Qt
# satisfies this too.
qt_standard_project_setup(REQUIRES 6.4)

qt_add_executable(lookout-marine
    src/main.cpp
)

# So moc's generated QML type-registration TU can resolve <chartview.h> etc.
target_include_directories(lookout-marine PRIVATE src)

qt_add_qml_module(lookout-marine
    URI LookoutMarine
    VERSION 1.0
    # Relocate the module's build dir out from beside the executable: by default
    # it is <build>/LookoutMarine, which collides with the <build>/lookout-marine
    # executable on a case-insensitive filesystem (macOS APFS, or a macOS Docker
    # bind mount) — the linker then finds a directory where it wants to write the
    # binary. Build-time files only.
    OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/qml_module/LookoutMarine
    # Pin the resource prefix so the module lands under :/qt/qml and Main's qrc
    # URL is stable, whatever the Qt policy default would pick.
    RESOURCE_PREFIX "/qt/qml"
    SOURCES
        src/coordformat.h
        src/formats.h
        src/s57.h              src/s57.cpp
        src/lookoutchart.h     src/lookoutchart.cpp
        src/marinersettings.h  src/marinersettings.cpp
        src/renderworker.h     src/renderworker.cpp
        src/chartview.h        src/chartview.cpp
        src/mercator.h
    QML_FILES
        qml/Main.qml
        qml/ChartPicker.qml
        qml/SettingsPanel.qml
        qml/PickReport.qml
        qml/AuxFile.qml
        qml/PictureViewer.qml
        qml/ScaleEntry.qml
        qml/ReadoutsCapsule.qml
        qml/ScaleBar.qml
        qml/ChromeBubble.qml
        qml/FlatButton.qml
        qml/GlyphIcon.qml
        qml/Panel.qml
        qml/SectionHeader.qml
        qml/ToggleRow.qml
        qml/SegmentedRow.qml
        qml/NumberRow.qml
    RESOURCES
        qml/Theme.qml
)

# Theme.qml is a QML singleton.
set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_target_qml_sources(lookout-marine QML_FILES qml/Theme.qml)

target_link_libraries(lookout-marine PRIVATE
    Qt6::Core Qt6::Gui Qt6::Quick Qt6::QuickControls2
    lookout::core lookout::tile57)

# Ship the monochrome "ink" S-52 colour profile beside the binary; main.cpp
# points TILE57_COLORPROFILE at it (through applicationDirPath) so the engine
# recolours the chart for e-ink. Copied every build, so profile edits take.
add_custom_command(TARGET lookout-marine POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_SOURCE_DIR}/assets/colorProfile.ink.xml
        $<TARGET_FILE_DIR:lookout-marine>/colorProfile.ink.xml
    VERBATIM)

# The core and the engine bundle Lua and the portrayal catalogue; they still need
# the C runtime and maths, and on Linux Zig's panic/backtrace path pulls in the
# unwinder.
if(UNIX AND NOT APPLE)
    target_link_libraries(lookout-marine PRIVATE m dl pthread)
    # Export symbols so the crash handler's backtrace can name our own frames.
    target_link_options(lookout-marine PRIVATE -rdynamic)
endif()
