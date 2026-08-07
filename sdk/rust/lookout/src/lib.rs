//! The plugin side of the Lookout ABI, in Rust.
//!
//! # This public surface is PROVISIONAL
//!
//! The plugin-facing API is being simplified — declarative inputs with their own
//! freshness, a draw callback over a retained scene, typed settings, managed
//! connections — and this crate will be rewritten to that shape. What is below
//! mirrors today's `plugins/common/lk.zig` and will not survive as it stands.
//!
//! What IS settled, and what this crate is worth reading for, is everything
//! between the language and the ABI: the `wasm_import_module` bindings, the
//! `lk_alloc` and `lk_free` layouts, the `register!` macro that plants the five
//! exports in the user's crate, the dependency-free JSON reader, and the fact
//! that `std` works on the host's WASI floor. That plumbing carries over
//! unchanged.
//!
//! Add this crate, write one `impl`, call one macro, and you have a plugin.
//!
//! ```ignore
//! use lookout as lk;
//!
//! #[derive(Default)]
//! struct Windline { timer: i64 }
//!
//! lk::register!(Windline::default());
//!
//! impl lk::Plugin for Windline {
//!     fn start(&mut self, _s: lk::Start) -> lk::Result {
//!         lk::subscribe_paths(&["navigation.position"]);
//!         self.timer = lk::timer_set(1000, true);
//!         Ok(())
//!     }
//!
//!     fn on_event(&mut self, e: lk::Event) -> lk::Result {
//!         if let lk::Event::Timer(id) = e { if id == self.timer { /* draw */ } }
//!         Ok(())
//!     }
//! }
//! ```
//!
//! `register!` writes the five exports the ABI requires — `lk_abi`,
//! `lk_alloc`, `lk_free`, `lk_start`, `lk_event` — and routes the last two to
//! your two methods. An event kind it does not recognise is answered 0 without
//! reaching you, which is what the ABI says must happen.
//!
//! # Target and crate type
//!
//! `wasm32-wasip1`, `crate-type = ["cdylib"]`. `no_std` is not required: the
//! standard library boots on the floor the host provides, so `String`, `Vec`,
//! `format!` and `std::time` all work.
//!
//! # Single-threaded, and it is not a suggestion
//!
//! One plugin is one thread, and it runs only while the host is inside one of
//! your exports. There are no threads to spawn — `std::thread::spawn` fails —
//! and `std::thread::sleep` does not sleep, it panics, because the host
//! refuses the WASI call that would park the thread. So:
//!
//! * Do the work in the handler and return.
//! * To wake up later, ask for [`timer_set`] and handle [`Event::Timer`].
//! * To read a socket, ask for [`tcp_connect`] and handle [`Event::TcpData`].
//!
//! The reason is time isolation, not taste. The host gives every call into
//! your module a budget and kills the instance when it runs out, so that a
//! plugin that stops answering delays nobody but itself.
//!
//! # What WASI gives you, which is almost nothing
//!
//! Clocks, randomness, and stdout and stderr. Nothing else. There is no
//! filesystem — `File::open` fails on every path — no sockets, no environment
//! variables and no arguments. `println!` works and goes to your plugin's log,
//! one line per call.
//!
//! # Panics
//!
//! A panic unwinds into a trap, the host tears the instance down and the
//! plugin lands at `failed`. Build with `panic = "abort"` and the message
//! still reaches your log through stderr. Do not panic on data off the wire.

use std::borrow::Cow;

pub mod json;
pub use json::Json;

/// The ABI version this library speaks. `lk_abi` returns it.
pub const ABI_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// The host imports, exactly as the ABI freezes them
// ---------------------------------------------------------------------------

#[link(wasm_import_module = "lookout")]
extern "C" {
    #[link_name = "log"]
    fn host_log(level: u32, ptr: *const u8, len: u32);
    #[link_name = "now_ms"]
    fn host_now_ms() -> i64;
    #[link_name = "mono_ms"]
    fn host_mono_ms() -> i64;
    #[link_name = "publish"]
    fn host_publish(ptr: *const u8, len: u32) -> i32;
    #[link_name = "ais_upsert"]
    fn host_ais_upsert(ptr: *const u8, len: u32) -> i32;
    #[link_name = "overlay"]
    fn host_overlay(ptr: *const u8, len: u32) -> i32;
    #[link_name = "chrome_status"]
    fn host_chrome_status(ptr: *const u8, len: u32);
    #[link_name = "alert"]
    fn host_alert(ptr: *const u8, len: u32) -> i32;
    #[link_name = "tcp_connect"]
    fn host_tcp_connect(host_ptr: *const u8, host_len: u32, port: u32) -> i64;
    #[link_name = "tcp_send"]
    fn host_tcp_send(id: i64, ptr: *const u8, len: u32) -> i32;
    #[link_name = "tcp_close"]
    fn host_tcp_close(id: i64);
    #[link_name = "timer_set"]
    fn host_timer_set(delay_ms: i64, periodic: u32) -> i64;
    #[link_name = "timer_cancel"]
    fn host_timer_cancel(id: i64);
    #[link_name = "subscribe"]
    fn host_subscribe(ptr: *const u8, len: u32) -> i32;
    #[link_name = "ais_subscribe"]
    fn host_ais_subscribe() -> i32;
}

