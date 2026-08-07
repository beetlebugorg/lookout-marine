//! The raw ABI: the host imports, the event union and the JSON builders.
//!
//! Tier 3. A plugin that fits tiers 1 and 2 never touches this module — the
//! library above it owns the subscription, the timer, the scene and the
//! sockets. Reach in here for what the first two tiers do not cover, and use
//! [`crate::register!`] instead of [`crate::plugin!`] to be handed every event
//! with nothing consumed.
//!
//! ```ignore
//! use lookout::raw;
//!
//! #[derive(Default)]
//! struct Probe;
//!
//! lookout::register!(Probe::default());
//!
//! impl raw::RawPlugin for Probe {
//!     fn start(&mut self, _s: raw::Start<'_>) -> lookout::Result {
//!         raw::subscribe_paths(&["navigation.position"]);
//!         Ok(())
//!     }
//!     fn on_event(&mut self, _e: raw::Event<'_>) -> lookout::Result {
//!         Ok(())
//!     }
//! }
//! ```
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
//! the exports. There are no threads to spawn — `std::thread::spawn` fails —
//! and `std::thread::sleep` panics, because the host refuses the WASI call
//! that would park the thread. Do the work in the handler and return. To wake
//! up later ask for [`timer_set`]; to read a socket ask for [`tcp_connect`].
//! The host gives every call into the module a budget and kills the instance
//! when it runs out.
//!
//! # What WASI gives you
//!
//! Clocks, randomness, stdout and stderr. There is no filesystem, no sockets,
//! no environment variables and no arguments. `println!` works and goes to the
//! plugin's log, one line per call.
//!
//! # Panics
//!
//! A panic unwinds into a trap, the host tears the instance down and the
//! plugin lands at `failed`. Build with `panic = "abort"`; the message still
//! reaches the log through stderr. Do not panic on data off the wire.

use crate::chart::{Color, Sym};
use crate::json::{self, Json};
use std::borrow::Cow;

/// The ABI version this library speaks. `lk_abi` returns it.
pub const ABI_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// The host imports, exactly as the ABI freezes them
// ---------------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
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
    #[link_name = "udp_open"]
    fn host_udp_open(port: u32) -> i64;
    #[link_name = "udp_send"]
    fn host_udp_send(
        id: i64,
        ptr: *const u8,
        len: u32,
        host_ptr: *const u8,
        host_len: u32,
        port: u32,
    ) -> i32;
    #[link_name = "udp_close"]
    fn host_udp_close(id: i64);
    #[link_name = "http_fetch"]
    fn host_http_fetch(ptr: *const u8, len: u32) -> i64;
    #[link_name = "ws_connect"]
    fn host_ws_connect(ptr: *const u8, len: u32) -> i64;
    #[link_name = "ws_send"]
    fn host_ws_send(id: i64, ptr: *const u8, len: u32) -> i32;
    #[link_name = "ws_close"]
    fn host_ws_close(id: i64);
    #[link_name = "storage_get"]
    fn host_storage_get(kptr: *const u8, klen: u32, vptr: *mut u8, vcap: u32) -> i32;
    #[link_name = "storage_put"]
    fn host_storage_put(kptr: *const u8, klen: u32, vptr: *const u8, vlen: u32) -> i32;
    #[link_name = "file_read"]
    fn host_file_read(handle: i64, offset: i64, ptr: *mut u8, cap: u32) -> i32;
    #[link_name = "file_write"]
    fn host_file_write(handle: i64, ptr: *const u8, len: u32) -> i32;
    #[link_name = "file_close"]
    fn host_file_close(handle: i64);
}

