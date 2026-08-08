//! The manifest fixtures the parts of the host share in their tests.
//!
//! There are no tests here. Each part carries its own.

pub const ais_settings_manifest =
    \\{"id":"org.beetlebug.ais","name":"AIS targets","api":1,
    \\ "capabilities":["ais.read"],
    \\ "settings":[
    \\  {"key":"cpa_limit","label":"CPA limit","kind":"number","unit":"m","min":93,"max":9260,"default":926},
    \\  {"key":"cpa_alarm","label":"Collision alarm","kind":"toggle","default":true}]}
;

pub const v2_manifest =
    \\{"id":"org.beetlebug.ais","name":"AIS targets","api":1,
    \\ "settings":{"groups":[
    \\  {"label":"Collision alarm","tab":"alarms","fields":[
    \\   {"key":"cpa_limit","label":"Closest approach","desc":"Alarm when a vessel will pass closer than this.",
    \\    "kind":"number","unit":"m","min":93,"max":9260,"default":926},
    \\   {"key":"cpa_alarm","label":"Collision alarm","kind":"toggle","default":true}]},
    \\  {"label":"AIS targets","tab":"vessels","fields":[
    \\   {"key":"vector_min","label":"Course vectors","kind":"number","unit":"min","min":1,"max":24,"default":6}]},
    \\  {"fields":[
    \\   {"key":"spare","label":"Spare","kind":"toggle","default":false}]}]}}
;

pub const list_manifest =
    \\{"id":"org.beetlebug.nmea0183","name":"NMEA 0183","api":1,
    \\ "settings":{"groups":[
    \\  {"label":"Connections","tab":"connections","list":{"key":"connections",
    \\   "footer":"Most WiFi gateways serve NMEA 0183 on port 10110.",
    \\   "empty":"No gateways yet.","add_label":"Add Gateway","switch_key":"enabled",
    \\   "item_fields":[
    \\   {"key":"name","label":"Name","kind":"text","optional":true},
    \\   {"key":"host","label":"Address","desc":"The gateway on your network.","kind":"text","default":"127.0.0.1"},
    \\   {"key":"port","label":"Port","kind":"number","min":1,"max":65535,"default":10110},
    \\   {"key":"enabled","label":"On","kind":"toggle","default":true}]}}]}}
;
