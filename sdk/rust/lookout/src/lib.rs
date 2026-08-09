//! The plugin API, in Rust. Declare what you read, and draw.
//!
//! ```ignore
//! use lookout as lk;
//!
//! struct Windline {
//!     boat: lk::Position,
//!     twd: lk::Number,
//! }
//!
//! lk::plugin!(Windline);
//!
//! impl lk::Plugin for Windline {
//!     fn inputs(&mut self) -> Vec<&mut dyn lk::AnyInput> {
//!         vec![&mut self.boat, &mut self.twd]
//!     }
//!
//!     fn draw(&mut self, c: &mut lk::Chart<'_>) {
//!         let from = self.boat.get();
//!         let to = from.destination(self.twd.get() + 180.0, lk::nm(1.0));
//!         c.line("windline", &[from, to], lk::Line::new(lk::Color::Warning).dashed());
//!     }
//! }
//! ```
//!
//! THREE TIERS. Tier 1 is the block above: inputs and `draw`. Tier 2 adds
//! [`ConnSpec`] and [`Source`] — the library owns the sockets, the reconnect
//! clock and the per-row status, and the plugin writes `on_data`. Tier 3 is
//! [`raw`], the whole event set, for whatever the first two do not cover.
//!
//! WHAT THE LIBRARY OWNS, so an author never writes it:
//!
//! * the subscription, and one recorded value per declared input, aged against
//!   the monotonic clock rather than the wall clock;
//! * the draw timer. `draw` runs at [`Plugin::DRAW_RATE_MS`], 1 Hz by default,
//!   not on every store change: the store fans out at up to 10 Hz. It runs only
//!   while there is somewhere for a scene to land, so a plugin whose
//!   `overlay.draw` grant the mariner has switched off stops drawing until it
//!   comes back;
//! * the freshness gate. `draw` runs only when every required input is inside
//!   its window. Otherwise the scene is cleared and the status names every
//!   missing input at once;
//! * the scene. `draw` describes the whole picture each call; the library
//!   compares it with the last one and sends only what changed. An object not
//!   drawn this call is deleted. There is no delete call and no buffer;
//! * the status line, deduped. The host logs every status text it has not
//!   seen, so a repeat would be a log line a second;
//! * the settings, parsed into a typed struct, with the manifest's schema
//!   generated from the same declaration.
//!
//! WHAT A PLUGIN DECLARES. Everything on [`Plugin`] but `draw` has a default,
//! and `draw` itself is empty by default for a plugin that only publishes.
//!
//! | | |
//! |---|---|
//! | `inputs()` | the `Number`, `Position` and `Ais` fields the library feeds |
//! | `draw(c)` | the scene, on the library's timer |
//! | `DRAW_RATE_MS` | how often, default 1000; `0` sets no timer at all |
//! | `on_update()` | after an input changed: the decision, and the rows |
//! | `tables()` | the [`Table`] fields the library declares and sends |
//! | `SETTINGS` | the settings groups, as `SettingsHook::of::<Group>()` |
//! | `on_settings()` | after a settings change, before the redraw |
//! | `on_start(s)` | anything else at startup |
//! | `on_event(e)` | every event the library did not consume (tier 3) |
//! | `on_shutdown()` | the last word |
//!
//! and for tier 2, on [`Source`]: `on_data(conn, bytes)`, `on_open`,
//! `on_close`, `connection_note` and `endpoint`.
//!
//! WHERE A DECISION BELONGS. `on_update` runs the moment a declared input has a
//! new value, with every input already current. It is the clock for work that
//! is not drawing: a plugin that only watches a condition writes `on_update`
//! and no `draw`, and a plugin that does both keeps the decision there and
//! renders it here. `DRAW_RATE_MS` is a graphics rate an author picked, so a
//! decision taken in `draw` runs at whatever rate suits the picture.
//!
//! `on_update` ALSO RUNS WHEN A READING EXPIRES. A plugin that only heard about
//! arrivals could never notice an absence. A reading carries its window, so the
//! moment it stops counting is known when it lands: the library arms a one-shot
//! for the earliest such moment across the declared inputs and runs the cycle
//! there. The input reads stale in that call, and the plugin empties what
//! depended on it. Windows differ, so each input expires on its own wakeup.
//! Nothing polls: once every input has expired there is no next moment, nothing
//! is armed, and an idle plugin costs nothing at all until the next reading
//! arrives. A plugin with no declared inputs has nothing that can expire and
//! hears only about arrivals.
//!
//! The declared inputs decide that, not the methods beside them. A plugin that
//! only draws is woken the same way, because a picture held up by a reading
//! that stopped counting is a confident drawing of a guess and has to come off
//! the chart.
//!
//! A TABLE IS FILLED FROM `on_update`. Rows are data. The library opens a table
//! cycle before that call and closes it after, so a plugin upserts its rows
//! there and nowhere else. A table costs no capability, so its rows keep
//! arriving while the chart grant is off and the draw timer is down.
//!
//! TARGET. `wasm32-wasip1`, `crate-type = ["cdylib"]`. One thread, no
//! filesystem, no sockets but the host's. See [`raw`] for the floor.

