//! The five exports, and the machine that turns them into `draw`.
//!
//! `plugin!` and `register!` plant the exports in the plugin's crate and route
//! them here. Nothing in this module is called by hand.

use crate::chart::{Chart, Scene, State};
use crate::conn::{ConnSpec, Conns, Source};
use crate::json::Json;
use crate::post::say_text;
use crate::raw;
use crate::{Plugin, Single};
use std::alloc::{alloc as raw_alloc, dealloc, Layout};
use std::any::Any;

/// The one plugin this module holds, with everything the library keeps for it.
/// Type-erased because the exports are `extern "C"` and cannot be generic.
static SLOT: Single<Option<Box<dyn Any>>> = Single::new(None);

/// Buffers are 8-aligned, which suits every payload the host writes and
/// matches what the Zig library hands out.
const ALIGN: usize = 8;

fn layout(len: u32) -> Option<Layout> {
    Layout::from_size_align(std::cmp::max(len as usize, 1), ALIGN).ok()
}

pub fn api() -> u32 {
    raw::API_VERSION
}

/// lk_alloc. Returns 0 when it cannot allocate, which the host reads as "the
/// plugin is out of memory".
pub fn alloc(len: u32) -> u32 {
    match layout(len) {
        Some(l) => (unsafe { raw_alloc(l) }) as u32,
        None => 0,
    }
}

/// lk_free. The host returns the same (address, length) it was given, so the
/// layout is reconstructible and no bookkeeping is needed.
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

/// The host's `{"abi":1,"config":{…}}`, checked. Nothing runs on a version
/// mismatch.
fn parse_start(ptr: u32, len: u32) -> Option<Json<'static>> {
    let text = match std::str::from_utf8(payload(ptr, len)) {
        Ok(t) => t,
        Err(_) => {
            raw::log(raw::Level::Error, "lk_start: config is not UTF-8");
            return None;
        }
    };
    let root = match Json::parse(text) {
        Some(v) => v,
        None => {
            raw::log(raw::Level::Error, "lk_start: config is not JSON");
            return None;
        }
    };
    let api = root.i64_or("abi", 0);
    if api != raw::API_VERSION as i64 {
        crate::log!(
            raw::Level::Error,
            "lk_start: host speaks API {}, this plugin speaks {}",
            api,
            raw::API_VERSION
        );
        return None;
    }
    Some(root.get("config").cloned().unwrap_or(Json::Null))
}

/// Everything the library keeps for one plugin.
struct Driver<P: Plugin, L: ConnSpec> {
    plugin: P,
    scene: Scene,
    conns: Conns<L>,
    draw_timer: i64,
}

impl<P: Source<L>, L: ConnSpec> Driver<P, L> {
    fn new() -> Driver<P, L> {
        Driver {
            plugin: P::default(),
            scene: Scene::new(),
            conns: Conns::new(),
            draw_timer: -1,
        }
    }

    /// True when the status line is the draw timer's to write. A plugin with a
    /// connection list has one line per row, built by the list, and a second
    /// writer would overwrite it once a second.
    fn owns_status(&self) -> bool {
        !Conns::<L>::declared()
    }

    fn read_settings(&mut self, cfg: &Json<'_>) {
        for hook in P::SETTINGS {
            (hook.apply)(cfg);
        }
    }

    /// One frame: gate on freshness, let the plugin describe the scene, send
    /// the difference, and post the status.
    fn run_draw(&mut self) {
        let mono = raw::mono_ms();
        let mut missing = String::new();
        for input in self.plugin.inputs() {
            if input.required() && !input.is_fresh(mono) {
                // Every missing input is named: a line that says "no wind"
                // while the GPS is also out sends the mariner to the wrong
                // instrument.
                if !missing.is_empty() {
                    missing.push_str(", ");
                }
                missing.push_str("no ");
                missing.push_str(input.status_label());
            }
        }
        if !missing.is_empty() {
            // Draws nothing, so everything drawn is deleted.
            Chart::new(&mut self.scene);
            self.scene.commit();
            if self.owns_status() {
                say_text(State::Degraded.text(), &missing);
            }
            return;
        }

        let mut chart = Chart::new(&mut self.scene);
        self.plugin.draw(&mut chart);
        let (state, detail, said) = chart.take_status();
        self.scene.commit();
        if said {
            say_text(state.text(), &detail);
        } else if self.owns_status() {
            say_text(State::Running.text(), "");
        }
    }
}

fn driver<P: Source<L>, L: ConnSpec>() -> Option<&'static mut Driver<P, L>> {
    let slot = SLOT.get();
    if slot.is_none() {
        *slot = Some(Box::new(Driver::<P, L>::new()));
    }
    slot.as_mut()?.downcast_mut::<Driver<P, L>>()
}