// ---------------------------------------------------------------------------
// Logging and clocks — no capability needed for either
// ---------------------------------------------------------------------------

/// How loud a log line is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum Level {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

/// Write one line. Nothing is added: no prefix, no newline. The host stamps
/// the plugin id and the level.
pub fn log(level: Level, msg: &str) {
    unsafe { host_log(level as u32, msg.as_ptr(), msg.len() as u32) }
}

/// `log!(Warn, "{} sentences dropped", n)`.
#[macro_export]
macro_rules! log {
    ($level:expr, $($arg:tt)*) => {
        $crate::log($level, &::std::format!($($arg)*))
    };
}

/// The wall clock, milliseconds since the epoch. Stamp published values with
/// this.
pub fn now_ms() -> i64 {
    unsafe { host_now_ms() }
}

/// Monotonic milliseconds. Measure intervals with this; it does not jump when
/// the boat's clock is set from a fresh GPS fix.
pub fn mono_ms() -> i64 {
    unsafe { host_mono_ms() }
}

// ---------------------------------------------------------------------------
// Talking to the host
// ---------------------------------------------------------------------------

/// Send a `{"updates":[...]}` batch. Returns the number of updates the host
/// accepted, or -1. [`Publish`] writes the JSON for you.
pub fn publish_json(s: &str) -> i32 {
    unsafe { host_publish(s.as_ptr(), s.len() as u32) }
}

/// Send a `{"targets":[...]}` batch. Speed over ground is METRES PER SECOND,
/// not knots: everything crossing this ABI is SI.
pub fn ais_upsert_json(s: &str) -> i32 {
    unsafe { host_ais_upsert(s.as_ptr(), s.len() as u32) }
}

/// Post an overlay batch, `{"set":[...],"del":[...]}`.
pub fn overlay_json(s: &str) -> i32 {
    unsafe { host_overlay(s.as_ptr(), s.len() as u32) }
}

/// Post one line of chrome, `{"state":"running","detail":"42 msg/s"}`. The
/// host keeps the latest per plugin and logs transitions, so posting the same
/// status repeatedly is free.
pub fn status_json(s: &str) {
    unsafe { host_chrome_status(s.as_ptr(), s.len() as u32) }
}

/// Raise an alert. Needs `alerts.raise`; without it this returns -1 and the
/// host logs the refusal.
pub fn alert_json(s: &str) -> i32 {
    unsafe { host_alert(s.as_ptr(), s.len() as u32) }
}

/// Open a connection. Returns a connection id at once — the connect itself
/// completes on the host's I/O thread and arrives as [`Event::TcpConnected`],
/// or as [`Event::TcpClosed`] if it failed. RECONNECTING IS YOURS: the host
/// never retries.
pub fn tcp_connect(host: &str, port: u16) -> i64 {
    unsafe { host_tcp_connect(host.as_ptr(), host.len() as u32, port as u32) }
}

pub fn tcp_send(id: i64, data: &[u8]) -> i32 {
    unsafe { host_tcp_send(id, data.as_ptr(), data.len() as u32) }
}

pub fn tcp_close(id: i64) {
    unsafe { host_tcp_close(id) }
}

/// Ask to be woken. A periodic timer repeats every `delay_ms`; otherwise it
/// fires once. It arrives as [`Event::Timer`] carrying the id this returns.
///
/// This is how a Rust plugin waits. `std::thread::sleep` is not.
pub fn timer_set(delay_ms: i64, periodic: bool) -> i64 {
    unsafe { host_timer_set(delay_ms, periodic as u32) }
}

pub fn timer_cancel(id: i64) {
    unsafe { host_timer_cancel(id) }
}

