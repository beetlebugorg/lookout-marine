//  FirstRunModel.swift: the setup flow as the views read it.
//
//  One decision per step, in the order a mariner is ready to make it. What
//  this is, where the charts come from, and then the screen that source needs.
//  The core holds the steps and whether setup runs (lookout_setup_*). This
//  holds the words and forwards the mariner's actions.
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

        /// The LOOKOUT_SETUP_FROM_* value.
        var core: Int32 {
            switch self {
            case .noaa: return LOOKOUT_SETUP_FROM_NOAA
            case .online: return LOOKOUT_SETUP_FROM_ONLINE
            case .files: return LOOKOUT_SETUP_FROM_FILES
            }
        }

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

    /// The step on screen, numbered as LOOKOUT_SETUP_STEP_*. `source` is the
    /// fork: the source step picks one, and the flow then shows the one
    /// screen that source needs.
    enum Step: UInt8, Equatable {
        case welcome = 0
        case source = 1
        case coverage = 2
        case onlineChart = 3
        /// Charts arriving and converting. Setup stays open through it,
        /// because the chart opens when the import finishes.
        case importing = 4
        /// The safety contour, asked once there is a chart to draw it on.
        case depths = 5
    }

    /// The source card picked on the source step.
    var source: Source = .noaa
    /// The regions of the NOAA order, named for the import step.
    var orderRegions = ""

    /// The core's setup state machine (src/firstrun.zig).
    private let handle: OpaquePointer?
    private(set) var state = lookout_setup_state()

    init() {
        handle = lookout_setup_new()
    }

    deinit {
        lookout_setup_free(handle)
    }

    var step: Step { Step(rawValue: state.step) ?? .welcome }
    /// True while the flow is over the chart.
    var showing: Bool { state.showing != 0 }
    var canGoBack: Bool { state.can_go_back != 0 }
    var primaryEnabled: Bool { state.primary_enabled != 0 }
    /// The NOAA order ended with no chart to continue to. The step states
    /// the end and offers Back.
    var importEnded: Bool { state.import_ended != 0 }
    /// Work ran on the import step. An import yet to start and one that has
    /// finished both have no work running.
    var sawWork: Bool { state.saw_work != 0 }
    /// The NOAA order's size as it was placed, or nil for a dropped folder.
    var order: (charts: UInt32, bytes: UInt64)? {
        state.ordered != 0 ? (state.order_charts, state.order_bytes) : nil
    }

    /// Raised when the mariner continues from the source step with NOAA
    /// picked. The regions come after they accept. Clearing it declines.
    var showingEncTerms: Bool {
        get { state.terms_showing != 0 }
        set { if !newValue { declineEncTerms() } }
    }

    // MARK: Whether it runs

    /// LOOKOUT_FIRST_RUN=1 runs setup whatever the library holds, and =0
    /// keeps it down. A screenshot run and a UI test both need to choose.
    ///
    /// A step name in place of 1 opens setup on that step: welcome, source,
    /// coverage, online. A screenshot run has no pointer to click Continue
    /// with.
    private static var setting: String? {
        ProcessInfo.processInfo.environment["LOOKOUT_FIRST_RUN"]
    }

    static var override: Bool? {
        guard let v = setting else { return nil }
        return v != "0"
    }

    /// The step LOOKOUT_FIRST_RUN names, or welcome.
    static var openingStep: Step {
        switch setting {
        case "source": return .source
        case "coverage": return .coverage
        case "online": return .onlineChart
        case "importing": return .importing
        case "depths": return .depths
        default: return .welcome
        }
    }

    /// True when setup is down and has a reason to come up.
    var shouldBegin: Bool {
        guard !showing else { return false }
        return Self.override ?? (state.should_run != 0)
    }

    /// Hand the core what the app observes.
    func note(_ facts: Facts) {
        var f = facts.c
        lookout_setup_note(handle, &f)
        refresh()
    }

    private func refresh() {
        lookout_setup_read(handle, &state)
    }

    @discardableResult
    private func act(_ action: Int32, _ arg: Int32 = 0) -> Int32 {
        defer { refresh() }
        return lookout_setup_act(handle, action, arg)
    }

    // MARK: Moving through it

    func begin() {
        act(LOOKOUT_SETUP_BEGIN, Int32(Self.openingStep.rawValue))
    }

    /// Accepted. On to picking water.
    func agreeToEncTerms() { act(LOOKOUT_SETUP_AGREE) }

    /// Dismissed without accepting. The source step stands, so another source
    /// is still open to them.
    func declineEncTerms() { act(LOOKOUT_SETUP_DECLINE) }

    /// The primary action for the step on screen. Returns the source to act on
    /// once the flow has finished asking and the shell has work to do, such as
    /// raising a file picker.
    @discardableResult
    func advance() -> Source? {
        switch act(LOOKOUT_SETUP_ADVANCE, source.core) {
        case LOOKOUT_SETUP_FROM_NOAA: return .noaa
        case LOOKOUT_SETUP_FROM_ONLINE: return .online
        case LOOKOUT_SETUP_FROM_FILES: return .files
        default: return nil
        }
    }

    func back() { act(LOOKOUT_SETUP_BACK) }

    /// Set Up Later, and the end of a run that finished. Both put setup away
    /// for this launch until the library that held charts is emptied.
    func finish() { act(LOOKOUT_SETUP_LATER) }

    // MARK: What each step says

    /// The picked chart's name, for the online step's button.
    func chosenChartName(_ links: ChartLinksModel) -> String? {
        guard let url = links.active else { return nil }
        return links.list.first { $0.url == url }?.name
    }

    /// The primary button's title. On the online step it names the picked
    /// chart.
    func primaryTitle(_ chosenChartName: String?) -> String {
        switch step {
        case .welcome, .source: return "Continue"
        case .coverage: return "Download"
        case .importing: return "Continue"
        case .depths: return "Start Sailing"
        case .onlineChart: return chosenChartName.map { "Use \($0)" } ?? "Continue"
        }
    }
}

extension FirstRunModel {
    /// What the app observes, as lookout_setup_facts. Equatable, so a view
    /// can note it whenever it changes.
    struct Facts: Equatable {
        var catalogReady = false
        var picked = false
        var onLink = false
        var nothingToDraw = false
        var hasCharts = false
        var workRunning = false
        var downloading = false
        var chartOpen = false
        var noaaOutcome: UInt8 = 0
        var noaaRun: UInt32 = 0
        var pickCharts: UInt32 = 0
        var pickBytes: UInt64 = 0

        var c: lookout_setup_facts {
            var f = lookout_setup_facts()
            f.catalog_ready = catalogReady ? 1 : 0
            f.picked = picked ? 1 : 0
            f.on_link = onLink ? 1 : 0
            f.nothing_to_draw = nothingToDraw ? 1 : 0
            f.has_charts = hasCharts ? 1 : 0
            f.work_running = workRunning ? 1 : 0
            f.downloading = downloading ? 1 : 0
            f.chart_open = chartOpen ? 1 : 0
            f.noaa_outcome = noaaOutcome
            f.noaa_run = noaaRun
            f.pick_charts = pickCharts
            f.pick_bytes = pickBytes
            return f
        }
    }
}
