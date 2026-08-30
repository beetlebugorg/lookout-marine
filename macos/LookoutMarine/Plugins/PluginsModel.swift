//  PluginsModel.swift — what the plugins are, declare and alarm about.
//
//  The alerts are cross-platform: the banner, the poll and the siren all run on
//  iOS too, so the plugins reach an iPad mariner. An alarm repeats until it is
//  acknowledged, and acknowledging silences ONE alert.

import Foundation

@MainActor
@Observable
final class PluginsModel {
    /// True while the plugin layer is up. Own ship comes from a plugin, so the
    /// follow control is only shown when one can supply a position.
    var active = false

    /// Every table the loaded plugins declare, in declaration order. The
    /// Vessels menu and the settings row are built from this, so what is
    /// offered follows the plugins that are up: a plugin that unloads takes
    /// its item with it.
    var tables: [PluginTableSpec] = []

    /// Every alert the plugins have raised, most urgent first. The banner over
    /// the chart is built from this.
    var alerts: [PluginAlert] = []

    /// The package on the consent sheet: set by `begin`, cleared by Install or
    /// Cancel. The sheet presents while this is non-nil.
    var pendingInstall: PluginPackage?
    /// The sentence of the last refused install, for its own alert — an
    /// install refusal is not a chart error.
    var installError: String?
    /// A .lkplug opened before any chart was: kept until the chart (and with
    /// it the plugin layer) is up, then inspected.
    var pendingInstallPath: String?
    /// The temporary directory holding a package copied off the Files picker,
    /// deleted once the sheet is answered either way.
    var pendingInstallCopy: URL?

    weak var controller: ChartController?

    /// How often the core is asked for its alerts. The plugins raise them from
    /// their own threads with no gesture behind them, so nothing else would
    /// bring one to the screen.
    private static let alertPollInterval: TimeInterval = 1.0

    private var alertTimer: Timer?
    private let siren = AlarmSiren()
    /// The last set the core reported. The list is rebuilt only when it moves.
    private var alertSeq = -1

    // MARK: Tables

    /// The tables the loaded plugins declare. The menu and the settings row are
    /// built from this, so setting it is all it takes to make them appear.
    func refreshTables() {
        guard let c = controller else { return }
        tables = c.tableSpecs()
    }

    // MARK: Alerts

    /// Start watching for alerts. Called once the plugin layer is up.
    func startAlertWatch() {
        guard alertTimer == nil else { return }
        refreshAlerts()
        alertTimer = Timer.scheduledTimer(withTimeInterval: Self.alertPollInterval,
                                          repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAlerts() }
        }
    }

    /// Stop watching, and stop sounding. The chart is going away with the
    /// plugins that raised the alarms.
    func stopAlertWatch() {
        alertTimer?.invalidate()
        alertTimer = nil
        alertSeq = -1
        siren.setSounding(false)
        if !alerts.isEmpty { alerts = [] }
    }

    private func refreshAlerts() {
        guard let got = controller?.pluginAlerts() else {
            // Nothing readable from the core. The polling continues, because
            // stopping it would leave the boat deaf for the rest of the
            // session over one unanswered read.
            alertSeq = -1
            if !alerts.isEmpty { alerts = [] }
            siren.setSounding(false)
            return
        }
        if got.seq != alertSeq {
            alertSeq = got.seq
            alerts = got.alerts
        }
        // An alarm nobody has answered keeps sounding. A warning is shown and
        // never sounded, so it is not counted here.
        siren.setSounding(alerts.contains { $0.severity.audible && !$0.acknowledged })
    }

    /// Silence one alert, and show the change without waiting for the next
    /// poll: the mariner pressed a control and must see it answer.
    func acknowledge(_ alert: PluginAlert) {
        guard controller?.acknowledgeAlert(alert.id) == true else { return }
        alertSeq = -1
        refreshAlerts()
    }

    // MARK: Install

    /// Read the package and put what it asks for in front of the mariner.
    /// AppModel holds every entry point, because a package that arrives before
    /// the chart does has to wait for the plugin layer.
    func begin(_ path: String) {
        guard let json = controller?.inspectPlugin(path) else {
            installError = "The plugin layer could not start."
            return
        }
        let pkg = PluginPackage.parse(json, path: path)
        if let err = pkg.error {
            installError = err
            return
        }
        pendingInstall = pkg
    }

    /// The Install button: the consent happened, so the package goes in and
    /// starts drawing. A refusal lands in its own alert.
    func confirmInstall() {
        guard let pkg = pendingInstall else { return }
        pendingInstall = nil
        if let err = controller?.installPlugin(pkg.path) {
            installError = err
        }
        dropCopy()
    }

    /// Throw away a package copied off the Files picker. The core keeps its own
    /// copy of anything it installed, and a cancel keeps nothing.
    func dropCopy() {
        guard let dir = pendingInstallCopy else { return }
        pendingInstallCopy = nil
        try? FileManager.default.removeItem(at: dir)
    }
}
