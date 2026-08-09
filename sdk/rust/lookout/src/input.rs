//! What a plugin reads: one recorded value per declared input, aged against
//! the monotonic clock, and the AIS target set.
//!
//! An input is a field of the plugin struct. The library subscribes to every
//! path it finds in [`crate::Plugin::inputs`], records what arrives, and holds
//! `draw` until every required input is inside its window.

use crate::geo::Point;
use crate::raw;
use std::marker::PhantomData;

/// One 5 s window rules all vessel data. The store, and every shipped plugin,
/// use the same number. Raise it per input where the data is slower.
pub const DEFAULT_MAX_AGE_MS: i64 = 5_000;

/// How long an AIS vessel's report stays interesting when the plugin declares
/// no window, and the same for an aid to navigation. Both match the host's
/// eviction clocks: past them the target is out of the store and no snapshot
/// can carry it again.
pub const DEFAULT_AIS_MAX_AGE_MS: i64 = 600_000;
pub const DEFAULT_ATON_MAX_AGE_MS: i64 = 1_800_000;

/// A value the store carries, and how to read one out of a reading.
pub trait Value: Copy + Default + 'static {
    fn from_reading(r: &raw::Reading<'_>) -> Option<Self>;
}

impl Value for f64 {
    fn from_reading(r: &raw::Reading<'_>) -> Option<f64> {
        r.number().filter(|v| v.is_finite())
    }
}

impl Value for Point {
    fn from_reading(r: &raw::Reading<'_>) -> Option<Point> {
        let (lat, lon) = r.position()?;
        let at = Point::new(lat, lon);
        if at.valid() {
            Some(at)
        } else {
            None
        }
    }
}

/// A required input: the library holds `draw` until it is fresh, so
/// [`Input::get`] needs no null check there.
#[derive(Debug)]
pub struct Required;

/// An optional input: it never blocks `draw` and never reaches the status
/// line. It has no `get` — read it with [`Input::fresh`] and decide yourself.
#[derive(Debug)]
pub struct Optional;

/// One value off the vessel store, aged.
///
/// ```ignore
/// struct Windline { boat: lk::Position, twd: lk::Number }
/// // boat: lk::subscribe_position("navigation.position"),
/// // twd:  lk::subscribe_number("environment.wind.directionTrue").label("wind"),
/// ```
pub struct Input<T: Value, R = Required> {
    path: &'static str,
    label: &'static str,
    max_age_ms: i64,
    optional: bool,
    /// The value, and enough to age it between events: the host stamps
    /// `age_ms` at delivery and the monotonic clock carries it on from there.
    value: Option<T>,
    at_mono_ms: i64,
    age_at_ms: i64,
    gate: PhantomData<R>,
}

/// A number off the vessel store: a speed, a depth, a wind direction.
pub type Number<R = Required> = Input<f64, R>;

/// A position off the vessel store.
pub type Position<R = Required> = Input<Point, R>;

/// Subscribe to one numeric path off the vessel store. The builder methods
/// refine it: `.label(...)`, `.max_age(...)`, `.optional()`.
pub const fn subscribe_number(path: &'static str) -> Number {
    Number::new(path)
}

/// Subscribe to one position path off the vessel store.
pub const fn subscribe_position(path: &'static str) -> Position {
    Position::new(path)
}

/// Subscribe to the AIS target set. `max` is the most targets kept; a longer
/// snapshot is truncated and logged.
pub const fn subscribe_ais(max: usize) -> Ais {
    Ais::new(max)
}

impl<T: Value> Input<T, Required> {
    pub const fn new(path: &'static str) -> Input<T, Required> {
        Input {
            path,
            label: "",
            max_age_ms: DEFAULT_MAX_AGE_MS,
            optional: false,
            value: None,
            at_mono_ms: 0,
            age_at_ms: 0,
            gate: PhantomData,
        }
    }

    /// Never block `draw` on this reading, and never name it on the status
    /// line. The value is read with [`Input::fresh`]; there is no `get`.
    pub const fn optional(self) -> Input<T, Optional> {
        Input {
            path: self.path,
            label: self.label,
            max_age_ms: self.max_age_ms,
            optional: true,
            value: None,
            at_mono_ms: 0,
            age_at_ms: 0,
            gate: PhantomData,
        }
    }

