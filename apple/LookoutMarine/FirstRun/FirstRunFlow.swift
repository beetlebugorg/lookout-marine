//  FirstRunFlow.swift: setup, over the running app.
//
//  A sheet on the Mac and the whole screen on a phone, because a phone has no
//  window to float a sheet over. The two share every step and every word. The
//  frame around them differs, and so does the place of the primary action: a
//  footer button on the right for a pointer, a 50pt button above the home
//  indicator for a thumb.
//
//  The app keeps running behind it. This flow leaves the chart open and the
//  plugins running, so Set Up Later returns the mariner to a working app.

import SwiftUI

/// The step on screen, in the frame this platform gives it.
struct FirstRunFlow: View {
    var model: AppModel
    @Bindable var flow: FirstRunModel

    /// The depth step's settings. Its own, because setup runs before the
    /// settings window has ever been opened, and it binds to the controller
    /// the same way that window's does.
    @StateObject private var mariner = MarinerSettings()



    /// The height the step's own content wants. A ScrollView accepts whatever
    /// height it is offered, so without measuring, the sheet grows to fill the
    /// window and leaves the cards floating above an empty half.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        frame
            // The engine's own values, and every change written back to it.
            .onAppear { mariner.bind(to: model.controller) }
    }

    @ViewBuilder private var frame: some View {
        #if os(macOS)
        GeometryReader { geo in
            ZStack {
                // The running app dims and stays visible, so the sheet reads
                // as something raised over a running chart.
                Chrome.scrim
                    .ignoresSafeArea()
                sheet(maxContent: geo.size.height - Chrome.margin * 2 - footerHeight)
                    .frame(width: step.sheetWidth)
                    .background(Chrome.surface)
                    // Clips, so the welcome hero bleeding to the top edge
                    // takes the card's corners instead of squaring them off.
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Chrome.edge, lineWidth: 1))
                    .shadow(color: .black.opacity(0.32), radius: 32, y: 24)
                    .padding(Chrome.margin)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        #else
        // No window to float over, so the step IS the screen.
        VStack(spacing: 0) {
            navigationBar
            sheet(maxContent: nil)
        }
        .background(Chrome.surface.ignoresSafeArea())
        #endif
    }

    /// Roughly what the footer and its rule occupy. Only the sheet's scrolling
    /// half is capped, so this keeps the whole card inside the window.
    private var footerHeight: CGFloat { step == .welcome ? 110 : 60 }

    private var step: FirstRunModel.Step { flow.step }

    // MARK: The step, and the action under it

    /// The step, and the action under it.
    ///
    /// `maxContent` caps the scrolling half so the card hugs a short step and
    /// scrolls a long one. nil offers the step whatever is left, which is what
    /// a full screen phone step wants.
    @ViewBuilder private func sheet(maxContent: CGFloat?) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                stepContent
                    .measureSize { contentHeight = $0.height }
            }
            // The welcome page's hero bleeds to the top edge, so the step
            // owns its own insets rather than taking them from here.
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: maxContent.map { min(contentHeight, max($0, 120)) })
            footer
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: WelcomeStep(flow: flow)
        case .source: SourceStep(flow: flow)
        case .coverage: CoverageStep(model: model, noaa: model.noaa)
        case .onlineChart: OnlineChartStep(model: model, flow: flow)
        case .importing: ImportingStep(model: model, flow: flow)
        case .depths: DepthStep(m: mariner)
        }
    }

    #if os(iOS)
    /// Back to the previous step, the step's name, and the way out. Cancel
    /// shows on the source step. Past that fork the mariner is choosing a
    /// chart, and Back returns them here.
    private var navigationBar: some View {
        ZStack {
            Text(step.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Chrome.ink)
            HStack {
                if flow.canGoBack {
                    Button { flow.back() } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityIdentifier("first-run-back")
                }
                Spacer()
                if step == .source {
                    Button("Cancel") { flow.finish() }
                        .accessibilityIdentifier("first-run-cancel")
                }
            }
            .font(.system(size: 16))
            .tint(Chrome.accent)
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) { Divider() }
    }
    #endif

    /// The primary action, and the way back or out beside it.
    @ViewBuilder private var footer: some View {
        #if os(macOS)
        // The welcome page centers its action under the prose. It has no
        // previous step, and a lone Continue in the right corner of a 640pt
        // sheet reads as a half filled form.
        if step == .welcome {
            VStack(spacing: 14) {
                primaryButton.frame(width: 300)
                Button("Set Up Later") { flow.finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.accent)
                    .accessibilityIdentifier("first-run-later")
            }
            .padding(.bottom, 30)
        } else {
            HStack(spacing: 12) {
                if let note = footnote {
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Chrome.muted)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                // Stop applies while the transfer or the bake runs. After
                // that it stood beside Continue with no job to stop.
                if step == .importing && !importFinished {
                    Button("Stop") { stopImport() }
                        .accessibilityIdentifier("first-run-stop")
                } else if flow.canGoBack {
                    Button("Back") { flow.back() }
                        .accessibilityIdentifier("first-run-back")
                }
                primaryButton
            }
            .controlSize(.regular)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider() }
        }
        #else
        VStack(spacing: 0) {
            if let note = footnote {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Chrome.muted)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)
            }
            primaryButton
            if step == .welcome {
                Button("Set Up Later") { flow.finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Chrome.accent)
                    .frame(height: 44)
                    .accessibilityIdentifier("first-run-later")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Chrome.surface)
        .overlay(alignment: .top) { if step != .welcome { Divider() } }
        #endif
    }

    private var primaryButton: some View {
        Button {
            act()
        } label: {
            #if os(macOS)
            Text(flow.primaryTitle(nil))
            #else
            Text(flow.primaryTitle(nil))
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(.white)
                .background(Chrome.accent,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            #endif
        }
        #if os(macOS)
        .buttonStyle(.borderedProminent)
        #else
        .buttonStyle(.plain)
        #endif
        .keyboardShortcut(.defaultAction)
        .disabled(!primaryEnabled)
        .accessibilityIdentifier("first-run-continue")
    }

    /// Whether the primary action has anything to do. Download with no region
    /// picked, and with no catalog to price it from, does nothing.
    private var primaryEnabled: Bool {
        switch step {
        case .welcome, .source, .onlineChart: return true
        case .coverage:
            return model.noaa.state.haveCatalog && !model.noaa.picked.isEmpty
        // ChartBake opens the library once the import finishes, so there is
        // nothing to continue to until it has.
        case .importing: return importFinished
        case .depths: return true
        }
    }

    /// True once the charts have arrived, converted, and opened.
    private var importFinished: Bool {
        flow.sawBake
            && model.noaa.state.phase != .downloading
            && model.charts.chartWork == nil
            && model.charts.hasChart
    }

    /// The line beside the primary action: the credit the active chart asks
    /// for.
    private var footnote: String? {
        switch step {
        case .welcome, .source: return nil
        case .coverage:
            let n = model.noaa
            guard n.state.haveCatalog else { return nil }
            // Held counts as picked, so a region wholly installed prices as
            // that rather than reading as an empty pick.
            guard n.cells > 0 || n.held > 0 else { return "Pick at least one region." }
            return n.costLine
        case .importing:
            return nil
        case .depths:
            return "Change any of this later in Mariner settings, in Depths."
        case .onlineChart:
            // The publisher's credit, and the thing a mariner about to pick a
            // link most wants to know: their own charts are still there.
            let kept = "installed charts stay installed"
            guard let credit = model.chartLinks.attribution, !credit.isEmpty else { return kept }
            return "\(credit) · \(kept)"
        }
    }

    /// Stop the download and the bake. Whatever landed stays: a cancelled
    /// bake still leaves a library, and the bake runs coarse band first.
    private func stopImport() {
        model.noaa.cancel()
        model.charts.cancelBake()
    }

    /// The primary action. The flow chooses the next step, and the shell does
    /// the part the flow cannot.
    private func act() {
        guard let source = flow.advance() else { return }
        switch source {
        case .files:
            model.requestOpenPicker()
        case .online:
            break   // the chart the mariner picked is already selected
        case .noaa:
            let n = model.noaa
            flow.noaaOrder = .init(
                regions: n.regions.filter { n.picked.contains($0.id) }
                    .map(\.name).joined(separator: ", "),
                charts: n.allInstalled ? n.held : n.cells,
                bytes: n.allInstalled ? n.heldBytes : n.bytes)
            model.startNoaaDownload(again: n.allInstalled)
        }
    }
}

private extension FirstRunModel.Step {
    /// The design's three sheet widths. A step is as wide as its content, and
    /// a row of cards needs more room than a paragraph.
    var sheetWidth: CGFloat {
        switch self {
        case .welcome: return 640
        case .source: return 760
        case .coverage: return 1040
        case .importing: return 940
        case .depths: return 920
        case .onlineChart: return 980
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .source: return "Add charts"
        case .coverage: return "Coverage"
        case .importing: return "Preparing"
        case .depths: return "Depths"
        case .onlineChart: return "Online chart"
        }
    }
}
