//! Connections the mariner keeps, owned by the library.
//!
//! A source plugin declares the list once as a type, and writes `on_data`:
//!
//! ```ignore
//! struct Servers;
//!
//! impl lk::ConnSpec for Servers {
//!     type Columns = SkColumns;      // beyond the four every list carries
//!     type State = Framer;           // per-connection parse state
//!     const OPTS: lk::ConnOpts = lk::ConnOpts {
//!         key: "servers",
//!         group: "Signal K servers",
//!         add_label: "Add Server",
//!         status_empty: "no servers",
//!         ..lk::ConnOpts::DEFAULT
//!     };
//! }
//!
//! impl lk::Source<Servers> for SignalK {
//!     fn on_data(&mut self, conn: &mut lk::Connection<Servers>, bytes: &[u8]) { … }
//! }
//! ```
//!
//! The library owns everything else: the settings list schema, one socket per
//! connection, the reconnect clock, the failure count behind "unreachable",
//! the pause switch, the per-row status item and the plugin's own status line.
//!
//! CONNECTIONS ARE MATCHED BY ID. Editing one connection never disturbs
//! another: only an address change, a pause or a delete closes a socket.

use crate::json::{self, Json};
use crate::raw;
use crate::settings::{
    Discover, Field, Fields, Flag, Group, ListInfo, Num, Spec, Tab, Text, MAX_ROWS,
};

/// The four columns every connection list carries, in the order a shell draws
/// them. A caller overrides the wording and the port's range; the keys and the
/// kinds are fixed, because the library dials the row itself.
#[derive(Debug, Clone, Copy)]
pub struct RowColumns {
    pub name: Text,
    pub host: Text,
    pub port: Num,
    pub enabled: Flag,
}

impl RowColumns {
    pub const DEFAULT: RowColumns = RowColumns {
        name: Text {
            label: "Name",
            desc: "What you call this source. Leave it empty to show the address.",
            default: "",
            optional: true,
        },
        host: Text {
            label: "Address",
            desc: "The name or IP address to connect to.",
            default: "",
            optional: false,
        },
        port: Num {
            label: "Port",
            desc: "The port to connect to.",
            unit: "",
            min: 1.0,
            max: 65535.0,
            default: 10110.0,
        },
        enabled: Flag {
            label: "On",
            desc: "Off closes the connection and stops reconnecting.",
            default: true,
        },
    };
}

/// How one connection list behaves.
#[derive(Debug, Clone, Copy)]
pub struct ConnOpts {
    /// The config key the connection array arrives under. Empty means the
    /// plugin has no connection list.
    pub key: &'static str,
    /// The section heading in the settings window.
    pub group: &'static str,
    pub tab: Tab,
    pub footer: &'static str,
    pub empty: &'static str,
    pub add_label: &'static str,
    /// What a shell browses the boat's network for on this list's behalf, so a
    /// source already running is offered ready to add.
    pub discover: &'static [Discover],
    /// The wording of the four standard columns, and the port's range.
    pub columns: RowColumns,
    /// Delay before a dropped connection is retried.
    pub reconnect_ms: i64,
    /// Failed connects in a row before a connection reads as unreachable
    /// rather than reconnecting. Three tries is six seconds of silence.
    pub unreachable_after: u32,
    /// How often the status is rebuilt, and the window a rate is averaged
    /// over.
    pub status_ms: i64,
    /// What `conn.count` counts, for the status: "42 msg/s".
    pub rate_noun: &'static str,
    /// The plugin's status detail when the mariner has added no connections.
    pub status_empty: &'static str,
    /// What a connection says once it has read as unreachable.
    pub no_answer_detail: &'static str,
    /// What a connection says when the host would not dial it at all. That only
    /// happens when the manifest's grant does not cover the address, and only
    /// the plugin knows which grant it asked for.
    pub refused_detail: &'static str,
}

impl ConnOpts {
    pub const DEFAULT: ConnOpts = ConnOpts {
        key: "",
        group: "",
        tab: Tab::Connections,
        footer: "",
        empty: "",
        add_label: "",
        discover: &[],
        columns: RowColumns::DEFAULT,
        reconnect_ms: 2_000,
        unreachable_after: 3,
        status_ms: 2_000,
        rate_noun: "msg",
        status_empty: "nothing configured",
        no_answer_detail: "check the address",
        refused_detail: "the host refused this address",
    };
}

