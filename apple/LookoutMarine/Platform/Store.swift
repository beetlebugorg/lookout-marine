//  Store.swift — the one place the shell reads and writes its settings.
//
//  Everything the shell keeps across launches goes through here: the camera
//  pose, the mariner settings, the plugin values and rows, the chart sets, and
//  the raster charts. It is `lookout_store`, so all four shells keep the same
//  settings in the same file format under the same key names, and the core can
//  read what the shell wrote.
//
//  A key lives in a GROUP. The group names are the core's
//  (LOOKOUT_STORE_VIEW and the rest), so a shell cannot invent a name the
//  others do not know.
//
//  `shared` is the store under this app's support directory. A test puts a
//  store in a temp directory of its own there, runs, and puts it back. That
//  also ends the redirected-HOME problem this file used to document: a file
//  under a directory of the test's choosing has no login session behind it.

import Foundation

/// The settings file the shell reads and writes.
final class Store {
    /// The store in force. A test swaps it.
    nonisolated(unsafe) static var shared = Store.appSupport()

    /// The core's group names, as Swift.
    enum Group {
        static let view = String(cString: LOOKOUT_STORE_VIEW)
        static let recents = String(cString: LOOKOUT_STORE_RECENTS)
        static let raster = String(cString: LOOKOUT_STORE_RASTER)
        static let mariner = String(cString: LOOKOUT_STORE_MARINER)
        static let plugins = String(cString: LOOKOUT_STORE_PLUGINS)
        static let chartlinks = String(cString: LOOKOUT_STORE_CHARTLINKS)
        static let chartsets = String(cString: LOOKOUT_STORE_CHARTSETS)
    }

    /// The core's store. `lookout_set_store` takes it, so the engine keeps the
    /// pose and the mariner settings in the same file the shell writes.
    private(set) var handle: OpaquePointer?

    /// A store on `dir`. Nil inside when the core would not open one, which
    /// leaves every read on its fallback and every write a no-op: a settings
    /// file that cannot be opened must not stop the chart coming up.
    init(directory: String) {
        handle = directory.withCString { lookout_store_open($0) }
        if handle == nil { lkLog("store: could not open \(directory)") }
    }

    deinit {
        if let handle { lookout_store_close(handle) }
    }

    /// The app's own directory under Application Support, made if it is not
    /// there. The core makes the directory at its first write, so this only
    /// has to name it.
    static func appSupport() -> Store {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
        let dir = base?.appendingPathComponent("LookoutMarine", isDirectory: true)
        return Store(directory: dir?.path ?? NSTemporaryDirectory())
    }

    // MARK: Reading

    func has(_ group: String, _ key: String) -> Bool {
        guard let handle else { return false }
        return group.withCString { g in
            key.withCString { k in lookout_store_has(handle, g, k) != 0 }
        }
    }

    func string(_ group: String, _ key: String) -> String? {
        guard let handle else { return nil }
        return group.withCString { g in
            key.withCString { k in
                lookout_store_text(handle, g, k).map { String(cString: $0) }
            }
        }
    }

    func number(_ group: String, _ key: String, _ fallback: Double = 0) -> Double? {
        guard let handle, has(group, key) else { return nil }
        return group.withCString { g in
            key.withCString { k in lookout_store_number(handle, g, k, fallback) }
        }
    }

    func bool(_ group: String, _ key: String, _ fallback: Bool = false) -> Bool? {
        guard let handle, has(group, key) else { return nil }
        return group.withCString { g in
            key.withCString { k in
                lookout_store_flag(handle, g, k, fallback ? 1 : 0) != 0
            }
        }
    }

    func strings(_ group: String, _ key: String) -> [String] {
        guard let handle else { return [] }
        return group.withCString { g in
            key.withCString { k in
                var n = 0
                guard let items = lookout_store_list(handle, g, k, &n) else { return [] }
                return (0..<n).compactMap { items[$0].map { String(cString: $0) } }
            }
        }
    }

    /// The keys set under a group, in the order they were written. This is how
    /// the plugin ids a config was saved for are read back.
    func keys(_ group: String) -> [String] {
        guard let handle else { return [] }
        return group.withCString { g in
            var n = 0
            guard let items = lookout_store_keys(handle, g, &n) else { return [] }
            return (0..<n).compactMap { items[$0].map { String(cString: $0) } }
        }
    }

    // MARK: Writing

    func set(_ value: String, _ group: String, _ key: String) {
        guard let handle else { return }
        group.withCString { g in
            key.withCString { k in
                value.withCString { v in lookout_store_set_text(handle, g, k, v) }
            }
        }
    }

    func set(_ value: Double, _ group: String, _ key: String) {
        guard let handle else { return }
        group.withCString { g in
            key.withCString { k in lookout_store_set_number(handle, g, k, value) }
        }
    }

    func set(_ value: Int, _ group: String, _ key: String) {
        set(Double(value), group, key)
    }

    func set(_ value: Bool, _ group: String, _ key: String) {
        guard let handle else { return }
        group.withCString { g in
            key.withCString { k in lookout_store_set_flag(handle, g, k, value ? 1 : 0) }
        }
    }

    /// An empty list clears the key, which is what an empty list means.
    func set(_ value: [String], _ group: String, _ key: String) {
        guard let handle else { return }
        let cs = value.map { strdup($0) }
        defer { cs.forEach { free($0) } }
        var ptrs = cs.map { UnsafePointer($0) }
        group.withCString { g in
            key.withCString { k in
                ptrs.withUnsafeMutableBufferPointer { p in
                    lookout_store_set_list(handle, g, k, p.baseAddress, p.count)
                }
            }
        }
    }

    func remove(_ group: String, _ key: String) {
        guard let handle else { return }
        group.withCString { g in
            key.withCString { k in lookout_store_remove(handle, g, k) }
        }
    }

    /// Write anything waiting now. The core coalesces, so this is for the
    /// moments a shell knows it may be about to go away.
    func flush() {
        if let handle { lookout_store_flush(handle) }
    }
}