    /// The value. A required input is fresh whenever `draw` runs, so this
    /// needs no check there. Outside `draw`, use [`Input::fresh`].
    pub fn get(&self) -> T {
        self.value.unwrap_or_default()
    }
}

impl<T: Value, R> Input<T, R> {
    /// What the status line calls this reading when it is missing: `no wind`.
    /// Defaults to the last segment of the path.
    pub const fn label(mut self, label: &'static str) -> Self {
        self.label = label;
        self
    }

    /// How old the value may be and still count.
    pub const fn max_age(mut self, ms: i64) -> Self {
        self.max_age_ms = ms;
        self
    }

    /// The value, or nothing when none has arrived or what arrived is older
    /// than the window. Safe anywhere, at any time.
    pub fn fresh(&self) -> Option<T> {
        if self.fresh_at(raw::mono_ms()) {
            self.value
        } else {
            None
        }
    }

    /// How old the value is, or nothing when there is none.
    pub fn age_ms(&self) -> Option<i64> {
        self.value.map(|_| self.age_at(raw::mono_ms()))
    }

    pub fn path(&self) -> &'static str {
        self.path
    }

    fn age_at(&self, mono_ms: i64) -> i64 {
        self.age_at_ms + (mono_ms - self.at_mono_ms)
    }

    fn fresh_at(&self, mono_ms: i64) -> bool {
        self.value.is_some() && self.age_at(mono_ms) <= self.max_age_ms
    }
}

/// What the library needs of an input, whatever it holds. Every input a plugin
/// declares is listed in [`crate::Plugin::inputs`] through this trait.
pub trait AnyInput {
    /// The store path to subscribe to, or nothing for the AIS set.
    fn path(&self) -> Option<&'static str>;
    /// What the status line calls this reading when it is missing. The
    /// builder is `Input::label`; this is what the library reads.
    fn status_label(&self) -> &'static str;
    /// True when `draw` waits for it.
    fn required(&self) -> bool;
    fn is_fresh(&self, mono_ms: i64) -> bool;
    /// The monotonic moment this input stops counting, or nothing when it
    /// already has. The window is known the moment a reading lands, so its
    /// expiry is an appointment rather than something to poll for.
    fn stale_at(&self, mono_ms: i64) -> Option<i64>;
    fn take_reading(&mut self, r: &raw::Reading<'_>, mono_ms: i64);
    /// True when the plugin must be subscribed to AIS.
    fn wants_ais(&self) -> bool {
        false
    }
    fn take_ais(&mut self, payload: &str, mono_ms: i64) {
        let _ = (payload, mono_ms);
    }
}

impl<T: Value, R> AnyInput for Input<T, R> {
    fn path(&self) -> Option<&'static str> {
        Some(self.path)
    }

    fn status_label(&self) -> &'static str {
        if self.label.is_empty() {
            last_segment(self.path)
        } else {
            self.label
        }
    }

    fn required(&self) -> bool {
        !self.optional
    }

    fn is_fresh(&self, mono_ms: i64) -> bool {
        self.fresh_at(mono_ms)
    }

    fn stale_at(&self, mono_ms: i64) -> Option<i64> {
        self.value.as_ref()?;
        let at = self.at_mono_ms + self.max_age_ms - self.age_at_ms;
        if at > mono_ms {
            Some(at)
        } else {
            None
        }
    }

    fn take_reading(&mut self, r: &raw::Reading<'_>, mono_ms: i64) {
        // A null value means the path has no source left. Treat it as removal:
        // the reading is gone, not zero.
        if r.removed() {
            self.value = None;
            return;
        }
        if let Some(v) = T::from_reading(r) {
            self.value = Some(v);
            self.at_mono_ms = mono_ms;
            self.age_at_ms = r.age_ms.max(0);
        }
    }
}