/// One connection list: its columns, its per-connection state and its wording.
pub trait ConnSpec: 'static {
    /// Columns beyond the four every list carries. `()` for none.
    type Columns: Fields;
    /// Per-connection state the plugin keeps: a framer, a parser, an identity.
    type State: Default;
    const OPTS: ConnOpts;

    /// This list's entry in the manifest's settings schema.
    fn schema() -> Group {
        let o = Self::OPTS;
        let mut fields = vec![
            Field {
                key: "name",
                spec: Spec::Text(o.columns.name),
            },
            Field {
                key: "host",
                spec: Spec::Text(o.columns.host),
            },
            Field {
                key: "port",
                spec: Spec::Num(o.columns.port),
            },
        ];
        fields.extend_from_slice(Self::Columns::FIELDS);
        // The switch goes last: a shell draws the columns in order and the
        // address is what a mariner fills in first.
        fields.push(Field {
            key: "enabled",
            spec: Spec::Flag(o.columns.enabled),
        });
        Group {
            label: o.group.to_owned(),
            tab: o.tab,
            fields,
            list: Some(ListInfo {
                key: o.key.to_owned(),
                footer: o.footer.to_owned(),
                empty: o.empty.to_owned(),
                add_label: o.add_label.to_owned(),
                discover: o.discover.to_vec(),
                switch_key: "enabled".to_owned(),
            }),
        }
    }
}

/// A plugin with no connection list.
pub struct NoConns;

impl ConnSpec for NoConns {
    type Columns = ();
    type State = ();
    const OPTS: ConnOpts = ConnOpts::DEFAULT;
}

/// Where one connection is dialled.
#[derive(Debug, Clone)]
pub enum Endpoint {
    Tcp {
        host: String,
        port: u16,
    },
    /// A websocket URL. The manifest must grant `net.ws` for its host.
    Ws(String),
    /// This connection cannot be dialled, and the text says why. The library
    /// stops retrying and shows the reason on the connection's line.
    Refused(String),
}

/// What one connection is doing, in the words the shell shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowState {
    Connected,
    Reconnecting,
    /// Dialled and dialled and nothing answered.
    NoAnswer,
    Paused,
    /// The connection has no address, or a port nothing can dial.
    NoAddress,
    /// The endpoint refused the connection outright: a grant that does not
    /// cover it.
    Refused,
}

impl RowState {
    fn text(self) -> &'static str {
        match self {
            RowState::Connected => "connected",
            RowState::Reconnecting => "reconnecting",
            RowState::NoAnswer => "unreachable",
            RowState::Paused => "paused",
            RowState::NoAddress => "no_address",
            RowState::Refused => "refused",
        }
    }
}

/// One connection: the row the mariner filled in, the plugin's own state for
/// it, and the socket the library holds.
pub struct Connection<L: ConnSpec> {
    /// The shell's id for this row. It survives an edit, and it is what a
    /// status item points at.
    pub id: String,
    /// What the mariner calls it. May be empty.
    pub name: String,
    pub host: String,
    pub port: u16,
    /// False means PAUSED: the stream closes and nothing reconnects.
    pub enabled: bool,
    /// The plugin's own columns.
    pub cols: L::Columns,
    /// The plugin's own state for this connection.
    pub state: L::State,

    seen: bool,
    /// Where the row sits in the mariner's list, so the status items come back
    /// in the order the settings window shows.
    order: usize,

    sock: i64,
    ws: bool,
    retry_timer: i64,
    failures: u32,
    conn: RowState,

    counted: u64,
    last_counted: u64,
    rate: u64,
    detail: String,
}

impl<L: ConnSpec> Connection<L> {
    fn new(id: &str) -> Connection<L> {
        Connection {
            id: id.to_owned(),
            name: String::new(),
            host: String::new(),
            port: 0,
            enabled: true,
            cols: L::Columns::default(),
            state: L::State::default(),
            seen: true,
            order: 0,
            sock: -1,
            ws: false,
            retry_timer: -1,
            failures: 0,
            conn: RowState::Reconnecting,
            counted: 0,
            last_counted: 0,
            rate: 0,
            detail: String::new(),
        }
    }

