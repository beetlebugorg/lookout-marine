# The Rust SDK: the listings

Every entry point of `sdk/rust/lookout` on the lk v2 surface, one minimal
listing each. The docs may take these verbatim. Each listing compiles as
written for `wasm32-wasip1`, apart from the parser bodies marked `…`.

The names are the Zig library's names in Rust idiom: `Plugin`, `Chart`,
`Number`, `Position`, `Ais`, `Publish`, `Upsert`, `ConnSpec`, `Source`, `Connection`,
`Endpoint`, `SettingsHook`. A plugin author reads the same API in either
language.

## The crate

```toml
# Cargo.toml
[package]
name = "windline"
version = "0.1.0"
edition = "2021"

[lib]
# cdylib is what makes wasm-ld keep the five exports and emit a reactor with
# no _start. Cargo fixes the file name; rename the artifact to the plugin's id
# when you copy it into a plugin directory.
crate-type = ["cdylib"]

[dependencies]
lookout = { path = "../../lookout" }

[profile.release]
opt-level = "s"
lto = true
codegen-units = 1
panic = "abort"
strip = true
```

```sh
rustup target add wasm32-wasip1
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/windline.wasm \
   zig-out/plugins/org.example.windline.rs.wasm
cp manifest.json zig-out/plugins/org.example.windline.rs.manifest.json
```

The example in this repository is a member of the `sdk/rust` workspace, so its
artifact lands in `sdk/rust/target/wasm32-wasip1/release/windline.wasm` and it
takes the workspace's release profile.

`cargo test` runs on the development machine. Off wasm every host call answers
"refused", so the geodesy, the scene diff, the settings schema and the
connection list are all testable without a boat or an emulator.

## Tier 1 — a drawing plugin

The whole of `sdk/rust/examples/windline/src/lib.rs`, less its header comment.

```rust
use lookout as lk;

struct Windline {
    boat: lk::Position,
    twd: lk::Number,
}

impl Default for Windline {
    fn default() -> Self {
        Windline {
            boat: lk::subscribe_position("navigation.position"),
            twd: lk::subscribe_number("environment.wind.directionTrue").label("wind"),
        }
    }
}

lk::plugin!(Windline);

impl lk::Plugin for Windline {
    fn inputs(&mut self) -> Vec<&mut dyn lk::AnyInput> {
        vec![&mut self.boat, &mut self.twd]
    }

    fn draw(&mut self, c: &mut lk::Chart<'_>) {
        let from = self.boat.get();
        // The wind direction is where the wind blows FROM, so downwind is the
        // reciprocal.
        let to = from.destination(self.twd.get() + 180.0, lk::nm(1.0));
        c.line(
            "windline",
            &[from, to],
            lk::Line::new(lk::Color::Warning).dashed(),
        );
    }
}
```

`plugin!` writes the five exports and builds the plugin with `Default` on
the first call. The library subscribes to both paths, records and ages what
arrives, runs `draw` once a second, and sends the difference between this
scene and the last. A reading older than 5 s takes the line off the chart and
posts `degraded, no position, no wind`.

## Inputs

An input is a field. Anything left out of `inputs()` is never fed.

```rust
struct Instruments {
    boat: lk::Position,                     // required, 5 s window
    twd: lk::Number,                        // required, named "wind" when missing
    depth: lk::Number<lk::Optional>,        // never holds the draw
    traffic: lk::Ais,                       // the AIS target set
}

impl Default for Instruments {
    fn default() -> Self {
        Instruments {
            boat: lk::subscribe_position("navigation.position"),
            twd: lk::subscribe_number("environment.wind.directionTrue").label("wind"),
            depth: lk::subscribe_number("environment.depth.belowKeel")
                .max_age(10_000)
                .optional(),
            traffic: lk::subscribe_ais(256),
        }
    }
}
```

* `get()` is on a required input only, and is correct inside `draw`, where the
  library has already gated on freshness.
* `fresh()` answers `None` past the window, and is correct anywhere. An
  optional input has no `get`: the compiler says so.
* `Ais` never holds `draw`, because an empty sea is not a missing instrument.

## Reading AIS traffic

```rust
fn draw(&mut self, c: &mut lk::Chart<'_>) {
    for t in self.traffic.targets() {
        let at = match t.at {
            Some(at) => at,
            None => continue,
        };
        c.symbol(
            &format!("t{}", t.mmsi),
            lk::Sym::Target,
            at,
            lk::Symbol::new(lk::Color::Target)
                .rot(t.cog_deg.unwrap_or(0.0))
                .pick(lk::Pick::new(t.name()).row(
                    "SOG",
                    format!("{:.1} kn", lk::knots(t.sog_mps.unwrap_or(0.0))),
                )),
        );
    }
}
```

`t.age_ms` is the age at the snapshot; `self.traffic.age_ms(t)` adds the time
since it arrived.