/// Subscribe to vessel paths. One subscription per plugin: calling again
/// REPLACES the path list. Changes arrive as [`Event::StoreChanged`].
pub fn subscribe_paths(paths: &[&str]) -> i32 {
    let mut s = String::with_capacity(64);
    s.push('[');
    for (i, p) in paths.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        json::push_str(&mut s, p);
    }
    s.push(']');
    unsafe { host_subscribe(s.as_ptr(), s.len() as u32) }
}

/// Ask for the AIS target set. The whole snapshot arrives as
/// [`Event::AisChanged`], at most twice a second and only when something moved.
pub fn ais_subscribe() -> i32 {
    unsafe { host_ais_subscribe() }
}

/// Post one line of chrome.
pub fn status(state: &str, detail: &str) {
    let mut s = String::with_capacity(96);
    s.push_str("{\"state\":");
    json::push_str(&mut s, state);
    s.push_str(",\"detail\":");
    json::push_str(&mut s, detail);
    s.push('}');
    status_json(&s);
}

/// How loud an alert is. The host maps these to log levels: `Alarm` at error,
/// `Warning` at warn, `Notice` at info.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Alarm,
    Warning,
    Notice,
}

impl Severity {
    fn text(self) -> &'static str {
        match self {
            Severity::Alarm => "alarm",
            Severity::Warning => "warning",
            Severity::Notice => "notice",
        }
    }
}

/// Raise an alert. Needs `alerts.raise`; -1 means the grant is missing.
pub fn alert(severity: Severity, title: &str, body: &str) -> i32 {
    let mut s = String::with_capacity(128);
    s.push_str("{\"severity\":\"");
    s.push_str(severity.text());
    s.push_str("\",\"title\":");
    json::push_str(&mut s, title);
    s.push_str(",\"body\":");
    json::push_str(&mut s, body);
    s.push('}');
    alert_json(&s)
}

// ---------------------------------------------------------------------------
// What the host sends
// ---------------------------------------------------------------------------

/// Everything that happens.
///
/// The payload slices borrow the host's buffer. They are valid for the length
/// of your `on_event` call and freed after it, which the lifetime enforces:
/// copy anything you keep.
#[derive(Debug)]
pub enum Event<'a> {
    /// Your whole settings object, after the mariner changed one of them.
    /// Every field the manifest's schema declares is present, so a handler
    /// reads what it wants and never merges.
    ConfigChanged(&'a str),
    /// The timer id [`timer_set`] returned.
    Timer(i64),
    TcpConnected(i64),
    TcpData {
        conn: i64,
        bytes: &'a [u8],
    },
    TcpClosed(i64),
    /// `{"values":[...]}`. [`readings`] parses it.
    StoreChanged(&'a str),
    /// `{"targets":[...]}`, the full set. [`targets`] parses it.
    AisChanged(&'a str),
    /// The last thing you will ever be handed. Close sockets, post a final
    /// status.
    Shutdown,
}

/// What `start` receives: the host's `{"abi":1,"config":{...}}`, parsed.
pub struct Start<'a> {
    pub abi: u32,
    /// The `config` object.
    pub config: Json<'a>,
}

impl<'a> Start<'a> {
    /// A string out of the config, or `fallback`.
    pub fn str_or<'b>(&'b self, key: &str, fallback: &'b str) -> &'b str {
        self.config.str_or(key, fallback)
    }
    /// An integer out of the config, or `fallback`.
    pub fn i64_or(&self, key: &str, fallback: i64) -> i64 {
        self.config.i64_or(key, fallback)
    }
    /// A number out of the config, or `fallback`.
    pub fn f64_or(&self, key: &str, fallback: f64) -> f64 {
        self.config.f64_or(key, fallback)
    }
}

/// One entry of a `StoreChanged` payload.
///
/// `path` is a `Cow` because it usually borrows the payload and only copies
/// when the JSON had an escape in it. Compare it with `&*r.path`.
#[derive(Debug)]
pub struct Reading<'a> {
    pub path: Cow<'a, str>,
    /// `Json::Null` means the path has NO value any more — the source was
    /// cleared — not that a source published a null. [`Reading::removed`]
    /// reports it.
    pub value: Json<'a>,
    pub ts_ms: i64,
    pub age_ms: i64,
}

impl<'a> Reading<'a> {
    /// True when the path has no value at all any more. Treat it as removal:
    /// stop drawing whatever the value fed.
    pub fn removed(&self) -> bool {
        self.value.is_null()
    }

    pub fn number(&self) -> Option<f64> {
        self.value.as_f64()
    }

    /// `(lat, lon)`, or nothing when the value is not a position.
    pub fn position(&self) -> Option<(f64, f64)> {
        Some((
            self.value.get("lat")?.as_f64()?,
            self.value.get("lon")?.as_f64()?,
        ))
    }
}

