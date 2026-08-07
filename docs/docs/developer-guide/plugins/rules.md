---
id: rules
title: The rules
sidebar_position: 5
---

# The rules

Some of these the host enforces on you. The rest are mistakes it cannot catch,
and those are the expensive ones: a plugin that breaks one of them usually keeps
running and drawing, and is quietly wrong.

Skim the headings now and come back to a rule when you hit it. Under each rule,
the line in *italics* is the reason it exists, and the reason is always the same
shape: a chartplotter that draws something wrong is worse than one that draws
nothing.

## State lives in globals

`lk.scratch()` is a bump arena that is **reset the moment your handler returns**.
Anything you allocate from it — a parsed JSON tree, a slice of readings, a
formatted string — is gone when the next event arrives. State that must survive
goes in a container-level `var`: a counter, a fixed array, a struct.

*There is no heap and no free list, so an allocation that outlives its event is a
use-after-free the arena will not catch.*

The host's inbound payload comes through the same arena and is released after
your call, which is why a burst of AIS snapshots does not grow linear memory.
Copy anything you keep.

## No plugin code runs per frame

You post **retained** objects. An overlay object stays on the chart until you
replace it or delete it, and the core re-expands it to triangles when the zoom
moves, without asking you for anything. Own ship's symbol and its two lines
travel between fixes because they declared `"anchor":"ownship"`, not because a
plugin is called sixty times a second.

*The frame loop must never wait on a plugin, so no per-frame callback exists.*

If you find yourself wanting to draw on a timer faster than about 1 Hz, the
thing you want is probably an anchor or a retained object that already moves.

## Redraw on a timer, not on every reading

`STORE_CHANGED` arrives at up to 10 Hz. Rebuilding the chart's vertex buffers ten
times a second for a line that a mariner reads once a minute is waste, and a line
that twitches is harder to read than one that steps.

*A timer is also the only way to notice that a value went stale, because that is
time passing rather than an event.*

Record what the event gave you, and draw from a 1 Hz timer.

## Deletes always happen before sets

The host applies every delete before every set, whatever order they are in inside
the JSON. `lk.Overlay` makes you write them that way round too: it refuses a `del`
that comes after a `symbol` or a `polyline`, and says so in the log, so that what
you read matches what happens.

*One batch that deletes a stale target and sets a fresh one with the same id must
mean "replace", never "delete what I just drew".*

Delete what you stop drawing, in the same batch. A plugin that goes degraded and
leaves its lines up is showing the mariner data it no longer has.

## Colours are tokens, never RGB