    /// What to call this connection: the mariner's name, or the address.
    pub fn label(&self) -> &str {
        if self.name.is_empty() {
            &self.host
        } else {
            &self.name
        }
    }

    /// True while the stream is up.
    pub fn connected(&self) -> bool {
        self.conn == RowState::Connected
    }

    /// What this connection has carried in the last status window, per
    /// second.
    pub fn rate(&self) -> u64 {
        self.rate
    }

    /// Write to this connection's stream. Returns the bytes queued, or -1.
    pub fn send(&mut self, bytes: &[u8]) -> i32 {
        if self.sock < 0 {
            return -1;
        }
        if self.ws {
            match std::str::from_utf8(bytes) {
                Ok(text) => raw::ws_send(self.sock, text),
                // A websocket carries TEXT here; bytes that are not text would
                // be dropped by the host with a log line.
                Err(_) => -1,
            }
        } else {
            raw::tcp_send(self.sock, bytes)
        }
    }

    /// Count `n` of whatever this connection carries. The library turns it
    /// into the rate on the connection's status line and in the plugin's.
    pub fn count(&mut self, n: u64) {
        self.counted += n;
    }

    /// Add a phrase to this connection's status line, after the state. Say
    /// nothing that only repeats the state.
    pub fn set_detail(&mut self, text: &str) {
        self.detail.clear();
        self.detail.push_str(text);
    }

    /// A connection with no address cannot be dialled.
    fn usable(&self) -> bool {
        !self.host.is_empty() && self.port > 0
    }

    fn close_socket(&mut self) {
        if self.sock >= 0 {
            if self.ws {
                raw::ws_close(self.sock);
            } else {
                raw::tcp_close(self.sock);
            }
        }
        self.sock = -1;
        if self.retry_timer >= 0 {
            raw::timer_cancel(self.retry_timer);
        }
        self.retry_timer = -1;
        self.rate = 0;
    }

    fn schedule_retry(&mut self) {
        if self.retry_timer >= 0 || !self.enabled || !self.usable() {
            return;
        }
        let id = raw::timer_set(L::OPTS.reconnect_ms, false);
        if id >= 0 {
            self.retry_timer = id;
        }
    }

    fn note_failure(&mut self) {
        if self.failures < L::OPTS.unreachable_after {
            self.failures += 1;
        }
        if self.failures >= L::OPTS.unreachable_after {
            self.conn = RowState::NoAnswer;
            self.set_detail(L::OPTS.no_answer_detail);
        } else {
            self.conn = RowState::Reconnecting;
            self.set_detail("");
        }
    }
}

/// What a source plugin writes. Everything but `on_data` has a default.
pub trait Source<L: ConnSpec>: crate::Plugin {
    /// Bytes from one connection's socket.
    fn on_data(&mut self, conn: &mut Connection<L>, bytes: &[u8]);

    /// A stream came up. Send a subscription here.
    fn on_open(&mut self, conn: &mut Connection<L>) {
        let _ = conn;
    }

    /// A stream ended.
    fn on_close(&mut self, conn: &mut Connection<L>) {
        let _ = conn;
    }

    /// A phrase to add after the connection's rate while the stream is up.
    fn connection_note(&mut self, conn: &Connection<L>) -> String {
        let _ = conn;
        String::new()
    }

    /// Where to dial, when it is not the connection's host and port: a
    /// websocket URL, say.
    fn endpoint(&mut self, conn: &Connection<L>) -> Endpoint {
        Endpoint::Tcp {
            host: conn.host.clone(),
            port: conn.port,
        }
    }
}

/// A plugin with no list still satisfies the trait, so tier 1 declares
/// nothing.
impl<P: crate::Plugin> Source<NoConns> for P {
    fn on_data(&mut self, conn: &mut Connection<NoConns>, bytes: &[u8]) {
        let _ = (conn, bytes);
    }
}

/// The connections, the sockets and the status line. The library owns one of
/// these per plugin; a plugin reaches its connections through the hooks.
pub struct Conns<L: ConnSpec> {
    conns: Vec<Connection<L>>,
    status_timer: i64,
    last_status: String,
}

impl<L: ConnSpec> Default for Conns<L> {
    fn default() -> Self {
        Self::new()
    }
}

impl<L: ConnSpec> Conns<L> {
    pub fn new() -> Conns<L> {
        Conns {
            conns: Vec::new(),
            status_timer: -1,
            last_status: String::new(),
        }
    }

