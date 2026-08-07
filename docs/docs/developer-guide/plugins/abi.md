---
id: abi
title: The ABI
sidebar_position: 3
---

# The ABI

This is the reference. The contract is in the code: `plugins/common/lk.zig` is
the plugin side, `src/plugin/broker.zig` implements every import, and
`src/plugin/host.zig` parses every manifest. Where this page and the code
disagree, the code is right.

A plugin is a **wasm32-freestanding** module. No WASI, no filesystem, no clock
but the two the host lends you, no threads. Everything crossing the boundary is
an integer or a `(pointer, length)` byte range in the module's own linear memory,
always copied — never a pointer into host memory. Text is UTF-8 and control
payloads are JSON.

The ABI version is **1**, and it is unstable. See
[the stability statement](index.md#the-abi-is-v0-and-unstable).

## The five exports

Every plugin provides exactly these. `lk.registerPlugin` writes all five for you.

| Export | Signature | Meaning |
|---|---|---|
| `lk_abi` | `() -> u32` | The ABI version this module speaks. Must return 1. |
| `lk_alloc` | `(len: u32) -> ptr` | Give the host `len` bytes to write an inbound payload into. **Returning 0 means out of memory**, and the host treats the call as a fault. |
| `lk_free` | `(ptr, len: u32)` | The host is done with that buffer. |
| `lk_start` | `(ptr, len: u32) -> i32` | Begin. The payload is `{"abi":1,"config":{…}}`. Non-zero refuses the start, and the plugin is not loaded. |
| `lk_event` | `(kind: u32, handle: u64, ptr, len: u32) -> i32` | Everything that happens. `handle` correlates: which timer, which socket. Non-zero is logged as a complaint and the plugin keeps running. |

The host checks `lk_abi` at load and refuses a mismatch, because the same five
names could mean something else in another version.

## Event kinds

One entry point, one enum, delivered one at a time per plugin from that plugin's
own FIFO. **An unknown kind must be ignored and answered 0** — that tolerance is
what lets the host add an event without breaking a module built today.

| # | Kind | `handle` | Payload |
|---|---|---|---|
| 1 | `CONFIG_CHANGED` | 0 | The plugin's whole settings object, `{"cpa_limit":926,"cpa_alarm":true}`. Every field the schema declares is present, so a handler never merges. |
| 3 | `TIMER` | The timer id `timer_set` returned | empty |
| 4 | `TCP_CONNECTED` | The connection id | empty |
| 5 | `TCP_DATA` | The connection id | Raw bytes, one event per socket read, at most 8192 bytes. Reassembling lines is yours. |
| 6 | `TCP_CLOSED` | The connection id | empty. Sent when the peer or an error ended it — not when you called `tcp_close`. |
| 10 | `STORE_CHANGED` | 0 | `{"values":[…]}`, subscribed paths only, coalesced to at most 10 Hz |
| 11 | `AIS_CHANGED` | 0 | `{"targets":[…]}`, the whole target set, at most 2 Hz and only when something moved |
| 99 | `SHUTDOWN` | 0 | empty. The last thing you are ever handed, whatever you return. |

Kind 2 is unassigned. `SHUTDOWN` ignores the queue cap: a plugin in trouble is
exactly the one that must hear it.

## The imports

Module name `lookout`. Every call is checked against the calling plugin's
manifest. A call the manifest did not ask for **returns -1 and logs**; it does
not trap.

| Import | Signature | Capability | Returns |
|---|---|---|---|
| `log` | `(level: u32, ptr, len)` | — | The host stamps the plugin id and the level: 0 debug, 1 info, 2 warn, 3 error. |
| `now_ms` | `() -> i64` | — | Wall clock, ms since the epoch. Stamp published values with this. |
| `mono_ms` | `() -> i64` | — | Monotonic ms. Measure intervals with this; it does not jump when a GPS fix sets the boat's clock. |
| `publish` | `(ptr, len) -> i32` | `vessel.publish` | Updates applied, or -1. A bad update inside a good batch is skipped and not counted. |
| `ais_upsert` | `(ptr, len) -> i32` | `ais.publish` | Targets applied, or -1. |
| `overlay` | `(ptr, len) -> i32` | `overlay.draw` | 0, or -1 when the batch was refused whole. |
| `chrome_status` | `(ptr, len)` | — | Nothing. The host keeps the latest line per plugin. |
| `alert` | `(ptr, len) -> i32` | `alerts.raise` | 0, or -1. |
| `tcp_connect` | `(host_ptr, host_len, port: u32) -> i64` | `net.tcp-client` | A connection id at once, or -1. The resolve and the connect happen on the host's I/O thread; the outcome arrives as `TCP_CONNECTED` or `TCP_CLOSED`. |
| `tcp_send` | `(id: i64, ptr, len) -> i32` | `net.tcp-client` | Bytes queued for writing, or -1 for an unknown connection or one belonging to another plugin. |
| `tcp_close` | `(id: i64)` | — | Nothing, and no `TCP_CLOSED`: you asked, so you know. It can only close your own connection. |
| `timer_set` | `(delay_ms: i64, periodic: u32) -> i64` | — | A timer id, or -1. A delay under 1 ms is raised to 1 ms. A periodic timer that fires late does not then fire a burst of catch-up ticks. |
| `timer_cancel` | `(id: i64)` | — | Nothing. Cancelling another plugin's timer does nothing. |
| `subscribe` | `(ptr, len) -> i32` | `vessel.read` | The number of paths, or -1. The payload is `["navigation.position",…]`. **One subscription per plugin**: calling again replaces the list. |
| `ais_subscribe` | `() -> i32` | `ais.read` | 0, or -1. The current target set arrives on the next fanout tick rather than when a target next moves. |

Timers, status lines, the log and the clocks need no capability. They are
baseline plumbing: a plugin that cannot say what it is doing is worse than one
that can.

### The capabilities

| Capability | What it grants |
|---|---|
| `vessel.publish` | `publish` — write vessel paths as a source in the store |
| `vessel.read` | `subscribe` — receive `STORE_CHANGED` for named paths |
| `ais.publish` | `ais_upsert` — write AIS targets |
| `ais.read` | `ais_subscribe` — receive `AIS_CHANGED` snapshots |
| `overlay.draw` | `overlay` — retained objects on the chart |
| `alerts.raise` | `alert` |
| `net.tcp-client` | `tcp_connect`, `tcp_send` |

An unknown capability name in a manifest refuses the whole plugin. A typo in a
grant is a permission silently lost at sea, so it is a load error instead.

There is no subtree restriction yet: `vessel.publish` grants every path, not
`navigation.*`. Per-argument checks of that kind are named in
`specs/plugins/implementation.md` and are not built.

## JSON shapes

### publish

```json
{"updates":[
  {"path":"navigation.position","value":{"lat":38.9763,"lon":-76.4767},"ts":1754400000123},
  {"path":"environment.depth.belowTransducer","value":2.9,"ts":1754400000123}]}
```

`ts` is wall-clock milliseconds; the host stamps arrival time if you leave it
out. A `value` is a number, a `{"lat":…,"lon":…}` object, or `null`. Strings and
booleans are refused rather than coerced, and the JSON text of one value is
capped at 512 bytes. `null` means "this source has the path and no value for it
right now".

**Every unit crossing this boundary is SI.** The instrument's unit is the
publishing plugin's problem: `nmea0183` converts knots to metres per second and
degrees stay degrees, so nothing downstream ever asks which unit it is holding.

| Path | Value | Unit |
|---|---|---|
| `navigation.position` | `{"lat":…,"lon":…}` | degrees, WGS84 |
| `navigation.headingTrue` | number | degrees true |
| `navigation.courseOverGroundTrue` | number | degrees true |
| `navigation.speedOverGround` | number | metres per second |
| `environment.depth.belowTransducer` | number | metres |
| `environment.wind.speedApparent` | number | metres per second |
| `environment.wind.angleApparent` | number | degrees, positive to starboard |
| `environment.wind.directionTrue` | number | degrees true, the direction the wind blows **from** |

The store itself takes any path string; that table is the prototype's vocabulary.
The core reads four of them directly — position, heading, course and speed drive
own ship's display position, follow mode and course-up — so a plugin that
publishes those under other names gets no boat.

Several plugins may publish the same path. The store elects one: the
first-registered source wins while its value is inside the staleness window, and
load order is sorted file order. If no source is fresh, the most recent stale
value is elected and flagged stale.

### ais_upsert

```json
{"targets":[{"mmsi":366123456,"lat":38.98,"lon":-76.47,"sog":5.1,"cog":210.0,
             "heading":211.0,"name":"EVER GIVEN","ts":1754400000123}]}
```

Only `mmsi` is required; the upsert merges each field it carries into the target
it names. `sog` is **metres per second**, not knots — the AIS wire format reports
knots and converting is the parsing plugin's job. An aid to navigation adds
`"aton":true` and may add `"aton_type"` (0..31), `"virtual":true` and
`"off_position"`. A target that has once reported as an aid stays one.

### STORE_CHANGED

```json
{"values":[{"path":"navigation.position","value":{"lat":38.9763,"lon":-76.4767},
            "ts":1754400000123,"age_ms":120},
           {"path":"environment.wind.directionTrue","value":null}]}
```

Only the paths you subscribed to, only when the elected reading changed, and at
most 10 Hz. `age_ms` is how old the value was **when the host wrote the payload**;
it is already stale when you read it, so age it on with `mono_ms` if you need it
later.

**A `null` value is a removal, not a null reading.** The path has no value from
any source any more, because a source was cleared or the plugin that owned it was
disabled. Stop drawing whatever it fed. There is no separate delete list, and a
removal carries no `ts` and no `age_ms`, because a timestamp on a value that does
not exist would be a lie.

### AIS_CHANGED

```json
{"targets":[{"mmsi":367123450,"lat":38.966,"lon":-76.434,"sog":4.1,"cog":300.0,
             "ts":1754400000123,"age_ms":540},
            {"mmsi":993672315,"lat":38.972,"lon":-76.466,"aton":true,
             "aton_type":25,"name":"CHANNEL BUOY 3","ts":1754400000000,"age_ms":663}]}
```

The **whole** target set, at most twice a second and only when something moved.
An unknown field is left out rather than sent as null: at sea "never heard" and
"heard as zero" are different facts. Targets are evicted from the store after
600 s, and an aid to navigation after 1800 s, because an aid transmits about
every three minutes.

### overlay

```json
{"del":["t366123456","t366123456/vec"],
 "set":[{"id":"ownship","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],
         "rot_deg":213.0,"scale":1.0,"color":"ownship","anchor":"ownship"},
        {"id":"hdg","kind":"polyline","pts":[[-76.47,38.97],[-76.46,38.98]],
         "width_pt":2.0,"dash":false,"color":"ownship"},
        {"id":"zone","kind":"polygon","ring":[[-76.48,38.97],[-76.47,38.97],[-76.47,38.98]],
         "alpha":0.25,"color":"warning"}]}
```

Objects are **retained**: post one once and it stays until you replace it or
delete it. A `set` replaces the whole object; there is no partial update. Ids are
namespaced by the host as `<plugin id>/<your id>`, so two plugins may both have an
`ownship`.

**Deletes are applied before sets**, whatever their order in the JSON, so one
batch can delete a stale object and set a new one with the same id.

| Field | Applies to | Rule |
|---|---|---|
| `id` | all | Required. Yours, inside your namespace. |
| `kind` | all | `symbol`, `polyline` or `polygon`. Required. |
| `color` | all | A token, never an RGB. Required. |
| `sym` | symbol | `ownship`, `target`, `aton` or `aton_virtual`. Required. |
| `at` | symbol | `[lon, lat]`. Required. |
| `rot_deg` | symbol | True bearing, clockwise from north. Default 0. |
| `scale` | symbol | Default 1. Outside 0.05..20 it is reset to 1. |
| `pts` | polyline | 2 to 8192 points of `[lon, lat]` |
| `ring` | polygon | 3 to 8192 points. Closed for you. |
| `width_pt` | polyline | Screen **points**, not metres — the core converts at the live zoom. Default 1.5; outside 0.1..64 it is reset. |
| `dash` | polyline | Default false |
| `alpha` | polygon | Multiplies the token's own alpha. Clamped to 0..1, default 1. |
| `anchor` | symbol, polyline | `"ownship"` and nothing else. See below. |
| `pick` | symbol | See below. |

A malformed object is skipped and the rest of the batch still applies — one bad
row must not drop the good ones. Malformed JSON, a top-level value that is not an
object, or going over the 4096-object budget fails the whole batch with -1.

Paint order is areas, then lines, then symbols: a track must not cover the boat.

**Colour tokens.** The core resolves a token to RGBA for the day, dusk and night
palettes, which is why an overlay never carries an RGB. Night values are held
under a luminance ceiling, and a test enforces it.

| Token | For |
|---|---|
| `ownship` | Own ship, its heading line and its course vector |
| `target` | An AIS target |
| `target_danger` | A target inside the collision gate |
| `track` | Where the boat has been |
| `layline_port` | The port-tack layline |
| `layline_stbd` | The starboard-tack layline |
| `warning` | Anything that wants attention: an off-position aid, a hazard area |

**`"anchor":"ownship"`.** Fixes arrive about once a second, and a symbol drawn at
the last fix steps across the screen. An object with this anchor rides own ship's
**display** position, which the core carries forward between fixes and
substitutes every frame; a polyline keeps its shape and travels with its first
point. The lon/lat you post is still the fix, and it is what draws if the core
has no carried position. Dead reckoning stops at the 5 s staleness window.

**Pick payloads.** A symbol may carry what a hover or a tap reports:

```json
"pick":{"title":"EVER GIVEN","rows":[["MMSI","366123456"],["SOG","9.9 kn"],["CPA","149 m in 591 s"]]}
```

Both parts are optional and a payload with neither is dropped. The core
validates, escapes and caps the text at 16 rows of 96 bytes; a row that is not
two strings is dropped and the symbol still draws. **Values are strings, already
formatted for display** — the core cannot know that a row called SOG holds metres
per second. That breaks the SI rule on purpose and is the one place it is broken;
the fix is a typed payload and it is not built. Lines and areas carry no payload:
they have no single point to measure a hit to. A shell reads the payload back
with `lookout_overlay_at`, which answers with the nearest symbol whose **anchor**
is within about 14 pt of a logical point.

### chrome_status

```json
{"state":"running","detail":"42 msg/s"}
```

One line, kept per plugin, truncated at 160 bytes. The host logs it at info only
when the text changes, so posting the same status at 1 Hz is free. `state` and
`detail` are free strings; the first-party plugins use `starting`, `running`,
`degraded` and `stopped`, which is a convention, not a rule. The host writes
`{"state":"disabled","detail":"<reason>"}` itself when it takes a plugin out of
service.

The status line reaches a shell through `lookout_plugins_json`. There is no other
chrome: no jobs, no tables, no alarm surface, and no status **items** for the rows
of a repeating setting. All of that is in `specs/plugins/chrome.md` and none of it
is built.

### alert

```json
{"severity":"alarm","title":"AIS CPA alarm","body":"367123450: CPA 149 m in 591 s"}
```

The prototype has no alarm surface, so **an alert is its log line**, and the
severity picks the level so the line carries the difference between "you may want
to know" and "act now".

| Severity | Log level |
|---|---|
| `alarm` | error |
| `warning` | warn |
| `caution`, `notice` | info |
| anything else, or no severity at all | error |

An unreadable severity is not a reason to be quiet. The host also keeps the last
alert per plugin, up to 400 bytes.

## The manifest

`<id>.manifest.json`, beside `<id>.wasm`.

```json
{
  "id": "org.beetlebug.ais",
  "name": "AIS targets",
  "abi": 1,
  "capabilities": ["ais.read", "vessel.read", "overlay.draw", "alerts.raise"],
  "settings": {
    "groups": [
      {
        "label": "Collision alarm",
        "tab": "alarms",
        "fields": [
          {"key": "cpa_limit", "label": "Closest approach (CPA)",
           "desc": "Alarm when a vessel will pass closer than this.",
           "kind": "number", "unit": "m", "min": 93, "max": 9260, "default": 926},
          {"key": "cpa_alarm", "label": "Collision alarm",
           "desc": "Sound the alarm and colour the vessel red. Off silences both.",
           "kind": "toggle", "default": true}
        ]
      }
    ]
  }
}
```

| Key | Required | Rule |
|---|---|---|
| `id` | yes | 1 to 128 bytes. The overlay namespace, the settings key, and the name a shell uses. Reverse-DNS by convention. |
| `name` | no | What a shell would show. Defaults to the id. |
| `abi` | yes | Must be 1. |
| `capabilities` | no | An array of the names above. Absent grants nothing. An unknown name refuses the manifest. |
| `settings` | no | A v1 array of fields, or a v2 object of groups. At most 16 fields in total. |

There is no `limits` block. Memory, time and queue budgets are the host's, they
are the same for every plugin, and a manifest cannot ask for more:

| Limit | Value |
|---|---|
| Linear memory | 16 MiB (256 wasm pages). A module whose declared minimum memory is over the cap fails at load. |
| Interpreter stack | 64 KiB |
| One module call | 1000 ms, then the watchdog terminates the instance |
| Event queue | 1024 events per plugin; socket reads pause at 768 |
| Module file | 8 MiB; manifest file 64 KiB |

### Settings schema v2

A field is one control in the mariner's settings window. The plugin receives the
values and nothing else — it cannot read its own manifest at run time, so a plugin
that clamps repeats the ranges in its own source, and a test compares the two.

```json
"settings": {"groups": [
  {"label": "Collision alarm", "tab": "alarms", "fields": [ … ]},
  {"label": "AIS targets",     "tab": "vessels", "fields": [ … ]}]}
```

A **group** is one heading in the settings window. A **tab** is where that
heading goes. One plugin's groups may go to different tabs, and the `ais` plugin
does: the alarm limits to Alarms, the presentation to Vessels.

| Group key | Rule |
|---|---|
| `label` | The section heading. Absent gives no heading. |
| `tab` | One of `display`, `depths`, `text`, `charts`, `vessels`, `alarms`, `connections`, `advanced`. Unknown or absent falls back to `advanced`. **A manifest can never make a tab of its own.** |
| `fields` | The controls, in the order they are drawn |

A field:

| Field key | Applies to | Rule |
|---|---|---|
| `key` | all | Required, 1 to 32 bytes, unique across the whole schema. The key in the config object. |
| `kind` | all | `number` or `toggle`. |
| `label` | all | What the shell shows beside the control. Defaults to the key. |
| `desc` | all | One sentence, in plain language, about what the setting does for the person at the helm. Shown under the control. Absent shows none. |
| `unit` | number | Display only. The value crosses the ABI in the unit the schema names. |
| `min`, `max` | number | Both required, and `max` must be greater than `min`. |
| `default` | number | Required. Clamped into the range rather than refused. |
| `default` | toggle | Required, and must be a JSON boolean. A toggle whose default is a number refuses the manifest. |

Schema v1 — `"settings"` as a bare array of fields — still parses. Those fields
carry no group and land on `advanced`.

**The plugin always receives the whole settings object**, in `lk_start`'s config
and again on every `CONFIG_CHANGED`, so a handler never merges. A value outside
its range is clamped on the way in, so a plugin never defends against a setting
it did not publish. A key the schema does not declare is ignored.

There is no choice field, no text field, no colour, and no repeating list of rows
— a plugin that wants a table of NMEA gateways cannot ask for one yet. Nothing
validates one field against another.

## What a shell sees

The plugin layer reaches an app through four calls in `include/lookout.h`. A
plugin author does not call them, but they are how a setting gets from a window
to `CONFIG_CHANGED`.

```c
int  lookout_plugins_load(lookout *h, const char *dir);
int  lookout_plugins_active(lookout *h);
const char *lookout_plugins_json(lookout *h, size_t *out_len);
const char *lookout_plugin_config_get(lookout *h, const char *id, size_t *out_len);
int  lookout_plugin_config_set(lookout *h, const char *id, const char *json);
```

`lookout_plugins_json` is the registry: every loaded plugin with its id, name,
whether it is live, its status line, and each settings field with its label,
description, unit, range, group, tab, default and the value in force. A shell
draws a control per field and needs to know nothing about what any plugin does.

```json
{"plugins":[{"id":"org.beetlebug.ais","name":"AIS targets","live":true,
             "status":"{\"state\":\"running\",\"detail\":\"5 targets\"}",
             "settings":[{"key":"cpa_limit","label":"Closest approach (CPA)",
                          "desc":"Alarm when a vessel will pass closer than this.",
                          "kind":"number","unit":"m","group":"Collision alarm",
                          "tab":"alarms","min":93,"max":9260,"default":926,"value":926}]}]}
```

`lookout_plugins_active` exists for a render-on-demand shell: while it returns 1,
poll `lookout_needs_redraw` a few times a second instead of sleeping until the
mariner touches something, or plugin traffic freezes on screen.