/// Parse a `StoreChanged` payload. The readings borrow the payload.
pub fn readings(payload: &str) -> Vec<Reading<'_>> {
    let root = match Json::parse(payload) {
        Some(v) => v,
        None => return Vec::new(),
    };
    let values = match root.get("values").and_then(Json::as_array) {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(values.len());
    for item in values {
        let path = match item.get("path").and_then(Json::as_cow) {
            Some(p) => p,
            None => continue,
        };
        out.push(Reading {
            path,
            value: item.get("value").cloned().unwrap_or(Json::Null),
            ts_ms: item.i64_or("ts", 0),
            age_ms: item.i64_or("age_ms", 0),
        });
    }
    out
}

/// One AIS target. An absent field is `None`: "never heard" and "heard as
/// zero" are different things at sea.
#[derive(Debug, Default, Clone)]
pub struct Target {
    pub mmsi: u32,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    /// Metres per second.
    pub sog: Option<f64>,
    pub cog: Option<f64>,
    pub heading: Option<f64>,
    pub name: Option<String>,
    /// True when this is an aid to navigation, not a vessel: no CPA, no
    /// vector, and its own aging.
    pub aton: bool,
    /// The navaid type, 0..=31, as message type 21 carries it.
    pub aton_type: Option<u8>,
    /// True for an aid with nothing in the water behind it.
    pub virtual_aton: bool,
    /// True when the aid reports itself off its charted position; `None` when
    /// it has never said either way.
    pub off_position: Option<bool>,
    pub ts_ms: i64,
    pub age_ms: i64,
}

impl Target {
    pub fn has_position(&self) -> bool {
        self.lat.is_some() && self.lon.is_some()
    }
}

/// Parse an `AisChanged` payload: the whole target set, every time.
pub fn targets(payload: &str) -> Vec<Target> {
    let root = match Json::parse(payload) {
        Some(v) => v,
        None => return Vec::new(),
    };
    let items = match root.get("targets").and_then(Json::as_array) {
        Some(a) => a,
        None => return Vec::new(),
    };
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let mmsi = match item.get("mmsi").and_then(Json::as_f64) {
            Some(n) if n > 0.0 && n <= u32::MAX as f64 => n as u32,
            _ => continue,
        };
        let num = |k: &str| item.get(k).and_then(Json::as_f64);
        out.push(Target {
            mmsi,
            lat: num("lat"),
            lon: num("lon"),
            sog: num("sog"),
            cog: num("cog"),
            heading: num("heading"),
            name: item.get("name").and_then(Json::as_str).map(str::to_owned),
            aton: item.bool_or("aton", false),
            // Anything outside 0..=31 loses the type, not the target.
            aton_type: num("aton_type")
                .filter(|n| (0.0..=31.0).contains(n))
                .map(|n| n as u8),
            virtual_aton: item.bool_or("virtual", false),
            off_position: item.get("off_position").and_then(Json::as_bool),
            ts_ms: item.i64_or("ts", 0),
            age_ms: item.i64_or("age_ms", 0),
        });
    }
    out
}

// ---------------------------------------------------------------------------
// Writing what the host reads
// ---------------------------------------------------------------------------

/// Builds `{"updates":[...]}` and sends it.
///
/// ```ignore
/// let mut p = lk::Publish::new();
/// p.position("navigation.position", lat, lon, ts);
/// p.number("navigation.speedOverGround", sog_mps, ts);
/// p.send();
/// ```
pub struct Publish {
    s: String,
    n: usize,
}

impl Default for Publish {
    fn default() -> Self {
        Self::new()
    }
}

impl Publish {
    pub fn new() -> Self {
        Publish {
            s: String::from("{\"updates\":["),
            n: 0,
        }
    }

    fn open(&mut self, path: &str) {
        if self.n > 0 {
            self.s.push(',');
        }
        self.n += 1;
        self.s.push_str("{\"path\":");
        json::push_str(&mut self.s, path);
        self.s.push_str(",\"value\":");
    }

    pub fn number(&mut self, path: &str, v: f64, ts_ms: i64) {
        self.open(path);
        json::push_num(&mut self.s, v);
        self.s.push_str(&format!(",\"ts\":{}}}", ts_ms));
    }

    pub fn position(&mut self, path: &str, lat: f64, lon: f64, ts_ms: i64) {
        self.open(path);
        self.s.push_str("{\"lat\":");
        json::push_num(&mut self.s, lat);
        self.s.push_str(",\"lon\":");
        json::push_num(&mut self.s, lon);
        self.s.push_str(&format!("}},\"ts\":{}}}", ts_ms));
    }

