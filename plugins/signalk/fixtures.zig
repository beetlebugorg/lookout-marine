//! Signal K documents the tests read, and what each one should decode to.
//!
//! PROVENANCE. Every fixture says where it came from. A fixture marked
//! SPEC is copied out of the Signal K specification repository at the file
//! named beside it, and it is the only kind that proves this plugin reads what
//! a real server writes. A fixture marked BUILT was written here, because the
//! specification prints no example of that case; a BUILT fixture proves the
//! plugin's own logic and nothing about the wire.
//!
//! IDENTITIES. Every vessel MMSI here is invented on MID 899, which is
//! unallocated, so none can belong to a real vessel; an aid to navigation
//! uses 99, then 899, then four digits. A SPEC fixture keeps the
//! specification's document shape, paths and values and carries an invented
//! identity in place of the one the specification prints: what the fixture
//! proves is the reading of the shape, not the number in the context URN.
//!
//! Version 1.8.2 of the specification is the one read. The pages are
//! `streaming_api`, `data_model`, `subscription_protocol` and `urls_ports`,
//! and the samples are under `samples/` in the same repository.
//!
//! Two of the specification's own sample files are NOT here.
//! `samples/delta/0183-RMC-export-delta.json` and its `-min-` twin are marked
//! legacy: they carry a bare MMSI as the context, they flatten a position into
//! two leaf paths, and they carry a course in DEGREES where the current
//! specification has radians. `mmsiOf` refuses that context shape on purpose.

// ---------------------------------------------------------------------------
// SPEC — samples/hello/docs-hello.json, printed in streaming_api.md under
// "Connection Hello". A TCP server writes this, unasked, when the socket
// opens.
// ---------------------------------------------------------------------------

pub const hello =
    \\{"name":"foobar marine server","version":"1.0.4","timestamp":"2018-06-21T15:09:16.704Z","self":"vessels.urn:mrn:signalk:uuid:c0d79334-4e25-4245-8892-54e8ccc8021d","roles":["master","main"]}
;
pub const hello_expect_self = "vessels.urn:mrn:signalk:uuid:c0d79334-4e25-4245-8892-54e8ccc8021d";

// ---------------------------------------------------------------------------
// SPEC — samples/hello/docs-hello-minimal.json. `version` and `roles` are the
// only fields the hello schema requires, so a legal server may never say which
// vessel is own ship.
// ---------------------------------------------------------------------------

pub const hello_minimal =
    \\{"version":"1.0.2","roles":["slave"]}
;

// ---------------------------------------------------------------------------
// SPEC — samples/delta/docs-data_model.json, the file data_model.md slices to
// print the Delta Format section.
//
// It carries three updates for one MMSI context: two propulsion paths this
// plugin does not map, a course in radians, a speed in metres per second, and
// a name delivered at the EMPTY path, which is how the specification says a
// subtree is merged.
// ---------------------------------------------------------------------------

pub const spec_data_model =
    \\{"context":"vessels.urn:mrn:imo:mmsi:899000606","updates":[{"source":{"label":"N2000-01","type":"NMEA2000","src":"017","pgn":127488},"timestamp":"2010-01-07T07:18:44Z","values":[{"path":"propulsion.0.revolutions","value":16.341667},{"path":"propulsion.0.boostPressure","value":45500.0}]},{"source":{"label":"N2000-01","type":"NMEA2000","src":"115","pgn":128267},"timestamp":"2014-08-15T16:00:00.081Z","values":[{"path":"navigation.courseOverGroundTrue","value":2.971},{"path":"navigation.speedOverGround","value":3.85}]},{"source":{"label":"N2000-01","type":"NMEA2000","src":"115","pgn":128267},"timestamp":"2014-08-15T19:02:31.507Z","values":[{"path":"","value":{"name":"MOSSY LANTERN"}}]}]}
;

pub const spec_data_model_identity = "vessels.urn:mrn:imo:mmsi:899000606";
pub const spec_data_model_expect = .{
    .mmsi = @as(u32, 899000606),
    .sog_mps = 3.85,
    // 2.971 rad in degrees.
    .cog_deg = 170.22576093336758,
    .name = "MOSSY LANTERN",
    // The two propulsion paths.
    .unmapped = @as(u64, 2),
};

