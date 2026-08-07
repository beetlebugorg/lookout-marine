---
id: dev-harness
title: The dev harness
sidebar_position: 6
---

# The dev harness

`lookout-plugin-dev` runs your plugin without an app and without a boat. It is
Lookout's chart core opened offscreen with the real plugin host inside it, plus a
loopback TCP server standing in for a NMEA multiplexer. Give it a chart, a plugin
directory and a recorded log, and it prints what your plugin published, what it
drew and what it was denied, then writes the chart with your overlay on it to a
PNG.

Nothing about the plugin layer is simulated: it uses the same broker, stores,
overlay engine and watchdog as Lookout. What is missing is Lookout window and a
real boat.

```sh
zig build plugin-dev            # zig-out/bin/lookout-plugin-dev

./zig-out/bin/lookout-plugin-dev \
    --chart ~/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles \
    --plugins zig-out/plugins \
    --replay test/annapolis.nmea --rate 20 --until 410 \
    --view -76.4767,38.9763,15 --png out.png
```

It needs the plugin host, so it builds only where the host does: macOS and iOS
today, and `-Dplugins=true` with a WAMR archive elsewhere.

## Flags

| Flag | Meaning |
|---|---|
| `--chart PATH` | A baked `.pmtiles` archive or a directory of them. Repeatable; several charts compose. A bare path with no flag is read as a chart too. |
| `--plugins DIR` | The plugin directory: `<id>.wasm` beside `<id>.manifest.json`. Without it the chart runs alone. |
| `--replay FILE` | A NMEA 0183 log to serve on the loopback listener. |
| `--rate X` | Replay speed, times real time. Default 1. `0` serves as fast as the socket takes it. |
| `--until S` | Stop after S replay **seconds**. Default: the whole log. |
| `--png PATH` | The snapshot written at `--until`. Default `plugin-dev.png`. |
| `--view lon,lat,zoom[,rot]` | The camera. Default: fit the chart. Use the rotation at least once — geometry that looks right north-up can still be wrong under a turned camera, and rendering one is the only way to find out. |
| `--width W --height H` | Render size in pixels. Default 1600x1200. |
| `--scheme day\|dusk\|night` | The palette. Default day. Run night to see what your colour tokens actually look like. |
| `--print WHAT` | One of `all`, `deltas`, `overlay`, `alert`, `status`. Default `all`. |
| `--set-config [SECONDS@]ID JSON` | Change a plugin's settings, optionally at a replay second. Repeatable, applied in order. |
| `--grant-file [SECONDS@]ID PATH` | Hand a plugin a file, optionally at a replay second, and print the handle it was given. |
| `-h`, `--help` | The usage text. |

Every filter also prints every error line, so a filter never hides a trap.

Exit code 0 only when at least one frame rendered and no plugin trapped; 1 for a
trap or no frame; 2 for a bad invocation or a chart that will not open.

## How the plugins find the log

You configure nothing for this to work. The listener binds `127.0.0.1` on a port
the kernel picks, and the harness sets `LOOKOUT_NMEA` and `LOOKOUT_PLUGINS`
**before** the core is created; the core reads both while it opens the chart,
which is where the plugin layer is built and started. Because the port is chosen
at run time, several harnesses can run at once without colliding.

The log is served group by group, paced by its own timestamps at `rate` times
real time, and the socket is then held open: an EOF would send the `nmea0183`
plugin into its reconnect backoff and the log would replay from the start.

If nothing dials the listener within five seconds the harness says so, because
the replay clock cannot advance and the run would otherwise sit there until the
wall-clock cap.

**`--rate` speeds up the log, not the clocks.** Plugin timers, staleness windows,
reconnect delays and the AIS fanout all run on real time. At `--rate 20` a
410-second replay takes 20 real seconds, so the own-ship track holds about 20
points instead of 410, and the collision alarm lands a couple of replay seconds
later than the geometry says. Use `--rate 1` when the timing is what you are
testing.

## Making the replay log

`tools/nmea_gen.zig` writes the log the shipped plugins are verified against. It
is deterministic — no clock, no randomness — so two runs produce identical bytes.