    /// Publish a null: this source has the path but no value for it now.
    pub fn clear(&mut self, path: &str, ts_ms: i64) {
        self.open(path);
        self.s.push_str(&format!("null,\"ts\":{}}}", ts_ms));
    }

    /// Post the batch. Nothing to say is not an error: an empty batch is
    /// simply not sent.
    pub fn send(mut self) -> i32 {
        if self.n == 0 {
            return 0;
        }
        self.s.push_str("]}");
        publish_json(&self.s)
    }
}

/// A palette token. A plugin names a token; the core resolves it per day, dusk
/// and night scheme, which is why an overlay never holds an RGB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Color {
    Ownship,
    Target,
    TargetDanger,
    Track,
    LaylinePort,
    LaylineStbd,
    Warning,
}

impl Color {
    fn text(self) -> &'static str {
        match self {
            Color::Ownship => "ownship",
            Color::Target => "target",
            Color::TargetDanger => "target_danger",
            Color::Track => "track",
            Color::LaylinePort => "layline_port",
            Color::LaylineStbd => "layline_stbd",
            Color::Warning => "warning",
        }
    }
}

/// A symbol shape the core draws. `Aton` is a physical aid to navigation and
/// `AtonVirtual` one that exists only as a broadcast.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sym {
    Ownship,
    Target,
    Aton,
    AtonVirtual,
}

impl Sym {
    fn text(self) -> &'static str {
        match self {
            Sym::Ownship => "ownship",
            Sym::Target => "target",
            Sym::Aton => "aton",
            Sym::AtonVirtual => "aton_virtual",
        }
    }
}

/// Builds `{"set":[...],"del":[...]}`.
///
/// DELETES FIRST. Call [`Overlay::del`] before any symbol or line; a delete
/// after a shape is dropped with a log line. The host applies deletes before
/// sets whatever the order in the JSON, so this only makes the builder match
/// the semantics.
pub struct Overlay {
    s: String,
    dels: usize,
    sets: usize,
    in_set: bool,
}

impl Default for Overlay {
    fn default() -> Self {
        Self::new()
    }
}

// The symbol builders take seven or eight positional arguments because they
// mirror `lk.zig`'s, so that the same plugin reads the same way in Zig, Go and
// Rust. A builder struct per shape would break that and buy nothing.
#[allow(clippy::too_many_arguments)]
impl Overlay {
    pub fn new() -> Self {
        Overlay {
            s: String::from("{\"del\":["),
            dels: 0,
            sets: 0,
            in_set: false,
        }
    }

    pub fn del(&mut self, id: &str) {
        if self.in_set {
            log!(
                Level::Warn,
                "overlay: del(\"{}\") after a set is ignored",
                id
            );
            return;
        }
        if self.dels > 0 {
            self.s.push(',');
        }
        self.dels += 1;
        json::push_str(&mut self.s, id);
    }

    fn begin_set(&mut self) {
        if self.in_set {
            self.s.push(',');
        } else {
            self.s.push_str("],\"set\":[");
            self.in_set = true;
        }
        self.sets += 1;
    }

    fn symbol_open(
        &mut self,
        id: &str,
        sym: Sym,
        lon: f64,
        lat: f64,
        rot_deg: f64,
        color: Color,
        scale: f64,
    ) {
        self.begin_set();
        self.s.push_str("{\"id\":");
        json::push_str(&mut self.s, id);
        self.s.push_str(",\"kind\":\"symbol\",\"sym\":\"");
        self.s.push_str(sym.text());
        self.s.push_str("\",\"at\":[");
        json::push_num(&mut self.s, lon);
        self.s.push(',');
        json::push_num(&mut self.s, lat);
        self.s.push_str("],\"rot_deg\":");
        json::push_num(&mut self.s, rot_deg);
        self.s.push_str(",\"scale\":");
        json::push_num(&mut self.s, scale);
        self.s.push_str(",\"color\":\"");
        self.s.push_str(color.text());
        self.s.push('"');
    }

    /// A symbol at lon/lat, rotated to a TRUE bearing (clockwise from north).
    pub fn symbol(
        &mut self,
        id: &str,
        sym: Sym,
        lon: f64,
        lat: f64,
        rot_deg: f64,
        color: Color,
        scale: f64,
    ) {
        self.symbol_open(id, sym, lon, lat, rot_deg, color, scale);
        self.s.push('}');
    }

