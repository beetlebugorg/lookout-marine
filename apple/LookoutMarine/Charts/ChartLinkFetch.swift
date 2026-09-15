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
    /// Wakes the frame loop. An answer is adopted at the top of a frame, and
    /// the display link pauses when nothing is moving, so a resolve landing
    /// with no gesture behind it needs someone to ask for the next frame.
    private var wake: (() -> Void)?
    /// Tasks by request id, so a cancel can reach the transfer.
    private var inFlight: [UInt64: URLSessionTask] = [:]
    /// Request id and final status by task, for the delegate that hands the
    /// body over a piece at a time.
    private var byTask: [Int: UInt64] = [:]
    private var statusByTask: [Int: Int32] = [:]
    private var session: URLSession!
    private let proxy = FetchProxy()

    init() {
        let cfg = URLSessionConfiguration.default
        // Tiles are the one thing this app fetches in bulk. A shared memory
        // cache spares the pan back over water already crossed, and the disk
        // cache survives a relaunch on the same chart. URL-keyed, so it covers
        // styles and sprite sheets on the same terms.
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        // A stalled fetch must not hold a slot forever: the chart is drawn from
        // whatever HAS landed, so a slow tile costs only itself, and a style
        // that asks a base map past the zoom it actually serves fails fast
        // instead of holding a worker. It also bounds how long detach waits.
        cfg.timeoutIntervalForRequest = 8
        // URLSession pools per host. Connection concurrency is its business:
        // nothing here reasons about which source a url belongs to, so no
        // source can hold a lane another source's tiles are waiting on.
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.httpAdditionalHeaders = [
            "User-Agent": ChartLinkFetch.userAgent,
            "Referer": ChartLinkFetch.referer,
        ]
        // A delegate rather than a completion handler: it hands over the body
        // as it arrives. A NOAA district downloads as one zip of a couple of
        // hundred megabytes, and a data task holds that whole thing in memory
        // before anyone sees a byte of it.
        session = URLSession(configuration: cfg, delegate: proxy, delegateQueue: nil)
        proxy.owner = self
    }

    /// Attach to a chart handle and start answering. Call once per handle.
    /// `wake` is called on the main thread after every answer.
    func attach(to h: OpaquePointer, wake: @escaping () -> Void) {
        lock.lock()
        handle = h
        self.wake = wake
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
        byTask = [:]
        statusByTask = [:]
        if let h {
            for (id, _) in tasks { lookout_http_respond(h, id, nil, 0, 0) }
        }
        handle = nil
        wake = nil
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
        let task = session.dataTask(with: URLRequest(url: url))
        lock.lock()
        if handle != nil {
            inFlight[id] = task
            byTask[task.taskIdentifier] = id
        }
        let live = handle != nil
        lock.unlock()
        if live { task.resume() } else { answer(id, nil, 0) }
    }

    /// A style file on the device. Read off the main thread: a file
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
        if let t = inFlight.removeValue(forKey: id) {
            byTask.removeValue(forKey: t.taskIdentifier)
            statusByTask.removeValue(forKey: t.taskIdentifier)
        }
        lock.unlock()
    }

    // ---- the delegate's side ------------------------------------------------

    /// The status a task's pieces carry. Kept until the task finishes.
    fileprivate func noteStatus(_ task: Int, _ status: Int32) {
        lock.lock()
        statusByTask[task] = status
        lock.unlock()
    }

    /// One piece of a body. Passed straight through, with no buffer here.
    fileprivate func piece(_ task: Int, _ data: Data) {
        lock.lock()
        let h = handle
        let id = byTask[task]
        let status = statusByTask[task] ?? 0
        if let h, let id {
            // Data may hold several buffers. Each region is contiguous, and
            // lookout reads pieces in order, so they go one after another
            // rather than through a flattening copy.
            for region in data.regions where !region.isEmpty {
                region.withUnsafeBytes { raw in
                    lookout_http_respond_chunk(h, id, raw.baseAddress, raw.count, status, 0)
                }
            }
        }
        lock.unlock()
    }

    /// A task that ended. `err` nil finishes the body; anything else fails it.
    fileprivate func finish(_ task: Int, err: Error?) {
        lock.lock()
        let h = handle
        let wake = self.wake
        let id = byTask.removeValue(forKey: task)
        let status = statusByTask.removeValue(forKey: task) ?? 0
        if let id { inFlight.removeValue(forKey: id) }
        if let h, let id {
            lookout_http_respond_chunk(h, id, nil, 0, err == nil ? status : 0, 1)
        }
        lock.unlock()
        if h != nil, id != nil, let wake { DispatchQueue.main.async(execute: wake) }
    }

    private func answer(_ id: UInt64, _ bytes: Data?, _ status: Int32) {
        // Under the lock, so a handle closing mid-answer cannot be answered
        // into. lookout_http_respond takes no lock of its own, so nothing can
        // deadlock behind this.
        lock.lock()
        let h = handle
        let wake = self.wake
        if let h {
            if let bytes, !bytes.isEmpty {
                bytes.withUnsafeBytes { raw in
                    lookout_http_respond(h, id, raw.baseAddress, raw.count, status)
                }
            } else {
                lookout_http_respond(h, id, nil, 0, status)
            }
        }
        lock.unlock()
        if h != nil, let wake { DispatchQueue.main.async(execute: wake) }
    }
}

/// URLSession's side of a streamed body. Separate from the fetcher because
/// URLSession keeps a strong reference to its delegate, and the fetcher owns
/// the session.
private final class FetchProxy: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: ChartLinkFetch?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        owner?.noteStatus(dataTask.taskIdentifier, Int32(code))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.piece(dataTask.taskIdentifier, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.finish(task.taskIdentifier, err: error)
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
