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

    /// The core handle a response goes to: a chart handle, or the NOAA
    /// service's own.
    private enum Target {
        case chart(OpaquePointer)
        case noaa(OpaquePointer)

        /// One piece of a response. `done` ends the body.
        func respond(_ id: UInt64, _ bytes: UnsafeRawPointer?, _ count: Int,
                     _ status: Int32, done: Bool) {
            let d: Int32 = done ? 1 : 0
            switch self {
            case .chart(let h): lookout_http_respond_chunk(h, id, bytes, count, status, d)
            case .noaa(let n): lookout_noaa_svc_http_respond_chunk(n, id, bytes, count, status, d)
            }
        }
    }

    private let lock = NSLock()
    /// nil once the handle is closing: a fetch still in flight must not
    /// respond into a handle that is going away.
    private var target: Target?
    /// Wakes the frame loop. An answer is adopted at the top of a frame, and
    /// the display link pauses when nothing is moving, so a resolve landing
    /// with no gesture behind it needs someone to ask for the next frame.
    /// Under a lock of its own: the NOAA service calls it from inside a
    /// respond made with `lock` held.
    private var wake: (() -> Void)?
    private let wakeLock = NSLock()
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

    /// URLSession retains its delegate until the session is invalidated.
    /// Without this each fetcher leaked its session and its proxy.
    deinit {
        session.invalidateAndCancel()
    }

    /// Attach to a chart handle and start answering. Call once per handle.
    /// `wake` is called on the main thread after every answer.
    func attach(to h: OpaquePointer, wake: @escaping () -> Void) {
        attach(.chart(h), wake)
    }

    /// Attach to the NOAA service instead. `wake` is also called each time
    /// the core queues a response for it.
    func attach(noaa n: OpaquePointer, wake: @escaping () -> Void) {
        attach(.noaa(n), wake)
    }

    private func attach(_ t: Target, _ wake: @escaping () -> Void) {
        lock.lock()
        target = t
        lock.unlock()
        wakeLock.lock()
        self.wake = wake
        wakeLock.unlock()
        let me = Unmanaged.passUnretained(self).toOpaque()
        switch t {
        case .chart(let h): lookout_set_http_provider(h, chartLinkGet, chartLinkCancel, me)
        case .noaa(let n):
            lookout_noaa_svc_set_http_provider(n, chartLinkGet, chartLinkCancel, noaaWake, me)
        }
    }

    /// Call `wake` on the main thread. Any thread.
    fileprivate func ping() {
        wakeLock.lock()
        let w = wake
        wakeLock.unlock()
        if let w { DispatchQueue.main.async(execute: w) }
    }

    /// Stop answering, before the handle closes. Idempotent.
    ///
    /// The in-flight ids are answered "failed" FIRST: lookout holds an
    /// outstanding-request slot for every id it has neither been answered nor
    /// cancelled on, and clearing the provider is what releases the rest.
    func detach() {
        lock.lock()
        let t = target
        let tasks = inFlight
        inFlight = [:]
        byTask = [:]
        statusByTask = [:]
        if let t {
            for (id, _) in tasks { t.respond(id, nil, 0, 0, done: true) }
        }
        target = nil
        lock.unlock()
        wakeLock.lock()
        wake = nil
        wakeLock.unlock()
        switch t {
        case .chart(let h): lookout_set_http_provider(h, nil, nil, nil)
        case .noaa(let n): lookout_noaa_svc_set_http_provider(n, nil, nil, nil, nil)
        case nil: break
        }
        for (_, task) in tasks { task.cancel() }
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
        if target != nil {
            inFlight[id] = task
            byTask[task.taskIdentifier] = id
        }
        let live = target != nil
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
        let t = target
        let id = byTask[task]
        let status = statusByTask[task] ?? 0
        if let t, let id {
            // Data may hold several buffers. Each region is contiguous, and
            // lookout reads pieces in order, so they go one after another
            // rather than through a flattening copy.
            for region in data.regions where !region.isEmpty {
                region.withUnsafeBytes { raw in
                    t.respond(id, raw.baseAddress, raw.count, status, done: false)
                }
            }
        }
        lock.unlock()
    }

    /// A task that ended. `err` nil finishes the body; anything else fails it.
    fileprivate func finish(_ task: Int, err: Error?) {
        lock.lock()
        let t = target
        let id = byTask.removeValue(forKey: task)
        let status = statusByTask.removeValue(forKey: task) ?? 0
        if let id { inFlight.removeValue(forKey: id) }
        if let t, let id {
            t.respond(id, nil, 0, err == nil ? status : 0, done: true)
        }
        lock.unlock()
        if t != nil, id != nil { ping() }
    }

    private func answer(_ id: UInt64, _ bytes: Data?, _ status: Int32) {
        // Under the lock, so a handle closing mid-answer cannot be answered
        // into. lookout_http_respond takes no lock of its own, so nothing can
        // deadlock behind this.
        lock.lock()
        let t = target
        if let t {
            if let bytes, !bytes.isEmpty {
                bytes.withUnsafeBytes { raw in
                    t.respond(id, raw.baseAddress, raw.count, status, done: true)
                }
            } else {
                t.respond(id, nil, 0, status, done: true)
            }
        }
        lock.unlock()
        if t != nil { ping() }
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

/// The NOAA service queued a response, from any thread.
private let noaaWake: lookout_noaa_wake = { user in
    guard let user else { return }
    Unmanaged<ChartLinkFetch>.fromOpaque(user).takeUnretainedValue().ping()
}