/// Off wasm there is no host. These stubs are what let the library's own tests
/// — the scene diff, the settings schema, the connection list — run under
/// `cargo test` on the development machine. Every call answers "refused".
#[cfg(not(target_arch = "wasm32"))]
#[allow(unused_variables, clippy::missing_safety_doc)]
mod off_host {
    pub unsafe fn host_log(level: u32, ptr: *const u8, len: u32) {}
    pub unsafe fn host_now_ms() -> i64 {
        0
    }
    pub unsafe fn host_mono_ms() -> i64 {
        0
    }
    pub unsafe fn host_publish(ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_ais_upsert(ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_overlay(ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_chrome_status(ptr: *const u8, len: u32) {}
    pub unsafe fn host_alert(ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_tcp_connect(host_ptr: *const u8, host_len: u32, port: u32) -> i64 {
        -1
    }
    pub unsafe fn host_tcp_send(id: i64, ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_tcp_close(id: i64) {}
    pub unsafe fn host_timer_set(delay_ms: i64, periodic: u32) -> i64 {
        -1
    }
    pub unsafe fn host_timer_cancel(id: i64) {}
    pub unsafe fn host_subscribe(ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_ais_subscribe() -> i32 {
        -1
    }
    pub unsafe fn host_udp_open(port: u32) -> i64 {
        -1
    }
    pub unsafe fn host_udp_send(
        id: i64,
        ptr: *const u8,
        len: u32,
        host_ptr: *const u8,
        host_len: u32,
        port: u32,
    ) -> i32 {
        -1
    }
    pub unsafe fn host_udp_close(id: i64) {}
    pub unsafe fn host_http_fetch(ptr: *const u8, len: u32) -> i64 {
        -1
    }
    pub unsafe fn host_ws_connect(ptr: *const u8, len: u32) -> i64 {
        -1
    }
    pub unsafe fn host_ws_send(id: i64, ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_ws_close(id: i64) {}
    pub unsafe fn host_storage_get(kptr: *const u8, klen: u32, vptr: *mut u8, vcap: u32) -> i32 {
        -1
    }
    pub unsafe fn host_storage_put(kptr: *const u8, klen: u32, vptr: *const u8, vlen: u32) -> i32 {
        -1
    }
    pub unsafe fn host_file_read(handle: i64, offset: i64, ptr: *mut u8, cap: u32) -> i32 {
        -1
    }
    pub unsafe fn host_file_write(handle: i64, ptr: *const u8, len: u32) -> i32 {
        -1
    }
    pub unsafe fn host_file_close(handle: i64) {}
}

#[cfg(not(target_arch = "wasm32"))]
use off_host::*;

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

/// The wall clock, milliseconds since the epoch. Published values are stamped
/// with this.
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
/// accepted, or -1.
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
/// host keeps the latest per plugin and logs every text it has not seen.
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

/// Bind a UDP port. Every datagram that arrives becomes one [`Event::UdpData`];
/// a datagram over 8192 bytes is dropped rather than split.
pub fn udp_open(port: u16) -> i64 {
    unsafe { host_udp_open(port as u32) }
}

/// Send one datagram. `address` is an IP LITERAL — the host resolves no name
/// here. Returns the bytes sent, or -1.
pub fn udp_send(id: i64, data: &[u8], address: &str, port: u16) -> i32 {
    unsafe {
        host_udp_send(
            id,
            data.as_ptr(),
            data.len() as u32,
            address.as_ptr(),
            address.len() as u32,
            port as u32,
        )
    }
}

pub fn udp_close(id: i64) {
    unsafe { host_udp_close(id) }
}

/// One request header.
pub struct HttpHeader<'a> {
    pub name: &'a str,
    pub value: &'a str,
}

/// What [`http_fetch`] sends.
pub struct HttpRequest<'a> {
    /// `GET` or `HEAD`. The host refuses anything else.
    pub method: &'a str,
    pub url: &'a str,
    pub headers: &'a [HttpHeader<'a>],
    /// `bytes=0-1048575`, or empty. This is the way to read a file larger than
    /// the 4 MiB body cap: ask for it a range at a time.
    pub range: &'a str,
}

impl<'a> HttpRequest<'a> {
    pub fn get(url: &'a str) -> Self {
        HttpRequest {
            method: "GET",
            url,
            headers: &[],
            range: "",
        }
    }
}

/// Start a fetch. Returns a request id at once, or -1 when the manifest does
/// not name the URL's host. The answer arrives as one [`Event::HttpResponse`].
pub fn http_fetch(req: &HttpRequest<'_>) -> i64 {
    let mut s = String::with_capacity(128);
    s.push_str("{\"method\":");
    json::push_str(&mut s, req.method);
    s.push_str(",\"url\":");
    json::push_str(&mut s, req.url);
    if !req.range.is_empty() {
        s.push_str(",\"range\":");
        json::push_str(&mut s, req.range);
    }
    if !req.headers.is_empty() {
        s.push_str(",\"headers\":{");
        for (i, h) in req.headers.iter().enumerate() {
            if i > 0 {
                s.push(',');
            }
            json::push_str(&mut s, h.name);
            s.push(':');
            json::push_str(&mut s, h.value);
        }
        s.push('}');
    }
    s.push('}');
    unsafe { host_http_fetch(s.as_ptr(), s.len() as u32) }
}

/// Open a WebSocket. Returns a connection id at once, or -1 when the manifest
/// does not name the URL's host. The handshake happens on the host's thread:
/// [`Event::WsOpen`] when it succeeds, [`Event::WsClosed`] when it does not.
/// RECONNECTING IS YOURS, exactly as it is for TCP.
pub fn ws_connect(url: &str, protocols: &[&str]) -> i64 {
    let mut s = String::with_capacity(96);
    s.push_str("{\"url\":");
    json::push_str(&mut s, url);
    if !protocols.is_empty() {
        s.push_str(",\"protocols\":[");
        for (i, p) in protocols.iter().enumerate() {
            if i > 0 {
                s.push(',');
            }
            json::push_str(&mut s, p);
        }
        s.push(']');
    }
    s.push('}');
    unsafe { host_ws_connect(s.as_ptr(), s.len() as u32) }
}

/// Queue one TEXT message. Returns the bytes queued, or -1 when the connection
/// is not yours, is not open, or is already holding more than it can write.
pub fn ws_send(id: i64, text: &str) -> i32 {
    unsafe { host_ws_send(id, text.as_ptr(), text.len() as u32) }
}

/// Ask the host to close a WebSocket. [`Event::WsClosed`] still arrives.
pub fn ws_close(id: i64) {
    unsafe { host_ws_close(id) }
}

/// How big the value under `key` is, or nothing when there is no such key.
pub fn storage_size(key: &str) -> Option<usize> {
    let mut none = [0u8; 1];
    let n = unsafe { host_storage_get(key.as_ptr(), key.len() as u32, none.as_mut_ptr(), 0) };
    if n < 0 {
        None
    } else {
        Some(n as usize)
    }
}

/// Read the value under `key`. Returns nothing when there is no such key and
/// nothing when the value is longer than `out` — ask [`storage_size`] first.
pub fn storage_get<'a>(key: &str, out: &'a mut [u8]) -> Option<&'a [u8]> {
    if out.is_empty() {
        return None;
    }
    let n = unsafe {
        host_storage_get(
            key.as_ptr(),
            key.len() as u32,
            out.as_mut_ptr(),
            out.len() as u32,
        )
    };
    if n < 0 {
        return None;
    }
    let size = n as usize;
    if size > out.len() {
        return None;
    }
    Some(&out[..size])
}

/// Write `value` under `key`. Returns 0, or -1 when a cap is in the way: a key
/// over 128 bytes, a value over 64 KiB, or more than 1 MiB in total.
pub fn storage_put(key: &str, value: &[u8]) -> i32 {
    unsafe {
        host_storage_put(
            key.as_ptr(),
            key.len() as u32,
            value.as_ptr(),
            value.len() as u32,
        )
    }
}

/// Forget a key. An empty value IS the delete.
pub fn storage_delete(key: &str) -> i32 {
    storage_put(key, &[])
}

/// Read from a file the host granted, at an absolute offset. An empty slice is
/// the end of the file; nothing is an error. There is no way to open a file:
/// every handle arrived as [`Event::FileOpened`].
pub fn file_read(handle: i64, offset: i64, out: &mut [u8]) -> Option<usize> {
    if out.is_empty() {
        return Some(0);
    }
    let n = unsafe { host_file_read(handle, offset, out.as_mut_ptr(), out.len() as u32) };
    if n < 0 {
        None
    } else {
        Some(n as usize)
    }
}

/// Append to a granted write file. Returns the bytes written, or -1.
pub fn file_write(handle: i64, data: &[u8]) -> i32 {
    unsafe { host_file_write(handle, data.as_ptr(), data.len() as u32) }
}

/// Give a granted file back. The host closes everything a plugin holds when it
/// stops.
pub fn file_close(handle: i64) {
    unsafe { host_file_close(handle) }
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

/// Post one line of chrome. [`crate::say`] dedupes; this does not.
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
    pub fn text(self) -> &'static str {
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

/// One reassembled WebSocket TEXT message. The host joins the fragments and
/// answers the pings.
#[derive(Debug)]
pub struct WsData<'a> {
    pub conn: i64,
    pub text: &'a str,
}

/// A WebSocket that opened. `protocol` is the subprotocol the server chose.
#[derive(Debug)]
pub struct WsOpen {
    pub conn: i64,
    /// Owned: the envelope is parsed out of a payload the host frees when the
    /// call returns, and a subprotocol arrives once per connection.
    pub protocol: String,
}

/// A WebSocket that ended. `code` is the RFC 6455 close code, or 0 when the
/// connection never opened — `reason` then names what stopped it.
#[derive(Debug)]
pub struct WsClosed {
    pub conn: i64,
    pub code: u16,
    pub reason: String,
}

/// The answer to one [`http_fetch`]. `status` is 0 when the fetch never
/// reached a server, and `head` then carries an `"error"` naming what stopped
/// it.
#[derive(Debug)]
pub struct HttpResponse<'a> {
    pub request: i64,
    pub status: u16,
    /// `{"status":200,"url":…,"headers":{…}}`.
    pub head: &'a str,
    /// The body, exactly as it arrived. Empty for a failure.
    pub body: &'a [u8],
}

impl HttpResponse<'_> {
    /// One header's value, by its LOWER-CASE name. The host lower-cases every
    /// name it writes, so `"content-length"` finds `Content-Length`.
    pub fn header(&self, name: &str) -> Option<String> {
        let root = Json::parse(self.head)?;
        Some(root.get("headers")?.get(name)?.as_str()?.to_owned())
    }
}

