//! Windline in Rust: one dashed line downwind from own ship, 1 nm long.
//!
//! The whole plugin. The library subscribes, ages both values against the
//! 5 s window, runs `draw` once a second, and takes the line off the chart and
//! says which instrument is missing when either one goes stale.
//!
//! The same plugin as the Zig walkthrough in
//! docs/developer-guide/plugins/build-your-first.md, so the languages can be
//! read side by side.
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

struct Windline {
    boat: lk::Position,
    twd: lk::Number,
}

impl Default for Windline {
    fn default() -> Self {
        Windline {
            boat: lk::subscribe_position("navigation.position"),
            twd: lk::subscribe_number("environment.wind.directionTrue").label("wind"),
        }
    }
}

lk::plugin!(Windline);

impl lk::Plugin for Windline {
    fn inputs(&mut self) -> Vec<&mut dyn lk::AnyInput> {
        vec![&mut self.boat, &mut self.twd]
    }

    fn draw(&mut self, c: &mut lk::Chart<'_>) {
        let from = self.boat.get();
        // The wind direction is where the wind blows FROM, so downwind is the
        // reciprocal.
        let to = from.destination(self.twd.get() + 180.0, lk::nm(1.0));
        c.line(
            "windline",
            &[from, to],
            lk::Line::new(lk::Color::Warning).dashed(),
        );
    }
}
