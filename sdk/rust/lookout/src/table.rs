//! Tables: the dialogs a plugin fills. A table is data, not drawing. There is
//! no capability to ask for, and the library runs its cycle on the data path,
//! around [`crate::Plugin::on_update`].
//!
//! ```ignore
//! const TARGETS: lk::TableSpec = lk::TableSpec {
//!     key: "targets",
//!     title: "AIS Targets",
//!     menu: "Vessels",
//!     columns: &[
//!         lk::Column::text("name", "Vessel"),
//!         lk::Column::new("cpa", "CPA", lk::ColumnType::Distance),
//!     ],
//!     sort: Some(lk::TableSort::by("cpa")),
//!     at: None,
//! };
//!
//! impl lk::Plugin for Ais {
//!     fn tables(&mut self) -> Vec<&mut lk::Table> {
//!         vec![&mut self.targets]
//!     }
//!
//!     fn on_update(&mut self) {
//!         if !self.targets.is_open() {
//!             return;
//!         }
//!         for t in self.traffic.targets() {
//!             self.targets
//!                 .row(&t.mmsi.to_string())
//!                 .num("cpa", cpa_of(t))
//!                 .done();
//!         }
//!     }
//! }
//! ```

use crate::geo::Point;
use crate::json;
use crate::raw;

/// What a column carries. THE PLUGIN SENDS SI AND THE SHELL FORMATS: metres,
/// metres per second, degrees true, seconds. That is the reverse of a pick row,
/// and it is what lets the shell sort a column numerically and show it in the
/// mariner's own units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    Distance,
    Speed,
    Bearing,
    Duration,
    Number,
    Text,
    /// A state word the shell colours: `"alarm"`, `"warning"`.
    Flag,
}

impl ColumnType {
    fn text(self) -> &'static str {
        match self {
            ColumnType::Distance => "distance",
            ColumnType::Speed => "speed",
            ColumnType::Bearing => "bearing",
            ColumnType::Duration => "duration",
            ColumnType::Number => "number",
            ColumnType::Text => "text",
            ColumnType::Flag => "flag",
        }
    }

    fn is_text(self) -> bool {
        matches!(self, ColumnType::Text | ColumnType::Flag)
    }
}

/// One declared column. An empty label is a column with no heading, which is
/// what a flag column usually wants.
#[derive(Debug, Clone, Copy)]
pub struct Column {
    pub key: &'static str,
    pub label: &'static str,
    pub kind: ColumnType,
}

impl Column {
    pub const fn new(key: &'static str, label: &'static str, kind: ColumnType) -> Column {
        Column { key, label, kind }
    }

    pub const fn text(key: &'static str, label: &'static str) -> Column {
        Column::new(key, label, ColumnType::Text)
    }

    /// A state word with no heading of its own.
    pub const fn flag(key: &'static str) -> Column {
        Column::new(key, "", ColumnType::Flag)
    }
}

/// The column the shell sorts by until the mariner says otherwise.
#[derive(Debug, Clone, Copy)]
pub struct TableSort {
    pub key: &'static str,
    pub ascending: bool,
}

impl TableSort {
    pub const fn by(key: &'static str) -> TableSort {
        TableSort {
            key,
            ascending: true,
        }
    }

    pub const fn descending(key: &'static str) -> TableSort {
        TableSort {
            key,
            ascending: false,
        }
    }
}

/// The two row keys carrying a position. A row that has them is locatable: the
/// mariner activates it and the chart centres on it. They need not be columns;
/// a position is usually not worth a column of its own.
#[derive(Debug, Clone, Copy)]
pub struct TableAt {
    pub lat: &'static str,
    pub lon: &'static str,
}

/// One dialog, declared. The declaration is the whole contract: the shell
/// builds the dialog from it, opens it from the menu it names, sorts any
/// column, and formats every value for the mariner. Write it as a `const`.
#[derive(Debug, Clone, Copy)]
pub struct TableSpec {
    pub key: &'static str,
    pub title: &'static str,
    /// Where the shell opens the dialog from: `"Vessels"`.
    pub menu: &'static str,
    pub columns: &'static [Column],
    pub sort: Option<TableSort>,
    pub at: Option<TableAt>,
}

