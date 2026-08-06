//! Real-format NMEA 0183 lines and the values they must decode to.
//!
//! Provenance matters here, because a fixture built to agree with the
//! parser proves nothing about the parser:
//!
//!   - RMC, GGA, VTG, the relative MWV and GSV are the worked examples the
//!     standard's documentation and the common receiver manuals print,
//!     published checksums included.
//!   - The AIS type 1, type 18 and two-part type 5 are the worked examples
//!     from the AIVDM/AIVDO decoding guide. They must decode to the MMSIs,
//!     positions and ship names that guide states, which is what checks the
//!     bit layouts in `parser.zig` against something outside this
//!     repository.
//!   - The rest follow the same field layouts by hand: a receiver with no
//!     fix, the heading, depth and wind sentences, and — from the encoder
//!     in `tools/nmea_gen.zig` — a type 24 A/B pair and a type 1 carrying
//!     every not-available sentinel at once, which no published example
//!     does.
//!
//! Every checksum was computed over its body and pasted in as a literal;
//! the first test in `parser.zig` re-verifies all of them.

/// Every line here parses. `bad_checksum` and `no_checksum` are excluded on
/// purpose: they exist to be rejected.
pub const all = [_][]const u8{
    rmc,           rmc_void,        gga,           gga_nofix,
    vtg,           hdt,             hdg,           hdg_novar,
    dpt,           dbt,             mwv_apparent,  mwv_true,
    mwd,           vhw,             gsv,           aivdm_type1,
    aivdm_type18,  aivdm_type5_a,   aivdm_type5_b, aivdm_type24a,
    aivdm_type24b, aivdm_sentinels,
};

// --- talker sentences ------------------------------------------------------

pub const rmc = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A";
pub const rmc_expect = .{
    .lat = 48.0 + 7.038 / 60.0,
    .lon = 11.0 + 31.0 / 60.0,
    // 22.4 kn in m/s.
    .sog_mps = 22.4 * 1852.0 / 3600.0,
    .cog_true = 84.4,
    // 3.1° W.
    .variation = -3.1,
    // 1994-03-23 12:35:19 UTC.
    .epoch_ms = @as(i64, 764426119000),
};

/// A receiver with no fix: status V and every data field empty.
pub const rmc_void = "$GPRMC,041215,V,,,,,,,150926,,,N*59";

pub const gga = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47";
pub const gga_expect = .{
    .lat = 48.0 + 7.038 / 60.0,
    .lon = 11.0 + 31.0 / 60.0,
};

pub const gga_nofix = "$GPGGA,041215,,,,,0,00,99.99,,,,,,*4B";

pub const vtg = "$GPVTG,054.7,T,034.4,M,005.5,N,010.2,K*48";
pub const vtg_expect_sog_mps = 5.5 * 1852.0 / 3600.0;

pub const hdt = "$HEHDT,274.07,T*19";

/// Sensor 101.1° with 7.1° W variation and no deviation: true is 94.0°.
pub const hdg = "$HCHDG,101.1,,,7.1,W*3C";
/// The same compass with no variation available: true heading is unknown.
pub const hdg_novar = "$HCHDG,101.1,,,,*43";

pub const dpt = "$SDDPT,4.1,0.5,100.0*54";
pub const dbt = "$SDDBT,17.5,f,5.3,M,2.9,F*38";

/// 214.8° relative — 145.2° to port, which the parser signs negative.
pub const mwv_apparent = "$WIMWV,214.8,R,0.1,K,A*28";
pub const mwv_true = "$WIMWV,045.0,T,10.5,N,A*10";

pub const mwd = "$WIMWD,220.0,T,209.0,M,12.0,N,6.2,M*66";
pub const vhw = "$VWVHW,274.0,T,262.0,M,5.5,N,10.2,K*60";

/// A well-formed sentence the parser does not decode.
pub const gsv = "$GPGSV,3,1,11,03,03,111,00,04,15,270,00,06,01,010,00,13,06,292,00*74";

/// The RMC body with one digit of longitude changed and the original sum.
pub const bad_checksum = "$GPRMC,123519,A,4807.038,N,01132.000,E,022.4,084.4,230394,003.1,W*6A";
/// A sentence that never carried a checksum at all.
pub const no_checksum = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W";

// --- AIS -------------------------------------------------------------------

/// Type 1, moored in Seattle.
pub const aivdm_type1 = "!AIVDM,1,1,,B,177KQJ5000G?tO`K>RA1wUbN0TKH,0*5C";
pub const aivdm_type1_expect = .{
    .mmsi = @as(u32, 477553000),
    .lat = 47.58283333,
    .lon = -122.34583333,
    .sog_kn = 0.0,
    .cog_deg = 51.0,
    .heading_deg = 181.0,
    .nav_status = @as(u8, 5),
};

/// Type 18, a class B under way in the Caspian.
pub const aivdm_type18 = "!AIVDM,1,1,,A,B6CdCm0t3`tba35f@V9faHi7kP06,0*58";
pub const aivdm_type18_expect = .{
    .mmsi = @as(u32, 423302100),
    .lat = 40.00528333,
    .lon = 53.01099667,
    .sog_kn = 1.4,
    .cog_deg = 177.0,
};

/// Type 5 in two fragments: 60 armored characters then 11, fill 2.
pub const aivdm_type5_a = "!AIVDM,2,1,1,A,55?MbV02;H;s<HtKR20EHE:0@T4@Dn2222222216L961O5Gf0NSQEp6ClRp8,0*1C";
pub const aivdm_type5_b = "!AIVDM,2,2,1,A,88888888880,2*25";
pub const aivdm_type5_expect = .{
    .mmsi = @as(u32, 351759000),
    .imo = @as(u32, 9134270),
    .callsign = "3FOF8",
    .name = "EVER DIADEM",
    .destination = "NEW YORK",
    .ship_type = @as(u8, 70),
};

/// A fragment index outside its own fragment count.
pub const aivdm_bad_index = "!AIVDM,2,3,1,A,88888888880,2*24";

/// Type 24 A and B for target C of the synthetic log.
pub const aivdm_type24a = "!AIVDM,1,1,,B,H52LbuQ<D61=18U@D00000000000,0*4A";
pub const aivdm_type24b = "!AIVDM,1,1,,B,H52LbuTU<;?40CBG47mmij104220,0*4F";
pub const aivdm_type24_expect = .{
    .mmsi = @as(u32, 338111222),
    .name = "SEA SPRITE",
    .callsign = "WDG5512",
    .ship_type = @as(u8, 37),
};

/// A type 1 carrying every not-available sentinel at once: latitude 91°,
/// longitude 181°, speed 1023, course 3600, heading 511, status 15.
pub const aivdm_sentinels = "!AIVDM,1,1,,A,15MwqgwP?w<tSF0l4Q@>4?wp0000,0*77";
