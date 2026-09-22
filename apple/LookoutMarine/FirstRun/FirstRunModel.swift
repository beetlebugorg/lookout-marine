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
        /// Charts arriving and converting. Setup stays open through it,
        /// because the chart opens when the import finishes.
        case importing
        /// The safety contour, asked once there is a chart to draw it on.
        case depths
    }

    var step: Step = .welcome
    /// True once a bake has been seen running. Without it an import that has
    /// yet to start reads the same as one that has finished, because both
    /// report no work.
    var sawBake = false
    /// What the mariner asked NOAA for, kept from the moment they asked. The
    /// service's own counters are for the transfer, and the panel outlives it.
    var noaaOrder: NoaaOrder?
    /// True once a NOAA order has ended with no charts to prepare. The
    /// transfer is over, no cell arrived, and no bake ran or is about to run.
    /// This happens when every cell fails, when Stop comes before the first
    /// cell, or when the core rejects the order. The step then offers Back.
    private(set) var importEnded = false

    /// A NOAA download as it was ordered.
    struct NoaaOrder: Equatable {
        let regions: String
        let charts: UInt32
        let bytes: UInt64
    }
    var source: Source = .noaa
    /// True while the flow is over the chart.
    var showing = false

    // MARK: Whether it runs

    /// True once the mariner has put setup away for this run. Set Up Later is
    /// "not now", not an answer, so it holds only until the app is next
    /// started with nothing to draw.
    private var putAway = false

    /// True once this run has seen a library with something to draw.
    ///
    /// A mariner who finished setup and then removed every chart is offered
    /// the page that builds one again. One whose library never held charts
    /// keeps the answer they gave, so Set Up Later stands, and so does a
    /// cancelled file picker.
    private var sawCharts = false

    /// LOOKOUT_FIRST_RUN=1 runs setup whatever the store says, and =0 keeps it
    /// down. A screenshot run and a UI test both need to choose, because the
    /// store keeps the answer between launches on one device.
    ///
    /// A step name in place of 1 opens setup on that step: welcome, source,
    /// coverage, online. A screenshot run has no pointer to click Continue
    /// with.
    private static var setting: String? {
        ProcessInfo.processInfo.environment["LOOKOUT_FIRST_RUN"]
    }

    private static var override: Bool? {
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

    /// The flow runs over an app that has settled on having no chart to draw,
    /// on every platform and on every launch.
    ///
    /// Not once per device. A mariner with an empty library has the same
    /// questions to answer whether this is their first launch or their
    /// fiftieth, and the way back to the library they lost is the same page
    /// that built it.
    ///
    /// A linked chart is a chart. Somebody sailing on a published style has no
    /// empty library to fill, so setup stays down over one.
    func shouldRun(charts: ChartsModel, links: ChartLinksModel) -> Bool {
        if let override = Self.override { return override }
        guard links.active == nil else { return false }
        guard !putAway || sawCharts else { return false }
        return charts.nothingToDraw && charts.chartWork == nil
    }

    /// Note what the library holds, wherever setup is considered.
    ///
    /// The test is what a set holds rather than `nothingToDraw`. That reads
    /// false for the first moment of every launch while the scan runs, and
    /// reading it as a library puts setup away on a device that has none.
    func noteLibrary(_ charts: ChartsModel) {
        if charts.sets.contains(where: { $0.on && $0.hasSomethingToDraw }) {
            sawCharts = true
        }
    }

    // MARK: NOAA's terms

    /// Raised when the mariner continues from the source step with NOAA
    /// picked. The regions come after they accept.
    var showingEncTerms = false

    /// Accepted. On to picking water.
    func agreeToEncTerms() {
        showingEncTerms = false
        step = .coverage
    }

    /// Dismissed without accepting. The source step stands, so another source
    /// is still open to them.
    func declineEncTerms() {
        showingEncTerms = false
    }

    // MARK: Moving through it

    func begin() {
        step = Self.openingStep
        showing = true
        resetImport()
    }

    /// Read the download and the bake, while the importing step is up.
    ///
    /// The download watcher starts a bake only when at least one cell
    /// arrived. A download that ends with none never starts the bake that
    /// finishes the step, so the step reads that state here.
    func noteImport(_ noaa: NoaaState, bakeRunning: Bool) {
        importEnded = step == .importing
            && noaaOrder != nil
            && !sawBake
            && !bakeRunning
            && noaa.ended
            && noaa.done == 0
    }

    /// Clear the last order, so a second order starts from a clean state.
    private func resetImport() {
        sawBake = false
        noaaOrder = nil
        importEnded = false
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
                // NOAA's terms apply to NOAA's charts, so they are put where
                // those charts are chosen. A mariner who picks an online chart
                // or their own files never downloads an ENC and is not asked
                // to accept one.
                showingEncTerms = true
                return nil
            case .online:
                step = .onlineChart
                return nil
            case .files:
                finish()
                return .files
            }
        case .coverage:
            step = .importing
            return .noaa
        case .onlineChart:
            step = .depths
            return .online
        case .importing:
            step = .depths
            return nil
        case .depths:
            finish()
            return nil
        }
    }

    /// Whether Back applies. The first step offers Set Up Later instead. The
    /// import and the depth steps have no step to return to, because the
    /// charts are already arriving.
    var canGoBack: Bool {
        switch step {
        case .welcome, .depths: return false
        case .source, .coverage, .onlineChart: return true
        // Back applies only after the order ends with no charts to prepare.
        // While charts arrive, the step waits for them.
        case .importing: return importEnded
        }
    }

    func back() {
        switch step {
        case .welcome: break
        case .source: step = .welcome
        case .coverage, .onlineChart: step = .source
        case .importing:
            guard importEnded else { break }
            resetImport()
            step = .coverage
        // The charts are in. Back offers a second import of them.
        case .depths: break
        }
    }

    /// Set Up Later, and the end of a run that finished. Both put setup away
    /// for this launch. A run that finished leaves a chart behind it, and a
    /// chart is what keeps setup down after that. Remove every chart and
    /// setup comes back, because the way to the library that went is the page
    /// that built it.
    func finish() {
        putAway = true
        showing = false
        step = .welcome
    }

    // MARK: What each step says

    /// Whether the online step can continue. Continuing with no chart picked
    /// finishes setup over the basemap and puts it away for the run.
    func canUseOnlineChart(_ links: ChartLinksModel) -> Bool {
        links.active != nil
    }

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