/// Columns one table may declare. The host's budget, and the reason for it: a
/// table wider than this is a spreadsheet, and nobody reads a spreadsheet on a
/// moving boat.
pub const MAX_COLUMNS: usize = 16;

/// Rows one plugin's diff holds between cycles. The host takes 512.
pub const MAX_TABLE_ROWS: usize = 256;

/// The shortest gap between two batches, measured from the start of one cycle
/// to the start of the next. The library holds a batch back rather than have
/// the host refuse it, and it leaves itself the margin between this and the
/// host's own 900 ms.
pub const TABLE_INTERVAL_MS: i64 = 950;

struct Entry {
    id: String,
    hash: u64,
    live: bool,
    seen: bool,
}

/// One declared dialog and the rows it holds. List it in
/// [`crate::Plugin::tables`] and the library declares it at start, tells you
/// when the mariner opens it, and sends what changed once a cycle.
///
/// DESCRIBE THE WHOLE SET EVERY CYCLE, the way `draw` describes the whole
/// picture: a row you do not upsert leaves the table. There is no delete call.
pub struct Table {
    spec: TableSpec,
    entries: Vec<Entry>,
    buf: String,
    sets: usize,
    /// True between the start of a cycle and its end, and only while the dialog
    /// is open and the cadence allows another batch.
    building: bool,
    open: bool,
    /// When the last batch that went out was BUILT, monotonic. Measuring from
    /// the start of a cycle rather than from the send keeps the gap the host
    /// sees a shade wider than the one measured here.
    last_ms: i64,
    cycle_ms: i64,
    warned: Vec<String>,
}

impl Table {
    pub const fn new(spec: TableSpec) -> Table {
        Table {
            spec,
            entries: Vec::new(),
            buf: String::new(),
            sets: 0,
            building: false,
            open: false,
            last_ms: 0,
            cycle_ms: 0,
            warned: Vec::new(),
        }
    }