fn last_segment(path: &'static str) -> &'static str {
    match path.rfind('.') {
        Some(i) => &path[i + 1..],
        None => path,
    }
}

// ---------------------------------------------------------------------------
// AIS traffic
// ---------------------------------------------------------------------------

/// One vessel or aid the AIS receiver has heard. Absent fields are `None`:
/// "never heard" and "heard as zero" are different things at sea.
#[derive(Debug, Default, Clone)]
pub struct Target {
    pub mmsi: u32,
    pub at: Option<Point>,
    /// Metres per second.
    pub sog_mps: Option<f64>,
    pub cog_deg: Option<f64>,
    pub heading_deg: Option<f64>,
    /// True for an aid to navigation, which has its own aging and no CPA.
    pub aton: bool,
    pub aton_type: Option<u8>,
    pub virtual_aton: bool,
    pub off_position: Option<bool>,
    pub name: Option<String>,
    /// How old the report was when the snapshot arrived. [`Ais::age_ms`] adds
    /// what has passed since.
    pub age_ms: i64,
}

impl Target {
    pub fn name(&self) -> &str {
        self.name.as_deref().unwrap_or("")
    }

    fn from_raw(t: raw::Target) -> Target {
        Target {
            mmsi: t.mmsi,
            at: match (t.lat, t.lon) {
                (Some(lat), Some(lon)) => Some(Point::new(lat, lon)),
                _ => None,
            },
            sog_mps: t.sog,
            cog_deg: t.cog,
            heading_deg: t.heading,
            aton: t.aton,
            aton_type: t.aton_type,
            virtual_aton: t.virtual_aton,
            off_position: t.off_position,
            name: t.name,
            age_ms: t.age_ms,
        }
    }

    pub(crate) fn to_raw(&self, ts_ms: i64) -> raw::Target {
        raw::Target {
            mmsi: self.mmsi,
            lat: self.at.map(|p| p.lat),
            lon: self.at.map(|p| p.lon),
            sog: self.sog_mps,
            cog: self.cog_deg,
            heading: self.heading_deg,
            name: self.name.clone(),
            aton: self.aton,
            aton_type: self.aton_type,
            virtual_aton: self.virtual_aton,
            off_position: self.off_position,
            ts_ms,
            age_ms: self.age_ms,
        }
    }
}

/// The AIS target set, recorded and aged by the library. Declare it beside the
/// vessel inputs; it never holds `draw` back, because an empty sea is not a
/// missing instrument.
pub struct Ais {
    max: usize,
    max_age_ms: i64,
    aton_max_age_ms: i64,
    list: Vec<Target>,
    at_mono_ms: i64,
}

impl Ais {
    /// `max` is the most targets kept. A snapshot longer than this is
    /// truncated and logged.
    pub const fn new(max: usize) -> Ais {
        Ais {
            max,
            max_age_ms: DEFAULT_AIS_MAX_AGE_MS,
            aton_max_age_ms: DEFAULT_ATON_MAX_AGE_MS,
            list: Vec::new(),
            at_mono_ms: 0,
        }
    }

    /// How long a vessel's report stays interesting. Past it the target can no
    /// longer change anything the plugin decides, so the library stops waking
    /// for it. Set it to the age at which this plugin drops a target.
    pub const fn max_age(mut self, ms: i64) -> Self {
        self.max_age_ms = ms;
        self
    }

    /// The same, for an aid to navigation. An aid reports about every three
    /// minutes, so a vessel's window would age one out while it is still on
    /// station.
    pub const fn aton_max_age(mut self, ms: i64) -> Self {
        self.aton_max_age_ms = ms;
        self
    }

    /// Every target in the last snapshot. Each `age_ms` is the age at the
    /// snapshot; [`Ais::age_ms`] adds the time since.
    pub fn targets(&self) -> &[Target] {
        &self.list
    }

    /// The target with this MMSI, or nothing.
    pub fn find(&self, mmsi: u32) -> Option<&Target> {
        self.list.iter().find(|t| t.mmsi == mmsi)
    }

    /// Milliseconds since the snapshot arrived.
    pub fn carried_ms(&self) -> i64 {
        if self.at_mono_ms == 0 {
            0
        } else {
            raw::mono_ms() - self.at_mono_ms
        }
    }

    /// How old this target's report is now.
    pub fn age_ms(&self, t: &Target) -> i64 {
        t.age_ms + self.carried_ms()
    }
}

impl AnyInput for Ais {
    fn path(&self) -> Option<&'static str> {
        None
    }

    fn status_label(&self) -> &'static str {
        "traffic"
    }

    /// An empty sea is not a missing instrument, so this never holds `draw`.
    fn required(&self) -> bool {
        false
    }

    fn is_fresh(&self, _mono_ms: i64) -> bool {
        true
    }

    /// When the next target in the set ages out, or nothing when none can.
    /// Each target keeps its own clock, so the set produces one appointment
    /// per target rather than one for the snapshot.
    fn stale_at(&self, mono_ms: i64) -> Option<i64> {
        self.list
            .iter()
            .map(|t| {
                let window = if t.aton {
                    self.aton_max_age_ms
                } else {
                    self.max_age_ms
                };
                self.at_mono_ms + window - t.age_ms
            })
            .filter(|at| *at > mono_ms)
            .min()
    }

    fn take_reading(&mut self, _r: &raw::Reading<'_>, _mono_ms: i64) {}

    fn wants_ais(&self) -> bool {
        true
    }

    fn take_ais(&mut self, payload: &str, mono_ms: i64) {
        let incoming = raw::targets(payload);
        let keep = incoming.len().min(self.max);
        if incoming.len() > self.max {
            crate::log!(
                raw::Level::Warn,
                "ais: {} targets, keeping {}",
                incoming.len(),
                self.max
            );
        }
        self.list.clear();
        self.list
            .extend(incoming.into_iter().take(keep).map(Target::from_raw));
        self.at_mono_ms = mono_ms;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::Json;

    fn reading<'a>(path: &'a str, value: Json<'a>, age_ms: i64) -> raw::Reading<'a> {
        raw::Reading {
            path: std::borrow::Cow::Borrowed(path),
            value,
            ts_ms: 0,
            age_ms,
        }
    }

    #[test]
    fn a_recorded_value_ages_off_the_monotonic_clock() {
        let mut twd: Number = Number::new("environment.wind.directionTrue");
        twd.take_reading(
            &reading("environment.wind.directionTrue", Json::Num(215.0), 400),
            1_000,
        );
        assert_eq!(twd.get(), 215.0);
        // 400 ms old at delivery, so it goes stale 4600 ms after it arrived.
        assert!(twd.is_fresh(1_000 + 4_500));
        assert!(!twd.is_fresh(1_000 + 4_700));
    }

    #[test]
    fn a_cleared_path_removes_the_value_rather_than_zeroing_it() {
        let mut depth: Number = Number::new("environment.depth.belowKeel");
        depth.take_reading(
            &reading("environment.depth.belowKeel", Json::Num(4.2), 0),
            100,
        );
        assert!(depth.is_fresh(100));
        depth.take_reading(&reading("environment.depth.belowKeel", Json::Null, 0), 200);
        assert!(!depth.is_fresh(200));
        assert_eq!(depth.get(), 0.0);
    }

    #[test]
    fn a_reading_that_is_not_a_number_is_dropped_and_the_last_one_stands() {
        let mut sog: Number = Number::new("navigation.speedOverGround");
        sog.take_reading(
            &reading("navigation.speedOverGround", Json::Num(3.5), 0),
            10,
        );
        sog.take_reading(
            &reading("navigation.speedOverGround", Json::Bool(true), 0),
            20,
        );
        assert_eq!(sog.get(), 3.5);
        assert!(sog.is_fresh(20));
    }

    #[test]
    fn a_position_off_the_earth_is_refused() {
        let mut boat: Position = Position::new("navigation.position");
        let good = Json::Obj(vec![
            (std::borrow::Cow::Borrowed("lat"), Json::Num(38.9)),
            (std::borrow::Cow::Borrowed("lon"), Json::Num(-76.4)),
        ]);
        let bad = Json::Obj(vec![
            (std::borrow::Cow::Borrowed("lat"), Json::Num(91.0)),
            (std::borrow::Cow::Borrowed("lon"), Json::Num(0.0)),
        ]);
        boat.take_reading(&reading("navigation.position", good, 0), 10);
        boat.take_reading(&reading("navigation.position", bad, 0), 20);
        assert_eq!(boat.get(), Point::new(38.9, -76.4));
    }

    #[test]
    fn a_label_defaults_to_the_last_segment_of_the_path() {
        let boat: Position = Position::new("navigation.position");
        assert_eq!(boat.status_label(), "position");
        let twd: Number = Number::new("environment.wind.directionTrue").label("wind");
        assert_eq!(twd.status_label(), "wind");
        let bare: Number = Number::new("depth");
        assert_eq!(bare.status_label(), "depth");
    }

    #[test]
    fn an_optional_input_never_holds_the_draw() {
        let depth: Number<Optional> = Number::new("environment.depth.belowKeel").optional();
        assert!(!depth.required());
        assert!(!depth.is_fresh(0));
    }

    #[test]
    fn the_target_set_is_truncated_and_the_rest_survives() {
        let mut ais = Ais::new(2);
        ais.take_ais(
            r#"{"targets":[{"mmsi":1,"lat":38.0,"lon":-76.0,"sog":4.0},{"mmsi":2},{"mmsi":3}]}"#,
            50,
        );
        assert_eq!(ais.targets().len(), 2);
        assert_eq!(ais.find(1).unwrap().at, Some(Point::new(38.0, -76.0)));
        assert_eq!(ais.find(1).unwrap().sog_mps, Some(4.0));
        // The second target reported no position, which is not a position of
        // zero.
        assert_eq!(ais.find(2).unwrap().at, None);
        assert!(ais.find(3).is_none());
        assert!(!ais.required());
        assert!(ais.wants_ais());
    }

    #[test]
    fn a_reading_expires_at_an_appointment_it_carries() {
        // Nothing has arrived, so nothing can expire and there is nothing to
        // wait for.
        let mut twd: Number = Number::new("environment.wind.directionTrue");
        assert_eq!(twd.stale_at(0), None);

        // 400 ms old at delivery, so it stops counting 4600 ms after it
        // arrived, and the appointment is that moment rather than a guess.
        twd.take_reading(
            &reading("environment.wind.directionTrue", Json::Num(215.0), 400),
            1_000,
        );
        assert_eq!(twd.stale_at(1_000), Some(1_000 + 4_600));

        // Once it has, there is no later moment to wake for.
        assert_eq!(twd.stale_at(1_000 + 4_600), None);
        assert_eq!(twd.stale_at(1_000 + 9_000), None);

        // A reading that arrives resets its own appointment.
        twd.take_reading(
            &reading("environment.wind.directionTrue", Json::Num(216.0), 0),
            9_000,
        );
        assert_eq!(twd.stale_at(9_000), Some(9_000 + DEFAULT_MAX_AGE_MS));
    }

    #[test]
    fn the_earliest_window_rules_the_appointment() {
        // Two readings on different clocks, delivered together. They stop
        // counting at different moments, so each expires on its own wakeup and
        // the plugin can say which one went.
        let mut boat: Position = Position::new("navigation.position");
        let mut twd: Number = Number::new("environment.wind.directionTrue").max_age(20_000);
        boat.take_reading(
            &reading(
                "navigation.position",
                Json::parse(r#"{"lat":38.97,"lon":-76.46}"#).unwrap(),
                0,
            ),
            1_000,
        );
        twd.take_reading(
            &reading("environment.wind.directionTrue", Json::Num(215.0), 0),
            1_000,
        );

        let inputs: Vec<&dyn AnyInput> = vec![&boat, &twd];
        let earliest =
            |mono: i64| -> Option<i64> { inputs.iter().filter_map(|i| i.stale_at(mono)).min() };
        assert_eq!(earliest(1_000), Some(1_000 + DEFAULT_MAX_AGE_MS));

        // The position has gone and the wind has not. The next appointment is
        // the wind's own.
        let after_boat = 1_000 + DEFAULT_MAX_AGE_MS + 1;
        assert!(!boat.is_fresh(after_boat));
        assert!(twd.is_fresh(after_boat));
        assert_eq!(earliest(after_boat), Some(1_000 + 20_000));

        // Both gone: nothing further can change, so nothing is armed.
        assert_eq!(earliest(1_000 + 20_001), None);
    }

    #[test]
    fn each_target_ages_out_on_its_own_clock() {
        // A vessel and an aid heard at the same moment. An aid reports about
        // every three minutes, so a vessel's window would age one out while it
        // is still on station.
        let mut ais = Ais::new(8).max_age(180_000).aton_max_age(600_000);
        ais.take_ais(
            r#"{"targets":[{"mmsi":899000101,"lat":38.97,"lon":-76.46},
                {"mmsi":998990101,"lat":38.98,"lon":-76.47,"aton":true}]}"#,
            1_000,
        );

        // The vessel's own limit comes first, then the aid's.
        assert_eq!(ais.stale_at(1_000), Some(1_000 + 180_000));
        assert_eq!(ais.stale_at(1_000 + 180_000), Some(1_000 + 600_000));

        // An empty sea can change no further on its own.
        assert_eq!(ais.stale_at(1_000 + 600_000), None);
        assert_eq!(Ais::new(8).stale_at(0), None);
    }
}
