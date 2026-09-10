//  FirstRunModel.swift: the setup flow's state, and whether it runs.
//
//  One decision per step, in the order a mariner is ready to answer. What this
//  is, where the charts come from, and then the screen that source needs. The
//  flow holds the answers and the steps draw them.
//
//  Source lists only the sources the app can follow through. An offer the app
//  cannot honor costs the mariner a step and returns them nowhere.

import Foundation

@MainActor
@Observable
final class FirstRunModel {

    /// Where the first charts come from.
    enum Source: String, CaseIterable, Identifiable {
        /// NOAA's own ENC, downloaded and prepared here.
        case noaa
        /// A publisher's own style, rendered from tiles as they are needed.
        case online
        /// Cells or prepared charts the mariner already holds.
        case files

        var id: String { rawValue }

        var title: String {
            switch self {
            case .noaa: return "NOAA charts"
            case .online: return "Online chart"
            case .files: return "Files on this \(FirstRun.deviceName)"
            }
        }

        var icon: String {
            switch self {
            case .noaa: return "map"
            case .online: return "globe"
            case .files: return "folder"
            }
        }

        var blurb: String {
            switch self {
            case .noaa:
                return "Official ENC for every U.S. waterway, free. Downloaded to this \(FirstRun.deviceName) and prepared here."
            case .online:
                return "A published chart style. Renders straight away, worldwide, and stores nothing."
            case .files:
                return FirstRun.filesBlurb
            }
        }
    }

    /// The step on screen. `source` is the fork: the flow asks which source,
    /// then shows the one screen that source needs.
    enum Step: Equatable {
        case welcome
        case source
        case coverage
        case onlineChart
    }

    var step: Step = .welcome
    var source: Source = .noaa
    /// True while the flow is over the chart.
    var showing = false

    // MARK: Whether it runs

    private static let group = "firstrun"
    private static let doneKey = "done"

    /// True once the mariner has been through setup, or said Set Up Later.
    /// Kept in the core store beside the other shell preferences, so both
    /// platforms read the same value.
    static var completed: Bool {
        get { Store.shared.bool(group, doneKey, false) ?? false }
        set {
            Store.shared.set(newValue, group, doneKey)
            Store.shared.flush()
        }
    }

    /// LOOKOUT_FIRST_RUN=1 runs setup whatever the store says, and =0 keeps it
    /// down. A screenshot run and a UI test both need to choose, because the
    /// store carries over between launches on one device.
    private static var override: Bool? {
        guard let v = ProcessInfo.processInfo.environment["LOOKOUT_FIRST_RUN"] else {
            return nil
        }
        return v == "1"
    }

    /// The flow runs once, over an app that has settled on having no chart to
    /// draw. It stays down over a chart, because a mariner holding charts has
    /// already answered every question in it.
    static func shouldRun(_ charts: ChartsModel) -> Bool {
        if let override { return override }
        return !completed && charts.nothingToDraw && charts.chartWork == nil
    }

    // MARK: Moving through it

    func begin() {
        step = .welcome
        showing = true
    }

    /// The primary action for the step on screen. Returns the source to act on
    /// once the flow has finished asking and the shell has work to do, such as
    /// raising a file picker.
    @discardableResult
    func advance() -> Source? {
        switch step {
        case .welcome:
            step = .source
            return nil
        case .source:
            switch source {
            case .noaa:
                step = .coverage
                return nil
            case .online:
                step = .onlineChart
                return nil
            case .files:
                finish()
                return .files
            }
        case .coverage:
            finish()
            return .noaa
        case .onlineChart:
            finish()
            return .online
        }
    }

    /// Whether Back applies. The first step offers Set Up Later instead.
    var canGoBack: Bool { step != .welcome }

    func back() {
        switch step {
        case .welcome: break
        case .source: step = .welcome
        case .coverage, .onlineChart: step = .source
        }
    }

    /// Set Up Later, and the end of a completed run. Both record that setup
    /// has run, so it does not ask again.
    func finish() {
        Self.completed = true
        showing = false
        step = .welcome
    }

    // MARK: What each step says

    /// The primary button's words. The last step names the chart it keeps, so
    /// the button states what the choice does.
    func primaryTitle(_ chosenChartName: String?) -> String {
        switch step {
        case .welcome, .source: return "Continue"
        case .coverage: return "Download"
        case .onlineChart: return chosenChartName.map { "Use \($0)" } ?? "Continue"
        }
    }
}