    /// The table's key, as the manifest and the host know it.
    pub fn key(&self) -> &'static str {
        self.spec.key
    }

    /// True while the mariner has the dialog on screen. Skip the work of
    /// building rows nobody is looking at.
    pub fn is_open(&self) -> bool {
        self.open
    }

    /// Start one row. `id` names it for its whole life. Set its cells and call
    /// [`Row::done`].
    #[must_use = "a row is only held once done() is called"]
    pub fn row(&mut self, id: &str) -> Row<'_> {
        if !self.building || id.is_empty() {
            return Row {
                table: self,
                id: String::new(),
                live: false,
                start: 0,
                body: 0,
            };
        }
        let start = self.buf.len();
        if self.sets > 0 {
            self.buf.push(',');
        }
        let body = self.buf.len();
        self.buf.push_str("{\"id\":");
        json::push_str(&mut self.buf, id);
        Row {
            table: self,
            id: id.to_owned(),
            live: true,
            start,
            body,
        }
    }

    /// Take one row out now, without waiting for a cycle to pass it by.
    pub fn remove(&mut self, id: &str) {
        if let Some(e) = self.entries.iter_mut().find(|e| e.id == id) {
            e.seen = false;
        }
    }

    /// Tell the host about the declaration. The library calls this at start.
    pub(crate) fn declare(&self) {
        if raw::table_declare_json(&self.declaration()) < 0 {
            crate::log!(
                raw::Level::Warn,
                "table {}: the host refused the declaration",
                self.spec.key
            );
        }
    }

    /// Start a cycle. The library calls this before `on_update`.
    pub(crate) fn begin(&mut self, mono: i64) {
        self.building =
            self.open && (self.last_ms == 0 || mono - self.last_ms >= TABLE_INTERVAL_MS);
        if !self.building {
            return;
        }
        self.cycle_ms = mono;
        for e in &mut self.entries {
            e.seen = false;
        }
        self.buf.clear();
        self.buf.push_str("{\"key\":");
        json::push_str(&mut self.buf, self.spec.key);
        self.buf.push_str(",\"upsert\":[");
        self.sets = 0;
    }

    /// Close the batch, and report whether there is anything to send. `commit`
    /// is what sends it; a test reads the batch through here.
    pub(crate) fn finish(&mut self) -> bool {
        if !self.building {
            return false;
        }
        self.building = false;
        let dels = self.entries.iter().filter(|e| e.live && !e.seen).count();
        if self.sets == 0 && dels == 0 {
            return false;
        }
        self.buf.push_str("],\"remove\":[");
        let mut k = 0;
        for e in &self.entries {
            if !e.live || e.seen {
                continue;
            }
            if k > 0 {
                self.buf.push(',');
            }
            k += 1;
            json::push_str(&mut self.buf, &e.id);
        }
        self.buf.push_str("]}");
        true
    }

    /// Send what changed and take off what this cycle did not describe. The
    /// library calls this after `on_update`.
    pub(crate) fn flush(&mut self) {
        if !self.finish() {
            return;
        }
        if raw::table_update_json(&self.buf) < 0 {
            // The host refused the batch, so what is on screen no longer
            // matches what is held here. Forget it and describe the whole set
            // next cycle.
            self.forget();
            return;
        }
        self.last_ms = self.cycle_ms;
        // A row this cycle did not describe has left the table.
        self.entries.retain(|e| e.live && e.seen);
    }

    /// Route one table_open or table_closed event. True when it was ours.
    pub(crate) fn set_open(&mut self, key: &str, open: bool) -> bool {
        if key != self.spec.key {
            return false;
        }
        self.open = open;
        if !open {
            // The host dropped the rows when it closed the dialog, so the diff
            // must forget them too, or the next opening sends nothing.
            self.forget();
            self.last_ms = 0;
        }
        true
    }

    fn forget(&mut self) {
        self.entries.clear();
        self.buf.clear();
        self.sets = 0;
    }

    /// Record one finished row, or rewind it when the table already holds
    /// exactly that row.
    fn take(&mut self, id: String, start: usize, body: usize) {
        let hash = fnv1a(self.buf[body..].as_bytes());
        if let Some(e) = self.entries.iter_mut().find(|e| e.id == id) {
            e.seen = true;
            if e.live && e.hash == hash {
                self.buf.truncate(start);
                return;
            }
            e.hash = hash;
            e.live = true;
            self.sets += 1;
            return;
        }
        if self.entries.len() == MAX_TABLE_ROWS {
            self.buf.truncate(start);
            self.warn_once(
                "rows",
                &format!(
                    "table {}: more than {} rows; \"{}\" dropped",
                    self.spec.key, MAX_TABLE_ROWS, id
                ),
            );
            return;
        }
        self.entries.push(Entry {
            id,
            hash,
            live: true,
            seen: true,
        });
        self.sets += 1;
    }

    /// One log line for a mistake the plugin will make every cycle.
    fn warn_once(&mut self, tag: &str, msg: &str) {
        if self.warned.iter().any(|w| w == tag) {
            return;
        }
        self.warned.push(tag.to_owned());
        raw::log(raw::Level::Warn, msg);
    }

    /// The manifest's entry for this table, which is the same text the host is
    /// given at start.
    pub fn declaration(&self) -> String {
        let mut out = String::with_capacity(256);
        out.push_str("{\"key\":");
        json::push_str(&mut out, self.spec.key);
        out.push_str(",\"title\":");
        json::push_str(&mut out, self.spec.title);
        out.push_str(",\"menu\":");
        json::push_str(&mut out, self.spec.menu);
        out.push_str(",\"columns\":[");
        for (i, c) in self.spec.columns.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str("{\"key\":");
            json::push_str(&mut out, c.key);
            out.push_str(",\"label\":");
            json::push_str(&mut out, c.label);
            out.push_str(",\"type\":");
            json::push_str(&mut out, c.kind.text());
            out.push('}');
        }
        out.push(']');
        if let Some(s) = self.spec.sort {
            out.push_str(",\"sort\":{\"key\":");
            json::push_str(&mut out, s.key);
            out.push_str(",\"ascending\":");
            out.push_str(if s.ascending { "true" } else { "false" });
            out.push('}');
        }
        if let Some(a) = self.spec.at {
            out.push_str(",\"at\":{\"lat\":");
            json::push_str(&mut out, a.lat);
            out.push_str(",\"lon\":");
            json::push_str(&mut out, a.lon);
            out.push('}');
        }
        out.push('}');
        out
    }

    fn column(&self, key: &str) -> Option<ColumnType> {
        self.spec
            .columns
            .iter()
            .find(|c| c.key == key)
            .map(|c| c.kind)
    }
}