    /// True when the plugin declared a list at all.
    pub(crate) fn declared() -> bool {
        !L::OPTS.key.is_empty()
    }

    /// Every connection the mariner has, in slot order.
    pub fn all(&self) -> &[Connection<L>] {
        &self.conns
    }

    /// The connection with this id, or nothing.
    pub fn by_id(&mut self, id: &str) -> Option<&mut Connection<L>> {
        self.conns.iter_mut().find(|r| r.id == id)
    }

    // ---- what the driver calls --------------------------------------------

    pub(crate) fn start<P: Source<L>>(&mut self, p: &mut P, cfg: &Json<'_>) {
        self.reconcile(p, cfg);
        self.status_timer = raw::timer_set(L::OPTS.status_ms, true);
        self.post_status(p);
    }

    pub(crate) fn config<P: Source<L>>(&mut self, p: &mut P, cfg: &Json<'_>) {
        self.reconcile(p, cfg);
        self.post_status(p);
    }

    /// True when the timer was the library's.
    pub(crate) fn timer<P: Source<L>>(&mut self, p: &mut P, id: i64) -> bool {
        if id >= 0 && id == self.status_timer {
            self.post_status(p);
            return true;
        }
        let at = match self.conns.iter().position(|r| r.retry_timer == id) {
            Some(i) => i,
            None => return false,
        };
        self.conns[at].retry_timer = -1;
        self.open(p, at);
        true
    }

    /// True when the event belonged to one of these connections.
    pub(crate) fn event<P: Source<L>>(&mut self, p: &mut P, e: &raw::Event<'_>) -> bool {
        match e {
            raw::Event::TcpConnected(id) => match self.by_socket(*id, false) {
                Some(at) => self.opened(p, at),
                None => return false,
            },
            raw::Event::WsOpen(w) => match self.by_socket(w.conn, true) {
                Some(at) => self.opened(p, at),
                None => return false,
            },
            raw::Event::TcpData { conn, bytes } => match self.by_socket(*conn, false) {
                Some(at) => p.on_data(&mut self.conns[at], bytes),
                None => return false,
            },
            raw::Event::WsData(w) => match self.by_socket(w.conn, true) {
                Some(at) => p.on_data(&mut self.conns[at], w.text.as_bytes()),
                None => return false,
            },
            raw::Event::TcpClosed(id) => match self.by_socket(*id, false) {
                Some(at) => self.ended(p, at),
                None => return false,
            },
            raw::Event::WsClosed(w) => match self.by_socket(w.conn, true) {
                Some(at) => self.ended(p, at),
                None => return false,
            },
            _ => return false,
        }
        true
    }

    pub(crate) fn shutdown(&mut self) {
        for r in &mut self.conns {
            r.close_socket();
        }
        self.conns.clear();
        if self.status_timer >= 0 {
            raw::timer_cancel(self.status_timer);
        }
        self.status_timer = -1;
    }

    // ---- the connection itself --------------------------------------------

    fn by_socket(&self, id: i64, ws: bool) -> Option<usize> {
        if id < 0 {
            return None;
        }
        self.conns.iter().position(|r| r.sock == id && r.ws == ws)
    }

    /// Ask for a connection. The result arrives later as an open or a close
    /// event, so only an outright refusal is visible here.
    fn open<P: Source<L>>(&mut self, p: &mut P, at: usize) {
        if !self.conns[at].enabled {
            self.conns[at].conn = RowState::Paused;
            return;
        }
        if !self.conns[at].usable() {
            self.conns[at].conn = RowState::NoAddress;
            return;
        }
        match p.endpoint(&self.conns[at]) {
            Endpoint::Tcp { host, port } => {
                self.conns[at].ws = false;
                self.conns[at].sock = raw::tcp_connect(&host, port);
            }
            Endpoint::Ws(url) => {
                self.conns[at].ws = true;
                self.conns[at].sock = raw::ws_connect(&url, &[]);
            }
            Endpoint::Refused(why) => {
                self.conns[at].conn = RowState::Refused;
                let why = why.clone();
                self.conns[at].set_detail(&why);
                return;
            }
        }
        if self.conns[at].sock < 0 {
            self.conns[at].sock = -1;
            // The host would not make the call at all, and the only reason it
            // does that is the grant. Retrying is a refusal every two seconds
            // for ever, so the connection stops and says what is wrong.
            if self.conns[at].ws {
                self.conns[at].conn = RowState::Refused;
                self.conns[at].set_detail(L::OPTS.refused_detail);
                return;
            }
            self.conns[at].note_failure();
            self.conns[at].schedule_retry();
        }
    }

