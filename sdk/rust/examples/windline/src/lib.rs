//! Windline in Rust: one dashed line downwind from own ship, 1 nm long.
//!
//! The same plugin as the Zig walkthrough in
//! docs/developer-guide/plugins/build-your-first.md, so the languages can be
//! read side by side. It keeps the last position and the last true wind in the
//! plugin struct and redraws from a 1 Hz timer, because the store fans out at
//! up to 10 Hz and a line that twitches ten times a second is harder to read
//! than one that steps once a second. Data older than the 5 s staleness window
//! takes the line off the chart.
//!
//! Build:
//!
//! ```sh
//! cargo build --release --target wasm32-wasip1
//! cp ../../target/wasm32-wasip1/release/windline.wasm \
//!    ../../../../zig-out/plugins/org.example.windline.rs.wasm
//! cp manifest.json ../../../../zig-out/plugins/org.example.windline.rs.manifest.json
//! ```

use lookout as lk;

const LINE_ID: &str = "windline";
const MAX_AGE_MS: i64 = 5_000;
const REDRAW_MS: i64 = 1_000;
const LENGTH_M: f64 = 1852.0;
const EARTH_RADIUS_M: f64 = 6_371_008.8;

lk::register!(Windline::default());

/// A value and enough to age it between events: the host stamps `age_ms` at
/// delivery, and the monotonic clock carries it on from there.
#[derive(Default)]
struct Sample {
    have: bool,
    at_mono_ms: i64,
    age_at_ms: i64,
}

impl Sample {
    fn stamp(&mut self, age_ms: i64) {
        self.have = true;
        self.at_mono_ms = lk::mono_ms();
        self.age_at_ms = age_ms;
    }

    fn fresh(&self, mono_ms: i64) -> bool {
        self.have && self.age_at_ms + (mono_ms - self.at_mono_ms) <= MAX_AGE_MS
    }
}

struct Windline {
    pos: Sample,
    lat: f64,
    lon: f64,

    wind: Sample,
    twd_deg: f64,

    timer_id: i64,
    drawn: bool,

    /// The chrome only hears about a change of state: the host logs every
    /// status line it has not seen, so a 1 Hz repeat would be a 1 Hz log line.
    state: State,
}

impl Default for Windline {
    fn default() -> Self {
        Windline {
            pos: Sample::default(),
            lat: 0.0,
            lon: 0.0,
            wind: Sample::default(),
            twd_deg: 0.0,
            timer_id: -1,
            drawn: false,
            state: State::Starting,
        }
    }
}

#[derive(PartialEq, Clone, Copy)]
enum State {
    Starting,
    Running,
    Degraded,
    Stopped,
}

impl State {
    fn text(self) -> &'static str {
        match self {
            State::Starting => "starting",
            State::Running => "running",
            State::Degraded => "degraded",
            State::Stopped => "stopped",
        }
    }
}

impl Windline {
    fn say(&mut self, next: State, detail: &str) {
        if self.state == next {
            return;
        }
        self.state = next;
        lk::status(next.text(), detail);
    }

    /// Record what the store sent. Nothing draws here; the timer does that.
    fn take(&mut self, payload: &str) {
        for r in lk::readings(payload) {
            match &*r.path {
                "navigation.position" => {
                    if r.removed() {
                        self.pos.have = false;
                        continue;
                    }
                    if let Some((lat, lon)) = r.position() {
                        self.lat = lat;
                        self.lon = lon;
                        self.pos.stamp(r.age_ms);
                    }
                }
                "environment.wind.directionTrue" => {
                    if r.removed() {
                        self.wind.have = false;
                        continue;
                    }
                    match r.number() {
                        Some(v) if v.is_finite() => {
                            self.twd_deg = v;
                            self.wind.stamp(r.age_ms);
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
    }

    fn redraw(&mut self) {
        let mono = lk::mono_ms();
        if !self.pos.fresh(mono) || !self.wind.fresh(mono) {
            self.clear_line();
            self.say(State::Degraded, "no wind or no position");
            return;
        }

        // The wind direction is where the wind blows FROM, so downwind is the
        // reciprocal.
        let (end_lon, end_lat) = destination(self.lat, self.lon, self.twd_deg + 180.0, LENGTH_M);
        let mut ov = lk::Overlay::new();
        ov.polyline(
            LINE_ID,
            &[(self.lon, self.lat), (end_lon, end_lat)],
            1.5,
            lk::Color::Warning,
            true,
        );
        if ov.send() < 0 {
            return;
        }
        self.drawn = true;
        self.say(State::Running, "downwind line drawn");
    }

    /// Take the line off the chart. Idempotent: nothing is sent once it is
    /// gone.
    fn clear_line(&mut self) {
        if !self.drawn {
            return;
        }
        let mut ov = lk::Overlay::new();
        ov.del(LINE_ID);
        ov.send();
        self.drawn = false;
    }
}

impl lk::Plugin for Windline {
    fn start(&mut self, _s: lk::Start<'_>) -> lk::Result {
        if lk::subscribe_paths(&["navigation.position", "environment.wind.directionTrue"]) < 0 {
            return Err("subscribe refused".into());
        }
        self.timer_id = lk::timer_set(REDRAW_MS, true);
        if self.timer_id < 0 {
            return Err("timer refused".into());
        }
        // The floor the host gives Rust, demonstrated in one line: std is up,
        // the clock answers, and a println goes to this plugin's log rather
        // than to the app's terminal. Everything else std can reach — files,
        // sockets, environment variables, threads — is refused.
        let epoch_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(-1);
        println!(
            "windline (rust): std is up, epoch {} ms, host {} ms",
            epoch_ms,
            lk::now_ms()
        );

        lk::status("starting", "waiting for wind and position");
        Ok(())
    }

    fn on_event(&mut self, e: lk::Event<'_>) -> lk::Result {
        match e {
            lk::Event::StoreChanged(payload) => self.take(payload),
            lk::Event::Timer(id) if id == self.timer_id => self.redraw(),
            lk::Event::Shutdown => {
                if self.timer_id >= 0 {
                    lk::timer_cancel(self.timer_id);
                }
                self.clear_line();
                self.say(State::Stopped, "shut down");
            }
            _ => {}
        }
        Ok(())
    }
}

/// Great-circle destination, returned as (lon, lat). A sphere, not the
/// ellipsoid the chart is drawn on: the error over 1 nm is under 4 m.
fn destination(from_lat: f64, from_lon: f64, bearing_deg: f64, distance_m: f64) -> (f64, f64) {
    let lat1 = from_lat.to_radians();
    let lon1 = from_lon.to_radians();
    let brg = bearing_deg.to_radians();
    let d = distance_m / EARTH_RADIUS_M;
    let lat2 = (lat1.sin() * d.cos() + lat1.cos() * d.sin() * brg.cos()).asin();
    let lon2 = lon1 + (brg.sin() * d.sin() * lat1.cos()).atan2(d.cos() - lat1.sin() * lat2.sin());
    (lon2.to_degrees(), lat2.to_degrees())
}
