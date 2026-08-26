//  LicensesTests.swift — the About section and the licenses screen.
//
//  The screen is reached from Mariner Settings > Advanced > About, which is
//  the only route iOS has: the Mac's About panel and its licenses window are
//  AppKit and compile out here.
//
//  The two idioms differ in where a push lands. A phone puts the Advanced pane
//  on the settings NavigationStack and the licenses list on top of it. An iPad
//  stands the pane in the split view's detail column, which has a stack of its
//  own, and the sections list must stay beside it the whole way down. Every
//  test here runs on both; the ones that can only be true of one are guarded.
//
//  The list needs no chart: the manifest is static in the core.

import XCTest
import UIKit

final class LicensesTests: XCTestCase {

    // MARK: - What the manifest says this build carries
    //
    // vendor/licenses/licenses.json, for the entries whose `shells` name iOS,
    // in manifest order. Held here rather than read from the bundle so the
    // test asserts against a second copy: a row that silently loses its pin or
    // its licence has to disagree with something.

    struct Component {
        let name: String
        let summary: String
        /// The short form the list column shows.
        let column: String
        /// The full label the detail's License fact shows.
        let licenseLabel: String
        /// Version, or the seven-character commit, as the row's pin.
        let pin: String
        let pinnedIn: String
        let url: String
        /// A phrase from the licence text, proving the body is the real one.
        let textPhrase: String
    }

    static let components: [Component] = [
        .init(name: "tile57", summary: "The S-57, S-101 and raster chart engine.",
              column: "MIT", licenseLabel: "MIT", pin: "edcac13", pinnedIn: "build.zig.zon",
              url: "https://github.com/beetlebugorg/tile57",
              textPhrase: "Permission is hereby granted, free of charge"),
        .init(name: "charttable", summary: "Renders the chart.",
              column: "MIT", licenseLabel: "MIT", pin: "0d137fa", pinnedIn: "build.zig.zon",
              url: "https://github.com/beetlebugorg/charttable",
              textPhrase: "Permission is hereby granted, free of charge"),
        .init(name: "IHO S-101 Portrayal Catalogue",
              summary: "The portrayal rules: which symbol, which color, which text, at which scale.",
              column: "Not resolved", licenseLabel: "Not resolved", pin: "62f7773",
              pinnedIn: "tile57's build.zig.zon",
              url: "https://github.com/iho-ohi/S-101_Portrayal-Catalogue",
              textPhrase: ""),   // it has none; the pane says so instead
        .init(name: "WebAssembly Micro Runtime", summary: "The runtime the plugins execute in.",
              column: "Apache-2.0", licenseLabel: "Apache 2.0 with the LLVM exception",
              pin: "WAMR-2.4.5", pinnedIn: "scripts/build-wamr.sh",
              url: "https://github.com/bytecodealliance/wasm-micro-runtime",
              textPhrase: "Apache License"),
        .init(name: "stb_image", summary: "Reads the PNG and JPEG files a chart carries.",
              column: "MIT OR Unlicense", licenseLabel: "MIT or the Unlicense, at your option",
              pin: "2.30", pinnedIn: "vendor/stb/stb_image.h",
              url: "https://github.com/nothings/stb",
              textPhrase: "ALTERNATIVE A"),
        .init(name: "GSHHG coastline", summary: "The world coastline baked into the basemap.",
              column: "LGPL", licenseLabel: "GNU Lesser General Public License",
              pin: "", pinnedIn: "vendor/gshhg/coastline.geojson.gz",
              url: "https://www.soest.hawaii.edu/pwessel/gshhg/",
              textPhrase: "GNU LESSER GENERAL PUBLIC LICENSE"),
        .init(name: "libwebp", summary: "Decodes the WebP tiles a chart link serves.",
              column: "BSD-3-Clause", licenseLabel: "BSD 3-Clause", pin: "1.4.0",
              pinnedIn: "charttable's build.zig.zon",
              url: "https://github.com/webmproject/libwebp",
              textPhrase: "Redistribution and use in source and binary forms"),
        .init(name: "libpng", summary: "Reads interlaced and 16-bit PNGs.",
              column: "libpng-2.0", licenseLabel: "PNG Reference Library License version 2",
              pin: "1.6.44", pinnedIn: "charttable's build.zig.zon",
              url: "https://github.com/pnggroup/libpng",
              textPhrase: "COPYRIGHT NOTICE, DISCLAIMER, and LICENSE"),
        .init(name: "zlib", summary: "Deflate compression.",
              column: "Zlib", licenseLabel: "zlib License", pin: "1.3.1",
              pinnedIn: "charttable's build.zig.zon",
              url: "https://github.com/madler/zlib",
              textPhrase: "Jean-loup Gailly and Mark Adler"),
    ]

