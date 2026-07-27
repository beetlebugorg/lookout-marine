//  ViewState.swift
//  Persists the camera pose across launches, next to the mariner settings and
//  the recents list. Reopening on the far side of the world from where you left
//  is the kind of thing a chartplotter must not do.
//
//  The pose itself is `lookout_view`, the same struct the Android shell saves —
//  only the store differs (UserDefaults here, SharedPreferences there). The
//  opening view when nothing is saved is NOT decided here: that policy lives in
//  the core, behind lookout_default_view, so every host agrees.

import Foundation

enum ViewState {
    private static let key = "chart.view"

    /// The saved pose, or nil when there has never been one.
    static func load() -> lookout_view? {
        guard let d = UserDefaults.standard.dictionary(forKey: key),
              let lon = d["lon"] as? Double,
              let lat = d["lat"] as? Double,
              let zoom = d["zoom"] as? Double
        else { return nil }
        return lookout_view(lon: lon, lat: lat, zoom: zoom,
                            rotation_deg: d["rotationDeg"] as? Double ?? 0)
    }

    static func save(_ v: lookout_view) {
        UserDefaults.standard.set([
            "lon": v.lon,
            "lat": v.lat,
            "zoom": v.zoom,
            "rotationDeg": v.rotation_deg,
        ], forKey: key)
    }
}
