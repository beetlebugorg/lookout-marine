//! The chart a plugin draws on, and the retained scene behind it.
//!
//! `draw` describes the whole picture every call. The library compares it with
//! the last one: an object with the same id and the same shape is left alone, a
//! changed one is replaced, and one that was not drawn this call is taken off
//! the chart. There is no delete call and no batch to manage.

use crate::geo::Point;
use crate::json;
use crate::raw;

/// Most objects one plugin's scene may hold. The host's own budget is 4096
/// across every plugin; this is the table the diff keeps.
pub const MAX_OBJECTS: usize = 512;

/// The scene batch, holding the objects that changed and the ids that went. A
/// 600-point track is the largest thing any shipped plugin says, at about 45
/// bytes a point, so this has better than two to one in hand.
pub const SCENE_BYTES: usize = 64 * 1024;

/// The palette tokens. A plugin names a token; the core resolves it per
/// day/dusk/night scheme, which is why an overlay never carries an RGB.
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
    pub fn text(self) -> &'static str {
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

/// The symbol shapes the core draws. `Aton` is a physical aid to navigation
/// and `AtonVirtual` one that exists only as a broadcast.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sym {
    Ownship,
    Target,
    Aton,
    AtonVirtual,
}

impl Sym {
    pub fn text(self) -> &'static str {
        match self {
            Sym::Ownship => "ownship",
            Sym::Target => "target",
            Sym::Aton => "aton",
            Sym::AtonVirtual => "aton_virtual",
        }
    }
}

/// Where an object sits. `Ownship` rides own ship's display position, which
/// the core carries forward between fixes, so the object does not step once a
/// second while the chart slides smoothly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    Fixed,
    Ownship,
}

/// A line's weight, colour and whether it is dashed. `width_pt` is screen
/// points, not metres: the core converts at the live zoom.
#[derive(Debug, Clone, Copy)]
pub struct Line {
    pub color: Color,
    pub width_pt: f64,
    pub dash: bool,
    pub anchor: Anchor,
}

impl Line {
    pub const fn new(color: Color) -> Line {
        Line {
            color,
            width_pt: 1.5,
            dash: false,
            anchor: Anchor::Fixed,
        }
    }
    pub const fn width(mut self, pt: f64) -> Line {
        self.width_pt = pt;
        self
    }
    pub const fn dashed(mut self) -> Line {
        self.dash = true;
        self
    }
    /// Travel with own ship's display position, keeping the shape and the
    /// first point on the boat: a heading line, a speed vector.
    pub const fn on_ownship(mut self) -> Line {
        self.anchor = Anchor::Ownship;
        self
    }
}

/// What the shell shows when the mariner hovers or taps a symbol. The values
/// are strings you have already formatted: only the plugin knows the unit.
/// Lines and areas carry no payload — there is no single point to measure a
/// tap against.
#[derive(Debug, Clone, Default)]
pub struct Pick {
    pub title: String,
    pub rows: Vec<(String, String)>,
}

impl Pick {
    pub fn new(title: impl Into<String>) -> Pick {
        Pick {
            title: title.into(),
            rows: Vec::new(),
        }
    }
    pub fn row(mut self, key: impl Into<String>, value: impl Into<String>) -> Pick {
        self.rows.push((key.into(), value.into()));
        self
    }
}

/// A symbol's colour, rotation and size. `rot_deg` is a true bearing,
/// clockwise from north.
#[derive(Debug, Clone)]
pub struct Symbol {
    pub color: Color,
    pub rot_deg: f64,
    pub scale: f64,
    pub anchor: Anchor,
    pub pick: Option<Pick>,
}

impl Symbol {
    pub const fn new(color: Color) -> Symbol {
        Symbol {
            color,
            rot_deg: 0.0,
            scale: 1.0,
            anchor: Anchor::Fixed,
            pick: None,
        }
    }
    pub const fn rot(mut self, deg: f64) -> Symbol {
        self.rot_deg = deg;
        self
    }
    pub const fn scale(mut self, s: f64) -> Symbol {
        self.scale = s;
        self
    }
    pub const fn on_ownship(mut self) -> Symbol {
        self.anchor = Anchor::Ownship;
        self
    }
    pub fn pick(mut self, p: Pick) -> Symbol {
        self.pick = Some(p);
        self
    }
}

/// A filled ring. `alpha` multiplies the token's own alpha.
#[derive(Debug, Clone, Copy)]
pub struct Area {
    pub color: Color,
    pub alpha: f64,
}