    fn opened<P: Source<L>>(&mut self, p: &mut P, at: usize) {
        {
            let r = &mut self.conns[at];
            r.conn = RowState::Connected;
            r.failures = 0;
            r.last_counted = r.counted;
            r.rate = 0;
            r.set_detail("");
        }
        p.on_open(&mut self.conns[at]);
        self.post_status(p);
    }

    fn ended<P: Source<L>>(&mut self, p: &mut P, at: usize) {
        self.conns[at].sock = -1;
        p.on_close(&mut self.conns[at]);
        // The close of a connection the mariner just switched off is not a
        // failure, and must not read as one.
        let r = &mut self.conns[at];
        if r.enabled && r.usable() {
            r.note_failure();
            r.schedule_retry();
        }
        self.post_status(p);
    }

    /// Take the mariner's list and make the streams match it.
    fn reconcile<P: Source<L>>(&mut self, p: &mut P, cfg: &Json<'_>) {
        for r in &mut self.conns {
            r.seen = false;
        }

        let items: Vec<&Json<'_>> = cfg
            .get(L::OPTS.key)
            .and_then(Json::as_array)
            .map(|a| a.iter().collect())
            .unwrap_or_default();

        for (order, item) in items.into_iter().enumerate() {
            let id = match item.get("id").and_then(Json::as_str) {
                Some(id) if !id.is_empty() => id.to_owned(),
                _ => continue,
            };
            let (at, fresh) = match self.conns.iter().position(|r| r.id == id) {
                Some(at) => (at, false),
                None => {
                    if self.conns.len() == MAX_ROWS {
                        continue;
                    }
                    self.conns.push(Connection::new(&id));
                    (self.conns.len() - 1, true)
                }
            };

            let r = &mut self.conns[at];
            let was_enabled = !fresh && r.enabled;
            let old_host = std::mem::take(&mut r.host);
            let old_port = r.port;
            let old_cols = r.cols.clone();

            r.seen = true;
            r.order = order;
            r.name = item.str_or("name", "").to_owned();
            r.host = item.str_or("host", "").to_owned();
            let port = item.i64_or("port", L::OPTS.columns.port.default as i64);
            r.port = if (1..=65535).contains(&port) {
                port as u16
            } else {
                0
            };
            r.enabled = item.bool_or("enabled", true);
            r.cols.read(item);

            // A column of the plugin's own may pick the transport, so a change
            // to one is a change of address.
            let moved = fresh || old_host != r.host || old_port != r.port || old_cols != r.cols;

            if !r.enabled {
                r.close_socket();
                r.conn = RowState::Paused;
                r.failures = 0;
            } else if !r.usable() {
                r.close_socket();
                r.conn = RowState::NoAddress;
            } else if moved || !was_enabled {
                // A new address, or a connection just switched back on: start
                // over, including the count behind "unreachable".
                r.close_socket();
                r.failures = 0;
                r.conn = RowState::Reconnecting;
                r.state = L::State::default();
                self.open(p, at);
            } else if r.sock < 0 && r.retry_timer < 0 {
                self.open(p, at);
            }
        }

        // A connection the mariner deleted takes its stream with it.
        for r in &mut self.conns {
            if !r.seen {
                r.close_socket();
            }
        }
        self.conns.retain(|r| r.seen);
    }

    // ---- the status line ---------------------------------------------------