    /// A symbol that rides own ship's DISPLAY position: the core carries the
    /// newest fix forward and substitutes it every frame, so the boat sits
    /// still on screen instead of stepping once a second.
    pub fn ship_symbol(
        &mut self,
        id: &str,
        sym: Sym,
        lon: f64,
        lat: f64,
        rot_deg: f64,
        color: Color,
        scale: f64,
    ) {
        self.symbol_open(id, sym, lon, lat, rot_deg, color, scale);
        self.s.push_str(",\"anchor\":\"ownship\"}");
    }

    /// A symbol plus a pick payload: a title and rows the shell shows on hover
    /// or on a tap. Values are strings, not numbers — the payload is what the
    /// mariner reads, and only the plugin knows the unit.
    pub fn symbol_pick(
        &mut self,
        id: &str,
        sym: Sym,
        lon: f64,
        lat: f64,
        rot_deg: f64,
        color: Color,
        scale: f64,
        title: &str,
        rows: &[(&str, &str)],
    ) {
        self.symbol_open(id, sym, lon, lat, rot_deg, color, scale);
        self.s.push_str(",\"pick\":{\"title\":");
        json::push_str(&mut self.s, title);
        self.s.push_str(",\"rows\":[");
        for (i, (k, v)) in rows.iter().enumerate() {
            if i > 0 {
                self.s.push(',');
            }
            self.s.push('[');
            json::push_str(&mut self.s, k);
            self.s.push(',');
            json::push_str(&mut self.s, v);
            self.s.push(']');
        }
        self.s.push_str("]}}");
    }

    /// A polyline through `pts`, each `(lon, lat)`. `width_pt` is screen
    /// points, not metres — the core converts at the live zoom.
    pub fn polyline(
        &mut self,
        id: &str,
        pts: &[(f64, f64)],
        width_pt: f64,
        color: Color,
        dash: bool,
    ) {
        self.polyline_anchored(id, pts, width_pt, color, dash, false)
    }

    /// A line that travels with own ship's display position, keeping its shape
    /// and its first point on the boat — the heading line and the speed
    /// vector, which must not lag the hull between fixes.
    pub fn ship_polyline(
        &mut self,
        id: &str,
        pts: &[(f64, f64)],
        width_pt: f64,
        color: Color,
        dash: bool,
    ) {
        self.polyline_anchored(id, pts, width_pt, color, dash, true)
    }

    fn polyline_anchored(
        &mut self,
        id: &str,
        pts: &[(f64, f64)],
        width_pt: f64,
        color: Color,
        dash: bool,
        ship: bool,
    ) {
        self.begin_set();
        self.s.push_str("{\"id\":");
        json::push_str(&mut self.s, id);
        self.s.push_str(",\"kind\":\"polyline\",\"pts\":[");
        self.points(pts);
        self.s.push_str("],\"width_pt\":");
        json::push_num(&mut self.s, width_pt);
        self.s.push_str(",\"dash\":");
        self.s.push_str(if dash { "true" } else { "false" });
        self.s.push_str(",\"color\":\"");
        self.s.push_str(color.text());
        self.s.push('"');
        if ship {
            self.s.push_str(",\"anchor\":\"ownship\"");
        }
        self.s.push('}');
    }

    /// A filled ring. `alpha` multiplies the token's own alpha.
    pub fn polygon(&mut self, id: &str, ring: &[(f64, f64)], color: Color, alpha: f64) {
        self.begin_set();
        self.s.push_str("{\"id\":");
        json::push_str(&mut self.s, id);
        self.s.push_str(",\"kind\":\"polygon\",\"ring\":[");
        self.points(ring);
        self.s.push_str("],\"alpha\":");
        json::push_num(&mut self.s, alpha);
        self.s.push_str(",\"color\":\"");
        self.s.push_str(color.text());
        self.s.push_str("\"}");
    }

    fn points(&mut self, pts: &[(f64, f64)]) {
        for (i, (x, y)) in pts.iter().enumerate() {
            if i > 0 {
                self.s.push(',');
            }
            self.s.push('[');
            json::push_num(&mut self.s, *x);
            self.s.push(',');
            json::push_num(&mut self.s, *y);
            self.s.push(']');
        }
    }

    pub fn send(mut self) -> i32 {
        if self.dels == 0 && self.sets == 0 {
            return 0;
        }
        if !self.in_set {
            self.s.push_str("],\"set\":[");
        }
        self.s.push_str("]}");
        overlay_json(&self.s)
    }
}

/// Builds `{"targets":[...]}` for `ais_upsert`. `sog` is metres per second.
pub struct AisUpsert {
    s: String,
    n: usize,
}