impl Area {
    pub const fn new(color: Color) -> Area {
        Area { color, alpha: 1.0 }
    }
    pub const fn alpha(mut self, a: f64) -> Area {
        self.alpha = a;
        self
    }
}

/// What the chrome says about a plugin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Starting,
    Running,
    Degraded,
    Stopped,
}

impl State {
    pub fn text(self) -> &'static str {
        match self {
            State::Starting => "starting",
            State::Running => "running",
            State::Degraded => "degraded",
            State::Stopped => "stopped",
        }
    }
}

struct Entry {
    id: String,
    hash: u64,
    live: bool,
    seen: bool,
}

/// The retained scene: what is on the chart, and what changed since the last
/// call to `draw`.
pub(crate) struct Scene {
    entries: Vec<Entry>,
    /// The batch: `{"set":[` while `draw` runs, then the deletes and the
    /// closing brace at commit.
    buf: String,
    /// One object, serialized before it is compared. Reused every object, so
    /// a steady scene allocates nothing.
    obj: String,
    sets: usize,
    overflowed: bool,
}

const PREFIX: &str = "{\"set\":[";

impl Scene {
    pub(crate) fn new() -> Scene {
        Scene {
            entries: Vec::new(),
            buf: String::with_capacity(1024),
            obj: String::with_capacity(256),
            sets: 0,
            overflowed: false,
        }
    }

    fn begin(&mut self) {
        for e in &mut self.entries {
            e.seen = false;
        }
        self.buf.clear();
        self.buf.push_str(PREFIX);
        self.sets = 0;
        self.overflowed = false;
    }

    /// Take the object now in `obj`. One that has not changed since the last
    /// call is dropped, because it is already on the chart.
    fn take(&mut self, id: &str) {
        let hash = fnv1a(self.obj.as_bytes());
        if let Some(e) = self.entries.iter_mut().find(|e| e.id == id) {
            e.seen = true;
            if e.live && e.hash == hash {
                return;
            }
            e.hash = hash;
            e.live = true;
        } else {
            if self.entries.len() == MAX_OBJECTS {
                crate::log!(
                    raw::Level::Warn,
                    "overlay: more than {} objects; \"{}\" dropped",
                    MAX_OBJECTS,
                    id
                );
                return;
            }
            self.entries.push(Entry {
                id: id.to_owned(),
                hash,
                live: true,
                seen: true,
            });
        }
        if self.buf.len() + self.obj.len() + 1 > SCENE_BYTES {
            self.overflowed = true;
            return;
        }
        if self.sets > 0 {
            self.buf.push(',');
        }
        self.sets += 1;
        let obj = std::mem::take(&mut self.obj);
        self.buf.push_str(&obj);
        self.obj = obj;
    }