pub mod json;
pub mod raw;

mod chart;
mod conn;
mod geo;
mod input;
mod post;
mod settings;
mod table;

pub use chart::{
    Anchor, Area, Chart, Color, Line, Pick, State, Sym, Symbol, MAX_OBJECTS, SCENE_BYTES,
};
pub use conn::{
    ConnOpts, ConnSpec, Connection, Conns, Endpoint, NoConns, RowColumns, RowState, Source,
};
pub use geo::{knots, nm, normalize_deg, wrap_lon, Point, NM_M};
pub use input::{
    subscribe_ais, subscribe_number, subscribe_position, Ais, AnyInput, Input, Number, Optional,
    Position, Required, Target, Value, DEFAULT_MAX_AGE_MS,
};
pub use json::Json;
pub use post::{alert, say, Publish, Upsert};
pub use raw::{log, mono_ms, now_ms, Level, Severity, API_VERSION};
pub use settings::{
    expect_manifest, settings_json, Field, FieldSpec, Fields, Flag, Group, ListInfo, Num,
    SettingsGroup, SettingsHook, Spec, Store, Tab, Text, MAX_FIELDS, MAX_ROWS, MAX_TEXT_BYTES,
};
pub use table::{
    tables_json, Column, ColumnType, Row, Table, TableAt, TableSort, TableSpec, MAX_COLUMNS,
    MAX_TABLE_ROWS, TABLE_INTERVAL_MS,
};

use std::borrow::Cow;
use std::cell::UnsafeCell;

/// How often `draw` runs when the plugin declares no rate.
pub const DEFAULT_DRAW_RATE_MS: i64 = 1_000;

/// `log!(Level::Warn, "{} sentences dropped", n)`.
#[macro_export]
macro_rules! log {
    ($level:expr, $($arg:tt)*) => {
        $crate::log($level, &::std::format!($($arg)*))
    };
}

/// What a handler may fail with. Anything that reads as text does.
#[derive(Debug)]
pub struct Error(pub Cow<'static, str>);

impl From<&'static str> for Error {
    fn from(s: &'static str) -> Self {
        Error(Cow::Borrowed(s))
    }
}

