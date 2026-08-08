//! Real-format NMEA 0183 lines and the values they must decode to.
//!
//! Provenance matters here, because a fixture built to agree with the
//! parser proves nothing about the parser:
//!
//!   - RMC, GGA, VTG, the relative MWV and GSV are the worked examples the
//!     standard's documentation and the common receiver manuals print,
//!     published checksums included.
//!   - The AIS type 1, type 18, two-part type 5 and two-part type 21 are the
//!     worked examples from the AIVDM/AIVDO decoding guide. They must decode
//!     to the MMSIs, positions, ship names and aid names that guide states,
//!     which is what checks the bit layouts in `parser.zig` against something
//!     outside this repository.
//!   - The XDR is CAPTURED off a B&G Zeus, because no published example shows
//!     a real boat's transducer list. The Zeus type 5 pair copies that same
//!     device's FRAMING, which no published example shows either, around a
//!     vessel out of the encoder: a fixture never carries another boat's
//!     identity, and the framing is what it is there to prove.
//!   - The virtual and off-position type 21 lines have no published example.
//!     They come from the encoder in `tools/nmea_gen.zig`, and each says so.
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
    rmc,                  rmc_void,            gga,            gga_nofix,
    vtg,                  hdt,                 hdg,            hdg_novar,
    dpt,                  dbt,                 mwv_apparent,   mwv_true,
    mwd,                  vhw,                 gsv,            aivdm_type1,
    aivdm_type18,         aivdm_type5_a,       aivdm_type5_b,  aivdm_type24a,
    aivdm_type24b,        aivdm_sentinels,     aivdm_type21_a, aivdm_type21_b,
    aivdm_type21_virtual, aivdm_type21_offpos, xdr,            xdr_reordered,
    xdr_wrong_unit,       mtw,                 vlw,            zeus_type5_a,
    zeus_type5_b,
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

/// CAPTURED, off a B&G Zeus. Five transducers: air temperature and barometer
/// listed with no reading, then heel, trim and rudder angle. The value of the
/// fixture is the shape: a variable-length list whose names sit in an order no
/// other boat has to repeat.
pub const xdr = "$IIXDR,C,,C,AIRTEMP,A,3.4,D,HEEL,A,1.9,D,TRIM,P,,B,BARO,A,-2.2,D,RUDDER*0B";
pub const xdr_expect = .{
    .heel_deg = 3.4,
    .trim_deg = 1.9,
    .rudder_deg = -2.2,
};

/// The same three readings a different instrument's way: rudder first, heel
/// last, and an engine temperature in between that nothing here reads. A parser
/// that matched on position would report the rudder angle as heel.
pub const xdr_reordered = "$YXXDR,A,-4.2,D,RUDDER,C,21.5,C,ENGINETEMP,A,12.0,D,HEEL*59";

/// A heel transducer reporting radians. The unit letter is not `D`, so the
/// number is not degrees and is not published as degrees.
pub const xdr_wrong_unit = "$IIXDR,A,0.30,R,HEEL*44";

pub const mtw = "$IIMTW,17.9,C*1C";
/// 17.9 °C in kelvin.
pub const mtw_expect_k = 17.9 + 273.15;

pub const vlw = "$VWVLW,1234.5,N,12.3,N*4D";
pub const vlw_expect = .{
    .total_m = 1234.5 * 1852.0,
    .trip_m = 12.3 * 1852.0,
};

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

/// SELF-CONSISTENT, in the FRAMING a B&G Zeus was seen to use. This pair is the
/// whole reason `Assembler` tolerates a mismatched sequential message id.
///
/// Two things about the framing are wrong against IEC 61162-1 and neither stops
/// the message decoding: field 4, the sequential message id, is 4 on one
/// fragment and 5 on the other where the standard makes it identical, and field
/// 5, the channel, is empty where the standard puts `A` or `B`. The device
/// increments the id per SENTENCE, so every multi-fragment message it sends
/// arrives with fragments that disagree about which message they belong to.
///
/// The vessel is invented and so is everything identifying her: the ship the
/// framing was observed on is somebody's boat, and her MMSI and name are hers.
/// The payload comes from the encoder in `tools/nmea_gen.zig` and is a whole
/// 424-bit type 5, split 60 and 11 characters with two fill bits, which is the
/// split the observed message used.
pub const zeus_type5_a = "!AIVDM,2,1,4,,55NtpTh00001LASO3C8M85V0PE8tp000000000163064440008hCSPD3k2Dh,0*55";
pub const zeus_type5_b = "!AIVDM,2,2,5,,00000000000,2*60";
pub const zeus_type5_expect = .{
    .mmsi = @as(u32, 367999123),
    .callsign = "WDX7042",
    .name = "GRAY HERON",
    .destination = "ANNAPOLIS",
};

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

// --- type 21, aids to navigation -------------------------------------------

/// EXTERNALLY CORROBORATED. The two-fragment type 21 from the AIVDM/AIVDO
/// decoding guide's own sample data, with the decode that document prints
/// beside it — including the name that runs into the name extension. It is
/// 346 bits, so 74 of them are extension.
pub const aivdm_type21_a = "!AIVDM,2,1,5,B,E1mg=5J1T4W0h97aRh6ba84<h2d;W:Te=eLvH50```q,0*46";
pub const aivdm_type21_b = "!AIVDM,2,2,5,B,:D44QDlp0C1DU00,2*36";
pub const aivdm_type21_expect = .{
    .mmsi = @as(u32, 123456789),
    .aid_type = @as(u8, 20), // cardinal mark N
    .name = "CHINA ROSE MURPHY EXPRESS ALERT",
    .lat = 47.9206183333,
    .lon = -122.698591667,
    .off_position = false,
    .virtual_aid = false,
};

/// SELF-CONSISTENT. A virtual isolated danger at the synthetic log's own
/// water, written by the encoder in `tools/nmea_gen.zig` and read back here.
/// No published example of a virtual aid was available; the bit layout it is
/// built on is the one the corroborated fixture above checks.
pub const aivdm_type21_virtual = "!AIVDM,1,1,,B,E>k`s`v;4a::PV@;a2QUh6Pa5P0=@uoO;9kjH20@@@g010,4*3D";
pub const aivdm_type21_virtual_expect = .{
    .mmsi = @as(u32, 993672099),
    .aid_type = @as(u8, 28), // isolated danger
    .name = "VIRTUAL WRECK MARK",
    .lat = 38.983498333,
    .lon = -76.473228333,
    .off_position = false,
    .virtual_aid = true,
};

/// SELF-CONSISTENT, same provenance. A physical starboard hand buoy reporting
/// itself off station, with a 24-character name that needs the extension.
pub const aivdm_type21_offpos = "!AIVDM,1,1,,B,E>k`tNtPW70`7V4ah1T0W72V@1:e@vpV;9VVh20@@@gh03nH<P,4*22";
pub const aivdm_type21_offpos_expect = .{
    .mmsi = @as(u32, 993672315),
    .aid_type = @as(u8, 25), // starboard hand mark
    .name = "ANNAPOLIS CHANNEL BUOY 2",
    .lat = 38.97225,
    .lon = -76.466283333,
    .off_position = true,
    .virtual_aid = false,
};
