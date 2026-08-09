---
id: subscribing
title: Subscribing to data
---

import Tabs from '@theme/Tabs';
import TabItem from '@theme/TabItem';

# Subscribing to data

**Capabilities:** `vessel.read`, and `ais.read` for the AIS targets.

Your plugin subscribes by declaring inputs. When your plugin starts, Lookout
reads your `inputs` declaration and delivers each path's values from then
on.

```zig
pub const inputs = struct {
    pub const boat = lk.subscribePosition("navigation.position", .{});
    pub const twd = lk.subscribeNumber("environment.wind.directionTrue", .{ .label = "wind" });
    pub const depth = lk.subscribeNumber("environment.depth.belowTransducer", .{
        .max_age_ms = 10_000,
        .optional = true,
    });
    pub const traffic = lk.subscribeAis(.{});
};
```

| Declaration | What it holds |
|---|---|
| `lk.subscribeNumber(path, opts)` | an `f64` off the vessel store |
| `lk.subscribePosition(path, opts)` | an `lk.Point` off the vessel store |
| `lk.subscribeAis(.{ .max = 128 })` | the AIS target set |

Every value carries its age: the time since it arrived, measured on the
monotonic clock. A reading is **fresh** while its age is under the input's
`max_age_ms`, 5 seconds unless the declaration says otherwise. Past that it
is **stale**.

`opts` is an `lk.InputOpts`:

| Field | Default | What it does |
|---|---|---|
| `label` | the last segment of the path | what the status line calls this reading when it is missing |
| `max_age_ms` | `5_000` | how old the value may be and still count as fresh |
| `optional` | `false` | takes the input out of the freshness gate and out of the status line |

The paths are the vessel store's own: `navigation.position`,
`navigation.speedOverGround`, `environment.wind.directionTrue`,
`environment.depth.belowTransducer` and the rest.
[Capabilities and store data](glossary.md) lists every path the shipped
plugins fill, by plugin.

## Reading an input

Which call you use follows from the declaration. A required input is read
with `get()`. Lookout does not call your `draw` function until every required
input is fresh, so inside it the value is always current. An optional input is read with
`fresh()`, which returns null when the value is missing or older than its
window. Either kind answers `ageMs()` with the value's age, or null when
nothing has arrived yet.

An optional input has no `get`, and calling it is a compile error. The error
names both ways out: read it with `fresh()` and handle the null, or drop
`.optional = true` and let Lookout wait for the value before it calls your
`draw` function.

Lookout calls your `onData` function when bytes arrive, not on the draw
timer, so the freshness gate has not run there. Read inputs with `fresh()`
inside `onData`.

## Acting on a reading as it arrives