pub fn start<P: Source<L>, L: ConnSpec>(ptr: u32, len: u32) -> i32 {
    let config = match parse_start(ptr, len) {
        Some(c) => c,
        None => return -1,
    };
    let d = match driver::<P, L>() {
        Some(d) => d,
        None => return -1,
    };

    d.read_settings(&config);

    let mut paths: Vec<&'static str> = Vec::new();
    let mut wants_ais = false;
    let mut waiting: Vec<&'static str> = Vec::new();
    for input in d.plugin.inputs() {
        if let Some(path) = input.path() {
            paths.push(path);
        }
        wants_ais |= input.wants_ais();
        if input.required() {
            waiting.push(input.status_label());
        }
    }
    if !paths.is_empty() && raw::subscribe_paths(&paths) < 0 {
        raw::log(
            raw::Level::Error,
            "start: the host refused the subscription",
        );
        return -1;
    }
    if wants_ais && raw::ais_subscribe() < 0 {
        raw::log(
            raw::Level::Error,
            "start: the host refused the AIS subscription",
        );
        return -1;
    }
    if Conns::<L>::declared() {
        let Driver { plugin, conns, .. } = d;
        conns.start(plugin, &config);
    }
    if P::DRAW_RATE_MS > 0 {
        d.draw_timer = raw::timer_set(P::DRAW_RATE_MS, true);
        if d.draw_timer < 0 {
            raw::log(raw::Level::Error, "start: the host refused the draw timer");
            return -1;
        }
        if d.owns_status() {
            let detail = if waiting.is_empty() {
                String::new()
            } else {
                format!("waiting for {}", waiting.join(", "))
            };
            say_text(State::Starting.text(), &detail);
        }
    }

    let s = raw::Start {
        api: raw::API_VERSION,
        config,
    };
    match d.plugin.on_start(&s) {
        Ok(()) => 0,
        Err(e) => {
            crate::log!(raw::Level::Error, "start failed: {}", e);
            -1
        }
    }
}

pub fn event<P: Source<L>, L: ConnSpec>(kind: u32, handle: i64, ptr: u32, len: u32) -> i32 {
    let bytes = payload(ptr, len);
    // A text payload that is not text is a host bug, not a plugin one, so it
    // is refused rather than passed on as broken UTF-8.
    let text = std::str::from_utf8(bytes).unwrap_or("");
    let d = match driver::<P, L>() {
        Some(d) => d,
        None => return -1,
    };

    match kind {
        // The library consumes a payload it has an input for, and hands on one
        // it has not: a plugin that declares no input still sees the raw event.
        raw::KIND_STORE_CHANGED => {
            let mut inputs = d.plugin.inputs();
            if !inputs.is_empty() {
                let readings = raw::readings(text);
                let mono = raw::mono_ms();
                for input in &mut inputs {
                    let path = match input.path() {
                        Some(p) => p,
                        None => continue,
                    };
                    for r in &readings {
                        if &*r.path == path {
                            input.take_reading(r, mono);
                        }
                    }
                }
                return 0;
            }
        }
        raw::KIND_AIS_CHANGED => {
            let mut inputs = d.plugin.inputs();
            let mono = raw::mono_ms();
            let mut taken = false;
            for input in &mut inputs {
                if input.wants_ais() {
                    input.take_ais(text, mono);
                    taken = true;
                }
            }
            if taken {
                return 0;
            }
        }
        raw::KIND_CONFIG_CHANGED => {
            let cfg = match Json::parse(text) {
                Some(v) => v,
                None => return 0,
            };
            d.read_settings(&cfg);
            if Conns::<L>::declared() {
                let Driver { plugin, conns, .. } = d;
                conns.config(plugin, &cfg);
            }
            d.plugin.on_settings();
            // A changed setting must show now, not at the next tick.
            if d.draw_timer >= 0 {
                d.run_draw();
            }
            return 0;
        }
        raw::KIND_TIMER => {
            if d.draw_timer >= 0 && handle == d.draw_timer {
                d.run_draw();
                return 0;
            }
            if Conns::<L>::declared() {
                let Driver { plugin, conns, .. } = d;
                if conns.timer(plugin, handle) {
                    return 0;
                }
            }
        }
        raw::KIND_SHUTDOWN => {
            if d.draw_timer >= 0 {
                raw::timer_cancel(d.draw_timer);
                d.draw_timer = -1;
            }
            d.conns.shutdown();
            d.plugin.on_shutdown();
            // The host drops every overlay object a stopped plugin owns, so
            // there is nothing to delete here.
            say_text(State::Stopped.text(), "shut down");
            return 0;
        }
        _ => {}
    }

    let e = match decode(kind, handle, bytes, text) {
        Some(e) => e,
        // The API says an unknown kind is ignored and answered 0. A future
        // host must be able to add events without breaking a plugin built
        // today.
        None => return 0,
    };
    if Conns::<L>::declared() {
        let Driver { plugin, conns, .. } = d;
        if conns.event(plugin, &e) {
            return 0;
        }
    }
    match d.plugin.on_event(&e) {
        Ok(()) => 0,
        Err(err) => {
            crate::log!(raw::Level::Error, "event {} failed: {}", kind, err);
            -1
        }
    }
}

