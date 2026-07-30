---
id: roadmap
title: Roadmap
sidebar_position: 4
---

# Roadmap

The app draws charts. It does not yet know where the boat is. Below is the rest
of what a chartplotter has to do, grouped into releases. The order is by
dependency: each release needs the one above it.

No release here has a date.

## 0.1 — Chart

Shipped. S-57 cells, S-101 portrayal, a composed library, mariner settings, and
a native shell on macOS, iPadOS, iOS, Windows, Linux and Android.

## 0.2 — Own ship

The boat on the chart, and the numbers that come with it.

- **Position input.** CoreLocation on Apple platforms, the Android location
  service, and NMEA 0183 over serial, USB, TCP and UDP.
- **NMEA 0183 parser** in the core: RMC, GGA, VTG, GLL, HDT, HDG, HDM, DBT, DPT,
  VHW, MTW, MWV, MWD, ZDA.
- **Own-ship symbol** with a heading line and a course-and-speed vector whose
  length is a time you choose.
- **Follow modes**: centre on ship, and course-up.
- **Instruments**: SOG, COG, HDG, depth, wind and water temperature, as a split
  view beside the chart and as a strip on a phone. Each value states when it
  goes stale.

## 0.3 — Traffic

Other vessels, and the warnings that matter.

- **AIS** from the same NMEA stream: VDM and VDO.
- **Targets** drawn with the S-52 symbols, class A and class B, with heading,
  course vector, and the moored and lost states.
- **CPA and TCPA** against own ship.
- **Target list**, sorted by range or by closest approach.
- **Guard zone** with an alarm.

## 0.4 — Voyage

Where you have been, and where you are going.

- **Track** recording, drawing and GPX export.
- **Waypoints and routes** on the chart, with GPX import and export.
- **Active route**: bearing and range to the next mark, and cross-track error.
- **Alarms**: anchor watch, depth, cross-track error and arrival, in one place,
  with a state that survives a restart.
- **Man overboard**: one control drops a mark and starts a bearing and range to
  it.

## 0.5 — Working tools

- **Electronic bearing line** and **variable range marker**.
- **Tides and currents** from the harmonic stations in the cell.
- **Signal K** as one network source for the boat.

## Not scheduled

- **S-63** encrypted commercial cells.
- **S-101 native cells.** The engine portrays S-101 already; this is the reader
  for the format as hydrographic offices publish it.
- **Radar overlay**, where a platform gives a usable feed.
- **Weather (GRIB)**.

## What the core needs first

The chart scene is built one time and drawn with a uniform update per frame.
That is why the app holds 60 fps, and it is also why own ship, AIS targets and
tracks cannot live in that scene: they move every second, and a rebuild is far
too expensive.

They need a second, small draw pass above the chart scene, with a vertex buffer
the host updates per frame. The C ABI grows a few calls: set the own-ship state,
give it a list of targets, append to a track. The work sits in the core, so
every shell gets it at once and each shell only decides how it looks.

The NMEA parser belongs in the core for the same reason. The transports do not:
a serial port on Linux, a Bluetooth link on iOS and a TCP socket on Android have
nothing in common, so each shell opens its own and feeds sentences in.
