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
//
//  These check that the manifest reaches the screen, not what is in it. Whether
//  every component has a name, a summary, a pin and either terms or a note
//  saying why not is LicenseManifestTests, which reads the same JSON the screen
//  does. Restating the manifest here meant a second copy to update on every
//  dependency bump, and thirty rows walked one at a time.

import XCTest
import UIKit

final class LicensesTests: UITestCase {

    static let appName = "Lookout Marine"
    static let appCopyright = "© 2026 Jeremy Collins"
    static let appURL = "https://github.com/beetlebugorg/lookout-marine"

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() { continueAfterFailure = false }

    // MARK: - The About section

    /// Every row of the section, and the count it promises.
    func testAboutSectionCarriesVersionEngineAndTheLicensesRow() throws {
        let app = try openAdvanced()

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
        XCTAssertNotNil(row.label.range(of: #"[0-9]+ components"#, options: .regularExpression),
                        "the Licenses row does not name the count: \(row.label)")
        // A push, not a window: the phone's affordance is a chevron and no
        // ellipsis, which is what tells it from the Mac's.
        XCTAssertFalse(row.label.contains("…"), "the row reads as a dialog: \(row.label)")
        XCTAssertEqual(row.buttons.matching(
            NSPredicate(format: "label CONTAINS 'chevron'")).count, 0,
            "the row draws its own chevron over the platform's")
        assertNoHorizontalOverflow(app, "the About section")
        shot(app, "about-section")
    }

    // MARK: - The list

    /// This app heads the list, its components follow, and every row carries
    /// the name, licence and pin the manifest gives it.
    /// Every component in the manifest reaches the list.
    ///
    /// The count comes from the app's own Advanced row, which reads it off the
    /// manifest, so this compares the screen against the JSON without a second
    /// copy of the JSON.
    func testTheListShowsAComponentPerEntryInTheManifest() throws {
        let advanced = try openAdvanced()
        let declared = Int(licensesRow(advanced).label
            .replacingOccurrences(of: "[^0-9]", with: " ", options: .regularExpression)
            .split(separator: " ").last.map(String.init) ?? "") ?? 0
        XCTAssertGreaterThan(declared, 0, "the Advanced row names no component count")

        let app = try openLicenses()
        XCTAssertTrue(app.staticTexts["This app"].exists, "no 'This app' header")
        XCTAssertTrue(app.staticTexts["Components"].exists, "no 'Components' header")

        // The app's own entry is not a component and stays out of the count.
        let appRow = row(named: Self.appName, in: app)
        XCTAssertTrue(appRow.exists, "the app's own entry is missing")
        XCTAssertTrue(appRow.label.contains(Self.appCopyright),
                      "the app row drops its copyright: \(appRow.label)")

        // Scoped to the list. The chart page is behind the sheet and its own
        // buttons are in the tree.
        let list = scroller(app)
        var seen = Set<String>()
        var mark = ""
        for _ in 0..<12 {
            for row in list.buttons.allElementsBoundByIndex where row.exists {
                let label = row.label
                guard !label.isEmpty, !label.hasPrefix(Self.appName),
                      label != "Advanced", label != "Done", !label.hasPrefix("Back")
                else { continue }
                seen.insert(label)
                XCTAssertFalse(label.contains("…"), "a row is truncated: \(label)")
            }
            let now = scrollMark(app)
            if now == mark { break }
            mark = now
            scroller(app).swipeUp()
        }
        XCTAssertEqual(seen.count, declared,
                       "the list shows \(seen.count) components; the manifest declares \(declared)")
        // The loop above ended at the bottom, so the last row was reachable.
        XCTAssertTrue(list.buttons.allElementsBoundByIndex.last?.isHittable == true,
                      "the last row cannot be reached")
        // No row is drawn selected: iOS reaches a licence by pushing, so a
        // highlighted row would say a tap had already happened.
        for row in list.buttons.allElementsBoundByIndex where row.exists {
            XCTAssertFalse(row.isSelected, "a row is drawn selected: \(row.label)")
        }
        assertNoHorizontalOverflow(app, "the licences list")
        shot(app, "licenses-list-bottom")
    }

    func testNineComponentsGetNoSearchFieldAndNoGroupHeadings() throws {
        let app = try openLicenses()
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "a search field appeared below the twelve-row threshold")
        for group in ["Chart and rendering", "Plugins", "Images and data"] {
            XCTAssertFalse(app.staticTexts[group].exists,
                           "group heading '\(group)' appeared below the twelve-row threshold")
        }
    }

    // MARK: - The detail panes

