---
id: roadmap
title: Roadmap
sidebar_position: 4
---

# Roadmap

Today the app draws charts. It does not know where the boat is. Everything below
is the rest of what a chartplotter has to do, in the order it is worth building.

Nothing here is a promise of a date.

## Now

The chart itself: S-57 cells, S-101 portrayal, a composed library, mariner
settings, and one native shell per platform.

## Next: where the boat is

**Own ship.** A position from the platform, drawn as the S-52 own-ship symbol,
with a heading line and a course-and-speed vector whose length is a time you
choose. Centre-on-ship, and a course-up mode that turns the chart instead of the
symbol.

**Position sources.**

- CoreLocation on macOS, iPadOS and iOS. The Android location service.
- NMEA 0183 over a serial port, USB, TCP or UDP.

**NMEA 0183 input.** One parser in the core, and a per-platform transport.
The sentences that matter first:

| Sentence | What it carries |
|---|---|
| RMC | Position, speed and course over ground, time |
| GGA | Position, fix quality, satellites |
| VTG | Course and speed over ground |
| HDT, HDG, HDM | Heading |
| DBT, DPT | Depth |
| MWV, MWD | Wind |
| VHW | Speed through the water |
| MTW | Water temperature |
| ZDA | Time and date |

**Instruments.** The values a mariner reads at a glance: SOG, COG, HDG, depth,
wind, water temperature. As a split view beside the chart on a wide screen, and
as a strip on a phone. Each panel states when its data is stale, because a
number that stopped updating is worse than no number.

## Then: traffic

**AIS.** Decode VDM and VDO from the same NMEA stream. Draw class A and class B
targets with the S-52 symbols, with heading, course vector, and the moored and
lost states. A target list sorted by range or by closest approach.

**CPA and TCPA.** Compute both against own ship, and raise a guard when a target
comes inside the limits you set.

## Then: the voyage

**Track.** Record where the boat has been, draw it, and export it as GPX.

**Waypoints and routes.** Make them on the chart, import and export GPX, and
activate a route: bearing and range to the next mark, and cross-track error.

**Alarms.** Anchor watch, depth, cross-track error, arrival, and the AIS guard
above. One place to see them, and a state that survives a restart.

**Man overboard.** One control that drops a mark and starts a bearing and range
to it.

## Later

- **Measurement.** Electronic bearing line and variable range marker.
- **Tides and currents.** Harmonic predictions at the stations in the cell.
- **S-63.** Encrypted commercial cells, so the app can open the charts a
  commercial vessel already holds.
- **S-101 native cells.** The engine portrays S-101 already; this is the reader
  for the new format as hydrographic offices publish it.
- **Signal K.** One network source for the boat instead of many NMEA links.
- **Radar overlay.** Only where a platform gives a usable feed.

## What has to change inside

The chart scene is built one time and drawn with a uniform update per frame.
That is why the app holds 60 fps, and it is also why own ship, AIS targets and
tracks cannot be part of it: they move every second, and a rebuild is far too
expensive for that.

They need a second, small draw pass above the chart scene, with its own vertex
buffer that the host updates per frame. The C ABI grows a few calls to set the
own-ship state, to give it a list of targets, and to append to a track. The
work is in the core, so every shell gets it at the same time, and each shell
only decides how it looks.

The NMEA parser belongs in the core for the same reason. The transports do not:
a serial port on Linux, a Bluetooth link on iOS and a TCP socket on Android have
nothing in common, so each shell opens its own and feeds sentences in.
