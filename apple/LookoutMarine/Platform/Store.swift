//  Store.swift — the one place the shell reads and writes its settings.
//
//  Everything the shell keeps across launches goes through here: the camera
//  pose, the mariner settings, the plugin values and rows, the chart sets, and
//  the raster charts. They all used to name `UserDefaults.standard` themselves,
//  which meant nothing that persists could be tested without writing into the
//  test runner's own domain and cleaning up after it.
//
//  `shared` is `.standard` and never changes at run time. A test puts a suite
//  of its own in `Store.shared`, runs, and puts `.standard` back.
//
//  macOS preferences ignore a redirected HOME: CFPreferences resolves the
//  domain from the login session, so a screenshot or a test run cannot get a
//  clean slate by moving HOME. A suite of its own is the way.

import Foundation

/// The defaults domain the shell reads and writes.
final class Store {
    /// The domain in force. `.standard` in the app; a test swaps it.
    nonisolated(unsafe) static var shared = Store(UserDefaults.standard)

    private let defaults: UserDefaults

    init(_ defaults: UserDefaults) { self.defaults = defaults }

    /// A store on a suite of its own, for a test. Nil when the suite name is
    /// one UserDefaults refuses (its own domain, or an empty name).
    static func suite(_ name: String) -> Store? {
        UserDefaults(suiteName: name).map(Store.init)
    }

    /// Forget everything in this store's domain.
    func removeAll(suite name: String) {
        defaults.removePersistentDomain(forName: name)
    }

    func strings(_ key: String) -> [String]? { defaults.stringArray(forKey: key) }
    func string(_ key: String) -> String? { defaults.string(forKey: key) }
    func dictionary(_ key: String) -> [String: Any]? { defaults.dictionary(forKey: key) }
    func data(_ key: String) -> Data? { defaults.data(forKey: key) }
    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }

    func set(_ value: Any?, _ key: String) { defaults.set(value, forKey: key) }
    func remove(_ key: String) { defaults.removeObject(forKey: key) }
}
