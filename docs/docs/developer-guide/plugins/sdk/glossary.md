---
id: glossary
title: Capabilities and store data
---

# Capabilities and store data

Everything your manifest can ask for, and everything the store holds for
your plugin to read.

## The capabilities

A capability is a permission. Your manifest asks for the ones your plugin
uses, the mariner grants them at install, and Lookout checks them on every
call. If your plugin calls something its manifest did not ask for, the call
does nothing and returns -1, and Lookout counts it as a denied call on your
plugin's status. The dev harness prints that count at the end of every run.

| Capability | What it unlocks |
|---|---|
| `vessel.read` | declared inputs: `subscribeNumber`, `subscribePosition` |
| `ais.read` | the AIS target set: `subscribeAis` |
| `vessel.publish` | `lk.Publish`: writing readings into the store |
| `ais.publish` | `lk.Upsert`: writing AIS targets into the store |
| `overlay.draw` | your `draw` function and the chart scene |
| `alerts.raise` | `lk.alert`: alarms the mariner sees and hears |
| `net.tcp-client` | connection lists dialling TCP, and `lk.raw.tcpConnect` |
| `net.ws` | websocket connections. Named hosts only |
| `net.http` | `lk.raw.httpGet` and `httpFetch`. Named hosts only |
| `net.udp` | `lk.raw.udpOpen`, `udpSend`, `udpClose` |
| `storage` | `lk.raw.storageGet` and `storagePut`: the plugin's own JSON |
| `files` | files the mariner hands over, and the manifest's `file_types` |

`net.http` and `net.ws` never appear as bare names. Each carries the list of
hosts it covers, because "may reach any server" is not a sentence a mariner
can consent to:

```json
"capabilities": ["vessel.read", {"net.http": ["nomads.ncep.noaa.gov"]}]
```

You never request a capability for logging, the two clocks, timers or the
status line; every plugin has them.

Reference: [the manifest](../wire.md#the-manifest) has the exact rules and
every refusal.

## What is in the store, by plugin

The store takes any path a plugin publishes. These are the paths the shipped
plugins fill, which is what your inputs can count on when a boat's
instruments are connected.

**From `nmea0183`**, one path per sentence field it trusts:

| Path | From sentences |
|---|---|
| `navigation.position` | RMC, GGA |
| `navigation.speedOverGround` | RMC, VTG |
| `navigation.courseOverGroundTrue` | RMC, VTG |
| `navigation.headingTrue` | HDT, HDG, VHW |
| `environment.depth.belowTransducer` | DPT, DBT |
| `environment.wind.speedApparent`, `environment.wind.angleApparent` | MWV (apparent) |
| `environment.wind.directionTrue` | MWD |
| `navigation.attitude.roll`, `navigation.attitude.pitch` | XDR, the `HEEL` and `TRIM` transducers |
| `steering.rudderAngle` | XDR, the `RUDDER` transducer |
| `environment.water.temperature` | MTW |
| `navigation.log`, `navigation.trip.log` | VLW |

An XDR carries a list of transducers a boat's own instruments name, so a
reading is found by its name and never by its place in the list. A boat
whose instruments call heel something else publishes nothing for it.

**From `signalk`**, the first eight of those paths, read from a Signal K
server's deltas and converted to the store's units (Signal K carries radians;
the store carries degrees).

**The AIS target set**, from both: `nmea0183` assembles AIVDM broadcasts and
`signalk` reads vessel contexts. Position reports, static names, and type 21
aids to navigation including virtual ones. Read it with `subscribeAis`, not
a path.

A sentence with an empty field publishes nothing for it, so an absent reading
ages out instead of arriving as a guess. Two plugins publishing the same path
coexist; the store elects one source and falls back to the other when it goes
quiet.

Anything beyond these paths is yours to define: publish
`environment.inside.temperature` from your plugin and any other plugin can
subscribe to it by that name.