impl Default for AisUpsert {
    fn default() -> Self {
        Self::new()
    }
}

impl AisUpsert {
    pub fn new() -> Self {
        AisUpsert {
            s: String::from("{\"targets\":["),
            n: 0,
        }
    }

    pub fn target(&mut self, t: &Target) {
        if self.n > 0 {
            self.s.push(',');
        }
        self.n += 1;
        self.s.push_str(&format!("{{\"mmsi\":{}", t.mmsi));
        self.field("lat", t.lat);
        self.field("lon", t.lon);
        self.field("sog", t.sog);
        self.field("cog", t.cog);
        self.field("heading", t.heading);
        if let Some(name) = &t.name {
            self.s.push_str(",\"name\":");
            json::push_str(&mut self.s, name);
        }
        if t.aton {
            self.s.push_str(",\"aton\":true");
            if let Some(k) = t.aton_type {
                self.s.push_str(&format!(",\"aton_type\":{}", k));
            }
            if t.virtual_aton {
                self.s.push_str(",\"virtual\":true");
            }
            if let Some(off) = t.off_position {
                self.s.push_str(if off {
                    ",\"off_position\":true"
                } else {
                    ",\"off_position\":false"
                });
            }
        }
        self.s.push_str(&format!(",\"ts\":{}}}", t.ts_ms));
    }

    fn field(&mut self, name: &str, v: Option<f64>) {
        if let Some(v) = v {
            self.s.push_str(&format!(",\"{}\":", name));
            json::push_num(&mut self.s, v);
        }
    }

    pub fn send(mut self) -> i32 {
        if self.n == 0 {
            return 0;
        }
        self.s.push_str("]}");
        ais_upsert_json(&self.s)
    }
}

// ---------------------------------------------------------------------------
// The plugin trait and the five exports
// ---------------------------------------------------------------------------

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