    /// The plugin's line, and one item per row for the settings window. The
    /// item ids are the row ids the shell assigned, which is how each row's
    /// line finds its way back to the right row.
    fn post_status<P: Source<L>>(&mut self, p: &mut P) {
        let mut order: Vec<usize> = (0..self.conns.len()).collect();
        order.sort_by_key(|&i| self.conns[i].order);

        let mut live = 0usize;
        let mut total = 0u64;
        for &i in &order {
            self.sample_rate(i);
            if self.conns[i].connected() {
                live += 1;
                total += self.conns[i].rate;
            }
        }

        let n = order.len();
        let state = if live > 0 { "running" } else { "degraded" };
        let detail = if n == 0 {
            L::OPTS.status_empty.to_owned()
        } else if live > 0 {
            format!(
                "{} of {} connected, {} {}/s",
                live,
                n,
                total,
                L::OPTS.rate_noun
            )
        } else {
            format!("0 of {} connected", n)
        };

        let mut out = String::with_capacity(256);
        out.push_str("{\"state\":");
        json::push_str(&mut out, state);
        out.push_str(",\"detail\":");
        json::push_str(&mut out, &detail);
        out.push_str(",\"items\":[");
        for (k, &i) in order.iter().enumerate() {
            if k > 0 {
                out.push(',');
            }
            let line = if self.conns[i].connected() {
                let mut line = format!("{} {}/s", self.conns[i].rate, L::OPTS.rate_noun);
                let note = p.connection_note(&self.conns[i]);
                if !note.is_empty() {
                    line.push_str(", ");
                    line.push_str(&note);
                }
                line
            } else {
                self.conns[i].detail.clone()
            };
            out.push_str("{\"id\":");
            json::push_str(&mut out, &self.conns[i].id);
            out.push_str(",\"state\":");
            json::push_str(&mut out, self.conns[i].conn.text());
            out.push_str(",\"detail\":");
            json::push_str(&mut out, &line);
            out.push('}');
        }
        out.push_str("]}");

        // The host logs a status text it has not seen, so a 2 s repeat of the
        // same line would be a log line every 2 s.
        if self.last_status == out {
            return;
        }
        self.last_status.clear();
        self.last_status.push_str(&out);
        raw::status_json(&out);
    }

