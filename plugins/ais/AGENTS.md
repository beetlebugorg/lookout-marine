# The AIS plugin

Decodes AIVDM into the target store, draws traffic, and solves CPA and TCPA
against own ship. The collision alarm is the app's headline safety feature, so
the rules below are not style preferences.

## What must stay true

- **A target is drawn where it reported, never where it probably is.** AIS
  arrives every few seconds and the symbol steps between reports. Carrying it
  forward on its course would look smoother and would put a vessel on the chart
  where nothing is, which a mariner cannot tell from an observation. The
  stepping is honest. The same goes for deciding: a CPA, a gate and an alarm
  are answered from what was actually reported, never from an estimate.

- **The alarm is decided when a report arrives, not while drawing.** `evaluate()`
  holds the gate, the edge trigger and the per-target state, and runs from
  `onUpdate`. `draw` looks the ruling up and renders it. A drawing rate must
  never be able to make a collision alarm sluggish.
- **One approach is one alarm.** The gate is edge triggered, so a target
  crossing into danger alarms once and not on every report while it stays
  there. The day run asserts exactly one alarm on MMSI 899000101; if that
  becomes two, the latch broke.
