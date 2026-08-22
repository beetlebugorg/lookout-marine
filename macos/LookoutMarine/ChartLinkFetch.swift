//  ChartLinkFetch.swift
//
//  The shell's whole part in charts by link: fetch the bytes at a url.
//
//  Probing the link, inlining TileJSON sources, generating a wrapper style for
//  bare tiles, fetching sprite packs, building the credit line, templating tile
//  urls and keeping the list are all lookout's. See lookout_set_http_provider
//  in lookout.h.
//
//  THREADING. `get` is called by lookout with its lock held, so it does the
//  least possible: start the task, return. `lookout_http_respond` is the one
//  call that is safe from there and from the URLSession completion, because it
//  takes no lock of lookout's — it enqueues, and the next frame adopts.

import Foundation

final class ChartLinkFetch: @unchecked Sendable {
    /// Say who is asking, on every chart-link request. Public tile hosts serve
    /// "access blocked" placeholder tiles to anonymous or platform-default
    /// agents — openstreetmap.org's tile usage policy
    /// (osm.wiki/Blocked_tiles) wants a unique, identifiable User-Agent with a
    /// way to reach the developer, and the Referer names the app's home for
    /// hosts that key on it.
    static let userAgent =
        "LookoutMarine/1.0 (macOS; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)"
    static let referer = "https://beetlebug.org/"

    private let lock = NSLock()
    /// nil once the chart is closing: a fetch still in flight must not answer
    /// into a handle that is going away.
    private var handle: OpaquePointer?
    /// Tasks by request id, so a cancel can reach the transfer.
    private var inFlight: [UInt64: URLSessionTask] = [:]
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        // Tiles are the one thing this app fetches in bulk. A shared memory
        // cache spares the pan back over water already crossed, and the disk
        // cache survives a relaunch on the same chart. URL-keyed, so it covers
        // styles and sprite sheets on the same terms.
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        // A stalled fetch must not hold a slot forever: the chart is drawn from
        // whatever HAS landed, so a slow tile costs only itself.
        cfg.timeoutIntervalForRequest = 20
        // URLSession pools per host. Connection concurrency is its business:
        // nothing here reasons about which source a url belongs to, so no
        // source can hold a lane another source's tiles are waiting on.
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.httpAdditionalHeaders = [
            "User-Agent": ChartLinkFetch.userAgent,
            "Referer": ChartLinkFetch.referer,
        ]
        session = URLSession(configuration: cfg)
    }

    /// Attach to a chart handle and start answering. Call once per handle.
    func attach(to h: OpaquePointer) {
        lock.lock()
        handle = h
        lock.unlock()
        lookout_set_http_provider(h, chartLinkGet, chartLinkCancel,
                                  Unmanaged.passUnretained(self).toOpaque())
    }

    /// Stop answering, before the handle closes. Idempotent.
    ///
    /// The in-flight ids are answered "failed" FIRST: lookout holds an
    /// outstanding-request slot for every id it has neither been answered nor
    /// cancelled on, and clearing the provider is what releases the rest.
    func detach() {
        lock.lock()
        let h = handle
        let tasks = inFlight
        inFlight = [:]
        if let h {
            for (id, _) in tasks { lookout_http_respond(h, id, nil, 0, 0) }
        }
        handle = nil
        lock.unlock()
        if let h { lookout_set_http_provider(h, nil, nil, nil) }
        for (_, t) in tasks { t.cancel() }
    }

    /// One url lookout wants. Called on its render thread with its lock held —
    /// do not block.
    fileprivate func fetch(id: UInt64, url raw: String, allowFile: Bool) {
        guard let url = URL(string: raw) else {
            answer(id, nil, 0)
            return
        }
        // The file:// boundary. lookout says when a url may be read off disk
        // (see lookout_http_get): the link the mariner typed, and what a
        // document ALREADY read from disk names inside that link's directory.
        // A style that arrived over the network never gets it, so it cannot
        // make this read arbitrary local files as its "TileJSON".
        if url.isFileURL || raw.hasPrefix("/") {
            guard allowFile else {
                answer(id, nil, 0)
                return
            }
            readFile(id: id, url: url.isFileURL ? url : URL(fileURLWithPath: raw))
            return
        }
        let task = session.dataTask(with: URLRequest(url: url)) { [weak self] data, resp, err in
            guard let self else { return }
            self.done(id)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if err != nil {
                self.answer(id, nil, 0)
            } else {
                self.answer(id, data, Int32(code))
            }
        }
        lock.lock()
        if handle != nil { inFlight[id] = task }
        let live = handle != nil
        lock.unlock()
        if live { task.resume() } else { answer(id, nil, 0) }
    }

    /// A style file the mariner has aboard. Read off the main thread: a file
    /// read on a sandboxed volume can take long enough to be felt as a freeze.
    private func readFile(id: UInt64, url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // The sandbox hands access over with the pick and takes it back
            // when the scope closes. Harmless where no scope is held.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                self.answer(id, nil, 0)
                return
            }
            self.answer(id, data, 200)
        }
    }

    fileprivate func abort(id: UInt64) {
        lock.lock()
        let task = inFlight.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    private func done(_ id: UInt64) {
        lock.lock()
        inFlight.removeValue(forKey: id)
        lock.unlock()
    }

    private func answer(_ id: UInt64, _ bytes: Data?, _ status: Int32) {
        // Under the lock, so a handle closing mid-answer cannot be answered
        // into. lookout_http_respond takes no lock of its own, so nothing can
        // deadlock behind this.
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return }
        if let bytes, !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in
                lookout_http_respond(h, id, raw.baseAddress, raw.count, status)
            }
        } else {
            lookout_http_respond(h, id, nil, 0, status)
        }
    }
}

/// The C entry points. The url is lookout's memory and is only valid for the
/// call, so it is copied out at once.
private let chartLinkGet: lookout_http_get = { user, id, url, allowFile in
    guard let user, let url else { return }
    let f = Unmanaged<ChartLinkFetch>.fromOpaque(user).takeUnretainedValue()
    f.fetch(id: id, url: String(cString: url), allowFile: allowFile != 0)
}

private let chartLinkCancel: lookout_http_cancel = { user, id in
    guard let user else { return }
    Unmanaged<ChartLinkFetch>.fromOpaque(user).takeUnretainedValue().abort(id: id)
}
