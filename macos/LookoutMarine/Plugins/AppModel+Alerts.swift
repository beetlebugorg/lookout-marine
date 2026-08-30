//  AppModel+Alerts.swift — what the plugins are alarming about.
//
//  Cross-platform: the banner, the poll and the siren all run on iOS too, so
//  the plugins reach an iPad mariner. An alarm repeats until it is
//  acknowledged, and acknowledging silences ONE alert.

import Foundation

@MainActor
extension AppModel {

    /// How often the core is asked for its alerts. The plugins raise them from
    /// their own threads with no gesture behind them, so nothing else would
    /// bring one to the screen.
    private static let alertPollInterval: TimeInterval = 1.0

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
    func acknowledgeAlert(_ alert: PluginAlert) {
        guard controller?.acknowledgeAlert(alert.id) == true else { return }
        alertSeq = -1
        refreshAlerts()
    }
}