/// A file the mariner chose and the host handed over.
#[derive(Debug)]
pub struct FileOpened {
    pub handle: i64,
    pub name: String,
    pub size: u64,
    /// True when the plugin may write to it.
    pub writable: bool,
}

/// Everything that happens.
///
/// The payload slices borrow the host's buffer. They are valid for the length
/// of the call and freed after it, which the lifetime enforces: copy anything
/// you keep.
#[derive(Debug)]
pub enum Event<'a> {
    /// The whole settings object, after the mariner changed one of them. Every
    /// field the manifest's schema declares is present.
    ConfigChanged(&'a str),
    /// The timer id [`timer_set`] returned.
    Timer(i64),
    TcpConnected(i64),
    TcpData {
        conn: i64,
        bytes: &'a [u8],
    },
    TcpClosed(i64),
    UdpData {
        sock: i64,
        bytes: &'a [u8],
    },
    HttpResponse(HttpResponse<'a>),
    FileOpened(FileOpened),
    /// `{"values":[...]}`. [`readings`] parses it.
    StoreChanged(&'a str),
    /// `{"targets":[...]}`, the full set. [`targets`] parses it.
    AisChanged(&'a str),
    WsOpen(WsOpen),
    WsData(WsData<'a>),
    WsClosed(WsClosed),
    /// The last thing a plugin is handed. Close sockets, post a final status.
    Shutdown,
}

/// What `start` receives: the host's `{"abi":1,"config":{...}}`, parsed.
pub struct Start<'a> {
    pub abi: u32,
    /// The `config` object.
    pub config: Json<'a>,
}

impl Start<'_> {
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

impl Reading<'_> {
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

/// One AIS target as the wire carries it. An absent field is `None`: "never
/// heard" and "heard as zero" are different things at sea.
///
/// [`crate::Target`] is the same vessel with a [`crate::Point`] on it, and is
/// what tiers 1 and 2 use.
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

/// Builds `{"updates":[...]}` and sends it. [`crate::Publish`] stamps the
/// timestamp for you; this takes it per value.
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

    /// Post the batch. An empty batch is not sent and answers 0.
    pub fn send(mut self) -> i32 {
        if self.n == 0 {
            return 0;
        }
        self.s.push_str("]}");
        publish_json(&self.s)
    }
}

/// Builds `{"set":[...],"del":[...]}` by hand.
///
/// Tier 1 does not use this: [`crate::Chart`] describes the whole scene and
/// the library sends the difference. This is here for a tier-3 plugin that
/// owns its own overlay.
///
/// DELETES FIRST. Call [`Overlay::del`] before any symbol or line; a delete
/// after a shape is dropped with a log line.
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
// mirror the wire format's fields.
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
            crate::log!(
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
    /// newest fix forward and substitutes it every frame.
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
    /// or on a tap. Values are strings — only the plugin knows the unit.
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
    /// and its first point on the boat.
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
// The tier-3 plugin
// ---------------------------------------------------------------------------

/// A plugin that handles the raw events itself. [`crate::register!`] wires it
/// to the exports; nothing is consumed on the way, so every kind arrives.
pub trait RawPlugin {
    /// Begin. Return an error and the host records the plugin as failed to
    /// start, with the text in the log.
    fn start(&mut self, s: Start<'_>) -> crate::Result;
    /// Handle everything that happens. Ignore the kinds you do not care about.
    fn on_event(&mut self, e: Event<'_>) -> crate::Result;
}

pub(crate) const KIND_CONFIG_CHANGED: u32 = 1;
pub(crate) const KIND_TIMER: u32 = 3;
pub(crate) const KIND_TCP_CONNECTED: u32 = 4;
pub(crate) const KIND_TCP_DATA: u32 = 5;
pub(crate) const KIND_TCP_CLOSED: u32 = 6;
pub(crate) const KIND_UDP_DATA: u32 = 7;
pub(crate) const KIND_HTTP_RESPONSE: u32 = 8;
pub(crate) const KIND_FILE_OPENED: u32 = 9;
pub(crate) const KIND_STORE_CHANGED: u32 = 10;
pub(crate) const KIND_AIS_CHANGED: u32 = 11;
pub(crate) const KIND_WS_OPEN: u32 = 12;
pub(crate) const KIND_WS_DATA: u32 = 13;
pub(crate) const KIND_WS_CLOSED: u32 = 14;
pub(crate) const KIND_SHUTDOWN: u32 = 99;

/// Split an HTTP_RESPONSE payload: `u32 json_len | head JSON | raw body`. One
/// event carries both because a plugin needs both and the ABI carries one
/// payload per event.
pub(crate) fn http_response(request: i64, payload: &[u8]) -> HttpResponse<'_> {
    let bad = HttpResponse {
        request,
        status: 0,
        head: "",
        body: &[],
    };
    if payload.len() < 4 {
        return bad;
    }
    let json_len = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    if 4 + json_len > payload.len() {
        return bad;
    }
    let head = match std::str::from_utf8(&payload[4..4 + json_len]) {
        Ok(t) => t,
        Err(_) => return bad,
    };
    HttpResponse {
        request,
        status: Json::parse(head)
            .map(|v| v.i64_or("status", 0))
            .unwrap_or(0)
            .clamp(0, 0xffff) as u16,
        head,
        body: &payload[4 + json_len..],
    }
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

    #[test]
    fn an_http_response_splits_into_head_and_body() {
        let head = r#"{"status":206,"url":"https://x/y"}"#;
        let mut payload = (head.len() as u32).to_le_bytes().to_vec();
        payload.extend_from_slice(head.as_bytes());
        payload.extend_from_slice(b"\x00\x01body");
        let r = http_response(7, &payload);
        assert_eq!(r.status, 206);
        assert_eq!(r.body, b"\x00\x01body");
        // A truncated payload is a head of nothing, not a panic.
        assert_eq!(http_response(7, &payload[..3]).status, 0);
    }
}
