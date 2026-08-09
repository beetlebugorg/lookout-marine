//  PluginAlerts.swift: the alerts the plugins raise, on screen and out loud.
//
//  A plugin raises an alert with a severity, a title and a body. The core holds
//  it and hands it over through lookout_plugin_alerts_json, already ordered:
//  what nobody has answered first, then the loudest, then the oldest. This file
//  shows it, sounds the alarms, and calls lookout_plugin_alert_ack when the
//  mariner silences one.
//
//  AN ALARM IS AUDIBLE AND A WARNING IS VISIBLE. That is the whole of what
//  severity means here. An alarm repeats until it is acknowledged: it does not
//  stop because the mariner looked at it, and it does not time out. Silence is
//  a decision somebody makes.
//
//  Acknowledging silences ONE alert. The mariner who has seen the vessel
//  crossing ahead has not seen the one coming up astern, and a control that
//  silenced both would hide the second.

#if os(macOS)
import AppKit
import SwiftUI

// MARK: - What the core hands over

enum PluginAlertSeverity: String {
    case alarm, warning, notice

    /// True when this severity is sounded rather than only shown.
    var audible: Bool { self == .alarm }
}

struct PluginAlert: Identifiable, Equatable {
    let id: UInt64
    let plugin: String
    let severity: PluginAlertSeverity
    let title: String
    let body: String
    /// When the plugin first raised it.
    let raised: Date
    let acknowledged: Bool

    init?(_ o: [String: Any]) {
        guard let id = (o["id"] as? NSNumber)?.uint64Value,
              let title = o["title"] as? String else { return nil }
        self.id = id
        self.plugin = o["plugin"] as? String ?? ""
        // A severity this build does not know is treated as an alarm, the same
        // way the core treats one it cannot read. Silence is never the fallback.
        self.severity = PluginAlertSeverity(rawValue: o["severity"] as? String ?? "") ?? .alarm
        self.title = title
        self.body = o["body"] as? String ?? ""
        let ms = (o["raised"] as? NSNumber)?.doubleValue ?? 0
        self.raised = Date(timeIntervalSince1970: ms / 1000)
        self.acknowledged = o["acknowledged"] as? Bool ?? false
    }
}

// MARK: - The sound

/// The alarm tone, repeated while anything is unacknowledged.
///
/// A system sound stands in for the real tone, which is a product decision: a
/// marine alarm has to cut through wind and engine noise, and choosing what
/// that sounds like is not a thing to settle in the shell.
@MainActor
final class AlarmSiren {
    /// How often an unacknowledged alarm sounds again. Once a second is right
    /// on a boat and unusable at a desk; ten seconds still cannot be mistaken
    /// for a one-off chime, and leaves room to speak on the radio between
    /// soundings.
    static let repeatInterval: TimeInterval = 10

    private var timer: Timer?
    private let sound = NSSound(named: NSSound.Name("Submarine"))

    /// Start or stop the repeat. Sounding starts at once: the first alarm is
    /// not held back for a timer.
    func setSounding(_ on: Bool) {
        guard on != (timer != nil) else { return }
        guard on else {
            timer?.invalidate()
            timer = nil
            return
        }
        strike()
        timer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.strike() }
        }
    }

    private func strike() {
        guard let sound else {
            NSSound.beep()
            return
        }
        // Restart rather than overlap: a sound still playing would otherwise
        // swallow the next strike and the repeat would go quiet.
        sound.stop()
        sound.play()
    }
}

// MARK: - The banner

/// The alerts, over the chart. The palette is the chrome's, so the panel stays
/// readable at night without a hardcoded red burning the mariner's dark
/// adaptation.
struct AlertBanner: View {
    let alerts: [PluginAlert]
    let onAcknowledge: (PluginAlert) -> Void

    /// How many are shown. Beyond this the panel would cover the water the
    /// mariner is trying to look at; the rest are counted on the last line and
    /// take their turn as the ones above are answered.
    private static let maxVisible = 3
    static let width: CGFloat = 460

    var body: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(alerts.prefix(Self.maxVisible).enumerated()), id: \.element.id) { i, alert in
                    if i > 0 { Divider().overlay(Chrome.rule) }
                    AlertRow(alert: alert) { onAcknowledge(alert) }
                }
                if alerts.count > Self.maxVisible {
                    Divider().overlay(Chrome.rule)
                    Text("\(alerts.count - Self.maxVisible) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
            .frame(width: Self.width)
            .panelSurface(opaque: true)
        }
    }
}

/// One alert: the severity bar, the words, and the control that silences it.
private struct AlertRow: View {
    let alert: PluginAlert
    let onAcknowledge: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Self.tint(alert.severity))
                .frame(width: 4)
                // An acknowledged alert is still live. It is dimmed, not
                // removed: the mariner can see what they silenced.
                .opacity(alert.acknowledged ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: Self.glyph(alert.severity))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.tint(alert.severity))
                    Text(alert.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                }
                if !alert.body.isEmpty {
                    Text(alert.body)
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if alert.acknowledged {
                Text("Acknowledged")
                    .font(.system(size: 11))
                    .foregroundStyle(Chrome.muted)
            } else {
                Button(action: onAcknowledge) {
                    Text("Acknowledge")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Chrome.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ChromeFlatStyle(resting: Chrome.hoverFill, cornerRadius: 6))
                .help("Silence this alert. It stays listed until the condition clears")
            }
        }
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .opacity(alert.acknowledged ? 0.7 : 1)
    }

    /// Alarm takes the palette's strongest warning colour, a warning takes
    /// amber. Both are chrome tokens, so they follow the scheme the chart is in.
    private static func tint(_ s: PluginAlertSeverity) -> Color {
        switch s {
        case .alarm: return Chrome.overscale
        case .warning: return Chrome.amber
        case .notice: return Chrome.accent
        }
    }

    private static func glyph(_ s: PluginAlertSeverity) -> String {
        switch s {
        case .alarm: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .notice: return "info.circle.fill"
        }
    }
}

#endif
