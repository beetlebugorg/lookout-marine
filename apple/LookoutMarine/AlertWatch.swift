//
//  Watching for the alarms the plugins raise.
//
//  A plugin raises an alert from its own thread with no gesture behind it, so
//  nothing brings one to the screen unless something asks. This asks, once a
//  second, holds what the core answered, and sounds the siren while an audible
//  alarm is unanswered.
//
//  It reaches the chart through AlertHost and nothing else, so every app runs
//  the same watch over the same alerts: a collision alarm sounds the same on a
//  Mac, an iPad and a headset.
//

import Combine
import Foundation

/// What the watch needs from the chart.
@MainActor
protocol AlertHost: AnyObject {
    /// Every alert the plugins have raised, with the sequence the core stamps
    /// on the set. Nil when the core cannot be read.
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])?
    /// Silence one. It stays listed until the condition clears.
    func acknowledgeAlert(_ id: UInt64) -> Bool
}

@MainActor
final class AlertWatch: ObservableObject {
    /// Every alert the plugins have raised, most urgent first. A banner is
    /// built from this.
    @Published private(set) var alerts: [PluginAlert] = []

    private weak var host: (any AlertHost)?
    private var timer: Timer?
    private let siren = AlarmSiren()
    /// The last set the core reported. The list is rebuilt only when it moves.
    private var seq = -1

    /// How often the core is asked. A second is far below the time any alarm
    /// gives a mariner to act, and far above what the poll costs.
    private static let interval: TimeInterval = 1.0

    /// Start watching. Call it once the plugin layer is up.
    func start(host: any AlertHost) {
        self.host = host
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Stop watching, and stop sounding. The chart is going away with the
    /// plugins that raised the alarms.
    func stop() {
        timer?.invalidate()
        timer = nil
        seq = -1
        siren.setSounding(false)
        if !alerts.isEmpty { alerts = [] }
    }

    func refresh() {
        guard let got = host?.pluginAlerts() else {
            // Nothing readable from the core. The polling continues, because
            // stopping it would leave the boat deaf for the rest of the
            // session over one unanswered read.
            seq = -1
            if !alerts.isEmpty { alerts = [] }
            siren.setSounding(false)
            return
        }
        if got.seq != seq {
            seq = got.seq
            alerts = got.alerts
        }
        // An alarm nobody has answered keeps sounding. A warning is shown and
        // never sounded, so it is not counted here.
        siren.setSounding(alerts.contains { $0.severity.audible && !$0.acknowledged })
    }

    /// Silence one alert, and show the change without waiting for the next
    /// poll: the mariner pressed a control and must see it answer.
    func acknowledge(_ alert: PluginAlert) {
        guard host?.acknowledgeAlert(alert.id) == true else { return }
        seq = -1
        refresh()
    }
}
