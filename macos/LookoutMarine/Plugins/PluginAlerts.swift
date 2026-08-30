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

import SwiftUI
import AVFoundation

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
/// A real alarm, not a system chime: an urgent two-tone burst synthesised at
/// build-free runtime and played through AVAudioEngine, so it carries the same
/// on the Mac, the iPad and the phone. On iOS it sounds through a MUTED ringer
/// (AVAudioSession `.playback`) — a marine alarm that a silent switch could
/// turn off is not an alarm. The exact tone is deliberately plain; a bespoke
/// marine tone is a product decision, but "loud, urgent and unmutable" is not.
@MainActor
final class AlarmSiren {
    /// How often an unacknowledged alarm sounds again. Once a second is right
    /// on a boat and unusable at a desk; ten seconds still cannot be mistaken
    /// for a one-off chime, and leaves room to speak on the radio between
    /// soundings.
    static let repeatInterval: TimeInterval = 10

    private var timer: Timer?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var burst = Self.makeBurst(format: format)

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Start or stop the repeat. Sounding starts at once: the first alarm is
    /// not held back for a timer. The engine and the audio session stay up for
    /// the whole sounding — reactivating per strike would glitch and cost
    /// latency — and are torn down the moment nothing is unacknowledged.
    func setSounding(_ on: Bool) {
        guard on != (timer != nil) else { return }
        guard on else {
            timer?.invalidate()
            timer = nil
            player.stop()
            engine.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return
        }
        #if os(iOS)
        // .playback is the category that plays through Silent Mode and the
        // volume-mute; .duckOthers pulls chartplotter music or a podcast down
        // under the alarm rather than fighting it.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        #endif
        do {
            try engine.start()
        } catch {
            // A silent alarm is dangerous, so the failure is said, not swallowed.
            lkLog("alarm: audio engine did not start (\(error)); the siren is silent this session")
            return
        }
        player.play()
        strike()
        timer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.strike() }
        }
    }

    /// One sounding: schedule the burst to play now. The node plays on between
    /// strikes with nothing queued, so a strike is just the next buffer.
    private func strike() {
        guard engine.isRunning else { return }
        player.scheduleBuffer(burst, at: nil, options: [], completionHandler: nil)
    }

    /// A one-second urgent burst: six pulses alternating between two pitches,
    /// each pulse eased in and out over 5 ms so it beeps instead of clicking.
    /// Two alternating tones read as an alarm where a single steady one reads
    /// as a phone ringing.
    private static func makeBurst(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let onFrames = Int(0.12 * sr)     // pulse length
        let gapFrames = Int(0.08 * sr)    // silence between pulses
        let envFrames = Int(0.005 * sr)   // attack/release, kills the click
        let pulses = 6
        let freqs = [880.0, 1_245.0]      // A5 / D#6 — a minor-third urgency
        let frames = AVAudioFrameCount(pulses * (onFrames + gapFrames))
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let s = buf.floatChannelData![0]
        var i = 0
        for p in 0..<pulses {
            let f = freqs[p % freqs.count]
            for n in 0..<onFrames {
                var a = sin(2 * .pi * f * Double(n) / sr) * 0.6
                if n < envFrames { a *= Double(n) / Double(envFrames) }
                else if n >= onFrames - envFrames { a *= Double(onFrames - n) / Double(envFrames) }
                s[i] = Float(a); i += 1
            }
            for _ in 0..<gapFrames { s[i] = 0; i += 1 }
        }
        return buf
    }

    deinit { timer?.invalidate() }
}

// MARK: - The banner

/// The alerts, over the chart. The palette is the chrome's, so the panel stays
/// readable at night without a hardcoded red burning the mariner's dark
/// adaptation.
struct AlertBanner: View {
    let alerts: [PluginAlert]
    let onAcknowledge: (PluginAlert) -> Void

    /// How many are shown. The strip must not cover the water the mariner is
    /// reading, least of all during a collision alarm, when the target it
    /// names is on the chart underneath. The rest are counted on the last
    /// line and take their turn as the ones above are answered.
    private static let maxVisible = 2
    static let maxWidth: CGFloat = 560

    /// Only what still needs answering. Acknowledging takes a row off the
    /// chart, because the panel covers the water and its job is to say
    /// something needs attention now. What is still dangerous after that is
    /// the chart's to show: the target stays red, and the AIS Targets dialog
    /// holds it at the top of the list with its state.
    private var unanswered: [PluginAlert] { alerts.filter { !$0.acknowledged } }

    var body: some View {
        if !unanswered.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(unanswered.prefix(Self.maxVisible).enumerated()), id: \.element.id) { i, alert in
                    if i > 0 { Divider().overlay(Chrome.rule) }
                    AlertRow(alert: alert) { onAcknowledge(alert) }
                }
                if unanswered.count > Self.maxVisible {
                    Divider().overlay(Chrome.rule)
                    Text("\(unanswered.count - Self.maxVisible) more")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: Self.maxWidth)
            .fixedSize(horizontal: false, vertical: true)
            .panelSurface(opaque: true)
        }
    }
}

/// One alert: the severity bar, the words, and the control that silences it.
private struct AlertRow: View {
    let alert: PluginAlert
    let onAcknowledge: () -> Void

    var body: some View {
        // One line. The words say which danger and which vessel; the water
        // under them is what the mariner is actually looking at, so the row
        // stays the height of its text and the body truncates rather than
        // wrapping into a second line.
        HStack(spacing: 8) {
            Image(systemName: Self.glyph(alert.severity))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.tint(alert.severity))
            Text(alert.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .fixedSize()
            if !alert.body.isEmpty {
                Text(alert.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(action: onAcknowledge) {
                Text("Acknowledge")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Chrome.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ChromeFlatStyle(resting: Chrome.hoverFill, cornerRadius: 6))
            .help("Silence this alert and take it off the chart")
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        // The severity bar is an overlay, not a sibling. A Rectangle is greedy
        // in both directions and only its width is set here, so as a sibling
        // it would take every point of height going and drag the row with it.
        // An overlay takes the height the words settle on.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Self.tint(alert.severity))
                .frame(width: 4)
        }
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