    /// A component pushes a pane holding its facts and its terms, and Back
    /// returns to the list.
    ///
    /// One component, not all of them: the pane is one view and what fills it
    /// is the manifest. tile57 is the one About names, so it cannot be dropped
    /// without breaking that screen too.
    func testAComponentPushesItsOwnTermsAndComesBack() throws {
        let app = try openLicenses()
        let engine = scrollTo(in: app) { self.row(named: "tile57", in: app) }
        XCTAssertTrue(engine.exists, "the chart engine is not in the list")
        let summary = engine.label
        engine.tap()

        XCTAssertTrue(app.staticTexts["Upstream"].waitForExistence(timeout: 10),
                      "tile57 never pushed its pane")
        XCTAssertTrue(app.staticTexts["License"].exists, "the pane drops the License fact")
        XCTAssertTrue(app.staticTexts["Pinned in"].exists, "the pane drops 'Pinned in'")
        XCTAssertTrue(app.buttons["Copy address"].exists, "the upstream has no copy button")
        // The row's own summary is repeated as the pane's heading, so the pane
        // is showing the component the row named.
        XCTAssertTrue(text(containing: "chart engine", in: app).exists,
                      "the pane drops its summary; the row read \(summary)")
        XCTAssertTrue(scrollTo(in: app) {
            self.text(containing: "Permission is hereby granted", in: app)
        }.exists, "the pane shows no licence text")
        assertNoHorizontalOverflow(app, "the tile57 pane")

        goBack(app)
        XCTAssertTrue(row(named: "tile57", in: app).waitForExistence(timeout: 10),
                      "Back did not return to the list")
        // And Back again to the pane it was opened from. It lands on the About
        // section, which is where the row was tapped, not at the top.
        goBack(app)
        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 10),
                      "Back from the list did not return to the Advanced pane")
        XCTAssertTrue(licensesRow(app).exists, "the About section did not come back")
    }

    /// A component whose terms the build could not determine says so in both
    /// places, rather than showing an empty pane. The S-101 catalogue is the
    /// one the build carries.
    func testAnUnresolvedComponentExplainsItselfRatherThanShowingNothing() throws {
        let app = try openLicenses()
        let listRow = scrollTo(in: app) {
            self.row(named: "IHO S-101 Portrayal Catalogue", in: app)
        }
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
    func testTheAppsOwnEntryCarriesItsTerms() throws {
        let app = try openLicenses()
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

    /// The copy button puts the address on the clipboard. Opening it needs a
    /// connection; copying it does not, which is the point of the button.
    func testTheCopyButtonCopiesTheUpstreamAddress() throws {
        let app = try openLicenses()
        UIPasteboard.general.string = "not the address"
        XCTAssertFalse(UIPasteboard.general.hasURLs, "the clipboard did not start clean")

        scrollTo(in: app) { self.row(named: "zlib", in: app) }.tap()
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

    /// Done shuts the whole form from inside the licences screen. A mariner
    /// three pushes deep must not have to walk back out.
    /// Its own launch: it shuts the form, and LOOKOUT_SHOW only fires once.
    func testDoneDismissesTheFormFromInsideTheLicences() throws {
        _ = try freshApp(["LOOKOUT_NO_CHART": "1", "LOOKOUT_SHOW": "settings:advanced"])
        let app = try openLicenses()
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
        let app = try openLicenses()

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
        let app = try openLicenses()

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
    /// Back to the Advanced pane, from a component pane, from the list, or
    /// from the sections list. False when the form itself is gone: a test shut
    /// it, and LOOKOUT_SHOW only fires at launch.
    override func resetToStart(_ app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            if app.staticTexts["Safety & Quality"].exists { return true }
            let advanced = app.buttons["Advanced"]
            if advanced.exists, advanced.isHittable {
                advanced.tap()
                _ = app.staticTexts["Safety & Quality"].waitForExistence(timeout: 5)
                continue
            }
            let back = app.buttons["BackButton"]
            guard back.exists, back.isHittable else { break }
            back.tap()
            _ = app.staticTexts["Safety & Quality"].waitForExistence(timeout: 2)
        }
        return app.staticTexts["Safety & Quality"].exists
    }

    private func openAdvanced() throws -> XCUIApplication {
        let app = try self.app(["LOOKOUT_NO_CHART": "1",
                                "LOOKOUT_SHOW": "settings:advanced"])
        XCTAssertTrue(app.staticTexts["Safety & Quality"].waitForExistence(timeout: 60),
                      "the Advanced pane never opened")
        scrollTo(in: app) { self.licensesRow(app) }
        return app
    }

    /// The app on the licences list.
    private func openLicenses() throws -> XCUIApplication {
        let app = try openAdvanced()
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