    /// Close the batch. False when there is nothing to send.
    fn finish(&mut self) -> bool {
        let dels = self.entries.iter().filter(|e| e.live && !e.seen).count();
        if self.overflowed {
            crate::log!(
                raw::Level::Warn,
                "overlay dropped: the scene did not fit in {} bytes",
                SCENE_BYTES
            );
            self.forget();
            return false;
        }
        if self.sets == 0 && dels == 0 {
            return false;
        }
        self.buf.push_str("],\"del\":[");
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

    /// Send what changed, and delete what this call did not draw.
    pub(crate) fn commit(&mut self) {
        if !self.finish() {
            return;
        }
        if raw::overlay_json(&self.buf) < 0 {
            // The host refused the batch, so what is on the chart no longer
            // matches the table. Forget it; the next call redraws in full.
            self.forget();
            return;
        }
        // An object deleted this call leaves the table.
        self.entries.retain(|e| e.live && e.seen);
    }

    /// Drop every memory of what is drawn. The next call sends the whole scene
    /// again.
    fn forget(&mut self) {
        self.entries.clear();
        self.buf.clear();
        self.sets = 0;
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

/// What a plugin draws on, handed to `draw`.
///
/// Describe the whole picture every call. An object with the same id and the
/// same shape as last call costs a serialize and nothing else; one you did not
/// draw is taken off the chart.
pub struct Chart<'a> {
    scene: &'a mut Scene,
    pub(crate) state: State,
    pub(crate) detail: String,
    pub(crate) said: bool,
}

impl<'a> Chart<'a> {
    pub(crate) fn new(scene: &'a mut Scene) -> Chart<'a> {
        scene.begin();
        Chart {
            scene,
            state: State::Running,
            detail: String::new(),
            said: false,
        }
    }

    /// A line through `pts`, in order. Two points at least.
    pub fn line(&mut self, id: &str, pts: &[Point], style: Line) {
        if pts.len() < 2 {
            return;
        }
        let mut o = std::mem::take(&mut self.scene.obj);
        o.clear();
        o.push_str("{\"id\":");
        json::push_str(&mut o, id);
        o.push_str(",\"kind\":\"polyline\",\"pts\":[");
        points(&mut o, pts);
        o.push_str("],\"width_pt\":");
        json::push_num(&mut o, style.width_pt);
        o.push_str(",\"dash\":");
        o.push_str(if style.dash { "true" } else { "false" });
        o.push_str(",\"color\":\"");
        o.push_str(style.color.text());
        o.push('"');
        anchor(&mut o, style.anchor);
        o.push('}');
        self.scene.obj = o;
        self.scene.take(id);
    }

    /// A symbol at `at`.
    pub fn symbol(&mut self, id: &str, sym: Sym, at: Point, style: Symbol) {
        if !at.valid() {
            return;
        }
        let mut o = std::mem::take(&mut self.scene.obj);
        o.clear();
        o.push_str("{\"id\":");
        json::push_str(&mut o, id);
        o.push_str(",\"kind\":\"symbol\",\"sym\":\"");
        o.push_str(sym.text());
        o.push_str("\",\"at\":[");
        json::push_num(&mut o, at.lon);
        o.push(',');
        json::push_num(&mut o, at.lat);
        o.push_str("],\"rot_deg\":");
        json::push_num(&mut o, style.rot_deg);
        o.push_str(",\"scale\":");
        json::push_num(&mut o, style.scale);
        o.push_str(",\"color\":\"");
        o.push_str(style.color.text());
        o.push('"');
        anchor(&mut o, style.anchor);
        if let Some(p) = &style.pick {
            o.push_str(",\"pick\":{\"title\":");
            json::push_str(&mut o, &p.title);
            o.push_str(",\"rows\":[");
            for (i, (k, v)) in p.rows.iter().enumerate() {
                if i > 0 {
                    o.push(',');
                }
                o.push('[');
                json::push_str(&mut o, k);
                o.push(',');
                json::push_str(&mut o, v);
                o.push(']');
            }
            o.push_str("]}");
        }
        o.push('}');
        self.scene.obj = o;
        self.scene.take(id);
    }

    /// A filled area. The ring is closed for you; three points at least.
    pub fn area(&mut self, id: &str, ring: &[Point], style: Area) {
        if ring.len() < 3 {
            return;
        }
        let mut o = std::mem::take(&mut self.scene.obj);
        o.clear();
        o.push_str("{\"id\":");
        json::push_str(&mut o, id);
        o.push_str(",\"kind\":\"polygon\",\"ring\":[");
        points(&mut o, ring);
        o.push_str("],\"alpha\":");
        json::push_num(&mut o, style.alpha);
        o.push_str(",\"color\":\"");
        o.push_str(style.color.text());
        o.push_str("\"}");
        self.scene.obj = o;
        self.scene.take(id);
    }

    /// Say the plugin is working, and what it is doing. Posted once; the
    /// library sends nothing while the text is unchanged.
    pub fn status(&mut self, detail: &str) {
        self.say(State::Running, detail);
    }

    /// Say the plugin is short of something. The library adds nothing: name
    /// the instrument, so a mariner knows which one to look at.
    pub fn degraded(&mut self, detail: &str) {
        self.say(State::Degraded, detail);
    }

    fn say(&mut self, state: State, detail: &str) {
        self.state = state;
        self.detail.clear();
        self.detail.push_str(detail);
        self.said = true;
    }

    /// What the plugin said this call, and whether it said anything. Consumes
    /// the chart, which is what releases the scene for the commit.
    pub(crate) fn take_status(self) -> (State, String, bool) {
        (self.state, self.detail, self.said)
    }
}

fn points(out: &mut String, pts: &[Point]) {
    for (i, p) in pts.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('[');
        json::push_num(out, p.lon);
        out.push(',');
        json::push_num(out, p.lat);
        out.push(']');
    }
}

fn anchor(out: &mut String, a: Anchor) {
    if a == Anchor::Ownship {
        out.push_str(",\"anchor\":\"ownship\"");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The scene writes JSON and compares hashes without touching the host, so
    // the diff is testable on the development machine. `finish` is what
    // `commit` would have sent.
    fn batch(scene: &mut Scene) -> Option<String> {
        if scene.finish() {
            Some(scene.buf.clone())
        } else {
            None
        }
    }

    fn sent(scene: &mut Scene) {
        scene.entries.retain(|e| e.live && e.seen);
    }

    #[test]
    fn the_first_call_sends_the_object_and_the_second_sends_nothing() {
        let mut scene = Scene::new();
        let line = Line::new(Color::Warning).dashed();
        let pts = [Point::new(38.0, -76.0), Point::new(38.1, -76.1)];

        let mut c = Chart::new(&mut scene);
        c.line("windline", &pts, line);
        let first = batch(&mut scene).expect("the first call draws");
        assert_eq!(
            first,
            r#"{"set":[{"id":"windline","kind":"polyline","pts":[[-76,38],[-76.1,38.1]],"width_pt":1.5,"dash":true,"color":"warning"}],"del":[]}"#
        );
        sent(&mut scene);

        let mut c = Chart::new(&mut scene);
        c.line("windline", &pts, line);
        assert!(
            batch(&mut scene).is_none(),
            "an unchanged object is not resent"
        );
    }

    #[test]
    fn an_object_not_drawn_this_call_is_deleted() {
        let mut scene = Scene::new();
        let mut c = Chart::new(&mut scene);
        c.symbol(
            "a",
            Sym::Target,
            Point::new(1.0, 2.0),
            Symbol::new(Color::Target),
        );
        c.symbol(
            "b",
            Sym::Target,
            Point::new(3.0, 4.0),
            Symbol::new(Color::Target),
        );
        assert!(batch(&mut scene).is_some());
        sent(&mut scene);

        let mut c = Chart::new(&mut scene);
        c.symbol(
            "a",
            Sym::Target,
            Point::new(1.0, 2.0),
            Symbol::new(Color::Target),
        );
        let text = batch(&mut scene).expect("b went");
        assert_eq!(text, r#"{"set":[],"del":["b"]}"#);
        sent(&mut scene);
        assert_eq!(scene.entries.len(), 1);
    }

    #[test]
    fn a_changed_object_is_resent_and_an_unchanged_neighbour_is_not() {
        let mut scene = Scene::new();
        let mut c = Chart::new(&mut scene);
        c.symbol(
            "a",
            Sym::Target,
            Point::new(1.0, 2.0),
            Symbol::new(Color::Target),
        );
        c.symbol(
            "b",
            Sym::Target,
            Point::new(3.0, 4.0),
            Symbol::new(Color::Target),
        );
        assert!(batch(&mut scene).is_some());
        sent(&mut scene);

        let mut c = Chart::new(&mut scene);
        c.symbol(
            "a",
            Sym::Target,
            Point::new(1.0, 2.5),
            Symbol::new(Color::Target),
        );
        c.symbol(
            "b",
            Sym::Target,
            Point::new(3.0, 4.0),
            Symbol::new(Color::Target),
        );
        let text = batch(&mut scene).expect("a moved");
        assert!(text.contains(r#""id":"a""#), "{}", text);
        assert!(!text.contains(r#""id":"b""#), "{}", text);
        assert!(text.ends_with(r#","del":[]}"#), "{}", text);
    }

    #[test]
    fn a_pick_payload_rides_on_the_symbol() {
        let mut scene = Scene::new();
        let mut c = Chart::new(&mut scene);
        c.symbol(
            "t366",
            Sym::Target,
            Point::new(38.0, -76.0),
            Symbol::new(Color::TargetDanger)
                .rot(215.0)
                .pick(Pick::new("SEA WOLF").row("CPA", "0.3 nm")),
        );
        let text = batch(&mut scene).unwrap();
        assert!(
            text.contains(r#""pick":{"title":"SEA WOLF","rows":[["CPA","0.3 nm"]]}"#),
            "{}",
            text
        );
    }

    #[test]
    fn a_line_of_one_point_and_a_position_off_the_earth_draw_nothing() {
        let mut scene = Scene::new();
        let mut c = Chart::new(&mut scene);
        c.line("short", &[Point::new(1.0, 2.0)], Line::new(Color::Track));
        c.symbol(
            "nowhere",
            Sym::Target,
            Point::new(91.0, 0.0),
            Symbol::new(Color::Target),
        );
        c.area(
            "thin",
            &[Point::new(1.0, 2.0), Point::new(3.0, 4.0)],
            Area::new(Color::Warning),
        );
        assert!(batch(&mut scene).is_none());
    }
}