```sh
zig run tools/nmea_gen.zig -- test/annapolis.nmea
```

600 seconds at 1 Hz out of Annapolis harbour: own ship sails a gentle S curve at
5 kn reporting RMC, HDT, MWD and DPT, and holds ten degrees between heading and
course so the heading line and the course vector are two visibly different lines.
Three AIS targets exercise all three sides of the `ais` plugin's alarm gate — one
crosses into it at about t = 50 s and stays, one lies anchored 1.4 km abeam and
never gates, one is a class B already departing with a negative TCPA. Two aids to
navigation report type 21.

The log itself is not in the repository — run the command above to write it.

Any recording works: `--replay` reads a plain NMEA 0183 log. A capture from your
own boat is better test data than the generated log.

## Changing settings while it runs

```sh
--set-config 200@org.beetlebug.ais '{"cpa_limit":100}'
```

The `SECONDS@` prefix is the replay second to make the change at; without one it
happens before the replay starts. To check that a setting applies **hot**, change
it while the log is playing and watch the behaviour change; a change made before
the run starts does not test that. Each change prints when it lands:

```
t=  200.0s set-config org.beetlebug.ais {"cpa_limit":100}
```

A refused change prints `set-config … REFUSED: <error>` and the run continues
with exit code 0. Read the output rather than trusting the exit code here: a
refused config does not fail the run today.

## Reading what it prints

Every line carries the replay clock, so any output can be matched to the second
of the log that caused it.

**`--print status`** — every status line a plugin posts, and only those. The host
logs a status only when the text changes, so this stream shows each plugin's
changes of state and nothing else:

```
t=    0.0s [info] org.beetlebug.nmea0183: status {"state":"degraded","detail":"connecting to 127.0.0.1:65129"}
t=    1.0s [info] org.beetlebug.nmea0183: status {"state":"running","detail":"connected, 0 msg/s"}
t=   20.0s [info] org.beetlebug.ais: status {"state":"running","detail":"5 targets, 1 in CPA alarm"}
```

**`--print alert`** — alerts, at the level their severity picked:

```
t=   20.0s [error] org.beetlebug.ais: ALERT {"severity":"alarm","title":"AIS CPA alarm","body":"367123450: CPA 149 m in 591 s"}
```

**`--print deltas`** — the vessel store and the AIS store as they change. This
reads the stores rather than the log, because the broker logs failures, not
successful publishes:

```
t=   12.0s publish navigation.position = {"lat":38.97655,"lon":-76.47494} src 1 (age 84 ms)
t=   30.0s publish environment.wind.directionTrue gone
t=   12.0s ais 367123450 38.96612,-76.43431 sog 4.1 m/s cog 300 hdg 300 (age 540 ms)
t=  180.0s ais 366987650 gone
```

`src N` is the source that won the election, `STALE` appears when no source is
fresh, and `gone` means the path or the target has no value at all any more. Age
is printed but not compared, so a value that never changes prints once.

**`--print overlay`** — objects appearing and disappearing, by their
host-namespaced id. Geometry moves every second, so movement itself is not
printed:

```
t=    2.0s overlay + org.beetlebug.ownship/ownship (symbol ownship)
t=    2.0s overlay + org.beetlebug.ownship/track (polyline track 2 pts)
t=  190.0s overlay - org.beetlebug.ais/t366987650
```

Every run ends with the inventory and a line per plugin:

```
overlay: 16 object(s)
  org.beetlebug.ais/t367123450: target target_danger at -76.43431,38.96612 rot 300
  org.beetlebug.ownship/ownship: ownship ownship at -76.47494,38.97655 rot 75
  org.beetlebug.laylines/layline_port: polyline layline_port 2 pts dashed
  ...
plugin org.beetlebug.ais: live, 0 denied call(s), status {"state":"running","detail":"5 targets, 1 in CPA alarm"}
replay: 61 group(s), 275 line(s), 60.0 s at 20x, 1 connection(s)
frames: 14 rendered, 1 alert(s) raised
```