## Drawing

Describe the whole picture every call. An object with the same id and the same
shape as last call is not resent; one you did not draw is taken off the chart.

```rust
c.line("track", &points, lk::Line::new(lk::Color::Track).width(2.0));
c.line("heading", &[boat, ahead], lk::Line::new(lk::Color::Ownship).on_ownship());
c.symbol("ownship", lk::Sym::Ownship, boat,
         lk::Symbol::new(lk::Color::Ownship).rot(heading_deg).on_ownship());
c.area("guard", &ring, lk::Area::new(lk::Color::Warning).alpha(0.25));
```

## The status line

```rust
c.status(&format!("TWD {:.0} deg", twd));   // running
c.degraded("no depth sounder");             // short of something, and which
```

Posted once. The library sends nothing while the text is unchanged, and writes
the degraded line itself when a required input is stale.

## Settings

```rust
lk::settings! {
    pub struct Display {
        group: "Downwind line",
        tab: Display,
        length_nm: Num {
            label: "Line length",
            desc: "How far downwind the line reaches.",
            unit: "nm", min: 0.1, max: 10.0, default: 1.0,
        },
        dashed: Flag { label: "Dashed", default: true },
    }
}

impl lk::Plugin for Windline {
    const SETTINGS: &'static [lk::SettingsHook] = &[lk::SettingsHook::of::<Display>()];

    fn draw(&mut self, c: &mut lk::Chart<'_>) {
        let s = Display::get();
        let to = self.boat.get().destination(self.twd.get() + 180.0, lk::nm(s.length_nm));
        …
    }
}
```

`Display::get()` is the live values: `f64` for a `Num`, `bool` for a `Flag`.
The library parses the host's config into them at start and on every change,
clamping each number into its declared range, and calls `draw` again. A value
of the wrong type is refused rather than coerced.

The same declaration is the manifest's schema. Check them against each other
in the plugin's own test:

```rust
#[test]
fn the_manifest_carries_the_schema_the_settings_struct_declares() {
    lookout::expect_manifest(include_str!("../manifest.json"), &[Display::schema()]).unwrap();
}
```

The error prints the JSON to paste into the manifest. `lookout::settings_json`
returns the same text on its own.

## Tier 2 — a source plugin

The library owns the connections end to end: the settings list schema, one
socket per connection, the reconnect clock, the pause switch, the per-row
status item and the plugin's status line. The plugin writes the protocol.

```rust
use lookout as lk;

lk::columns! {
    pub struct SkColumns {
        websocket: Flag {
            label: "WebSocket",
            desc: "Connect with a websocket instead of a plain TCP stream.",
            default: false,
        },
    }
}

struct Servers;

impl lk::ConnSpec for Servers {
    type Columns = SkColumns;       // beyond the four every list carries
    type State = Vec<u8>;           // per-connection parse state: the partial line
    const OPTS: lk::ConnOpts = lk::ConnOpts {
        key: "servers",
        group: "Signal K servers",
        add_label: "Add Server",
        status_empty: "no servers",
        rate_noun: "delta",
        columns: lk::RowColumns {
            port: lk::Num {
                label: "Port",
                desc: "The port to connect to.",
                unit: "",
                min: 1.0,
                max: 65535.0,
                default: 8375.0,
            },
            ..lk::RowColumns::DEFAULT
        },
        ..lk::ConnOpts::DEFAULT
    };
}

#[derive(Default)]
struct SignalK;

lk::plugin!(SignalK, connections: Servers);

impl lk::Plugin for SignalK {
    // It publishes and draws nothing, so it asks for no draw timer.
    const DRAW_RATE_MS: i64 = 0;
}

impl lk::Source<Servers> for SignalK {
    /// A stream came up. Send the subscription here.
    fn on_open(&mut self, conn: &mut lk::Connection<Servers>) {
        conn.send(br#"{"context":"vessels.self","subscribe":[{"path":"*"}]}"#);
    }

    /// Bytes from one connection's socket.
    fn on_data(&mut self, conn: &mut lk::Connection<Servers>, bytes: &[u8]) {
        conn.state.extend_from_slice(bytes);
        while let Some(at) = conn.state.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = conn.state.drain(..=at).collect();
            conn.count(1);
            let (path, value) = …;
            let mut p = lk::Publish::begin();
            p.number(path, value);
            p.send();
        }
    }

    /// Where to dial, when it is not the connection's host and port.
    fn endpoint(&mut self, conn: &lk::Connection<Servers>) -> lk::Endpoint {
        if conn.cols.websocket {
            lk::Endpoint::Ws(format!("ws://{}:{}/signalk/v1/stream", conn.host, conn.port))
        } else {
            lk::Endpoint::Tcp {
                host: conn.host.clone(),
                port: conn.port,
            }
        }
    }
}
```