// ---------------------------------------------------------------------------
// SPEC — samples/delta/docs-data_model_multiple_values.json. Two sources
// report the same path in one document, which the specification prints to show
// that a delta may carry more than one source. The context is a UUID, so no
// MMSI can be derived from it.
// ---------------------------------------------------------------------------

pub const spec_multiple_values =
    \\{"context":"vessels.urn:mrn:signalk:uuid:c0d79334-4e25-4245-8892-54e8ccc8021d","updates":[{"source":{"label":"GPS-1","type":"NMEA0183","talker":"GP","sentence":"RMC"},"timestamp":"2017-04-03T06:14:04.451Z","values":[{"path":"navigation.courseOverGroundTrue","value":3.615624078431440}]},{"source":{"label":"actisense","type":"NMEA2000","src":"115","pgn":128267},"timestamp":"2017-04-03T06:14:04.451Z","values":[{"path":"navigation.courseOverGroundTrue","value":3.615624078431453}]}]}
;

pub const spec_multiple_values_identity = "vessels.urn:mrn:signalk:uuid:c0d79334-4e25-4245-8892-54e8ccc8021d";
/// The LAST source in the document wins, and 3.615624078431453 rad is 207.16
/// degrees exactly. The first source's value is 207.15999999999926.
pub const spec_multiple_values_expect_cog_deg = 207.16;

// ---------------------------------------------------------------------------
// SPEC — the delta printed in sources.md. Its `context` is the LAST key, which
// the specification allows: JSON key order carries no meaning. Nothing in it
// is a path this plugin maps.
// ---------------------------------------------------------------------------

pub const spec_sources =
    \\{"updates":[{"source":{"label":"ttyUSB0","type":"NMEA2000","pgn":127251,"src":"204"},"timestamp":"2017-04-15T20:38:26.709Z","values":[{"path":"navigation.rateOfTurn","value":-0.000412469}]}],"context":"vessels.urn:mrn:imo:mmsi:899001010"}
;

// ---------------------------------------------------------------------------
// SPEC — samples/delta/docs-notifications.json. One value is an object and one
// is JSON null, on a path outside this plugin's vocabulary. It proves a value
// shape the plugin does not expect never reaches a conversion.
// ---------------------------------------------------------------------------

pub const spec_notifications =
    \\{"context":"vessels.urn:mrn:signalk:uuid:c0d79334-4e25-4245-8892-54e8ccc8021d","updates":[{"source":{"label":"ttyUSB0","type":"NMEA0183","talker":"GP","sentence":"MOB"},"timestamp":"2017-08-15T16:00:05.200Z","values":[{"path":"notifications.mob","value":{"message":"MOB","state":"emergency","method":["visual","sound"]}}]},{"source":{"label":"ttyUSB0","type":"NMEA0183","talker":"GP","sentence":"MOB"},"timestamp":"2017-08-15T16:00:05.538Z","values":[{"path":"notifications.mob","value":null}]}]}
;

// ---------------------------------------------------------------------------
// BUILT — no delta in the specification's samples carries
// `navigation.position`. The shape is fixed by two places that are not a delta
// sample: data_model.md prints the value as
// `{"latitude": -41.2936935424, "longitude": 173.2470855712}`, and the
// definitions schema requires `latitude` and `longitude` and makes `altitude`
// optional. The position here is the Annapolis water the rest of this
// repository is tested on.
// ---------------------------------------------------------------------------

pub const position_delta =
    \\{"context":"vessels.self","updates":[{"$source":"ttyUSB0.GP","timestamp":"2026-08-07T12:00:00.000Z","values":[{"path":"navigation.position","value":{"longitude":-76.4767,"latitude":38.9763,"altitude":0.0}}]}]}
;
pub const position_expect = .{ .lat = 38.9763, .lon = -76.4767 };

// ---------------------------------------------------------------------------
// BUILT — a heading of exactly a quarter turn, so a plugin that forgot to
// convert would publish 1.57 and a plugin that converted would publish 90.
// ---------------------------------------------------------------------------

pub const heading_delta =
    \\{"updates":[{"values":[{"path":"navigation.headingTrue","value":1.5707963267948966}]}]}
;