Three things to read every time. **`live`** — anything else means the plugin
trapped or was killed, and the status line beside it says why. **`denied
call(s)`** — any number but zero is a capability your manifest forgot.
**`alert(s) raised`** — how many alerts came out of the whole run, which is the
number to pin if you are testing an alarm.

The PNG is the other half. A plugin can publish and draw correctly and still put
its line in the wrong place, or in a colour that disappears at night; only the
render shows that. Run `--scheme night` as well as day.

One thing the print streams miss: everything the plugin layer says **before** the
chart is open. Module load and the plugin's start go straight to stderr, so if
your plugin never appears in any stream at all, look further up the terminal —
the reason it did not load is up there.

## Writing a golden test

The generator is deterministic and the harness is a plain program with an exit
code, so a plugin can be regression-tested without a Mac app in the loop.

```sh
zig run tools/nmea_gen.zig -- test/annapolis.nmea
./zig-out/bin/lookout-plugin-dev \
    --chart ~/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles \
    --plugins zig-out/plugins \
    --replay test/annapolis.nmea --rate 20 --until 60 \
    --view -76.4767,38.9763,15 --png out.png --print overlay \
    | tail -n 22 > actual.txt
diff expected.txt actual.txt
```

The tail — the object inventory, the per-plugin line and the alert count — is
byte-identical across repeated runs, so it is the part worth pinning. What is
**not** stable: the `t=` stamps, the `age` columns, the frame count, and
anything whose size depends on wall-clock time (the own-ship track keeps one point
per real second, so `--rate 20` gives a shorter track than `--rate 1`). Either
filter those or pin `--rate 1` and accept the wait.

For the whole overlay event stream rather than the end state, drop the clock and
sort:

```sh
sed -E 's/^t= *[0-9.]+s //' run.txt | grep '^overlay [+-]' | sort
```

That comparison is stable across runs too.

For pure logic — a parser, a CPA solver, geodesy — do not use the harness at all.
Keep that code in a file that does not `@import("lk")` and unit-test it natively,
the way `plugins/nmea0183/parser.zig` and `plugins/ais/cpa.zig` do — `zig build
test` runs those directly. A native test is faster to run and you can put a
debugger on it, which you cannot do inside the interpreter.

## Running your plugin in the real app

These environment variables put the same plugins in the real app, with no code
change:

| Variable | Effect |
|---|---|
| `LOOKOUT_PLUGINS=<dir>` | Load and start every `<id>.wasm` + `<id>.manifest.json` pair in the directory while the chart opens. An app that wants control of loading calls `lookout_plugins_load` instead and leaves this unset. |
| `LOOKOUT_NMEA=host:port` | Where the `nmea0183` plugin dials. It arrives in that plugin's start config. |
| `LOOKOUT_OPEN=<chart\|dir>` | Open a chart at startup, so you do not have to pick one by hand on every launch. |
| `LOOKOUT_VIEW=lon,lat,zoom[,rot]` | The first camera position. |

On the iOS simulator each name takes the `SIMCTL_CHILD_` prefix, as in
`SIMCTL_CHILD_LOOKOUT_PLUGINS`, and the simulator reaches a replay server on the
host over loopback. A python or netcat server serving the same log at a fixed
port is enough:

```sh
LOOKOUT_PLUGINS=$PWD/zig-out/plugins LOOKOUT_NMEA=127.0.0.1:10110 \
    open macos/build-mac/Build/Products/Debug/LookoutMarine.app
```

Everything the plugin layer prints goes to stderr. `open` detaches from your
terminal, so capture it with `open --stderr /tmp/lookout.log ...` and tail the
file, or launch the binary directly and keep it in the terminal:

```bash
macos/build-mac/Build/Products/Debug/LookoutMarine.app/Contents/MacOS/LookoutMarine
```

The Windows app is a Windows-subsystem binary with no console attached, so
redirect stderr to a file there or you will see nothing at all.

One more thing to expect from a live feed. An app that renders only when
something changes can freeze your plugin's traffic on screen while nobody
touches the machine: your plugin is still running, but the picture stops
updating. The Mac app polls for redraws while any plugin is active and does not
have this problem; the GTK and Windows apps still do. Pan the chart to force a
frame, or test on macOS.