/// One host event, as the plugin sees it. The three kinds the library consumes
/// whole — store, AIS and config — never reach here.
fn decode<'a>(kind: u32, handle: i64, bytes: &'a [u8], text: &'a str) -> Option<raw::Event<'a>> {
    Some(match kind {
        raw::KIND_CONFIG_CHANGED => raw::Event::ConfigChanged(text),
        raw::KIND_TIMER => raw::Event::Timer(handle),
        raw::KIND_TCP_CONNECTED => raw::Event::TcpConnected(handle),
        raw::KIND_TCP_DATA => raw::Event::TcpData {
            conn: handle,
            bytes,
        },
        raw::KIND_TCP_CLOSED => raw::Event::TcpClosed(handle),
        raw::KIND_UDP_DATA => raw::Event::UdpData {
            sock: handle,
            bytes,
        },
        raw::KIND_HTTP_RESPONSE => raw::Event::HttpResponse(raw::http_response(handle, bytes)),
        raw::KIND_FILE_OPENED => {
            let head = Json::parse(text)?;
            raw::Event::FileOpened(raw::FileOpened {
                handle,
                name: head.str_or("name", "").to_owned(),
                size: head.i64_or("size", 0).max(0) as u64,
                writable: head.str_or("mode", "read") == "write",
            })
        }
        raw::KIND_STORE_CHANGED => raw::Event::StoreChanged(text),
        raw::KIND_AIS_CHANGED => raw::Event::AisChanged(text),
        raw::KIND_WS_OPEN => {
            let head = Json::parse(text)?;
            raw::Event::WsOpen(raw::WsOpen {
                conn: handle,
                protocol: head.str_or("protocol", "").to_owned(),
            })
        }
        raw::KIND_WS_DATA => raw::Event::WsData(raw::WsData { conn: handle, text }),
        raw::KIND_WS_CLOSED => {
            let head = Json::parse(text)?;
            raw::Event::WsClosed(raw::WsClosed {
                conn: handle,
                code: head.i64_or("code", 0).clamp(0, 0xffff) as u16,
                reason: head.str_or("reason", "").to_owned(),
            })
        }
        raw::KIND_SHUTDOWN => raw::Event::Shutdown,
        _ => return None,
    })
}

// ---------------------------------------------------------------------------
// Tier 3
// ---------------------------------------------------------------------------

pub fn raw_start<P: raw::RawPlugin + Default + 'static>(ptr: u32, len: u32) -> i32 {
    let config = match parse_start(ptr, len) {
        Some(c) => c,
        None => return -1,
    };
    let slot = SLOT.get();
    if slot.is_none() {
        *slot = Some(Box::new(P::default()));
    }
    let p = match slot.as_mut().and_then(|b| b.downcast_mut::<P>()) {
        Some(p) => p,
        None => return -1,
    };
    let s = raw::Start {
        api: raw::API_VERSION,
        config,
    };
    match p.start(s) {
        Ok(()) => 0,
        Err(e) => {
            crate::log!(raw::Level::Error, "start failed: {}", e);
            -1
        }
    }
}

pub fn raw_event<P: raw::RawPlugin + Default + 'static>(
    kind: u32,
    handle: i64,
    ptr: u32,
    len: u32,
) -> i32 {
    let bytes = payload(ptr, len);
    let text = std::str::from_utf8(bytes).unwrap_or("");
    let e = match decode(kind, handle, bytes, text) {
        Some(e) => e,
        None => return 0,
    };
    let p = match SLOT.get().as_mut().and_then(|b| b.downcast_mut::<P>()) {
        Some(p) => p,
        None => return -1,
    };
    match p.on_event(e) {
        Ok(()) => 0,
        Err(err) => {
            crate::log!(raw::Level::Error, "event {} failed: {}", kind, err);
            -1
        }
    }
}
