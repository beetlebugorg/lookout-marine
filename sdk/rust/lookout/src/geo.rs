//! Places on the earth, and the two conversions a mariner's text needs.

/// Metres in a nautical mile.
pub const NM_M: f64 = 1852.0;

/// A distance in metres from a distance in nautical miles.
pub fn nm(n: f64) -> f64 {
    n * NM_M
}

/// Knots from metres per second. Everything crossing the ABI is SI; this is
/// for text a mariner reads.
pub fn knots(mps: f64) -> f64 {
    mps * 1.943_844_492_440_604_6
}

const EARTH_RADIUS_M: f64 = 6_371_008.8;

/// A place on the earth. Latitude first, always: the overlay wire format puts
/// longitude first and this type is what keeps that out of plugin code.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    pub lat: f64,
    pub lon: f64,
}

impl Point {
    pub const fn new(lat: f64, lon: f64) -> Point {
        Point { lat, lon }
    }

    /// Where you get to on `bearing_deg` true after `dist_m`. A sphere, not
    /// the ellipsoid the chart is drawn on: the error over 1 nm is under 4 m.
    pub fn destination(self, bearing_deg: f64, dist_m: f64) -> Point {
        let lat1 = self.lat.to_radians();
        let lon1 = self.lon.to_radians();
        let brg = normalize_deg(bearing_deg).to_radians();
        let d = dist_m / EARTH_RADIUS_M;

        let (sin_lat1, cos_lat1) = (lat1.sin(), lat1.cos());
        let (sin_d, cos_d) = (d.sin(), d.cos());

        let sin_lat2 = (sin_lat1 * cos_d + cos_lat1 * sin_d * brg.cos()).clamp(-1.0, 1.0);
        let lat2 = sin_lat2.asin();
        let lon2 = lon1 + (brg.sin() * sin_d * cos_lat1).atan2(cos_d - sin_lat1 * sin_lat2);
        Point {
            lat: lat2.to_degrees(),
            // Folded, so a leg across the antimeridian does not post a
            // longitude the host would refuse.
            lon: wrap_lon(lon2.to_degrees()),
        }
    }

    /// The initial great-circle bearing to `other`, degrees true.
    pub fn bearing_to(self, other: Point) -> f64 {
        let lat1 = self.lat.to_radians();
        let lat2 = other.lat.to_radians();
        let dlon = wrap_lon(other.lon - self.lon).to_radians();
        let y = dlon.sin() * lat2.cos();
        let x = lat1.cos() * lat2.sin() - lat1.sin() * lat2.cos() * dlon.cos();
        normalize_deg(y.atan2(x).to_degrees())
    }

    /// Metres to `other`, over the same sphere.
    pub fn distance_to(self, other: Point) -> f64 {
        let lat1 = self.lat.to_radians();
        let lat2 = other.lat.to_radians();
        let dlat = lat2 - lat1;
        let dlon = wrap_lon(other.lon - self.lon).to_radians();
        let s1 = (dlat / 2.0).sin();
        let s2 = (dlon / 2.0).sin();
        let h = s1 * s1 + lat1.cos() * lat2.cos() * s2 * s2;
        2.0 * EARTH_RADIUS_M * h.clamp(0.0, 1.0).sqrt().asin()
    }

    /// False for a position off the earth or carrying a NaN. The library
    /// refuses one before it records it.
    pub fn valid(self) -> bool {
        self.lat.is_finite()
            && self.lon.is_finite()
            && self.lat.abs() <= 90.0
            && self.lon.abs() <= 180.0
    }
}

/// A bearing folded into 0..360.
pub fn normalize_deg(deg: f64) -> f64 {
    if !deg.is_finite() {
        return 0.0;
    }
    let r = deg % 360.0;
    if r < 0.0 {
        r + 360.0
    } else {
        r
    }
}