    fn sample_rate(&mut self, at: usize) {
        let r = &mut self.conns[at];
        let diff = r.counted - r.last_counted;
        r.last_counted = r.counted;
        if !r.connected() {
            r.rate = 0;
            return;
        }
        let window = L::OPTS.status_ms.max(1) as u64;
        r.rate = (diff * 1000 + window / 2) / window;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::settings_json;
    use crate::{Chart, Plugin};

    crate::columns! {
        pub struct SkColumns {
            websocket: Flag { label: "WebSocket", default: false },
        }
    }

    struct Servers;

    impl ConnSpec for Servers {
        type Columns = SkColumns;
        type State = u32;
        const OPTS: ConnOpts = ConnOpts {
            key: "servers",
            group: "Signal K servers",
            add_label: "Add Server",
            discover: &[Discover {
                service: "_signalk-ws._tcp",
                set: r#"{"websocket":true}"#,
            }],
            status_empty: "no servers",
            columns: RowColumns {
                port: Num {
                    label: "Port",
                    desc: "The port to connect to.",
                    unit: "",
                    min: 1.0,
                    max: 65535.0,
                    default: 8375.0,
                },
                ..RowColumns::DEFAULT
            },
            ..ConnOpts::DEFAULT
        };
    }

    #[derive(Default)]
    struct Fake {
        seen: Vec<(String, String)>,
        opened: Vec<String>,
    }

    impl Plugin for Fake {
        fn draw(&mut self, _c: &mut Chart<'_>) {}
    }

    impl Source<Servers> for Fake {
        fn on_data(&mut self, conn: &mut Connection<Servers>, bytes: &[u8]) {
            conn.count(1);
            self.seen
                .push((conn.id.clone(), String::from_utf8_lossy(bytes).into_owned()));
        }
        fn on_open(&mut self, conn: &mut Connection<Servers>) {
            self.opened.push(conn.id.clone());
        }
    }

    // Off wasm every host call answers "refused", so a connection never opens
    // and nothing is dialled. What is testable here is the bookkeeping: which
    // connections exist, what they carry, and what the schema says.

    #[test]
    fn a_connection_list_is_matched_by_id_and_a_deleted_connection_goes() {
        let mut p = Fake::default();
        let mut c: Conns<Servers> = Conns::new();
        let cfg = Json::parse(
            r#"{"servers":[{"id":"a","host":"10.0.0.2","port":3000,"websocket":true},
                           {"id":"b","name":"Nav PC","host":"10.0.0.3"}]}"#,
        )
        .unwrap();
        c.reconcile(&mut p, &cfg);
        assert_eq!(c.all().len(), 2);
        assert_eq!(c.by_id("a").unwrap().port, 3000);
        assert!(c.by_id("a").unwrap().cols.websocket);
        // The port column's own default, not the standard 10110.
        assert_eq!(c.by_id("b").unwrap().port, 8375);
        assert_eq!(c.by_id("b").unwrap().label(), "Nav PC");
        assert_eq!(c.by_id("a").unwrap().label(), "10.0.0.2");

        let cfg = Json::parse(r#"{"servers":[{"id":"b","host":"10.0.0.3"}]}"#).unwrap();
        c.reconcile(&mut p, &cfg);
        assert_eq!(c.all().len(), 1);
        assert!(c.by_id("a").is_none());
    }

    #[test]
    fn a_paused_connection_is_paused_and_one_with_no_address_says_so() {
        let mut p = Fake::default();
        let mut c: Conns<Servers> = Conns::new();
        let cfg = Json::parse(
            r#"{"servers":[{"id":"a","host":"10.0.0.2","enabled":false},
                           {"id":"b","host":"","port":3000}]}"#,
        )
        .unwrap();
        c.reconcile(&mut p, &cfg);
        assert_eq!(c.by_id("a").unwrap().conn, RowState::Paused);
        assert_eq!(c.by_id("b").unwrap().conn, RowState::NoAddress);
    }

    #[test]
    fn data_reaches_on_data_with_the_connection_that_carried_it() {
        let mut p = Fake::default();
        let mut c: Conns<Servers> = Conns::new();
        c.reconcile(
            &mut p,
            &Json::parse(r#"{"servers":[{"id":"a","host":"10.0.0.2","port":3000}]}"#).unwrap(),
        );
        // Off wasm nothing dials, so the socket is planted by hand to drive the
        // routing the host would drive.
        c.conns[0].sock = 42;
        c.conns[0].conn = RowState::Connected;
        assert!(c.event(
            &mut p,
            &raw::Event::TcpData {
                conn: 42,
                bytes: b"$GPRMC,,,,",
            }
        ));
        assert_eq!(p.seen.len(), 1);
        assert_eq!(p.seen[0].0, "a");
        assert_eq!(c.all()[0].counted, 1);
        // Another plugin's socket is not this list's business.
        assert!(!c.event(
            &mut p,
            &raw::Event::TcpData {
                conn: 43,
                bytes: b"x",
            }
        ));
    }

    #[test]
    fn the_rate_is_what_arrived_over_the_status_window() {
        let mut p = Fake::default();
        let mut c: Conns<Servers> = Conns::new();
        c.reconcile(
            &mut p,
            &Json::parse(r#"{"servers":[{"id":"a","host":"10.0.0.2","port":3000}]}"#).unwrap(),
        );
        c.conns[0].conn = RowState::Connected;
        c.conns[0].count(84);
        c.sample_rate(0);
        // 84 in a 2 s window is 42 a second.
        assert_eq!(c.all()[0].rate(), 42);
    }

    #[test]
    fn the_list_schema_puts_the_switch_last_and_names_it() {
        let json = settings_json(&[Servers::schema()]);
        let root = Json::parse(&json).unwrap();
        let group = &root.get("groups").unwrap().as_array().unwrap()[0];
        let list = group.get("list").unwrap();
        assert_eq!(list.str_or("key", ""), "servers");
        assert_eq!(list.str_or("switch_key", ""), "enabled");
        assert_eq!(list.str_or("add_label", ""), "Add Server");

        // What a shell browses for, and what a row takes from a find beyond
        // its address.
        let found = list.get("discover").unwrap().as_array().unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].str_or("service", ""), "_signalk-ws._tcp");
        assert!(found[0].get("set").unwrap().bool_or("websocket", false));

        let cols = list.get("item_fields").unwrap().as_array().unwrap();
        let want = ["name", "host", "port", "websocket", "enabled"];
        assert_eq!(cols.len(), want.len());
        for (got, key) in cols.iter().zip(want) {
            assert_eq!(got.str_or("key", ""), key);
        }
        // An optional text column declares no default; a required one does.
        assert!(cols[0].get("default").is_none());
        assert!(cols[0].bool_or("optional", false));
        assert_eq!(cols[1].str_or("default", "missing"), "");
        assert_eq!(cols[2].f64_or("default", 0.0), 8375.0);
    }
}