    /// The one entry whose terms the build could not determine.
    static var unresolved: Component { components[2] }

    static let appName = "Lookout Marine"
    static let appCopyright = "© 2026 Jeremy Collins"
    static let appURL = "https://github.com/beetlebugorg/lookout-marine"

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() { continueAfterFailure = false }

    // MARK: - The About section

    /// Every row of the section, and the count it promises.
    func testAboutSectionCarriesVersionEngineAndTheLicensesRow() {
        let app = openAdvanced()

        XCTAssertTrue(app.staticTexts["About"].exists, "no About header")
        XCTAssertTrue(app.staticTexts["Version"].exists, "no Version row")

        // "<short> (<build>)", the two halves of the bundle's version.
        let version = valueBeside("Version", in: app)
        XCTAssertNotNil(version.range(of: #"^\d+(\.\d+)+ \(\d+\)$"#, options: .regularExpression),
                        "the Version row reads \(version), not '<short> (<build>)'")

        // The engine's name and its pin, which is what a bug report needs.
        XCTAssertTrue(app.staticTexts["Chart engine"].exists, "no Chart engine row")
        let engine = valueBeside("Chart engine", in: app)
        XCTAssertTrue(engine.hasPrefix("tile57 · "), "the Chart engine row reads \(engine)")
        XCTAssertNotNil(engine.range(of: #"· [0-9a-f]{7}$"#, options: .regularExpression),
                        "the Chart engine row carries no commit pin: \(engine)")

        let row = licensesRow(app)
        XCTAssertTrue(row.exists, "no Licenses row")
        XCTAssertTrue(row.label.contains("\(Self.components.count) components"),
                      "the Licenses row does not name the count: \(row.label)")
        assertNoHorizontalOverflow(app, "the About section")
        shot(app, "about-section")
    }

    /// The row is a push, not a window: the phone's affordance is a chevron
    /// and no ellipsis, which is what distinguishes it from the Mac's.
    func testTheLicensesRowIsAPushNotADialog() {
        let app = openAdvanced()
        let row = licensesRow(app)
        XCTAssertFalse(row.label.contains("…"),
                       "the row promises a window with an ellipsis: \(row.label)")
        XCTAssertTrue(row.isHittable, "the Licenses row is not tappable")
    }

    // MARK: - The list

    /// This app heads the list, its components follow, and every row carries
    /// the name, licence and pin the manifest gives it.
    func testTheListCarriesEveryComponentWithItsLicenceAndPin() {
        let app = openLicenses()

        XCTAssertTrue(app.staticTexts["This app"].exists, "no 'This app' header")
        XCTAssertTrue(app.staticTexts["Components"].exists, "no 'Components' header")

        // The app's own entry is not a component and stays out of the count.
        let appRow = row(named: Self.appName, in: app)
        XCTAssertTrue(appRow.exists, "the app's own entry is missing")
        XCTAssertTrue(appRow.label.contains(Self.appCopyright),
                      "the app row drops its copyright: \(appRow.label)")

        for c in Self.components {
            let r = scrollTo(in: app) { self.row(named: c.name, in: app) }
            XCTAssertTrue(r.exists, "the list is missing \(c.name)")
            XCTAssertTrue(r.label.contains(c.summary),
                          "\(c.name) drops its summary: \(r.label)")
            // The SHORT column, and the whole of it: a truncated label would
            // arrive with an ellipsis instead.
            XCTAssertTrue(r.label.contains(c.column),
                          "\(c.name) shows no '\(c.column)' licence column: \(r.label)")
            if !c.pin.isEmpty {
                XCTAssertTrue(r.label.contains(c.pin),
                              "\(c.name) drops its pin \(c.pin): \(r.label)")
            }
            XCTAssertFalse(r.label.contains("…"), "\(c.name)'s row is truncated: \(r.label)")
        }
        assertNoHorizontalOverflow(app, "the licences list")
        shot(app, "licenses-list-bottom")
    }

    /// Nine entries, so the headings and the field that only earn their place
    /// above twelve stay away.
    func testNineComponentsGetNoSearchFieldAndNoGroupHeadings() {
        let app = openLicenses()
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "a search field appeared for \(Self.components.count) components")
        for group in ["Chart and rendering", "Plugins", "Images and data"] {
            XCTAssertFalse(app.staticTexts[group].exists,
                           "group heading '\(group)' appeared below the twelve-row threshold")
        }
    }

    /// No row is drawn selected. iOS reaches a licence by pushing, so a
    /// highlighted row would be saying a tap had already happened.
    func testNoRowIsDrawnSelected() {
        let app = openLicenses()
        for name in [Self.appName] + Self.components.map(\.name) {
            let r = scrollTo(in: app) { self.row(named: name, in: app) }
            XCTAssertTrue(r.exists, "the list is missing \(name)")
            XCTAssertFalse(r.isSelected, "\(name)'s row is drawn selected")
        }
    }

    /// The list is a list: it scrolls, and the last row can be reached.
    func testTheListScrollsToItsLastRow() {
        let app = openLicenses()
        let last = Self.components.last!
        let r = scrollTo(in: app) { self.row(named: last.name, in: app) }
        XCTAssertTrue(r.isHittable, "\(last.name) cannot be scrolled to")
    }

    // MARK: - The detail panes

    /// Every component pushes a pane carrying its facts, its upstream and its
    /// terms — and Back comes home to the list.
    func testEveryComponentPushesItsOwnTermsAndComesBack() {
        let app = openLicenses()

        for c in Self.components where c.licenseLabel != "Not resolved" {
            scrollTo(in: app) { self.row(named: c.name, in: app) }.tap()

            XCTAssertTrue(app.staticTexts["Upstream"].waitForExistence(timeout: 10),
                          "\(c.name) never pushed its pane")
            // The heading, the facts block, and the body's own heading.
            XCTAssertTrue(text(containing: c.summary, in: app).exists,
                          "\(c.name)'s pane drops its summary")
            XCTAssertTrue(text(containing: c.licenseLabel, in: app).exists,
                          "\(c.name)'s pane drops the License fact '\(c.licenseLabel)'")
            XCTAssertTrue(text(containing: c.pinnedIn, in: app).exists,
                          "\(c.name)'s pane drops 'Pinned in \(c.pinnedIn)'")
            XCTAssertTrue(text(containing: c.url, in: app).exists,
                          "\(c.name)'s pane drops its upstream address")
            XCTAssertTrue(app.buttons["Copy address"].exists,
                          "\(c.name)'s upstream has no copy button")
            XCTAssertTrue(scrollTo(in: app) { self.text(containing: c.textPhrase, in: app) }.exists,
                          "\(c.name)'s licence text is missing or is not the real one")
            assertNoHorizontalOverflow(app, "\(c.name)'s pane")

            goBack(app)
            XCTAssertTrue(row(named: c.name, in: app).waitForExistence(timeout: 10),
                          "Back from \(c.name) did not return to the list")
        }
    }

    /// The pane a mariner sees for a component whose terms the build could not
    /// determine. An empty pane would read as "no obligation".
    func testAnUnresolvedComponentExplainsItselfRatherThanShowingNothing() {
        let app = openLicenses()
        let c = Self.unresolved

        let listRow = scrollTo(in: app) { self.row(named: c.name, in: app) }
        XCTAssertTrue(listRow.label.contains("Not resolved"),
                      "the list row does not flag it unresolved: \(listRow.label)")
        listRow.tap()

        // SwiftUI folds a Label's icon and its two lines into one element, so
        // this reads the phrase out of whatever it ended up attached to.
        XCTAssertTrue(text(containing: "License not resolved", in: app)
                        .waitForExistence(timeout: 10),
                      "the pane does not say the licence is unresolved")
        XCTAssertTrue(text(containing: "No license stated", in: app).exists,
                      "the pane drops the note explaining why")
        XCTAssertTrue(text(containing: "No license text.", in: app).exists,
                      "the pane does not say there is no licence text")
        assertNoHorizontalOverflow(app, "the unresolved pane")
        shot(app, "unresolved-detail")
    }

    /// This app's own entry, which carries the terms the binary ships under.
    func testTheAppsOwnEntryCarriesItsTerms() {
        let app = openLicenses()
        row(named: Self.appName, in: app).tap()

        XCTAssertTrue(app.staticTexts["Upstream"].waitForExistence(timeout: 10),
                      "the app's own pane never pushed")
        XCTAssertTrue(text(containing: Self.appCopyright, in: app).exists,
                      "the app's pane drops its copyright")
        XCTAssertTrue(text(containing: Self.appURL, in: app).exists,
                      "the app's pane drops its upstream")
        XCTAssertTrue(scrollTo(in: app) { self.text(containing: "MIT License", in: app) }.exists,
                      "the app's pane drops its licence text")
        assertNoHorizontalOverflow(app, "the app's pane")
        shot(app, "app-detail")
    }

    /// A long licence runs at the width of the view and scrolls in the page,
    /// rather than inside a box of its own. WAMR's Apache 2.0 is the longest
    /// text the build carries, so its last section is the one worth reaching.
    func testALongLicenceScrollsToItsEnd() {
        let app = openLicenses()
        let c = Self.components.first { $0.name == "WebAssembly Micro Runtime" }!
        scrollTo(in: app) { self.row(named: c.name, in: app) }.tap()
        XCTAssertTrue(app.staticTexts["Upstream"].waitForExistence(timeout: 10), "no pane")

        let end = scrollTo(in: app, swipes: 40) {
            self.text(containing: "END OF TERMS AND CONDITIONS", in: app)
        }
        XCTAssertTrue(end.exists, "the Apache licence cannot be scrolled to its end")
        shot(app, "long-licence-end")
    }

    /// The copy button puts the address on the clipboard. Opening it needs a
    /// connection; copying it does not, which is the point of the button.
    func testTheCopyButtonCopiesTheUpstreamAddress() {
        let app = openLicenses()
        let c = Self.components.first { $0.name == "zlib" }!
        UIPasteboard.general.string = "not the address"
        XCTAssertFalse(UIPasteboard.general.hasURLs, "the clipboard did not start clean")

        scrollTo(in: app) { self.row(named: c.name, in: app) }.tap()
        XCTAssertTrue(app.staticTexts["Upstream"].waitForExistence(timeout: 10), "no pane")
        app.buttons["Copy address"].tap()

        // Reading another app's clipboard would need the paste permission, and
        // a UI test cannot grant it. hasURLs needs none, so the assertion is
        // that an address arrived where a plain sentence had been.
        let copied = expectation(description: "an address reaches the clipboard")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            if UIPasteboard.general.hasURLs { t.invalidate(); copied.fulfill() }
        }
        wait(for: [copied], timeout: 10)
        poll.invalidate()
        XCTAssertTrue(UIPasteboard.general.hasURLs,
                      "the copy button put no address on the clipboard")
    }