/// A longitude folded into -180..180.
pub fn wrap_lon(deg: f64) -> f64 {
    if !deg.is_finite() {
        return 0.0;
    }
    (deg + 180.0).rem_euclid(360.0) - 180.0
}

#[cfg(test)]
mod tests {
    use super::*;

    const ANNAPOLIS: Point = Point::new(38.9763, -76.4767);

    fn close(a: f64, b: f64, tol: f64) {
        assert!((a - b).abs() <= tol, "{} != {} within {}", a, b, tol);
    }

    #[test]
    fn one_mile_east_lands_where_the_flat_earth_check_says() {
        let p = ANNAPOLIS.destination(90.0, NM_M);

        // Flat approximation for the same leg: dlon = d / (R cos lat).
        let dlon_deg = (NM_M / (EARTH_RADIUS_M * ANNAPOLIS.lat.to_radians().cos())).to_degrees();
        close(ANNAPOLIS.lon + dlon_deg, p.lon, 1e-6);
        close(-76.455_275_7, p.lon, 1e-7);

        // Due east is the vertex of its great circle, so the latitude falls
        // off by a fraction of a metre rather than holding exactly.
        close(ANNAPOLIS.lat, p.lat, 1e-5);
        assert!(p.lat < ANNAPOLIS.lat);

        close(NM_M, ANNAPOLIS.distance_to(p), 0.01);
        close(90.0, ANNAPOLIS.bearing_to(p), 1e-6);
    }

    #[test]
    fn the_cardinal_legs_are_one_mile_long_and_point_where_they_were_sent() {
        for brg in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0, 359.0] {
            let p = ANNAPOLIS.destination(brg, NM_M);
            close(NM_M, ANNAPOLIS.distance_to(p), 0.01);
            close(brg, ANNAPOLIS.bearing_to(p), 1e-6);
        }

        // Due north: the latitude change is the arc over the radius, exactly.
        let north = ANNAPOLIS.destination(0.0, NM_M);
        close(
            ANNAPOLIS.lat + (NM_M / EARTH_RADIUS_M).to_degrees(),
            north.lat,
            1e-9,
        );
        close(ANNAPOLIS.lon, north.lon, 1e-12);
    }

    #[test]
    fn a_bearing_out_of_range_is_the_same_leg_as_its_folded_form() {
        let a = ANNAPOLIS.destination(-270.0, NM_M);
        let b = ANNAPOLIS.destination(90.0, NM_M);
        close(b.lat, a.lat, 1e-12);
        close(b.lon, a.lon, 1e-12);
    }

    #[test]
    fn a_leg_across_the_antimeridian_keeps_its_longitude_on_the_chart() {
        let fiji = Point::new(-17.0, 179.95);
        let p = fiji.destination(90.0, nm(10.0));
        assert!(p.lon < 0.0); // it crossed, and folded rather than ran on
        assert!(p.lon > -180.0);
        close(nm(10.0), fiji.distance_to(p), 0.1);
    }

    #[test]
    fn a_longitude_folds_into_the_charts_range() {
        close(-179.0, wrap_lon(181.0), 1e-12);
        close(179.0, wrap_lon(-181.0), 1e-12);
        close(-76.4767, wrap_lon(-76.4767), 1e-12);
    }

    #[test]
    fn a_bearing_folds_into_the_compass() {
        close(10.0, normalize_deg(370.0), 1e-9);
        close(350.0, normalize_deg(-10.0), 1e-9);
        assert_eq!(0.0, normalize_deg(f64::NAN));
    }

    #[test]
    fn a_position_off_the_earth_is_refused() {
        assert!(Point::new(38.9, -76.4).valid());
        assert!(!Point::new(91.0, 0.0).valid());
        assert!(!Point::new(0.0, f64::NAN).valid());
    }

    #[test]
    fn knots_are_metres_per_second_read_out_loud() {
        close(19.438_444_9, knots(10.0), 1e-6);
        close(1852.0, nm(1.0), 1e-12);
    }
}
