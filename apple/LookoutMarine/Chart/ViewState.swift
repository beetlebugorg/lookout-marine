//  ViewState.swift
//  Persists the camera pose across launches, next to the mariner settings and
//  the recents list. Reopening on the far side of the world from where you left
//  is the kind of thing a chartplotter must not do.
//
//  The pose itself is `lookout_view`, the same struct the Android shell saves —
//  only the store differs (the defaults domain here, SharedPreferences there).
//  The
//  opening view when nothing is saved is NOT decided here: that policy lives in
//  the core, behind lookout_default_view, so every host agrees.

import Foundation

enum ViewState {
    private static let key = "chart.view"

    /// The saved pose, or nil when there has never been one.
    static func load() -> lookout_view? {
        guard let d = Store.shared.dictionary(key),
              let lon = d["lon"] as? Double,
              let lat = d["lat"] as? Double,
              let zoom = d["zoom"] as? Double
        else { return nil }
        return lookout_view(lon: lon, lat: lat, zoom: zoom,
                            rotation_deg: d["rotationDeg"] as? Double ?? 0)
    }

    /// True when this pose is a different one from the last saved.
    ///
    /// The periodic save runs off the render tick, and frames keep coming while
    /// a plugin moves own ship even though the camera is still. A boat at
    /// anchor with AIS running wrote the same four numbers to disk every three
    /// seconds, for as long as it lay there.
    static func differs(_ v: lookout_view, from o: lookout_view) -> Bool {
        v.lon != o.lon || v.lat != o.lat || v.zoom != o.zoom
            || v.rotation_deg != o.rotation_deg
    }

    static func save(_ v: lookout_view) {
        Store.shared.set([
            "lon": v.lon,
            "lat": v.lat,
            "zoom": v.zoom,
            "rotationDeg": v.rotation_deg,
        ], key)
    }
}
