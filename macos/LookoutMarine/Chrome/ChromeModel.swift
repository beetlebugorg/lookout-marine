//  ChromeModel.swift — what is raised over the chart, and what is typed into it.
//
//  Flags and fields only. Nothing here reaches the core; the chrome that these
//  raise does that for itself.

import Foundation

@MainActor
@Observable
final class ChromeModel {
    // MARK: The iOS pickers
    //
    // Unused on macOS, where the file panel and the Settings scene are
    // AppKit-native.

    var showImporter = false
    /// The Add Raster Charts picker. Separate from `showImporter` because the
    /// two import different things to different places: an ENC is copied into
    /// the container and opened, a raster chart is added to the underlay.
    var showRasterImporter = false
    /// The same two pickers again, for the SETTINGS sheet. A presented sheet
    /// cannot present another one from the view it came up over — the pair
    /// above hang on the chart view — so the form attaches its own and these
    /// are the flags that raise them. Add Charts used to dismiss the form and
    /// re-present the picker 0.45s later to get around it; Add Raster Charts
    /// never got that treatment and simply did nothing.
    var showSettingsImporter = false
    var showSettingsRasterImporter = false
    var showSettingsStyleImporter = false
    /// Install Plugin… on iOS. A plugin file arrives through the Files app.
    var showSettingsPluginImporter = false

    // MARK: The settings form

    var showSettings = false
    /// Which settings section shows, by its core name — "display", "depths",
    /// "text", "charts", "vessels", "alarms", "connections", "advanced". A
    /// name no section answers to falls back to Display. The screenshot hook
    /// sets it.
    var settingsTab = "display"

    // MARK: The search field, and the scale entry

    var searchOpen = false
    var searchText = ""
    var showScaleEntry = false
    var scaleEntryText = ""
}
