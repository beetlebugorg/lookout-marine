//! What a plugin sends the host: values, targets, the status line and alerts.

use crate::chart::State;
use crate::geo::Point;
use crate::input::Target;
use crate::raw;
use crate::Single;

/// A batch of vessel values. The library stamps every value with the host's
/// wall clock, which is what the store ages against.
///
/// ```ignore
/// let mut p = lk::Publish::begin();
/// p.number("navigation.speedOverGround", mps);
/// p.position("navigation.position", lk::Point::new(lat, lon));
/// p.send();
/// ```
pub struct Publish {
    b: raw::Publish,
    ts: i64,
}

impl Default for Publish {
    fn default() -> Self {
        Self::begin()
    }
}

impl Publish {
    pub fn begin() -> Publish {
        Publish {
            b: raw::Publish::new(),
            ts: raw::now_ms(),
        }
    }

    pub fn number(&mut self, path: &str, v: f64) {
        self.b.number(path, v, self.ts);
    }

    pub fn position(&mut self, path: &str, at: Point) {
        self.b.position(path, at.lat, at.lon, self.ts);
    }

    /// This source holds the path and has no reading for it right now.
    pub fn clear(&mut self, path: &str) {
        self.b.clear(path, self.ts);
    }

    /// The number of values the host took, or -1. An empty batch is not sent
    /// and answers 0.
    pub fn send(self) -> i32 {
        self.b.send()
    }
}

/// A batch of AIS targets. `sog_mps` is metres per second: everything crossing
/// the API is SI, whatever the wire format reported.
pub struct Upsert {
    b: raw::AisUpsert,
    ts: i64,
}

impl Default for Upsert {
    fn default() -> Self {
        Self::begin()
    }
}

impl Upsert {
    pub fn begin() -> Upsert {
        Upsert {
            b: raw::AisUpsert::new(),
            ts: raw::now_ms(),
        }
    }

    pub fn target(&mut self, t: &Target) {
        self.b.target(&t.to_raw(self.ts));
    }

    pub fn send(self) -> i32 {
        self.b.send()
    }
}

/// Raise an alert. Needs the `alerts.raise` capability.
///
/// Raise one when the mariner must act now and would not otherwise know.
/// Everything else is a status line: an alarm that cries wolf is switched off,
/// and then the real one is not heard.
pub fn alert(severity: raw::Severity, title: &str, body: &str) -> i32 {
    raw::alert(severity, title, body)
}

static LAST: Single<Option<(String, String)>> = Single::new(None);

/// Post one status line, deduped. Nothing is sent while the state and the
/// detail are what they already were.
pub fn say(state: State, detail: &str) {
    say_text(state.text(), detail);
}

pub(crate) fn say_text(state: &str, detail: &str) {
    let last = LAST.get();
    if let Some((s, d)) = last {
        if s == state && d == detail {
            return;
        }
    }
    *last = Some((state.to_owned(), detail.to_owned()));
    raw::status(state, detail);
}