Declare an update hook and Lookout calls it the moment a batch of readings
lands, with every input already holding its new value. It is the clock for
work that is not drawing. A plugin that only watches a condition declares the
update hook and no `draw` at all.

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
pub fn onUpdate() void {
    const d = inputs.depth.fresh() orelse return;
    const shallow = d < limit;
    if (shallow and !was_shallow) _ = lk.alert(.alarm, "Shallow water", "under the limit");
    was_shallow = shallow;
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
func (p *sounder) OnUpdate() {
	d, ok := depth.Fresh()
	if !ok {
		return
	}
	shallow := d < p.Settings.Limit
	if shallow && !p.wasShallow {
		lk.Alert(lk.Alarm, "Shallow water", "under the limit")
	}
	p.wasShallow = shallow
}
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
fn on_update(&mut self) {
    let Some(d) = self.depth.fresh() else {
        return;
    };
    let shallow = d < self.limit;
    if shallow && !self.was_shallow {
        lk::alert(lk::Severity::Alarm, "Shallow water", "under the limit");
    }
    self.was_shallow = shallow;
}
```

</TabItem>
</Tabs>

The draw rate is a graphics rate you chose for the picture. Decide in the
update hook and draw the decision, so how often the chart is redrawn cannot
change how quickly your plugin reacts. Keep the latch that stops one condition
becoming a run of alarms in the update hook too: it runs far more often than
your `draw` function does.

Lookout coalesces, so the update hook runs once for a batch and not once per
reading: at most 10 times a second for store readings, twice a second for the
AIS set, and less than either when the instruments report more slowly. It
does not run for a batch that touched none of your declared inputs, and a
settings change calls your settings hook instead.

Inside the update hook the freshness gate has not run, so read a required
input with `fresh()` here rather than `get()`.

## Acting on a reading that has expired

A plugin that only heard about arrivals could never notice an absence. Lookout
calls the update hook when a reading expires as well, so one function covers
both cases: the reading is there, or it has gone.

A reading carries its window, so the moment it stops counting is known when it
lands. Lookout takes the earliest such moment across your declared inputs and
wakes your plugin then. Read the input with `fresh()` in that call and it
answers null. Empty the rows that depended on it, clear the condition you were
watching, and say what is missing.

Windows differ, so each input expires on its own wakeup and you can tell which
reading went. Nothing polls. Once every input has expired there is no next
moment, nothing is armed, and a plugin on a boat with the instruments off costs
nothing until a reading arrives. That arrival runs the cycle and sets the next
wakeup.

The inputs you declare decide this, not the hooks beside them. A plugin that
only draws is woken the same way, because a picture held up by a reading that
stopped counting is a confident drawing of a guess and has to come off the
chart.

A plugin that declares no inputs has nothing that can expire, so it hears about
arrivals alone. A plugin that watches its own connection for silence keeps its
own clock.

## Ageing an AIS target out

The AIS set expires one target at a time. Each target ages on the window for
its kind, and Lookout wakes your plugin as each crosses it, so a target that
stops reporting leaves the chart and the dialog whether or not any other target
is still being heard. Set the two windows to the ages at which your plugin
drops a target. An aid to navigation reports about every three minutes, which
is why it has a window of its own.

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
pub const traffic = lk.subscribeAis(.{
    .max = 256,
    .max_age_ms = 180_000,
    .aton_max_age_ms = 600_000,
});
```

</TabItem>
<TabItem value="go" label="Go">

```go
var traffic = lk.SubscribeAIS(lk.AISOpts{
	Max:        256,
	MaxAge:     180 * time.Second,
	AtonMaxAge: 600 * time.Second,
})
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
traffic: lk::subscribe_ais(256)
    .max_age(180_000)
    .aton_max_age(600_000),
```

</TabItem>
</Tabs>

Leave them alone and they sit at the host's own eviction clocks, ten minutes
for a vessel and thirty for an aid. Past those the target is out of the store
and no snapshot can carry it again.

## Filling a dialog

A table is a dialog the shell builds from your declaration, opens from a menu,
and sorts by any column. Declare one and Lookout tells the host about it at
startup, so the mariner finds it in the menu whether or not your plugin has
anything to put in it yet.

<Tabs groupId="plugin-language">
<TabItem value="zig" label="Zig" default>

```zig
pub const Targets = lk.table(.{
    .key = "targets",
    .title = "AIS Targets",
    .menu = "Vessels",
    .columns = &.{
        .{ .key = "name", .label = "Vessel", .type = .text },
        .{ .key = "cpa", .label = "CPA", .type = .distance },
        .{ .key = "state", .label = "", .type = .flag },
    },
    .sort = .{ .key = "cpa", .ascending = true },
    .at = .{ .lat = "lat", .lon = "lon" },
});

pub fn onUpdate() void {
    if (!Targets.isOpen()) return;
    for (inputs.traffic.targets()) |*t| {
        const at = t.at orelse continue;
        Targets.upsert(.{
            .id = mmsiText(t.mmsi),
            .band = @as(i32, if (danger(t)) 0 else 1),
            .name = if (t.name().len > 0) t.name() else null,
            .cpa = cpaOf(t),
            .state = @as(?[]const u8, if (danger(t)) "alarm" else null),
            .lat = at.lat,
            .lon = at.lon,
        });
    }
}
```

</TabItem>
<TabItem value="go" label="Go">

```go
var targets = lk.NewTable(lk.TableOpts{
	Key: "targets", Title: "AIS Targets", Menu: "Vessels",
	Columns: []lk.Column{
		{Key: "name", Label: "Vessel", Type: lk.ColText},
		{Key: "cpa", Label: "CPA", Type: lk.ColDistance},
		{Key: "state", Type: lk.ColFlag},
	},
	Sort: &lk.TableSort{Key: "cpa", Ascending: true},
	At:   &lk.TableAt{Lat: "lat", Lon: "lon"},
})

func (p *ais) OnUpdate() {
	if !targets.IsOpen() {
		return
	}
	for _, t := range traffic.Targets() {
		at, ok := t.At()
		if !ok {
			continue
		}
		r := targets.Row(mmsiText(t.MMSI))
		r.Band(band(t))
		r.Cell("name", t.Name)
		r.Cell("cpa", cpaOf(t))
		r.Cell("state", stateOf(t))
		r.At(at)
		r.Done()
	}
}
```

</TabItem>
<TabItem value="rust" label="Rust">

```rust
const TARGETS: lk::TableSpec = lk::TableSpec {
    key: "targets",
    title: "AIS Targets",
    menu: "Vessels",
    columns: &[
        lk::Column::text("name", "Vessel"),
        lk::Column::new("cpa", "CPA", lk::ColumnType::Distance),
        lk::Column::flag("state"),
    ],
    sort: Some(lk::TableSort::by("cpa")),
    at: Some(lk::TableAt { lat: "lat", lon: "lon" }),
};

fn tables(&mut self) -> Vec<&mut lk::Table> {
    vec![&mut self.targets]
}

fn on_update(&mut self) {
    if !self.targets.is_open() {
        return;
    }
    for t in self.traffic.targets() {
        let Some((lat, lon)) = t.at() else { continue };
        self.targets
            .row(&t.mmsi.to_string())
            .band(band(t))
            .text("name", t.name.as_deref())
            .num("cpa", cpa_of(t))
            .text("state", state_of(t))
            .at(lk::Point::new(lat, lon))
            .done();
    }
}
```

</TabItem>
</Tabs>

**A table is filled from the update hook.** Rows are data, and a plugin with no
permission to draw still has a dialog to fill, so Lookout runs the table cycle
on the data path and not on the draw timer. A table-only plugin declares its
inputs, its table and the update hook, and no `draw` at all. Rows written
anywhere else are dropped, because no cycle is open to hold them.

Describe the whole set on each call, the way your `draw` function describes the
whole picture. A row you do not write leaves the table. There is no delete
call.

Building rows costs nothing while nobody is looking: ask the table whether it
is open and return if it is not. Lookout fills the dialog the moment the
mariner opens it, and sends at most one batch a second after that, however
fast the readings arrive.

Every value in a row is SI, as it is everywhere else: metres, metres per
second, degrees true, seconds. The shell formats each one in the mariner's own
units, and that is what lets it sort a column numerically.

| Field in the declaration | What it is |
|---|---|
| `key` | names the table on the wire and in the manifest |
| `title` | the dialog's own name |
| `menu` | the shell menu that opens it |
| `columns` | `key`, `label` and a type: `distance`, `speed`, `bearing`, `duration`, `number`, `text` or `flag` |
| `sort` | the column the shell sorts by until the mariner says otherwise |
| `at` | the two row keys carrying a position, which makes a row locatable |

A row also carries `id`, which names it for its whole life, and `band`. The
band is the ordering policy: band 0 sorts above band 1, and the mariner's
column sort never crosses a band. Put an alarmed row in band 0 and it holds the
top of the table whatever column the mariner sorted by.

The manifest carries the same declaration. `lk.expectTables` in Zig,
`lk.TablesJSON` in Go and `lk::tables_json` in Rust each render it, so your
plugin's own test compares the two.

## When a reading goes stale

A reading goes stale when its age passes `max_age_ms`. When a required
reading goes stale, Lookout clears everything your plugin drew, skips the
call to your `draw` function, and posts one degraded line naming every
missing input at once: `no wind, no
position`. Naming all of them matters: a line that says only "no wind" while
the GPS is also out sends the mariner to the wrong instrument. The word in
that list is the input's `label`.

An empty AIS set never stops Lookout calling your `draw` function. No
targets in range is a normal condition, not a missing instrument.

## Reading AIS targets

Declaring `lk.subscribeAis(.{})` subscribes the plugin to the AIS target set: one
entry for every vessel and aid to navigation Lookout has heard.
`inputs.traffic.targets()` returns the whole set and
`inputs.traffic.find(mmsi)` returns one target or null. Both read the last
snapshot, so they answer inside your `draw` function and inside the update hook
alike.

Each target carries the fields below. A field the vessel has not broadcast is
null: never heard and heard as zero are different readings.

| Field | Type | Note |
|---|---|---|
| `mmsi` | `u32` | |
| `at` | `?lk.Point` | |
| `sog_mps` | `?f64` | metres per second |
| `cog_deg`, `heading_deg` | `?f64` | degrees true |
| `aton`, `virtual_aton` | `bool` | an aid to navigation, and one that exists only as a broadcast |
| `aton_type` | `?u8` | |
| `off_position` | `?bool` | |
| `age_ms` | `i64` | |
| `name()` | `[]const u8` | cut at 32 bytes |

A target that stops being heard drops out of the set. Draw from the set each
call and Lookout takes the symbol off the chart for you.