An overlay object names one of [the seven colour tokens](wire.md#overlay). The
core resolves the token you named into a colour for the day, the dusk and the
night palette.

*A mariner on a night passage has dark-adapted eyes, and one plugin with a
hard-coded `#FF0000` costs twenty minutes of night vision.*

The night column is held under a luminance ceiling and a test enforces it; an
RGB you picked yourself would not be checked.

## Everything is SI at the boundary

Metres, metres per second, degrees, milliseconds. `sog` is metres per second even
though every AIS message and every mariner says knots.

*Converting at the edge is one line in the plugin that owns the instrument;
converting downstream is a question every consumer has to ask and one of them
will get wrong.*

The single exception is a pick payload, whose rows are display strings you format
yourself, because the core cannot know that a row called SOG holds metres per
second. It is the only exception.

## One event at a time, and return promptly

A plugin is entered by exactly one thread, ever, with one event in flight. There
are no threads inside the module and no way to make one.

*One thread and one event in flight means straight-line code with no locks.*

Do your work in the handler and return. When you need to wake later, ask for
`timer_set` and handle the `TIMER` event. There is no sleep to call, and blocking
stops only your own plugin.

## The watchdog kills a 1000 ms overrun

Every dispatch thread publishes the time it entered the module. The host's 100 ms
tick terminates any instance that has been inside longer than the budget; the
call comes back as a trap, and the plugin goes down the ordinary fault path.

*Time isolation is what keeps a slow weather plugin from delaying a collision
alarm.*

One second is enormous for an event handler — the four plugins that ship with
Lookout take microseconds. The kill lands between 1000 ms and 1100 ms, because
the precision is one tick. The budget covers **one call**: a plugin that takes
900 ms on every event is never stopped and is 900 ms late forever. The watchdog
does not cover the plugin's start, which runs on the loading thread before the
I/O thread exists.

## A plugin that traps is disabled, not retried

A trap, a watchdog kill, or the module failing to allocate memory for a payload
takes the plugin out of service. Everything it contributed is erased: overlay
objects, published values, AIS targets, sockets, timers, queued events. The
status line says why.

*A chartplotter that keeps drawing the last position a crashed plugin published
is worse than one that draws nothing.*

There is no restart and no backoff. The plugin is gone until Lookout restarts.

## Memory is capped at 16 MiB

Linear memory is capped at 256 wasm pages at instantiation, and the interpreter
stack is 64 KiB. A module whose declared **minimum** memory is over the cap fails
at load rather than at sea.

*Without a cap, a leak becomes the mariner's problem instead of the host's.*

Nothing an ordinary plugin does approaches it. The largest inbound payload is an
AIS snapshot, and `lk.zig`'s arena settles at the high-water mark of the largest
single event.

## The queue holds 1024 events, and then drops

Each plugin has its own FIFO. Over the cap, an event is dropped, counted against
that plugin, and logged — the first one and then every thousandth.

| Pressure | What happens |
|---|---|
| Queue at 768 | The I/O thread stops reading **that plugin's** sockets. The backlog waits in the kernel buffer and reaches the peer as TCP window pressure. No data is lost, and no other plugin is affected. |
| Queue at 1024 | Timers and store fanout have nobody to push back on, so they drop. |
| `SHUTDOWN` | Ignores the cap entirely. |

*Separate queues mean a plugin that stops consuming loses only its own events.*

## Unknown event kinds return 0

`lk.registerPlugin` does this for you. If you are writing a plugin without the
Zig library, do it yourself.

*A host must be able to add an event kind without breaking a module built against
an older one.*

## Vessel data goes stale after 5 seconds

The same window applies to every vessel path. The store elects the
first-registered source whose value is inside it; if no source is fresh, the
newest stale value is elected and flagged. `STORE_CHANGED` carries `age_ms`, and that number is already
stale when you read it.

*A mariner needs to see that an instrument has been silent for five seconds, and
one window for every path means nobody has to remember which path uses which.*

Age it on with `mono_ms`, never with the wall clock: a GPS that sets the boat's
clock mid-passage must not make a good fix look ten minutes old. AIS is a
different mechanism with different numbers, because ships report on minute
scales. The store evicts a vessel at 600 s and an aid to navigation at 1800 s,
and the `ais` plugin that ships with Lookout stops drawing a vessel at 180 s and
an aid at 600 s.

## A refused call returns -1 and logs

A call your manifest did not ask for does not trap. Lookout returns -1, counts
it, and writes `denied <call>: manifest does not request capability <name>`.

*A plugin asking for something it was not given is misconfigured, not malicious,
and a stack trace would hide the misconfiguration.*

Check the returns. `subscribe` coming back -1 means you will receive nothing at
all, so the right response is to fail `start`: a plugin that starts cleanly and
then receives nothing is harder to diagnose than one that refuses to start.

[The dev harness](dev-harness.md) prints `N denied call(s)` per plugin at the end
of every run. It should be zero. If it is not, the fix is almost always one more
name in your manifest's `capabilities`.

## Reconnecting is yours

`tcp_connect` returns an id at once and the outcome arrives as `TCP_CONNECTED` or
`TCP_CLOSED`. **The host never retries.** A closed socket stays closed until you
open another one, on a timer, with a backoff you choose. The `nmea0183` plugin
that ships with Lookout waits 2 s.

Reassembly is yours too: one `TCP_DATA` event is one socket read of at most 8192
bytes, which has no relationship to the line boundaries in what the peer sent.

The same rule covers WebSockets: `WS_CLOSED` is the end, and dialling again is
yours. What is **not** yours there is reassembly — the host joins a message's
fragments and answers the peer's pings before you see anything, so one `WS_DATA`
is one whole message. UDP is the third case: one `UDP_DATA` is exactly one
datagram, never two joined and never one split.

## Name every server you reach

`net.http` and `net.ws` are the only capabilities that carry an argument: the
list of hosts you may reach. A URL outside the list returns -1 before a socket
opens, and the log line names the host you asked for.

*A mariner cannot judge "this plugin may reach the internet", and naming the
hosts is what stops a weather plugin from quietly reaching a second server.*

There are no wildcards: a plugin that needs two servers must name both. A
redirect that would leave the host fails the fetch rather than following, because
the list was checked once at the URL you asked for.

When the address is a mariner's setting rather than yours — a Signal K server,
an instrument bridge — write `local`. It grants the boat's own network and
refuses the internet.

## Ask for a range, not a file

A response body is capped at 4 MiB, and the fetch fails rather than truncating.
A GRIB, a chart bundle and a tide table are all bigger than that, so ask for a
range: `{"url":…,"range":"bytes=0-1048575"}`.

*A 4 MiB slice can be decoded inside the watchdog's budget; a 200 MB body is more
than the plugin can hold and more than it can decode in a second.*

Four fetches run at once across every plugin. A fifth returns -1 at once, which
is a signal to try again from a timer, not an error.

## Storage is small, and it is yours alone

`storage_put` writes the file before it returns, so what you saved survives a
trap, a disable and a restart. It is not a database: 64 KiB a value, 1 MiB and
256 keys in total, and another plugin's store is another file that you cannot
read.

*A plugin's saved state is a mariner's settings and a resume point, not a data
store. A weather plugin caches WHICH run it fetched, not the run.*

`storage_get` uses the two-call pattern: it answers with the size, and writes
into your buffer only when the value fits. A key that was never written answers
-1, which is not the same as a key holding nothing.

## You cannot open a file

There is no `file_open`, and there never will be one. A file handle arrives as
`FILE_OPENED` because a mariner chose that file and Lookoutlication granted it.

*A plugin that could name a path could read the chart library, the settings and
the saved credentials of every other plugin on the machine.*

Read with an absolute offset — the handle has no cursor — and expect 0 bytes at
the end of the file rather than an error.

## A plugin has one subscription

Calling `subscribe` again **replaces** the path list rather than adding to it, so
a plugin that re-subscribes on reconnect does not leak handles. There are no
wildcards: name the exact paths.

## Never be silent

This is what every rule above comes back to. When your plugin cannot do its job,
say so, in the place a person will look:

- Post a `degraded` status line and name **every** missing input. "no wind" while
  the GPS is also out sends the mariner after the wrong instrument.
- Take the drawing off the chart. Stale geometry that still looks current is the
  failure mode that puts a boat on a rock.
- Say when a choice was made, not just when something broke. With its alarm
  switched off, the `ais` plugin posts "alarms off" rather than a count of zero,
  because a mariner has to be able to see that the silence was chosen and not
  broken.
- Post a status only on a transition. The host logs every line it has not seen,
  so a 1 Hz repeat is a 1 Hz log line, and the log becomes unreadable.