/// What you write. Both methods run on the one thread the host gives you, one
/// call at a time.
pub trait Plugin {
    /// Begin. Return an error and the host records the plugin as failed to
    /// start, with the text in the log.
    fn start(&mut self, s: Start<'_>) -> Result;
    /// Handle everything that happens. Ignore the kinds you do not care about.
    fn on_event(&mut self, e: Event<'_>) -> Result;
}

/// The plumbing `register!` calls. Public because a macro expands in your
/// crate, not in this one; there is nothing here to call by hand.
#[doc(hidden)]
pub mod rt {
    use super::*;
    use std::alloc::{alloc as raw_alloc, dealloc, Layout};
    use std::cell::UnsafeCell;

    /// A global with no lock. Sound here and nowhere else: wasm32 without the
    /// threads proposal has exactly one thread, and the host contract is one
    /// call into the module at a time.
    struct Single<T>(UnsafeCell<Option<T>>);
    unsafe impl<T> Sync for Single<T> {}

    static PLUGIN: Single<Box<dyn Plugin>> = Single(UnsafeCell::new(None));

    /// Buffers are 8-aligned, which suits every payload the host writes and
    /// matches what the Zig library hands out.
    const ALIGN: usize = 8;

    fn layout(len: u32) -> Option<Layout> {
        Layout::from_size_align(std::cmp::max(len as usize, 1), ALIGN).ok()
    }

    pub fn abi() -> u32 {
        ABI_VERSION
    }

    /// lk_alloc. Returns 0 when it cannot allocate, which the host reads as
    /// "the plugin is out of memory".
    pub fn alloc(len: u32) -> u32 {
        let l = match layout(len) {
            Some(l) => l,
            None => return 0,
        };
        let p = unsafe { raw_alloc(l) };
        p as u32
    }

    /// lk_free. The host returns the same (address, length) it was given, so
    /// the layout is reconstructible and no bookkeeping is needed.
    pub fn free(ptr: u32, len: u32) {
        if ptr == 0 {
            return;
        }
        if let Some(l) = layout(len) {
            unsafe { dealloc(ptr as *mut u8, l) }
        }
    }

    fn payload<'a>(ptr: u32, len: u32) -> &'a [u8] {
        if len == 0 || ptr == 0 {
            return &[];
        }
        unsafe { std::slice::from_raw_parts(ptr as *const u8, len as usize) }
    }

    pub fn start(ptr: u32, len: u32, make: fn() -> Box<dyn Plugin>) -> i32 {
        let text = match std::str::from_utf8(payload(ptr, len)) {
            Ok(t) => t,
            Err(_) => {
                log(Level::Error, "lk_start: config is not UTF-8");
                return -1;
            }
        };
        let root = match Json::parse(text) {
            Some(v) => v,
            None => {
                log(Level::Error, "lk_start: config is not JSON");
                return -1;
            }
        };
        let abi_field = root.i64_or("abi", 0);
        if abi_field != ABI_VERSION as i64 {
            log!(
                Level::Error,
                "lk_start: host speaks ABI {}, this plugin speaks {}",
                abi_field,
                ABI_VERSION
            );
            return -1;
        }
        let s = Start {
            abi: ABI_VERSION,
            config: root.get("config").cloned().unwrap_or(Json::Null),
        };

        let slot = unsafe { &mut *PLUGIN.0.get() };
        let p = slot.get_or_insert_with(make);
        match p.start(s) {
            Ok(()) => 0,
            Err(e) => {
                log!(Level::Error, "start failed: {}", e);
                -1
            }
        }
    }

    pub fn event(kind: u32, handle: i64, ptr: u32, len: u32) -> i32 {
        let bytes = payload(ptr, len);
        // A text payload that is not text is a host bug, not a plugin one, so
        // it is refused rather than passed on as broken UTF-8.
        let text = || std::str::from_utf8(bytes).unwrap_or("");
        let e = match kind {
            1 => Event::ConfigChanged(text()),
            3 => Event::Timer(handle),
            4 => Event::TcpConnected(handle),
            5 => Event::TcpData {
                conn: handle,
                bytes,
            },
            6 => Event::TcpClosed(handle),
            10 => Event::StoreChanged(text()),
            11 => Event::AisChanged(text()),
            99 => Event::Shutdown,
            // The ABI says an unknown kind is ignored and answered 0. A future
            // host must be able to add events without breaking a plugin built
            // today.
            _ => return 0,
        };
        let slot = unsafe { &mut *PLUGIN.0.get() };
        let p = match slot.as_mut() {
            Some(p) => p,
            None => return -1,
        };
        match p.on_event(e) {
            Ok(()) => 0,
            Err(err) => {
                log!(Level::Error, "event {} failed: {}", kind, err);
                -1
            }
        }
    }
}

/// Write the five ABI exports and wire them to your plugin. Call it once, at
/// the top level of your crate, with an expression that builds your plugin:
///
/// ```ignore
/// lookout::register!(Windline::default());
/// ```
///
/// The expression runs on the first `lk_start`, not at load time, so a plugin
/// can be built as late as possible.
#[macro_export]
macro_rules! register {
    ($init:expr) => {
        #[no_mangle]
        pub extern "C" fn lk_abi() -> u32 {
            $crate::rt::abi()
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
            fn make() -> ::std::boxed::Box<dyn $crate::Plugin> {
                ::std::boxed::Box::new($init)
            }
            $crate::rt::start(ptr, len, make)
        }

        #[no_mangle]
        pub extern "C" fn lk_event(kind: u32, handle: i64, ptr: u32, len: u32) -> i32 {
            $crate::rt::event(kind, handle, ptr, len)
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    // The builders write JSON without touching the host, so they are testable
    // on any target. `cargo test` runs these on the development machine.
    #[test]
    fn overlay_puts_deletes_before_sets() {
        let mut ov = Overlay::new();
        ov.del("gone");
        ov.polyline("line", &[(1.0, 2.0), (3.0, 4.0)], 1.5, Color::Warning, true);
        assert_eq!(
            ov.s.clone() + "]}",
            r#"{"del":["gone"],"set":[{"id":"line","kind":"polyline","pts":[[1,2],[3,4]],"width_pt":1.5,"dash":true,"color":"warning"}]}"#
        );
    }

    #[test]
    fn publish_writes_a_position() {
        let mut p = Publish::new();
        p.position("navigation.position", 38.9, -76.4, 17);
        assert_eq!(
            p.s.clone() + "]}",
            r#"{"updates":[{"path":"navigation.position","value":{"lat":38.9,"lon":-76.4},"ts":17}]}"#
        );
    }

    #[test]
    fn readings_survive_a_cleared_path() {
        let rs = readings(r#"{"values":[{"path":"a","value":null,"ts":1,"age_ms":2}]}"#);
        assert_eq!(rs.len(), 1);
        assert!(rs[0].removed());
    }

    #[test]
    fn targets_drop_a_bad_navaid_type_not_the_target() {
        let ts =
            targets(r#"{"targets":[{"mmsi":366000001,"lat":1.0,"aton":true,"aton_type":99}]}"#);
        assert_eq!(ts.len(), 1);
        assert!(ts[0].aton);
        assert_eq!(ts[0].aton_type, None);
    }
}