`Servers::schema()` is this list's entry in the manifest, and goes in the same
`expect_manifest` call as the scalar groups. It is a trait method, so the test
needs `use lookout::ConnSpec;` in scope; `Display::get()` and
`Display::schema()` are inherent and need no import.

The other two hooks are `on_close(conn)` and `connection_note(conn) -> String`, which
adds a phrase after the connection's rate.

## Publishing

```rust
let mut p = lk::Publish::begin();
p.number("navigation.speedOverGround", mps);
p.position("navigation.position", lk::Point::new(lat, lon));
p.clear("environment.depth.belowKeel");   // held, and no reading right now
p.send();
```

```rust
let mut u = lk::Upsert::begin();
u.target(&lk::Target {
    mmsi: 366_987_650,
    at: Some(lk::Point::new(lat, lon)),
    sog_mps: Some(mps),
    cog_deg: Some(cog),
    ..Default::default()
});
u.send();
```

Both stamp the host's wall clock, which is what the store ages against. `sog`
is metres per second: everything crossing the API is SI.

## Alarms

```rust
lk::alert(lk::Severity::Alarm, "Collision risk", &format!("{} at {:.1} nm", name, cpa_nm));
```

Needs `alerts.raise`. Raise one when the mariner must act now and would not
otherwise know. Everything else is a status line.

## Tier 3 — the raw events

For whatever the declared surface does not cover. `register!` hands over every
event with nothing consumed.

```rust
use lookout::raw;

#[derive(Default)]
struct Probe {
    timer: i64,
}

lookout::register!(Probe);

impl raw::RawPlugin for Probe {
    fn start(&mut self, _s: raw::Start<'_>) -> lookout::Result {
        self.timer = raw::timer_set(1_000, true);
        raw::subscribe_paths(&["navigation.position"]);
        Ok(())
    }

    fn on_event(&mut self, e: raw::Event<'_>) -> lookout::Result {
        match e {
            raw::Event::StoreChanged(payload) => {
                for r in raw::readings(payload) { … }
            }
            raw::Event::Timer(id) if id == self.timer => …,
            _ => {}
        }
        Ok(())
    }
}
```

Any plugin reaches the same calls through `lk::raw` without
giving up the library: storage, HTTP, UDP, files and the WebSocket calls all
live there.

```rust
lk::raw::storage_put("last-fix", &bytes);
lk::raw::http_fetch(&lk::raw::HttpRequest::get("https://tiles.example.org/x"));
```

`Plugin::on_event` receives every event the library did not consume, so a
drawing plugin can answer an HTTP response without giving anything up.

## Acting on a reading, and filling a dialog

`Plugin::on_update` runs the moment a batch of readings lands, with every input
already holding its new value. Decide there rather than in `draw`, whose rate is
one you chose for the picture.

A table is a dialog the shell builds from a `TableSpec`. List it in
`Plugin::tables` and the library declares it at start, tells you when the
mariner opens it, and sends what changed once a cycle.

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

struct Ais {
    targets: lk::Table,
}

impl Default for Ais {
    fn default() -> Self {
        Ais { targets: lk::Table::new(TARGETS) }
    }
}

impl lk::Plugin for Ais {
    fn tables(&mut self) -> Vec<&mut lk::Table> {
        vec![&mut self.targets]
    }

    fn on_update(&mut self) {
        if !self.targets.is_open() {
            return;
        }
        self.targets
            .row("899000101")
            .band(0)
            .text("name", Some("ANNE"))
            .num("cpa", Some(124.0))
            .at(lk::Point::new(38.97, -76.46))
            .done();
    }
}
```

The rows are written from `on_update` and nowhere else: the library opens a
cycle before that call and sends what changed after it. A row the cycle does
not describe leaves the table. `text` and `num` take an `Option`, and `None` is
a dash on screen. `lk::tables_json(&[&self.targets])` renders the `"tables"`
array the manifest must carry, for a `cargo test` to compare.

## The chart grant

The library reads `GRANTS_CHANGED` and follows `overlay.draw`. When the grant
goes it cancels the draw timer, forgets the scene diff and posts one status line
saying why the chart is empty; when it comes back it arms the timer and sends
the whole scene again. `on_update` and the tables carry on throughout: a table
costs no capability.

`lk::raw::granted(payload, "overlay.draw")` reads the payload, for a tier-3
plugin that handles the event itself.

## What it costs

| | Zig | Rust |
|---|---|---|
| windline, less its header and blank lines | 15 lines | 30 lines |
| the library, tests and raw calls included | 3846 lines in `plugins/common` | 5548 lines in `sdk/rust/lookout/src` |
| the built module | 82 KiB (laylines) | 110 KiB |

The Rust plugin is longer by its `Default` impl and its `inputs()` list, which
Zig reads off the `inputs` struct at comptime. The module is larger by what
`format!` and the allocator pull in.