impl From<String> for Error {
    fn from(s: String) -> Self {
        Error(Cow::Owned(s))
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// The result of a handler.
pub type Result<T = ()> = std::result::Result<T, Error>;

/// What a plugin writes. Every method has a default: a plugin that only draws
/// writes `inputs` and `draw`, and one that only publishes writes neither.
///
/// The instance is built with `Default` on the first call into the module.
pub trait Plugin: Default + 'static {
    /// The settings groups this plugin declares.
    ///
    /// ```ignore
    /// const SETTINGS: &'static [lk::SettingsHook] = &[lk::SettingsHook::of::<Display>()];
    /// ```
    const SETTINGS: &'static [SettingsHook] = &[];

    /// How often `draw` runs. `0` sets no timer, for a plugin that draws
    /// nothing.
    const DRAW_RATE_MS: i64 = DEFAULT_DRAW_RATE_MS;

    /// The inputs the library feeds and ages. List every `Number`, `Position`
    /// and `Ais` field the plugin holds; anything left out is never fed.
    fn inputs(&mut self) -> Vec<&mut dyn AnyInput> {
        Vec::new()
    }

    /// The dialogs the library declares, opens and sends rows for. List every
    /// [`Table`] field the plugin holds; anything left out is never declared.
    fn tables(&mut self) -> Vec<&mut Table> {
        Vec::new()
    }

    /// The data path: a batch of readings has landed and every declared input
    /// holds its new value. Decide here, and fill any table here.
    fn on_update(&mut self) {}

    /// The whole scene, every call. The library sends the difference.
    fn draw(&mut self, chart: &mut Chart<'_>) {
        let _ = chart;
    }

    /// After a settings change, before the redraw.
    fn on_settings(&mut self) {}

    /// Anything else at startup. The subscription, the timer and the
    /// connections are already made.
    fn on_start(&mut self, start: &raw::Start<'_>) -> Result {
        let _ = start;
        Ok(())
    }

    /// Every event the library did not consume: tier 3, beneath the tiers.
    fn on_event(&mut self, event: &raw::Event<'_>) -> Result {
        let _ = event;
        Ok(())
    }

    /// The last word. Sockets and timers are closed for you.
    fn on_shutdown(&mut self) {}
}

/// A global with no lock. Sound here and nowhere else: wasm32 without the
/// threads proposal has exactly one thread, and the host contract is one call
/// into the module at a time.
pub(crate) struct Single<T>(UnsafeCell<T>);

unsafe impl<T> Sync for Single<T> {}

impl<T> Single<T> {
    pub(crate) const fn new(value: T) -> Single<T> {
        Single(UnsafeCell::new(value))
    }

    #[allow(clippy::mut_from_ref)]
    pub(crate) fn get(&self) -> &mut T {
        unsafe { &mut *self.0.get() }
    }
}

/// The plumbing [`plugin!`] and [`register!`] call. Public because a macro
/// expands in your crate, not in this one; there is nothing here to call by
/// hand.
#[doc(hidden)]
pub mod rt;

/// Write the five exports and wire them to your plugin. Call it once, at
/// the top level of your crate, with the plugin's type:
///
/// ```ignore
/// lookout::plugin!(Windline);                        // tiers 1 and 3
/// lookout::plugin!(SignalK, connections: Servers);   // tier 2
/// ```
///
/// The plugin is built with `Default` on the first `lk_start`, not at load
/// time.
#[macro_export]
macro_rules! plugin {
    ($plugin:ty) => {
        $crate::plugin!($plugin, connections: $crate::NoConns);
    };
    ($plugin:ty, connections: $conns:ty) => {
        #[no_mangle]
        pub extern "C" fn lk_abi() -> u32 {
            $crate::rt::api()
        }

        #[no_mangle]
        pub extern "C" fn lk_alloc(len: u32) -> u32 {
            $crate::rt::alloc(len)
        }

        #[no_mangle]
        pub extern "C" fn lk_free(ptr: u32, len: u32) {
            $crate::rt::free(ptr, len)
        }

        #[no_mangle]
        pub extern "C" fn lk_start(ptr: u32, len: u32) -> i32 {
            $crate::rt::start::<$plugin, $conns>(ptr, len)
        }

        #[no_mangle]
        pub extern "C" fn lk_event(kind: u32, handle: i64, ptr: u32, len: u32) -> i32 {
            $crate::rt::event::<$plugin, $conns>(kind, handle, ptr, len)
        }
    };
}

/// Write the five exports for a TIER 3 plugin: one that handles the raw
/// events itself. [`plugin!`] is what a tier 1 or tier 2 plugin uses.
///
/// ```ignore
/// lookout::register!(Probe);
/// ```
#[macro_export]
macro_rules! register {
    ($plugin:ty) => {
        #[no_mangle]
        pub extern "C" fn lk_abi() -> u32 {
            $crate::rt::api()
        }

        #[no_mangle]
        pub extern "C" fn lk_alloc(len: u32) -> u32 {
            $crate::rt::alloc(len)
        }

        #[no_mangle]
        pub extern "C" fn lk_free(ptr: u32, len: u32) {
            $crate::rt::free(ptr, len)
        }

        #[no_mangle]
        pub extern "C" fn lk_start(ptr: u32, len: u32) -> i32 {
            $crate::rt::raw_start::<$plugin>(ptr, len)
        }

        #[no_mangle]
        pub extern "C" fn lk_event(kind: u32, handle: i64, ptr: u32, len: u32) -> i32 {
            $crate::rt::raw_event::<$plugin>(kind, handle, ptr, len)
        }
    };
}