/// The `"tables"` array a manifest must carry for these declarations. A
/// plugin's own test compares it with the manifest it ships, the way
/// [`crate::settings_json`] is compared.
pub fn tables_json(tables: &[&Table]) -> String {
    let mut out = String::from("[");
    for (i, t) in tables.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(&t.declaration());
    }
    out.push(']');
    out
}

/// One row under construction. Set its cells and call [`Row::done`].
pub struct Row<'a> {
    table: &'a mut Table,
    id: String,
    live: bool,
    /// Where the row began in the batch, and where its content did. A row the
    /// table already holds is rewound to `start`; the hash is taken over `body`
    /// onwards, so a leading comma cannot change it.
    start: usize,
    body: usize,
}

impl Row<'_> {
    /// The ordering policy: band 0 first, and the mariner's column sort never
    /// crosses a band. An alarmed row rides in band 0 and holds the top of the
    /// table whatever column the mariner sorted by.
    pub fn band(self, band: i32) -> Self {
        if self.live {
            self.table.buf.push_str(",\"band\":");
            json::push_num(&mut self.table.buf, band as f64);
        }
        self
    }

    /// One cell of a text or flag column. `None` is null on the wire and a dash
    /// on screen: never heard and heard as zero are different readings.
    pub fn text(mut self, key: &str, value: Option<&str>) -> Self {
        if self.cell(key, true) {
            match value {
                Some(s) => json::push_str(&mut self.table.buf, s),
                None => self.table.buf.push_str("null"),
            }
        }
        self
    }

    /// One cell of a number column: a distance, a speed, a bearing, a duration
    /// or a plain number, always SI.
    pub fn num(mut self, key: &str, value: Option<f64>) -> Self {
        if self.cell(key, false) {
            match value {
                Some(v) => json::push_num(&mut self.table.buf, v),
                None => self.table.buf.push_str("null"),
            }
        }
        self
    }

    /// The row's position, under the two keys the declaration named. A table
    /// with no [`TableAt`] has nowhere to put it, and this does nothing.
    pub fn at(self, at: Point) -> Self {
        let Some(keys) = self.table.spec.at else {
            return self;
        };
        if !self.live {
            return self;
        }
        self.table.buf.push(',');
        json::push_str(&mut self.table.buf, keys.lat);
        self.table.buf.push(':');
        json::push_num(&mut self.table.buf, at.lat);
        self.table.buf.push(',');
        json::push_str(&mut self.table.buf, keys.lon);
        self.table.buf.push(':');
        json::push_num(&mut self.table.buf, at.lon);
        self
    }

    /// Close the row and hand it to the diff.
    pub fn done(mut self) {
        if !self.live {
            return;
        }
        self.live = false;
        self.table.buf.push('}');
        let id = std::mem::take(&mut self.id);
        self.table.take(id, self.start, self.body);
    }

    /// Open one cell, and report whether the caller should write its value.
    /// A key the declaration does not carry is left out altogether and logged
    /// once: the plugin is passing it every cycle.
    fn cell(&mut self, key: &str, want_text: bool) -> bool {
        if !self.live {
            return false;
        }
        let Some(kind) = self.table.column(key) else {
            let msg = format!(
                "table {} declares no column \"{}\"",
                self.table.spec.key, key
            );
            self.table.warn_once(&format!("col:{key}"), &msg);
            return false;
        };
        if kind.is_text() != want_text {
            let wants = if kind.is_text() { "text" } else { "a number" };
            let msg = format!(
                "table {}: column \"{}\" holds {}",
                self.table.spec.key, key, wants
            );
            self.table.warn_once(&format!("cell:{key}"), &msg);
            return false;
        }
        self.table.buf.push(',');
        json::push_str(&mut self.table.buf, key);
        self.table.buf.push(':');
        true
    }
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100_0000_01b3);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    const TARGETS: TableSpec = TableSpec {
        key: "targets",
        title: "AIS Targets",
        menu: "Vessels",
        columns: &[
            Column::text("name", "Vessel"),
            Column::new("cpa", "CPA", ColumnType::Distance),
            Column::flag("state"),
        ],
        sort: Some(TableSort::by("cpa")),
        at: Some(TableAt {
            lat: "lat",
            lon: "lon",
        }),
    };

    // The table writes JSON and compares hashes without touching the host, so
    // the diff is testable on the development machine. `finish` is what `flush`
    // would have sent.
    fn batch(t: &mut Table) -> Option<String> {
        if t.finish() {
            Some(t.buf.clone())
        } else {
            None
        }
    }

    /// What `flush` does after the host has taken the batch.
    fn sent(t: &mut Table, mono: i64) {
        t.last_ms = mono;
        t.entries.retain(|e| e.live && e.seen);
    }

    fn opened() -> Table {
        let mut t = Table::new(TARGETS);
        assert!(t.set_open("targets", true));
        t
    }

    #[test]
    fn a_declaration_renders_the_entry_the_manifest_has_to_carry() {
        let t = Table::new(TARGETS);
        let want = concat!(
            r#"{"key":"targets","title":"AIS Targets","menu":"Vessels","columns":["#,
            r#"{"key":"name","label":"Vessel","type":"text"},"#,
            r#"{"key":"cpa","label":"CPA","type":"distance"},"#,
            r#"{"key":"state","label":"","type":"flag"}],"#,
            r#""sort":{"key":"cpa","ascending":true},"at":{"lat":"lat","lon":"lon"}}"#
        );
        assert_eq!(t.declaration(), want);
        assert_eq!(tables_json(&[&t]), format!("[{want}]"));
    }

    #[test]
    fn no_rows_are_built_while_the_dialog_is_shut() {
        let mut t = Table::new(TARGETS);
        t.begin(1);
        assert!(!t.is_open());
        t.row("1").text("name", Some("ANNE")).done();
        assert!(batch(&mut t).is_none());
    }

    #[test]
    fn a_cycle_sends_the_rows_that_changed_and_removes_the_rest() {
        let mut t = opened();

        t.begin(1);
        t.row("899000101")
            .band(0)
            .text("name", Some("ANNE"))
            .num("cpa", Some(124.0))
            .text("state", Some("alarm"))
            .at(Point::new(38.97, -76.46))
            .done();
        t.row("899000707")
            .band(1)
            .text("name", Some("BRAVO"))
            .num("cpa", None)
            .done();
        assert_eq!(
            batch(&mut t).expect("the first cycle sends every row"),
            concat!(
                r#"{"key":"targets","upsert":["#,
                r#"{"id":"899000101","band":0,"name":"ANNE","cpa":124,"state":"alarm","lat":38.97,"lon":-76.46},"#,
                r#"{"id":"899000707","band":1,"name":"BRAVO","cpa":null}],"remove":[]}"#
            )
        );
        sent(&mut t, 1);

        // The same picture again: nothing changed, so nothing is sent.
        t.begin(1_000);
        t.row("899000101")
            .band(0)
            .text("name", Some("ANNE"))
            .num("cpa", Some(124.0))
            .text("state", Some("alarm"))
            .at(Point::new(38.97, -76.46))
            .done();
        t.row("899000707")
            .band(1)
            .text("name", Some("BRAVO"))
            .num("cpa", None)
            .done();
        assert!(batch(&mut t).is_none(), "an unchanged set is not resent");
        sent(&mut t, 1_000);

        // One row moves and the other is not described at all.
        t.begin(2_000);
        t.row("899000101")
            .band(0)
            .text("name", Some("ANNE"))
            .num("cpa", Some(96.0))
            .text("state", Some("alarm"))
            .at(Point::new(38.97, -76.46))
            .done();
        let text = batch(&mut t).expect("one upsert and one removal");
        assert!(text.contains(r#""cpa":96"#), "{text}");
        assert!(text.contains(r#""remove":["899000707"]"#), "{text}");
    }

    #[test]
    fn the_cadence_gate_holds_a_rebuild_to_one_a_second() {
        let mut t = opened();
        t.begin(1);
        t.row("899000101").num("cpa", Some(0.0)).done();
        assert!(batch(&mut t).is_some());
        sent(&mut t, 1);

        // Eleven cycles across the next 990 ms, each describing a row the last
        // one did not. Exactly one of them clears the 950 ms gate.
        let mut built = 0;
        for i in 1..12 {
            let mono = 1 + i * 90;
            t.begin(mono);
            t.row("899000101").num("cpa", Some(i as f64)).done();
            if batch(&mut t).is_some() {
                built += 1;
                sent(&mut t, mono);
            }
        }
        assert_eq!(built, 1, "a rebuild a second, whatever the data rate");
        assert!(t.buf.contains(r#""cpa":11"#), "{}", t.buf);
    }

    #[test]
    fn closing_the_dialog_forgets_what_was_on_it() {
        let mut t = opened();
        t.begin(1);
        t.row("1").text("name", Some("ANNE")).done();
        assert!(batch(&mut t).is_some());
        sent(&mut t, 1);

        // The host drops the rows when the dialog closes, so the library must
        // too: the next opening has to describe the whole set again.
        assert!(t.set_open("targets", false));
        assert!(t.set_open("targets", true));
        t.begin(1);
        t.row("1").text("name", Some("ANNE")).done();
        let text = batch(&mut t).expect("the second opening describes the set again");
        assert!(text.contains(r#""ANNE""#), "{text}");
    }

    #[test]
    fn an_event_for_another_table_is_not_ours() {
        let mut t = Table::new(TARGETS);
        assert!(!t.set_open("anchors", true));
        assert!(!t.is_open());
    }

    #[test]
    fn a_cell_the_column_cannot_hold_is_left_out() {
        let mut t = opened();
        t.begin(1);
        t.row("899000202")
            .text("cpa", Some("close")) // a string in a number column
            .num("name", Some(12.0)) // a number in a text column
            .num("heading", Some(180.0)) // a column nobody declared
            .text("name", Some("ANNE")) // and one that fits
            .done();
        assert_eq!(
            batch(&mut t).expect("the row that fits still goes"),
            r#"{"key":"targets","upsert":[{"id":"899000202","name":"ANNE"}],"remove":[]}"#
        );
    }

    #[test]
    fn a_row_written_outside_a_cycle_is_dropped() {
        let mut t = opened();
        t.row("899000303").text("name", Some("LATE")).done();
        assert!(batch(&mut t).is_none());
        assert!(t.entries.is_empty());
    }

    /// A plugin holding a table, written the way the guide writes it. What is
    /// checked here is that the trait carries it: `tables` hands the library
    /// the field, and `on_update` fills it.
    struct Ais {
        targets: Table,
    }

    impl Default for Ais {
        fn default() -> Self {
            Ais {
                targets: Table::new(TARGETS),
            }
        }
    }

    impl crate::Plugin for Ais {
        fn tables(&mut self) -> Vec<&mut Table> {
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
                .at(Point::new(38.97, -76.46))
                .done();
        }
    }

    #[test]
    fn a_plugin_fills_its_table_from_on_update() {
        use crate::Plugin;
        let mut p = Ais::default();
        assert_eq!(p.tables().len(), 1);

        // Shut, so the cycle holds nothing.
        p.tables()[0].begin(1);
        p.on_update();
        assert!(!p.tables()[0].finish());

        assert!(p.targets.set_open("targets", true));
        p.tables()[0].begin(1);
        p.on_update();
        assert!(p.tables()[0].finish());
        assert_eq!(
            p.targets.buf,
            concat!(
                r#"{"key":"targets","upsert":[{"id":"899000101","band":0,"name":"ANNE","#,
                r#""cpa":124,"lat":38.97,"lon":-76.46}],"remove":[]}"#
            )
        );
    }
}