// ---------------------------------------------------------------------------
// BUILT — the three wind paths in one delta. The specification's schema calls
// `angleApparent` "negative to port", which is the host's own convention read
// from the other side.
// ---------------------------------------------------------------------------

pub const wind_delta =
    \\{"context":"vessels.self","updates":[{"timestamp":"2026-08-07T12:00:01.000Z","values":[{"path":"environment.wind.speedApparent","value":5.66},{"path":"environment.wind.angleApparent","value":-0.4},{"path":"environment.wind.directionTrue","value":3.5}]}]}
;
pub const wind_expect_speed_mps = 5.66;
pub const wind_expect_angle_deg = -22.918311805232918;
pub const wind_expect_direction_deg = 200.53522829578813;

// ---------------------------------------------------------------------------
// BUILT — a delta with no context at all. The specification says a delta
// without a context is about own ship.
// ---------------------------------------------------------------------------

pub const no_context_delta =
    \\{"updates":[{"values":[{"path":"environment.depth.belowTransducer","value":4.1}]}]}
;

// ---------------------------------------------------------------------------
// BUILT — a source that holds the path and has no reading for it. The
// specification says the value MUST be JSON null in that case, and the host
// reads a null the same way.
// ---------------------------------------------------------------------------

pub const null_delta =
    \\{"context":"vessels.self","updates":[{"values":[{"path":"environment.depth.belowTransducer","value":null}]}]}
;

// ---------------------------------------------------------------------------
// BUILT — a vessel that sends its name as its own path rather than merged at
// the empty one. Servers do both.
// ---------------------------------------------------------------------------

pub const name_path_delta =
    \\{"context":"vessels.urn:mrn:imo:mmsi:899000505","updates":[{"values":[{"path":"name","value":"COPPER KETTLE"},{"path":"navigation.speedOverGround","value":4.1}]}]}
;

// ---------------------------------------------------------------------------
// BUILT — contexts the plugin must not treat as a vessel. An aid to navigation
// has its own branch, and its MMSI must not become a ship.
// ---------------------------------------------------------------------------

pub const aton_context_delta =
    \\{"context":"atons.urn:mrn:imo:mmsi:998990001","updates":[{"values":[{"path":"navigation.position","value":{"longitude":-76.466,"latitude":38.972}}]}]}
;

// ---------------------------------------------------------------------------
// BUILT — values of a shape the path does not take. A position sent as a
// number is a fault in the server; a latitude of 91 is a fault in its
// instrument. Neither is guessed at.
// ---------------------------------------------------------------------------

pub const bad_position_delta =
    \\{"context":"vessels.self","updates":[{"values":[{"path":"navigation.position","value":38.9763}]}]}
;

pub const out_of_range_position_delta =
    \\{"context":"vessels.self","updates":[{"values":[{"path":"navigation.position","value":{"longitude":-76.4767,"latitude":91.5}}]}]}
;

// ---------------------------------------------------------------------------
// BUILT — a delta whose every path is outside the vocabulary, and one that
// mixes mapped and unmapped paths.
// ---------------------------------------------------------------------------

pub const only_unmapped_delta =
    \\{"context":"vessels.self","updates":[{"values":[{"path":"navigation.headingMagnetic","value":1.2},{"path":"electrical.batteries.house.voltage","value":12.9}]}]}
;

pub const mixed_delta =
    \\{"context":"vessels.self","updates":[{"values":[{"path":"navigation.headingMagnetic","value":1.2},{"path":"navigation.speedThroughWater","value":2.4},{"path":"environment.depth.belowKeel","value":1.8},{"path":"navigation.speedOverGround","value":2.6}]}]}
;
pub const mixed_expect_sog_mps = 2.6;
pub const mixed_expect_unmapped = 3;

/// Every document in this file, so a test can prove none of them is refused
/// for a reason nobody meant.
pub const all = [_][]const u8{
    hello,
    hello_minimal,
    spec_data_model,
    spec_multiple_values,
    spec_sources,
    spec_notifications,
    position_delta,
    heading_delta,
    wind_delta,
    no_context_delta,
    null_delta,
    name_path_delta,
    aton_context_delta,
    bad_position_delta,
    out_of_range_position_delta,
    only_unmapped_delta,
    mixed_delta,
};
