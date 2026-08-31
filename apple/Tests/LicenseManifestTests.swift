//  LicenseManifestTests.swift — the components this build carries.
//
//  lookout_licenses_read is static in the core and needs no chart, so these run
//  against the live list rather than a fixture. The core filters it to this
//  shell, and asserts that filtering in src/licenses.zig.

import XCTest
@testable import LookoutMarine

final class LicenseManifestTests: XCTestCase {

    private var manifest: LicenseManifest! {
        LicenseManifest.current
    }

    func testTheBuildCarriesAList() throws {
        let m = try XCTUnwrap(manifest, "lookout_licenses_read gave nothing")
        XCTAssertFalse(m.components.isEmpty)
        XCTAssertFalse(m.app.name.isEmpty)
        XCTAssertFalse(m.app.license.isEmpty)
        XCTAssertFalse(m.app.text.isEmpty)
    }

    /// The core filters by shell id, so this shell has to name itself the way
    /// the manifest does. A wrong id here is an empty screen.
    func testThisShellNamesItselfTheWayTheManifestDoes() throws {
        #if os(macOS)
        XCTAssertEqual(LicenseManifest.shell, "macos")
        #else
        XCTAssertEqual(LicenseManifest.shell, "ios")
        #endif
        let m = try XCTUnwrap(manifest)
        XCTAssertFalse(m.components.isEmpty)
    }

    /// The count a screen starts grouping and searching above is the core's.
    func testTheGroupThresholdIsTheCores() {
        XCTAssertEqual(LicenseManifest.groupAbove, 12)
    }

    /// The chart engine is the one component About names, so the screen breaks
    /// if it is ever dropped from the list.
    func testTheChartEngineIsListed() throws {
        let m = try XCTUnwrap(manifest)
        let engine = try XCTUnwrap(m.components.first { $0.id == "tile57" })
        XCTAssertFalse(engine.name.isEmpty)
        XCTAssertFalse(engine.pinLabel.isEmpty)
    }

    /// Every component says what it is and what its terms are, or says plainly
    /// that the terms could not be resolved.
    func testEveryComponentIsAnswerable() throws {
        let m = try XCTUnwrap(manifest)
        for c in m.components {
            XCTAssertFalse(c.name.isEmpty, c.id)
            XCTAssertFalse(c.summary.isEmpty, c.id)
            XCTAssertFalse(c.pinnedIn.isEmpty, c.id)
            XCTAssertFalse(c.licenseColumnLabel.isEmpty, c.id)
            if c.license.isEmpty {
                XCTAssertEqual(c.licenseLabel, "Not resolved", c.id)
                XCTAssertFalse(c.licenseNote.isEmpty,
                               "\(c.id) has no licence and no note saying why")
            } else {
                XCTAssertFalse(c.text.isEmpty, "\(c.id) has a licence and no text")
            }
        }
    }

    /// Groups keep the manifest's order, and every component lands in one.
    func testGroupsKeepTheManifestOrder() throws {
        let m = try XCTUnwrap(manifest)
        let groups = m.groups
        XCTAssertEqual(groups.reduce(0) { $0 + $1.items.count }, m.components.count)
        XCTAssertEqual(Set(groups.map(\.name)).count, groups.count, "a group appears twice")
        XCTAssertEqual(groups.flatMap { $0.items.map(\.id) }, orderedIDs(m))
    }

    private func orderedIDs(_ m: LicenseManifest) -> [String] {
        var order: [String] = []
        var byGroup: [String: [String]] = [:]
        for c in m.components {
            if byGroup[c.group] == nil { order.append(c.group) }
            byGroup[c.group, default: []].append(c.id)
        }
        return order.flatMap { byGroup[$0] ?? [] }
    }

    /// The short form is for the list's tight column; the full label is the
    /// detail's. A component with no short form uses the full one.
    func testTheShortLicenceLabel() {
        let one = component(license: "Apache-2.0 WITH LLVM-exception", short: "Apache-2.0")
        XCTAssertEqual(one.licenseColumnLabel, "Apache-2.0")
        XCTAssertEqual(one.licenseLabel, "Apache-2.0 WITH LLVM-exception")

        let plain = component(license: "MIT", short: "")
        XCTAssertEqual(plain.licenseColumnLabel, "MIT")

        let none = component(license: "", short: "")
        XCTAssertEqual(none.licenseColumnLabel, "Not resolved")
        XCTAssertEqual(none.licenseLabel, "Not resolved")
    }

    /// A version when there is one, else the short commit.
    func testThePinLabel() {
        XCTAssertEqual(component(version: "1.2.0", commit: "abcdef1234").pinLabel, "1.2.0")
        XCTAssertEqual(component(version: "", commit: "abcdef1234").pinLabel, "abcdef1")
        XCTAssertEqual(component(version: "", commit: "").pinLabel, "")
    }

    /// One component as the core hands it over.
    private func component(license: String = "MIT", short: String = "",
                           version: String = "", commit: String = "") -> LicenseComponent {
        "x".withCString { id in
            license.withCString { lic in
                short.withCString { sh in
                    version.withCString { ver in
                        commit.withCString { com in
                            "".withCString { e in
                                LicenseComponent(lookout_license(
                                    id: id, name: id, group: id, summary: id,
                                    license: lic, license_short: sh, license_note: e,
                                    version: ver, commit: com, pinned_in: id,
                                    copyright: id, url: id, text: id, notice: e))
                            }
                        }
                    }
                }
            }
        }
    }
}
