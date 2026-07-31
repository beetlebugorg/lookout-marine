# SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
# SPDX-License-Identifier: MIT
#
# CMake toolchain for cross-compiling the reMarkable shell WITHOUT the SDK's own
# OE toolchain file. docker/sdk-build.sh prefers OEToolchainConfig.cmake when the
# SDK ships one and falls back to this.
#
# It needs, for the target device:
#   * a cross C/C++ compiler       (the reMarkable SDK, or the toltec toolchain)
#   * a sysroot containing Qt 6    (matching the version on the device)
#   * a HOST Qt 6 of the SAME version (for moc, rcc and qmltyperegistrar)
#
# Point it at those on the cmake command line:
#
#   cmake -S . -B build-rm2 \
#     -DCMAKE_TOOLCHAIN_FILE=cmake/remarkable.toolchain.cmake \
#     -DREMARKABLE_SYSROOT=/opt/rm-sdk/sysroots/cortexa7... \
#     -DREMARKABLE_TOOLCHAIN=/opt/rm-sdk/sysroots/x86_64.../usr/bin/arm-remarkable-linux-gnueabi \
#     -DQT_HOST_PATH=/usr/lib/qt6 \
#     -DLOOKOUT_ROOT=/path/to/zig-out-rm2
#
# The CHART CORE is not built here. Cross-compile it first with Zig, which needs
# no toolchain of its own:
#
#   zig build lib -Dbackend=none -Dtarget=arm-linux-gnueabihf.2.31 \
#       -Dcpu=cortex_a7 -p zig-out-rm2
#
# reMarkable 2 / 1 -> REMARKABLE_DEVICE=rm2 (armv7l, arm-linux-gnueabihf).

set(CMAKE_SYSTEM_NAME Linux)

if(NOT DEFINED REMARKABLE_DEVICE)
    set(REMARKABLE_DEVICE "rm2")
endif()

set(CMAKE_SYSTEM_PROCESSOR arm)
set(_cc_suffix "arm-remarkable-linux-gnueabi-gcc")
set(_cxx_suffix "arm-remarkable-linux-gnueabi-g++")

# The cross compilers. REMARKABLE_TOOLCHAIN may be a directory of tools or the
# tool prefix itself; adjust the names to whatever your SDK ships.
if(DEFINED REMARKABLE_TOOLCHAIN)
    if(IS_DIRECTORY "${REMARKABLE_TOOLCHAIN}")
        set(CMAKE_C_COMPILER   "${REMARKABLE_TOOLCHAIN}/${_cc_suffix}")
        set(CMAKE_CXX_COMPILER "${REMARKABLE_TOOLCHAIN}/${_cxx_suffix}")
    else()
        set(CMAKE_C_COMPILER   "${REMARKABLE_TOOLCHAIN}-gcc")
        set(CMAKE_CXX_COMPILER "${REMARKABLE_TOOLCHAIN}-g++")
    endif()
endif()

if(DEFINED REMARKABLE_SYSROOT)
    set(CMAKE_SYSROOT "${REMARKABLE_SYSROOT}")
    set(CMAKE_FIND_ROOT_PATH "${REMARKABLE_SYSROOT}")
endif()

# Libraries and headers come from the target sysroot; tools run on the host.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# The Zig target triple that pairs with this build, for the core.
set(LOOKOUT_ZIG_TARGET "arm-linux-gnueabihf.2.31" CACHE STRING "Zig target for the chart core")
set(LOOKOUT_ZIG_CPU "cortex_a7" CACHE STRING "Zig CPU for the chart core")