    // MARK: - Getting back out

    /// Back from the list returns to Advanced, not to the sections list or the
    /// chart: a pushed pane must unwind one step at a time.
    func testBackFromTheListReturnsToAdvanced() {
        let app = openLicenses()
        goBack(app)
        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 10),
                      "Back from the list did not return to the Advanced pane")
        XCTAssertTrue(licensesRow(app).exists, "the About section did not come back")
    }

    /// Done shuts the whole form from inside the licences screen. A mariner
    /// three pushes deep must not have to walk back out.
    func testDoneDismissesTheFormFromInsideTheLicences() throws {
        let app = openLicenses()
        let done = app.buttons["Done"]
        try XCTSkipUnless(done.exists, "this layout carries no Done on the licences screen")
        done.tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["This app"]),
                      "Done did not shut the form")
    }

    // MARK: - The shape each idiom takes

    /// The sheet on an iPad is wide enough for two columns, so the sections
    /// list stands beside the pane. It must still be there once the licences
    /// have pushed: the list IS the navigation, and a sheet with it hidden has
    /// no way back to another section.
    func testTheIPadKeepsItsSectionsListBesideTheLicences() throws {
        try XCTSkipUnless(isPad, "the split layout is the iPad's")
        let app = openLicenses()

        XCTAssertTrue(app.navigationBars["Mariner Settings"].exists,
                      "the sections list vanished when the licences pushed")
        XCTAssertTrue(app.navigationBars["Licenses"].exists, "the licences list is not up")
        shot(app, "split-licences")

        // Two columns, not one. The bars are no use for this: a split view's
        // detail bar reports a frame spanning the whole sheet even while its
        // content sits in the detail column, so the columns are measured by
        // what is drawn in them — the selected section against the list's
        // first heading.
        let section = app.staticTexts["Advanced"]
        let heading = app.staticTexts["This app"]
        XCTAssertTrue(section.exists, "the selected section is no longer drawn")
        XCTAssertTrue(heading.exists, "the licences list is not drawn")
        XCTAssertLessThanOrEqual(section.frame.maxX, heading.frame.minX,
                                 "the licences are drawn over the sections list "
                                 + "(Advanced \(section.frame), This app \(heading.frame))")
        // And the sections list is still usable, not just present.
        XCTAssertTrue(section.isHittable, "the sections list cannot be reached")
    }

    /// A phone has no room for two columns, so the licences own the sheet and
    /// the sections list is left behind on the stack.
    func testThePhonePushesTheLicencesOverTheWholeSheet() throws {
        try XCTSkipUnless(!isPad, "the stack layout is the phone's")
        let app = openLicenses()

        XCTAssertFalse(app.navigationBars["Mariner Settings"].exists,
                       "the sections list is still on screen beside the licences")
        XCTAssertTrue(app.navigationBars["Licenses"].exists, "the licences list is not up")
        // Back goes one step, to the pane it was opened from.
        XCTAssertEqual(app.buttons["BackButton"].label, "Advanced",
                       "Back does not lead to the Advanced pane")
        shot(app, "phone-licences")
    }

    // MARK: - Driving the app

    /// The app on the Advanced settings pane, scrolled to the About section.
    private func openAdvanced() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_SHOW"] = "settings:advanced"
        app.launch()
        XCTAssertTrue(app.staticTexts["Safety & Quality"].waitForExistence(timeout: 60),
                      "the Advanced pane never opened")
        scrollTo(in: app) { self.licensesRow(app) }
        return app
    }

    /// The app on the licences list.
    private func openLicenses() -> XCUIApplication {
        let app = openAdvanced()
        licensesRow(app).tap()
        XCTAssertTrue(app.staticTexts["This app"].waitForExistence(timeout: 15),
                      "the licences list never opened")
        return app
    }

    /// The About section's Licenses row.
    private func licensesRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Licenses'")).firstMatch
    }

    /// One list row, found by the name it leads with. SwiftUI folds a row's
    /// name, summary, licence and pin into the one label a NavigationLink
    /// carries, so this is also how the row's whole content is read back.
    private func row(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// Anything carrying `s`. The panes put whole paragraphs in one Text, so a
    /// literal lookup by label would never match; an address is a Link and a
    /// Label folds its icon and lines into one element, so neither is found by
    /// looking at static text alone.
    private func text(containing s: String, in app: XCUIApplication) -> XCUIElement {
        let p = NSPredicate(format: "label CONTAINS %@", s)
        let t = app.staticTexts.matching(p).firstMatch
        if t.exists { return t }
        let l = app.links.matching(p).firstMatch
        if l.exists { return l }
        return app.buttons.matching(p).firstMatch
    }

    /// The value shown opposite a LabeledContent's label. SwiftUI publishes
    /// the pair as one element labelled "<label>, <value>".
    private func valueBeside(_ label: String, in app: XCUIApplication) -> String {
        let pair = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", label + ", ")).firstMatch
        guard pair.exists else { return "" }
        return String(pair.label.dropFirst(label.count + 2))
    }

    /// SwiftUI lists and scroll views are lazy: an element below the fold does
    /// not exist until it has been scrolled to, so the query has to be run
    /// again after every swipe rather than resolved once up front.
    ///
    /// Stops as soon as a swipe leaves the content where it was. Without that
    /// a miss costs the whole swipe budget against a view already sitting at
    /// its end, which was most of this suite's running time.
    @discardableResult
    private func scrollTo(in app: XCUIApplication, swipes: Int = 15,
                          _ resolve: () -> XCUIElement) -> XCUIElement {
        var element = resolve()
        if element.exists && element.isHittable { return element }
        let view = scroller(app)
        for _ in 0..<swipes {
            let before = scrollMark(app)
            view.swipeUp()
            element = resolve()
            if element.exists && element.isHittable { return element }
            if scrollMark(app) == before { break }   // it did not move: this is the end
        }
        return element
    }

    /// The view a swipe has to land on. An iPad's settings sheet has two
    /// columns, and a swipe at the middle of the app lands on the sections
    /// list, which scrolls nothing: the pane being read is the wider one.
    private func scroller(_ app: XCUIApplication) -> XCUIElement {
        var best: XCUIElement?
        var bestArea: CGFloat = 0
        for query in [app.collectionViews, app.scrollViews, app.tables] {
            for e in query.allElementsBoundByIndex {
                let f = e.frame
                guard f.width > 0, f.height > 0 else { continue }
                if f.width * f.height > bestArea { bestArea = f.width * f.height; best = e }
            }
        }
        return best ?? app
    }

    /// Where the content sits now. Equal across a swipe means the scroll view
    /// is against its stop. The rows of a list are cells and the body of a
    /// pane is text, so both are sampled.
    private func scrollMark(_ app: XCUIApplication) -> String {
        let cells = app.cells
        let texts = app.staticTexts
        let (nc, nt) = (cells.count, texts.count)
        let cy = nc > 0 ? Int(cells.element(boundBy: 0).frame.minY) : 0
        let ty = nt > 0 ? Int(texts.element(boundBy: nt - 1).frame.maxY) : 0
        return "\(nc)/\(nt):\(cy)/\(ty)"
    }

    /// Back, however the idiom labels the chevron. An iPad carries two
    /// navigation bars, so the button is taken by its identifier rather than
    /// by being the first one found.
    private func goBack(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.exists && back.isHittable { back.tap(); return }
        app.swipeRight()   // the interactive pop gesture
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    // MARK: - Visual quality

    /// Nothing may run off the side. A row whose licence column is pushed out
    /// of the window by a long name is the failure this catches, and it is
    /// also the one a screenshot alone would not.
    private func assertNoHorizontalOverflow(_ app: XCUIApplication, _ what: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        for e in app.staticTexts.allElementsBoundByIndex where e.isHittable {
            let f = e.frame
            guard f.width > 0 else { continue }
            XCTAssertGreaterThanOrEqual(f.minX, window.minX - 0.5,
                                        "\(what): '\(e.label.prefix(40))' runs off the left",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(f.maxX, window.maxX + 0.5,
                                     "\(what): '\(e.label.prefix(40))' runs off the right",
                                     file: file, line: line)
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(isPad ? "ipad" : "iphone")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}
