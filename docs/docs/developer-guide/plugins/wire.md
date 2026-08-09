---
id: wire
title: The wire protocol
sidebar_position: 4
---

# The wire protocol

This is the reference: every event your module can be handed, every call it
can make, and the format of every payload in between.

The boundary is deliberately narrow. Everything crossing it is either an integer
or a `(pointer, length)` byte range in your module's own linear memory, and it is
always copied. You are never handed a pointer into the host's memory. Text is
UTF-8, and anything structured is JSON.

Your module is `wasm32-freestanding` (Zig) or `wasm32-wasip1` (Go, Rust). Either
loads. The WASI a wasip1 module gets is a floor for its language runtime and
nothing more: [the WASI floor](#the-wasi-floor) below says exactly what works and
what does not.

Three files in Lookout are the real contract. Where this page disagrees with
them, they are right: `plugins/common/lk.zig` is the raw plugin side under
the SDK, `src/plugin/broker.zig`
implements every import, and `src/plugin/host.zig` parses every manifest. The Go
and Rust libraries in `sdk/` mirror `lk.zig`; `src/plugin/wasm.zig` bounds WASI.

The wire protocol version is **1**, and it is unstable:
[what that means for you](index.md#the-abi-is-version-0-and-unstable). The last
section is the raw module contract, for writing a library in another language.

## Event kinds

Everything that happens to your plugin arrives here. The host delivers one event
at a time, from that plugin's own FIFO, into the one handler you write. In Zig
that handler is `onEvent`, and each kind below is one branch of it. **Your
handler must ignore a kind it does not know and answer 0**; that tolerance is
what lets the host add an event without breaking a module built today.

| # | Kind | `handle` | Payload |
|---|---|---|---|
| 1 | `CONFIG_CHANGED` | 0 | The plugin's whole settings object, `{"cpa_limit":926,"cpa_alarm":true}`. Every field the schema declares is present, so a handler never merges. |
| 3 | `TIMER` | The timer id `timer_set` returned | empty |
| 4 | `TCP_CONNECTED` | The connection id | empty |
| 5 | `TCP_DATA` | The connection id | Raw bytes, one event per socket read, at most 8192 bytes. Reassembling lines is yours. |
| 6 | `TCP_CLOSED` | The connection id | empty. Sent when the peer or an error ended it, not when you called `tcp_close`. |
| 7 | `UDP_DATA` | The socket id `udp_open` returned | One datagram, raw. |
| 8 | `HTTP_RESPONSE` | The request id `http_fetch` returned | An envelope: `u32 json_len`, the head JSON, then the raw body. See [http_fetch](#http_fetch). |
| 9 | `FILE_OPENED` | The file handle | `{"name":"gfs.grib2","size":12582912,"mode":"read"}`. The mariner chose a file and the host granted it to you. |
| 10 | `STORE_CHANGED` | 0 | `{"values":[…]}`, subscribed paths only, coalesced to at most 10 Hz |
| 11 | `AIS_CHANGED` | 0 | `{"targets":[…]}`, the whole target set, at most 2 Hz and only when something moved |
| 12 | `WS_OPEN` | The connection id | `{"protocol":"v1.signalk"}`. The subprotocol the server chose, empty when it chose none. |
| 13 | `WS_DATA` | The connection id | One whole text message. The host joins the fragments, so this is never half of one. |
| 14 | `WS_CLOSED` | The connection id | `{"code":1000,"reason":"…"}`. The last event on that connection, whoever ended it. |
| 15 | `TABLE_OPEN` | 0 | `{"key":"targets"}`. A shell has put one of your declared tables on screen. Build its rows from here on; before this nobody was looking. Send the first batch from inside this call, or the dialog sits empty. |
| 16 | `TABLE_CLOSED` | 0 | `{"key":"targets"}`. The shell closed it and the host has already dropped the rows. |
| 17 | `GRANTS_CHANGED` | 0 | `{"v":1,"granted":["ais.read","overlay.draw"]}`, the capabilities you hold right now. |
| 99 | `SHUTDOWN` | 0 | empty. The last thing you are ever handed, whatever you return. |

Kind 2 is unassigned. `SHUTDOWN` ignores the queue cap, so a plugin whose queue
is already full still receives it.

**`GRANTS_CHANGED` is the only way to know what you hold.** The manifest is what
you asked for; this is what the mariner left on. It arrives once your module has
started, and again on every change. Use it to stop producing what the host would
only refuse: a grant that has gone means the calls it covered will answer -1, and
whatever earlier calls produced has already been taken back. It is not the
permission. Every call is still checked on its own, whether or not you read this.

Losing `overlay.draw` is the case worth writing for. Cancel the timer that
drives your scene, forget the diff you were keeping, because the host has
already removed what it described, and post one status line saying why the
chart is empty. Arm the timer again and send the whole scene when the grant
comes back. There is no capability to request for `TABLE_UPDATE`, so a dialog
on screen keeps filling throughout. Each SDK does all of this for you.

**One datagram is one event.** The host never joins two `UDP_DATA` payloads and
never splits one, so a plugin parsing NMEA over UDP does not reassemble anything.
`TCP_DATA` is the opposite: with TCP you must reassemble. A datagram over 8192
bytes is dropped whole and logged, because half a sentence looks to a parser
exactly like a short one.

## The imports

Module name `lookout`. Every call is checked against the calling plugin's
manifest. A call the manifest did not ask for **returns -1 and logs**; it does
not trap.

| Import | Signature | Capability | Returns |
|---|---|---|---|
| `log` | `(level: u32, ptr, len)` | none | The host stamps the plugin id and the level: 0 debug, 1 info, 2 warn, 3 error. |
| `now_ms` | `() -> i64` | none | Wall clock, ms since the epoch. Stamp published values with this. |
| `mono_ms` | `() -> i64` | none | Monotonic ms. Measure intervals with this; it does not jump when a GPS fix sets the boat's clock. |
| `publish` | `(ptr, len) -> i32` | `vessel.publish` | Updates applied, or -1. A bad update inside a good batch is skipped and not counted. |
| `ais_upsert` | `(ptr, len) -> i32` | `ais.publish` | Targets applied, or -1. |
| `overlay` | `(ptr, len) -> i32` | `overlay.draw` | 0, or -1 when the batch was refused whole. |
| `chrome_status` | `(ptr, len)` | none | Nothing. The host keeps the latest line per plugin. |
| `alert` | `(ptr, len) -> i32` | `alerts.raise` | 0, or -1. |
| `tcp_connect` | `(host_ptr, host_len, port: u32) -> i64` | `net.tcp-client` | A connection id at once, or -1. The resolve and the connect happen on the host's I/O thread; the outcome arrives as `TCP_CONNECTED` or `TCP_CLOSED`. |
| `tcp_send` | `(id: i64, ptr, len) -> i32` | `net.tcp-client` | Bytes queued for writing, or -1 for an unknown connection or one belonging to another plugin. |
| `tcp_close` | `(id: i64)` | none | Nothing, and no `TCP_CLOSED`: you asked, so you know. It can only close your own connection. |
| `timer_set` | `(delay_ms: i64, periodic: u32) -> i64` | none | A timer id, or -1. A delay under 1 ms is raised to 1 ms. A periodic timer that fires late does not then fire a burst of catch-up ticks. |
| `timer_cancel` | `(id: i64)` | none | Nothing. Cancelling another plugin's timer does nothing. |
| `subscribe` | `(ptr, len) -> i32` | `vessel.read` | The number of paths, or -1. The payload is `["navigation.position",…]`. **One subscription per plugin**: calling again replaces the list. |
| `ais_subscribe` | `() -> i32` | `ais.read` | 0, or -1. The current target set arrives on the next fanout tick rather than when a target next moves. |
| `udp_open` | `(port: u32) -> i64` | `net.udp` | A socket id, or -1. The host binds the port on every interface and delivers each datagram as `UDP_DATA`. The port must be one your manifest's `net.udp` grant names, so port 0 is refused: an ephemeral port is not a port the mariner consented to. |
| `udp_send` | `(id: i64, ptr, len, host_ptr, host_len, port: u32) -> i32` | `net.udp` | Bytes sent, or -1. The address is an **IP literal** (the host resolves no name here), so `255.255.255.255` works and `gateway.local` does not. |
| `udp_close` | `(id: i64)` | `net.udp` | Nothing. It closes only your own socket. |
| `http_fetch` | `(ptr, len) -> i64` | `net.http` + its host list | A request id at once, or -1. The host fetches on a thread of its own and delivers exactly one `HTTP_RESPONSE` carrying that id. |
| `ws_connect` | `(ptr, len) -> i64` | `net.ws` + its host list | A connection id at once, or -1. The host performs the handshake and delivers `WS_OPEN`, then `WS_DATA` per message, then `WS_CLOSED`. |
| `ws_send` | `(id: i64, ptr, len) -> i32` | `net.ws` | Bytes queued, or -1. Text messages only. The host writes the frame on the connection's own thread, so this returns at once however slow the peer is. |
| `ws_close` | `(id: i64)` | `net.ws` | Nothing. The host sends the close frame and still delivers `WS_CLOSED`. |
| `storage_get` | `(kptr, klen, vptr, vcap) -> i32` | `storage` | The value's size in bytes, or -1 when there is no such key. The host writes into your buffer only when the value fits it. See [storage_get and storage_put](#storage_get-and-storage_put). |
| `storage_put` | `(kptr, klen, vptr, vlen) -> i32` | `storage` | 0, or -1 when a cap is in the way. An empty value deletes the key. The host has written the file before this returns. |
| `file_read` | `(handle: i64, offset: i64, ptr, cap) -> i32` | `files` | Bytes read, 0 at the end of the file, or -1. `offset` is absolute: a handle has no cursor to move. |
| `file_write` | `(handle: i64, ptr, len) -> i32` | `files` | Bytes appended, or -1 for a read handle, or one that is not yours. |
| `file_close` | `(handle: i64)` | `files` | Nothing. The host also closes every handle you hold when you stop. |

A plugin never requests a capability for timers, status lines, the log or the
clocks. Every plugin can report what it is doing and measure time.

**There is no `file_open`.** You cannot name a path. Every file handle you ever
see arrived as a `FILE_OPENED` event because the host granted it, and the host
grants one only when Lookout asks it to on a mariner's behalf, which happens
when they open a file your
manifest claims. See **File types** below.

### The capabilities

| Capability | What it grants |
|---|---|
| `vessel.publish` | `publish`: write vessel paths as a source in the store |
| `vessel.read` | `subscribe`: receive `STORE_CHANGED` for named paths |
| `ais.publish` | `ais_upsert`: write AIS targets |
| `ais.read` | `ais_subscribe`: receive `AIS_CHANGED` snapshots |
| `overlay.draw` | `overlay`: retained objects on the chart |
| `alerts.raise` | `alert` |
| `net.tcp-client` | `tcp_connect`, `tcp_send`, `tcp_close` |
| `net.udp` | `udp_open`, `udp_send`, `udp_close` |
| `net.http` | `http_fetch`: **to the hosts the grant names, and no others** |
| `net.ws` | `ws_connect`, `ws_send`, `ws_close`: **to the hosts the grant names, and no others** |
| `storage` | `storage_get`, `storage_put`: a key-value store of your own |
| `files` | `file_read`, `file_write`, `file_close`, on handles the host granted |

An unknown capability name refuses the whole plugin, so a typo in a grant is a
load error rather than a permission that turns out to be missing at run time.
Check your spelling against the table above.

Most capabilities are all-or-nothing. There is no subtree restriction:
`vessel.publish` grants every path, not `navigation.*`.

**`net.http` and `net.ws` are the exception: each carries a list of hosts.** You
write the grant as an object rather than a name, and the plugin may reach the
servers on that list and nothing else:

```json
"capabilities": ["storage", {"net.http": ["nomads.ncep.noaa.gov"]},
                            {"net.ws": ["demo.signalk.org"]}]
```

The list exists so that a mariner can be told which servers a plugin reaches,
rather than only that it reaches the internet. The bare names `"net.http"` and
`"net.ws"` refuse the manifest, and so does an empty list.

| Rule | Detail |
|---|---|
| Match | Exact hostname, case-insensitive. The port and the path are not part of it. |
| Wildcards | None. `*.noaa.gov` refuses the manifest. Name each server. |
| Form | A hostname, never a URL: no scheme, no path, no trailing slash. |
| Count | 1 to 8 hosts per capability. |
| Redirects | The host follows a redirect only while it stays on the same host, so a fetch can never leave the list by being sent somewhere. |

**`local` is the one entry that is not a hostname.** It grants *this boat's own
network*: loopback, the private IPv4 ranges, IPv6 unique-local and link-local,
and the `.local` names mDNS serves. Nothing public matches it, however that
name resolves.

```json
"capabilities": [{"net.ws": ["local"]}]
```

Write it when the server is a **mariner's setting** rather than something you
chose: a Signal K server is at whatever address the boat's network gives it, and
no manifest can know that in advance. The grant still has a definite meaning:
this plugin may reach servers on the boat's network, and not the internet.

The check runs on the text of the URL, before any name lookup, so a public name
that happens to resolve to a private address is still refused.

The host checks the URL you pass against the list before it opens any socket. A
URL outside it returns -1 and logs a refusal naming the host, exactly as a
missing capability does.

## The WASI floor

Go and Rust do not compile a module that runs without WASI. Their runtimes import
`wasi_snapshot_preview1` before a line of your code executes, and a module with an
unresolved import does not instantiate. The host therefore provides WASI, and
this section lists all of it.

**WASI is a floor for language runtimes, not a capability surface.** Every
real thing a plugin does goes through a `lookout` import and is checked against
your manifest. The two lists below say which calls work and which do not; read
them before debugging a call that failed.

**What works**

| Call | Behaviour |
|---|---|
| `clock_time_get`, `clock_res_get` | Real. `SystemTime::now()` and `time.Now()` agree with the host's `now_ms` to the millisecond. `Instant` and monotonic timing work. |
| `random_get` | Real. Seeds Go's map hashing and Rust's `HashMap`, which is why both need it to boot. |
| `fd_write` on 1 and 2 | Becomes log lines, one per line written. `println!`, `fmt.Println`, `eprintln!` and a Rust `fatal error` all arrive in the plugin layer's log, never on the terminal Lookout was launched from and never in a file. A line over 512 bytes is cut. Any other descriptor is `EBADF`. |
| `args_*`, `environ_*` | Succeed and report nothing. Zero arguments, zero variables. |
| `sched_yield` | Real, and pointless: there is nothing else to schedule. |
| `proc_exit` | Real. It traps the instance, so a Rust panic or a Go `fatal error` fails the plugin loudly instead of half-running. |

**What does not**

| You wrote | You get | Why |
|---|---|---|
| `File::open`, `os.Open`, any path at all | `ENOENT` | **Zero preopened directories.** There is no root, so no path resolves, absolute or relative, read or write. `fd_prestat_get(3)` is `EBADF`, which is how the standard library discovers there is no filesystem. |
| `read_dir`, `os.ReadDir` | `ENOENT` | Same. |
| `TcpStream::connect`, `net.Dial` | `Unsupported` | No sockets. `sock_open` is refused before a descriptor exists. Use `tcp_connect` with the `net.tcp-client` capability. |
| `env::var`, `os.Getenv` | not present | The environment is empty on purpose: Lookout's configuration is not the plugin's. Your settings arrive when the plugin starts and in `CONFIG_CHANGED`. |
| `thread::spawn`, `go func()` | `ENOTSUP`, or a goroutine that never runs | One thread, and it runs only while the host is calling your plugin. |
| `thread::sleep`, `time.Sleep` | returns at once | `poll_oneoff` never waits. A thread parked in a sleep cannot see the watchdog, so a plugin that could sleep could hold its dispatch thread for as long as it liked. Sleeping is what `timer_set` is for. |
| `fd_read` on stdin | end of file | Backed by the null device. |

Two consequences worth knowing.

- **A sleep becomes a busy loop.** `time.Sleep(2 * time.Second)` spins instead
  of waiting, and the watchdog terminates the instance. Write a timer.
- **A Rust `cdylib` makes WAMR print `warning: a module with WASI apis should be
  either a command or a reactor` once at load.** It exports neither `_start` nor
  `_initialize` because `wasm-ld` calls its constructors from the top of each
  export instead. The warning is cosmetic; the module runs. A Go module exports
  `_initialize`, and the runtime calls it before anything else.

## JSON payloads

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

**Every unit crossing this boundary is SI.** Your instrument's unit is your
problem: convert knots to metres per second before you publish, leave degrees as
degrees, and nothing downstream ever has to ask what unit it is holding.

### Store paths

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
| `steering.rudderAngle` | number | degrees, positive to starboard |
| `navigation.attitude.roll` | number | degrees, positive with the mast to starboard |
| `navigation.attitude.pitch` | number | degrees, positive bow up |
| `environment.water.temperature` | number | kelvin |
| `navigation.log` | number | metres through the water since the log was installed |
| `navigation.trip.log` | number | metres through the water since the trip was reset |

The store takes any path string you like; that table is the vocabulary in use
today. Four of those paths are read by the core itself: position, heading,
course and speed drive own ship's display position, follow mode and course-up.
If you publish them under names of your own, no boat appears.

Angles are the one place the store leaves Signal K's units behind: Signal K
carries radians and the store carries degrees. Everything else is the SI unit
Signal K uses, which is why water temperature is kelvin.

Several plugins may publish the same path. The store elects one: the
first-registered source wins while its value is inside the staleness window, and
load order is sorted file order. If no source is fresh, the most recent stale
value is elected and flagged stale.

A batch may add `"source"`, and then it is one of your connections publishing
rather than your plugin at large:

```json
{"source":2,"updates":[
  {"path":"navigation.position","value":{"lat":38.9763,"lon":-76.4767},"ts":1754400000123}]}
```

The number is the connection's place in the mariner's list, counting from one.
The host reserves one store source per row your connection list can hold, so
two gateways carrying the same path go to the election instead of overwriting
each other, and the row at the top of the list wins while its values are fresh.
Leave the key out and the batch is your plugin publishing as itself, which is
what a plugin with no connection list does. A place you do not own is logged and
the values land under your plugin.

### ais_upsert

```json
{"targets":[{"mmsi":899000404,"lat":38.98,"lon":-76.47,"sog":5.1,"cog":210.0,
             "heading":211.0,"name":"TANGERINE OTTER","ts":1754400000123}]}
```

Only `mmsi` is required; the upsert merges each field it carries into the target
it names. `sog` is **metres per second**, not knots. The AIS wire format reports
knots, and converting is the parsing plugin's job. An aid to navigation adds
`"aton":true` and may add `"aton_type"` (0..31), `"virtual":true` and
`"off_position"`. A target that has once reported as an aid stays one.

`"source"` works here too, and means the same thing: the place in the mariner's
list of the connection that heard these targets. A target belongs to whichever
source last updated it, so naming the receiver is what lets one of them be
switched off without taking the other's targets with it.

### STORE_CHANGED

```json
{"values":[{"path":"navigation.position","value":{"lat":38.9763,"lon":-76.4767},
            "ts":1754400000123,"age_ms":120},
           {"path":"environment.wind.directionTrue","value":null}]}
```

Only the paths you subscribed to, only when the elected value changed, and at
most 10 Hz. `age_ms` is how old the value was **when the host wrote the payload**;
it is already stale when you read it, so age it on with `mono_ms` if you need it
later.

**A `null` value is a removal, not a null value.** The path has no value from
any source any more, because a source was cleared or the plugin that owned it was
disabled. Stop drawing whatever it fed. There is no separate delete list, and a
removal carries no `ts` and no `age_ms`, because there is no value for them to
describe.

### AIS_CHANGED

```json
{"targets":[{"mmsi":899000101,"lat":38.966,"lon":-76.434,"sog":4.1,"cog":300.0,
             "ts":1754400000123,"age_ms":540},
            {"mmsi":998990001,"lat":38.972,"lon":-76.466,"aton":true,
             "aton_type":25,"name":"EXAMPLE CHANNEL BUOY 2","ts":1754400000000,"age_ms":663}]}
```

The **whole** target set, at most twice a second and only when something moved.
An unknown field is left out rather than sent as null, because "never heard" and
"heard as zero" are different facts. Targets are evicted from the store after
600 s, and an aid to navigation after 1800 s, because an aid transmits about
every three minutes.

### overlay

```json
{"del":["t899000404","t899000404/vec"],
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
| `width_pt` | polyline | Screen **points**, not metres. The core converts at the live zoom. Default 1.5; outside 0.1..64 it is reset. |
| `dash` | polyline | Default false |
| `alpha` | polygon | Multiplies the token's own alpha. Clamped to 0..1, default 1. |
| `anchor` | symbol, polyline | `"ownship"` and nothing else. See below. |
| `pick` | symbol | See below. |

A malformed object is skipped and the rest of the batch still applies: one bad
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
the last fix steps across the screen. An object with this anchor follows own
ship's **display** position, which the core carries forward between fixes and
substitutes every frame; a polyline keeps its shape and travels with its first
point. The lon/lat you post is still the fix, and it is what draws if the core
has no carried position. Dead reckoning stops at the 5 s staleness window.

**Pick payloads.** A symbol may carry what a hover or a tap reports:

```json
"pick":{"title":"TANGERINE OTTER","rows":[["MMSI","899000404"],["SOG","9.9 kn"],["CPA","149 m in 591 s"]]}
```

Both parts are optional and a payload with neither is dropped. The core
validates, escapes and caps the text at 16 rows of 96 bytes; a row that is not
two strings is dropped and the symbol still draws. **Values are strings you have
already formatted for display.** The core cannot know that a row called SOG
holds metres per second, so you write the number and the unit yourself. This is
the only place the SI rule is broken, and it is deliberate. Lines and areas carry
no payload: there is no single point to measure a hit to. Lookout
reads the payload back with `lookout_overlay_at`, which answers with the nearest
symbol whose **anchor** is within about 14 pt of the point the mariner touched.

### chrome_status

```json
{"state":"running","detail":"42 msg/s"}
```

One status, kept per plugin, truncated past 768 bytes. The host logs it at info
only when the text changes, so posting the same status at 1 Hz is free. `state`
and `detail` are free strings; the plugins that ship with Lookout use `starting`,
`running`, `degraded` and `stopped`, which is a convention, not a rule. The host
writes `{"state":"disabled","detail":"<reason>"}` itself when it takes a plugin
out of service.

Your status is nearly the only thing you can put in front of a person away from
the chart itself. Use it to say what you are doing, or what you are missing. It
reaches Lookout through `lookout_plugins_json`. If your settings include a list,
a status can also carry one line per row. See
[status items](#status-items-one-line-per-row). There are no jobs and no
progress. An alarm belongs in [alert](#alert), not here.

### alert

```json
{"severity":"alarm","key":"cpa:899000101","title":"AIS CPA alarm",
 "body":"GALLEON is closing inside your CPA limit"}
```

The host holds the alert for the shell and logs it. **Set the severity
honestly.** An `alarm` is sounded and repeats until the mariner acknowledges it;
a `warning` and a `notice` are shown and never sounded. The severity also picks
the log level.

| Severity | Shown how | Log level |
|---|---|---|
| `alarm` | shown, and sounded until acknowledged | error |
| `warning` | shown | warn |
| `caution`, `notice` | shown | info |
| anything else, or no severity at all | treated as `alarm` | error |

An unreadable severity is an alarm rather than a dropped alert.

One condition is one alert. `key` is the identity you give it. The host holds
one alert for each plugin and key, so a raise under a key it already holds
updates that alert instead of adding one, and two vessels closing stay two
alarms. The mariner's acknowledgement survives the update, so an alarm they
silenced stays silent.

Without a `key` the host has only your words, so it keys the alert on your
plugin, the title and the body. A body carrying a figure that moves is then a
new alert every time it moves, and the mariner cannot silence it. Key the
alert, and draw the moving figure on the chart instead.

The key is cut at 64 bytes, the title at 96 and the body at 240. An alert whose
plugin unloads, or loses `alerts.raise`, is withdrawn with it.

### http_fetch

```json
{"method":"GET","url":"https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs.pl?file=gfs.t00z",
 "headers":{"accept":"application/octet-stream"},"range":"bytes=0-1048575"}
```

Only `url` is required. `method` is `GET` or `HEAD`. The host refuses anything
else, because a plugin that can POST can send data off the boat and nothing here
needs to. `headers` is optional and each name and value must be printable ASCII.
`range` is an HTTP range expression and is the way past the body cap.

The host resolves, connects, negotiates TLS and reads the body on a thread of
its own, so neither your dispatch thread nor the host's I/O thread waits for a
server. It then delivers **exactly one** `HTTP_RESPONSE` per request id, whether
the fetch worked or not, so you never have to time a request out yourself.

The payload is an envelope, because one event carries one payload and you need
both the head and the body:

```
u32 json_len (little-endian) | head JSON | raw body bytes
```

```json
{"status":200,"url":"https://nomads.ncep.noaa.gov/…","headers":{"content-type":"application/octet-stream","content-length":"1048576"}}
```

Header names are lower-cased, so look for `content-length`, not
`Content-Length`. `url` is where the body actually came from, after any
redirect. A fetch that never reached a server answers `"status":0` with an
`"error"` beside it naming what stopped it, and an empty body:

```json
{"status":0,"url":"https://nomads.ncep.noaa.gov/…","headers":{},"error":"ConnectFailed"}
```

| Limit | Value |
|---|---|
| Body | 4 MiB. Over it the fetch fails with `BodyTooLarge` rather than truncating. **Use `range` for anything bigger.** A 200 MB GRIB is 200 requests, and each one is an event you can act on. |
| Redirects | 5, and each must stay on the same host. One that leaves fails with `RedirectOffHost`. |
| In flight | 4 across every plugin. A fifth returns -1 at once; try again from a timer. |
| Read and connect | 20 s each. |
| Connection reuse | None. One fetch is one connection. |

TLS is Zig's own, with the platform's root certificates. There is no HTTP/2, no
cookie jar, no authentication and no compressed transfer encoding.

### ws_connect

```json
{"url":"wss://demo.signalk.org/signalk/v1/stream?subscribe=none",
 "protocols":["v1.signalk"]}
```

Only `url` is required; `protocols` is the subprotocol list the host offers in
the handshake. The host dials, performs the RFC 6455 handshake (checking the
accept hash), and then owns the connection on a thread of its own.

What you get:

- **`WS_OPEN`** once, carrying the subprotocol the server chose.
- **`WS_DATA`** per message. The host reassembles fragments, so a message split
  across ten frames arrives as one payload. It answers every ping with a pong
  itself: you never see one, and a connection stays alive while your plugin is
  busy.
- **`WS_CLOSED`** once, at the end, whoever ended it. `code` is the RFC 6455
  close code; `code` 0 means the connection never opened and `reason` names what
  stopped it: `HandshakeRefused`, `ConnectFailed`, `TlsFailed`.

`ws_send` takes one **text** message and queues it; the connection's own thread
writes the masked frame. An incoming **binary** message is dropped with a log
line, because `WS_DATA` is text by contract and a plugin handed bytes it cannot
tell from text would parse them as JSON.

| Limit | Value |
|---|---|
| Message | 1 MiB, in or out |
| Queued to send | 64 messages or 256 KiB, whichever comes first. Over either, `ws_send` returns -1. |
| Reconnecting | Yours. The host never retries, exactly as with TCP. |

### storage_get and storage_put

A key-value store of your own, one per plugin, that survives a restart. The host
keeps it as a JSON file under Lookout's data directory. That is data and
not cache, so nothing purges it when the disk runs low.

`storage_get` uses a **two-call pattern**, because the host cannot allocate in
your memory. Call it with a zero-length buffer to learn the size, then call it
again with a buffer that big:

```zig
const size = lk.storageSize("last_run") orelse return;   // no such key
var buf: [64]u8 = undefined;
if (size > buf.len) return;
const value = lk.storageGet("last_run", buf[0..size]) orelse return;
```

The return is the value's size in bytes, or -1 when there is no such key. The
host writes into your buffer only when the value fits it, so a short buffer
returns the size and writes nothing.

A value is **bytes**, not text: store a packed struct if you like. An empty
value deletes the key; there is no separate delete import. A key must be
printable ASCII with no quote and no backslash, because it goes into that JSON
file as itself.

| Limit | Value |
|---|---|
| Key | 128 bytes, printable ASCII |
| One value | 64 KiB |
| Total per plugin | 1 MiB, and 256 keys |
| Durability | `storage_put` has written the file before it returns |

Another plugin's store is another file. You cannot read it and you cannot
overwrite it. What you stored survives your plugin trapping, being disabled and
being loaded again.

### file_read and file_write

There is no way to open a file. A handle arrives as `FILE_OPENED` because the
mariner chose that file and Lookout asked the host to grant it:

```json
{"name":"gfs.t00z.pgrb2.0p25.f000","size":12582912,"mode":"read"}
```

`name` is the file's name with no directory: you are told what the file is
called, not where it is. `mode` is `read` or `write`.

`file_read` takes an **absolute offset**. The handle has no cursor, so two
reads never interfere and a plugin decoding a GRIB can seek freely. It returns
the bytes read, 0 at the end of the file, and -1 for a handle that is not yours.
`file_write` appends to a write handle and returns the bytes written.

| Limit | Value |
|---|---|
| Open handles | 8 per plugin |
| One read | 1 MiB |

The host closes every handle you hold when you stop, so `file_close` matters
only to a plugin that opens many files over a long run.


### File types

Name the extensions you read, and the mariner's Open command routes those files
to you:

    "capabilities": ["files"],
    "file_types": [".grib2", ".grb"]

The mariner opens a weather file the way they open a chart. They are not shown a
list of plugins and never learn one was involved; you never learn there was a
file picker. The host matches the extension, grants you read access, and sends
`FILE_OPENED`.

Write each type lowercase, with the leading dot and nothing else: `.grib2`, not
`.GRIB2` and not `grib2`. A name in any other form refuses the manifest, because
it would read as a claim and never match a file. The same applies to a compound
extension such as `.tar.gz`: only the last dot is matched. Eight types is the
most one plugin may claim.

`file_types` needs the `files` capability. Without it the manifest is refused:
the claim rests on the grant.

Two rules decide what you do NOT get:

- **A chart is always a chart.** `.pmtiles` and `.mbtiles` belong to the chart
  side of Lookout and are never offered to a plugin, whatever a manifest
  claims.
- **Two plugins claiming one type both lose it.** Neither is given the file and
  the log names both. Load order must not decide who reads the mariner's
  weather.

## The manifest

`<id>.manifest.json`, beside `<id>.wasm`.

```json
{
  "id": "org.beetlebug.ais",
  "name": "AIS targets",
  "api": 1,
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
| `id` | yes | 1 to 128 bytes. Your overlay namespace, your settings key, and the name Lookout knows you by. Reverse-DNS by convention. |
| `name` | no | What Lookout would show a person. Defaults to the id. |
| `api` | yes | Must be 1. |
| `capabilities` | no | An array of the names above, plus `{"net.http": […]}` and `{"net.ws": […]}` for the two that carry a host list. Absent grants nothing. An unknown name refuses the manifest. |
| `settings` | no | A v1 array of fields, or a v2 object of groups. At most 16 fields in total, and at most 16 columns in a list. |

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

A field is one control in the mariner's settings window. Your module receives the
values and nothing else: it cannot read its own manifest at run time. If you want
to clamp a value defensively, you repeat the range in your source, and it is on
you to keep the two in step.

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
| `kind` | all | `number`, `toggle`, or `text` inside a list. A `text` field outside a list refuses the manifest: a scalar value crosses the ABI as a number, and there is nowhere to keep a scalar string. |
| `label` | all | What Lookout shows beside the control. Defaults to the key. |
| `desc` | all | One sentence, in plain language, about what the setting does for the person at the helm. Shown under the control. Absent shows none. |
| `unit` | number | Display only. The value crosses the ABI in the unit the schema names. |
| `min`, `max` | number | Both required, and `max` must be greater than `min`. |
| `default` | number | Required. Clamped into the range rather than refused. |
| `default` | toggle | Required, and must be a JSON boolean. A toggle whose default is a number refuses the manifest. |
| `default` | text | Optional, a string, at most 128 bytes. Absent means empty. |
| `optional` | text | `true` says the mariner may leave it empty. Display only: what an empty value means is yours to decide. |

Schema v1 (`"settings"` as a bare array of fields) still parses. Those fields
carry no group and land on `advanced`.

**The plugin always receives the whole settings object**, in the config it is
started with and again on every `CONFIG_CHANGED`, so a handler never merges. A
value outside its range is clamped on the way in, so a plugin never receives a
setting outside the range it declared. A key the schema does not declare is
ignored.

There is no choice field and no colour. Nothing validates one field against
another.

### Lists: a group the mariner adds rows to

A group may hold a **list** instead of fields. A list is a table the mariner adds
rows to and removes rows from. The NMEA connections are the first one. The value
of the list's key in your config is a JSON **array** of row objects, replaced whole on
every edit and delivered like any other setting.

```json
"settings": {"groups": [
  {"label": "Connections", "tab": "connections",
   "list": {"key": "connections", "item_fields": [
     {"key": "name",    "label": "Name",    "kind": "text", "optional": true},
     {"key": "host",    "label": "Address", "kind": "text", "default": ""},
     {"key": "port",    "label": "Port",    "kind": "number", "min": 1, "max": 65535, "default": 10110},
     {"key": "enabled", "label": "On",      "kind": "toggle", "default": true}],
   "footer": "Give the address of your instrument network's gateway.",
   "empty": "No gateways yet.", "add_label": "Add Gateway", "switch_key": "enabled"}}]}
```

| List key | Rule |
|---|---|
| `key` | Required, 1 to 32 bytes. The key the array arrives under, and it may not collide with a field or another list. |
| `item_fields` | Required, 1 to 16 columns, the same field kinds as above. A column called `id` refuses the manifest: the id is the host's. |
| `footer` | The sentence under the section: what these rows are, and the one thing a mariner needs to know to fill one in. |
| `add_label` | The wording on the button that adds a row: "Add Server", not "Add". |
| `empty` | What the section says while it holds no rows. |
| `switch_key` | Which toggle column is the row's own on/off switch, drawn on the row's line rather than inside it. Absent means the first toggle column. Naming a column the list does not declare, or one that is not a toggle, refuses the manifest. |

The last four are optional; the three strings are at most 240 bytes each, and a
longer one is cut. **Write them.** A tab can hold two lists: Connections holds
NMEA gateways and Signal K servers. Without your own wording both lists show the
application's default text, which is wrong for at least one of them.

What you receive:

```json
{"connections":[{"id":"row-3f9c1a20","name":"Masthead","host":"10.0.0.9","port":2000,"enabled":true}]}
```

- **Every row carries an `id`** Lookout assigned when the row was added, and it
  does not change when the row is edited. Echo it back in your status items (see
  below) so Lookout can put each line beside the right row.
- Every column the schema declares is present in every row, in schema order.
  Numbers are clamped, text is capped at 128 bytes, a missing column takes its
  default, and a column nobody declared is dropped.
- At most 8 rows. Rows past that are dropped rather than wrapped.
- **The array is complete.** A row the mariner deleted is absent from the next
  array you receive.
- A list starts **empty**. `lookout_plugin_config_get` and the registry both show it
  as `[]` until an app writes rows. (The one exception is `nmea0183`: the host
  seeds row one from the address Lookout was started with, so a mariner sees the
  source already feeding the chart.)

### Status items: one line per row

`chrome_status` takes an optional `items` array beside the state and the detail.
One item per row of a list, keyed by the row id:

```json
{"state":"running","detail":"2 of 3 connected, 44 msg/s",
 "items":[{"id":"row-3f9c1a20","state":"connected","detail":"44 msg/s"},
          {"id":"row-8b02cc71","state":"paused","detail":"switched off"}]}
```

Lookout puts each item's line under its row and colours a dot from the state.
The whole status, items included, is capped at 768 bytes and truncated past
that, so keep a detail short. The item `state` is yours to name; Lookout that
ships knows `connected`, `paused`, `reconnecting`, `unreachable`,
`no_address` and `refused`, and shows anything else as it is written.

## How Lookout sees your plugin

You never call these. They are in `include/lookout.h`, the C header an app uses
to drive the chart core, and they are how a control in a settings window becomes
your `CONFIG_CHANGED`. That is worth knowing when a setting you declared is not
reaching you.

```c
int  lookout_plugins_load(lookout *h, const char *dir);
int  lookout_plugins_active(lookout *h);
const char *lookout_plugins_json(lookout *h, size_t *out_len);
const char *lookout_plugin_config_get(lookout *h, const char *id, size_t *out_len);
int  lookout_plugin_config_set(lookout *h, const char *id, const char *json);
```

`lookout_plugins_json` is the registry: every loaded plugin with its id, name,
whether it is live, its status line, each settings field with its label,
description, unit, range, group, tab, default and the value in force, and each
list with its columns and the rows in force. Lookout draws one control per field
and one editable row per list entry, and knows nothing about what your plugin
does, so your manifest schema is the whole of your user interface.

```json
{"plugins":[{"id":"org.beetlebug.ais","name":"AIS targets","live":true,
             "status":"{\"state\":\"running\",\"detail\":\"5 targets\"}",
             "settings":[{"key":"cpa_limit","label":"Closest approach (CPA)",
                          "desc":"Alarm when a vessel will pass closer than this.",
                          "kind":"number","unit":"m","min":93,"max":9260,"default":926,
                          "group":"Collision alarm","tab":"alarms","value":926}]}]}
```

A plugin with a list carries one more block, the schema of a row and the rows
themselves:

```json
{"plugins":[{"id":"org.beetlebug.nmea0183","name":"NMEA 0183","live":true,
             "status":"{\"state\":\"running\",\"detail\":\"1 of 2 connected, 44 msg/s\",\"items\":[…]}",
             "settings":[],
             "lists":[{"key":"connections","group":"Connections","tab":"connections",
                       "item_fields":[{"key":"host","label":"Address","kind":"text","default":"","max_len":128}],
                       "rows":[{"id":"lookout-nmea","name":"","host":"127.0.0.1","port":10110,"enabled":true}]}]}]}
```

`lookout_plugins_active` exists for an app that renders only on demand: while it
returns 1, that app must poll `lookout_needs_redraw` a few times a second instead
of sleeping until the mariner touches something. If an app skips that, your
plugin keeps running but nothing it draws reaches the screen until someone pans
the chart.

## The raw module contract

This section is for building a plugin WITHOUT the Zig SDK: from Go, Rust,
or any toolchain that emits wasm. With `lk.zig` you never touch any of this:
`lk.plugin(@This())` registers your plugin and routes the host's calls
to the `start` and `onEvent` functions you write.

Your compiled module must export these five functions. They are the only part
the host ever calls.

| Export | Signature | Meaning |
|---|---|---|
| `lk_abi` | `() -> u32` | The ABI version this module speaks. Must return 1. |
| `lk_alloc` | `(len: u32) -> ptr` | Give the host `len` bytes to write an inbound payload into. **Returning 0 means out of memory**, and the host treats the call as a fault. |
| `lk_free` | `(ptr, len: u32)` | The host is done with that buffer. |
| `lk_start` | `(ptr, len: u32) -> i32` | Begin. The payload is `{"abi":1,"config":{…}}`; the `abi` key is the wire's frozen name for the API version. Non-zero refuses the start, and the plugin is not loaded. |
| `lk_event` | `(kind: u32, handle: u64, ptr, len: u32) -> i32` | Everything that happens. `handle` correlates: which timer, which socket. Non-zero is logged as a complaint and the plugin keeps running. |

The host checks `lk_abi` at load and refuses a mismatch, because the same five
names could mean something else in another version.

Nothing else about the boundary changes with the toolchain. The imports, the
event kinds, the JSON and the manifest above are the whole contract; the Go and
Rust libraries in `sdk/` are conveniences over exactly the same five exports.
