//  AltChartStyle.swift
//
//  An online map AS the chart: the shell fetches a publisher's MapLibre style,
//  hands lookout the JSON, and then serves that style's tiles.
//
//  WHY THE FETCHING IS UP HERE. lookout does not do any networking (see lookout.h,
//  lookout_set_tile_provider). It reports the SOURCE NAME and z/x/y of a tile
//  it wants; this file resolves that against the style's own url template and
//  answers with URLSession — which already carries the app's proxy, ATS and
//  credential rules, and is what fetched the style in the first place.
//
//  WHY THE STYLE IS REWRITTEN ON THE WAY IN. A source may name its tiles
//  inline (`"tiles": [...]`) or point at a TileJSON document (`"url": ...`).
//  Only the first is something lookout can act on: it reads each source's zoom
//  band and tile size out of the style to know where to stop asking. So a
//  TileJSON source is resolved HERE, once, and its answer inlined before the
//  style goes down. Leaving it unresolved means a source with no declared
//  bounds, which asks for tiles at every zoom forever.

import Foundation

/// One sprite pack a style declares: the pack id as the icon-name prefix
/// ("" for the spec's "default"), and the base url `.json`/`.png` append to.
struct SpritePack {
    let prefix: String
    let url: String
}

/// A sprite pack fetched whole, ready for the engine.
struct FetchedSpritePack {
    let prefix: String
    let json: Data
    let png: Data
}

/// A chart style the host supplies, with its tile sources resolved.
struct AltChartStyle {
    /// The style JSON to hand to lookout: the publisher's, with every TileJSON
    /// source inlined.
    let json: String
    /// Where each source's tiles come from, by the name the style gave it.
    let sources: [String: AltChartTiles.Source]
    /// The style's sprite packs, still unfetched (fetchSpritePacks).
    var spritePacks: [SpritePack] = []
    /// Every distinct source attribution, tags stripped, joined for display.
    /// Public tile hosts make the visible credit a condition of service —
    /// OSM's tile usage policy among them.
    var attribution: String? = nil

    /// Say who is asking, on every chart-link request. Public tile hosts
    /// serve "access blocked" placeholder tiles to anonymous or
    /// platform-default agents — openstreetmap.org's tile usage policy
    /// (osm.wiki/Blocked_tiles) wants a unique, identifiable User-Agent with
    /// a way to reach the developer, and the Referer names the app's home
    /// for hosts that key on it.
    static let userAgent =
        "LookoutMarine/1.0 (macOS; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)"
    static let referer = "https://beetlebug.org/"

    /// A GET for a chart-link resource, identified as above.
    static func identifiedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        return req
    }

    /// Read a style and resolve every source in it. Network work, so async;
    /// the tile fetching that follows is not, because it is answered from
    /// whatever thread lookout asks on.
    static func resolve(json raw: String) async -> AltChartStyle? {
        guard let data = raw.data(using: .utf8),
              var top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var declared = top["sources"] as? [String: Any] else { return nil }

        var resolved: [String: AltChartTiles.Source] = [:]
        for (name, value) in declared {
            guard var src = value as? [String: Any] else { continue }
            // A TileJSON source names a document, not tiles. Read it and fold
            // what it says into the source itself.
            if src["tiles"] == nil, let link = src["url"] as? String,
               let doc = await fetchTileJSON(link) {
                for key in ["tiles", "minzoom", "maxzoom", "bounds", "scheme", "attribution"] {
                    if let v = doc[key] { src[key] = v }
                }
                // TileJSON says `tileSize` nowhere; raster tiles are 256 unless
                // the style already said otherwise, and getting this wrong
                // draws the imagery one zoom level off.
                if src["tileSize"] == nil, (src["type"] as? String) == "raster" {
                    src["tileSize"] = 256
                }
                src["url"] = nil
                declared[name] = src
            }
            guard let templates = src["tiles"] as? [String], !templates.isEmpty else { continue }
            resolved[name] = .init(
                templates: templates,
                flipY: (src["scheme"] as? String)?.lowercased() == "tms"
            )
        }
        top["sources"] = declared
        guard let out = try? JSONSerialization.data(withJSONObject: top),
              let text = String(data: out, encoding: .utf8) else { return nil }
        return .init(json: text, sources: resolved,
                     spritePacks: spritePacks(of: top),
                     attribution: attribution(of: declared))
    }

    /// The credit line the sources ask for: distinct attributions, HTML
    /// markup reduced to its text.
    private static func attribution(of declared: [String: Any]) -> String? {
        var seen: [String] = []
        for (_, v) in declared {
            guard let src = v as? [String: Any],
                  let raw = src["attribution"] as? String, !raw.isEmpty else { continue }
            let text = raw
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&copy;", with: "©")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && !seen.contains(text) { seen.append(text) }
        }
        // An attribution CONTAINED in another is dropped — sources repeat
        // each other's credits inside composite strings, and keeping both
        // made the line longer than the scale bar it sits under.
        let kept = seen.filter { s in !seen.contains { $0 != s && $0.contains(s) } }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    /// The style's `sprite` root: one base url, or the array form of
    /// {id, url} packs whose icons resolve as "id:name" ("default" gives
    /// bare names).
    private static func spritePacks(of top: [String: Any]) -> [SpritePack] {
        if let url = top["sprite"] as? String {
            return url.isEmpty ? [] : [SpritePack(prefix: "", url: url)]
        }
        guard let arr = top["sprite"] as? [[String: Any]] else { return [] }
        return arr.compactMap { o in
            guard let url = o["url"] as? String, !url.isEmpty else { return nil }
            let id = o["id"] as? String ?? ""
            return SpritePack(prefix: id == "default" ? "" : id, url: url)
        }
    }

    /// Fetch a style's sprite packs whole. @2x first — the sheets are drawn
    /// at their authored logical size whatever the ratio, and every display
    /// that matters is dense — with the 1x pack as the fallback for a
    /// publisher who ships only one. A pack that will not fetch is skipped,
    /// not fatal: the chart draws, short its icons.
    static func fetchSpritePacks(_ packs: [SpritePack]) async -> [FetchedSpritePack] {
        guard !packs.isEmpty else { return [] }
        var out: [FetchedSpritePack] = []
        for p in packs {
            var got: FetchedSpritePack?
            for s in ["@2x", ""] {
                guard let j = await fetchData(p.url + s + ".json"),
                      let b = await fetchData(p.url + s + ".png") else { continue }
                got = FetchedSpritePack(prefix: p.prefix, json: j, png: b)
                break
            }
            if let got {
                out.append(got)
            } else {
                lkLog("sprite pack \(p.url): fetch failed; its icons will be missing")
            }
        }
        return out
    }

    private static func fetchData(_ link: String) async -> Data? {
        guard let url = URL(string: link),
              let (data, resp) = try? await URLSession.shared.data(for: identifiedRequest(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func fetchTileJSON(_ link: String) async -> [String: Any]? {
        guard let url = URL(string: link),
              let (data, resp) = try? await URLSession.shared.data(for: identifiedRequest(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Answers lookout's asks for an alt style's tiles.
///
/// THREADING. `request` is called by lookout on its render thread with its own
/// lock held, so it does the least possible: look the source up, start the
/// fetch, return. `lookout_tile_respond` is the one call that is safe from
/// there and from the URLSession completion that follows, because it takes no
/// lock of lookout's.
final class AltChartTiles: @unchecked Sendable {
    struct Source {
        /// The style's url templates, with {z}/{x}/{y} still in them.
        var templates: [String]
        /// TMS counts y from the south; the style spec counts from the north.
        var flipY: Bool
    }

    /// Status codes lookout_tile_respond takes.
    private enum Answer: Int32 {
        case bytes = 0
        /// No tile there. Remembered, so a 404 is not re-asked every frame.
        case none = 1
        /// Tried and failed. Also remembered, for the same reason.
        case failed = 2
    }

    private let lock = NSLock()
    /// nil once the chart is closing: a fetch still in flight must not answer
    /// into a handle that is going away.
    private var handle: OpaquePointer?
    private var sources: [String: Source] = [:]
    private var inFlight: [URLSessionTask] = []
    private let session: URLSession
    /// Sources whose first tile has already been logged, and the first failure
    /// per source. Enough to see that a template resolved and that the server
    /// answered, without a line per tile at pan rate.
    private var loggedAsk: Set<String> = []
    private var loggedFail: Set<String> = []

    init() {
        let cfg = URLSessionConfiguration.default
        // Tiles are the one thing this app fetches in bulk. A shared memory
        // cache spares the pan back over water already crossed, and the disk
        // cache survives a relaunch on the same chart.
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        // A stalled tile must not hold a slot forever: the chart is drawn from
        // whatever HAS landed, so a slow tile costs only itself.
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 8
        // A unique, identifiable agent with a way to reach the developer:
        // public tile hosts (openstreetmap.org's tile usage policy,
        // osm.wiki/Blocked_tiles) serve "access blocked" placeholder tiles
        // to anonymous or platform-default agents.
        cfg.httpAdditionalHeaders = [
            "User-Agent": AltChartStyle.userAgent,
            "Referer": AltChartStyle.referer,
        ]
        session = URLSession(configuration: cfg)
    }

    /// Attach to a chart handle and start answering. Call once per handle.
    func attach(to h: OpaquePointer) {
        lock.lock()
        handle = h
        lock.unlock()
        lookout_set_tile_provider(h, altChartTileRequest, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Stop answering, before the handle closes. Idempotent.
    func detach() {
        lock.lock()
        let h = handle
        handle = nil
        let tasks = inFlight
        inFlight = []
        sources = [:]
        loggedAsk = []
        loggedFail = []
        lock.unlock()
        if let h { lookout_set_tile_provider(h, nil, nil) }
        for t in tasks { t.cancel() }
    }

    /// What the current style's sources are. Replaces the lot: a style change
    /// means the old names may not exist any more.
    func setSources(_ s: [String: Source]) {
        lock.lock()
        sources = s
        lock.unlock()
    }

    /// One tile lookout wants. Called on its render thread — do not block.
    fileprivate func request(source name: String, id: UInt64, z: Int32, x: Int32, y: Int32) {
        lock.lock()
        let src = sources[name]
        let live = handle != nil
        lock.unlock()

        guard live, let src, let url = Self.url(for: src, z: z, x: x, y: y) else {
            // Answered, not dropped: a tile nobody answers is a hole in the
            // chart that never fills.
            if live, noteFirst(.fail, name) {
                lkLog("alt tiles: \(name) — no source or no url template; failing its tiles")
            }
            answer(id, nil, .failed)
            return
        }
        if noteFirst(.ask, name) { lkLog("alt tiles: \(name) -> \(url.absoluteString)") }
        let task = session.dataTask(with: URLRequest(url: url)) { [weak self] data, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if err != nil || code != 200, self.noteFirst(.fail, name) {
                lkLog("alt tiles: \(name) z\(z)/\(x)/\(y) -> \(code) \(err?.localizedDescription ?? "")")
            }
            if err != nil {
                self.answer(id, nil, .failed)
            } else if code == 404 || code == 204 {
                // The publisher genuinely does not have a tile there — a hole in their
                // coverage, not a fault, and worth remembering as one.
                self.answer(id, nil, .none)
            } else if code == 200, let data, !data.isEmpty {
                self.answer(id, data, .bytes)
            } else if code == 200 {
                self.answer(id, nil, .none)   // 200 with an empty body
            } else {
                self.answer(id, nil, .failed)
            }
        }
        lock.lock()
        inFlight.append(task)
        // Completed tasks are only swept when the list grows: sweeping on
        // every tile would walk it at tile rate for nothing.
        if inFlight.count > 64 { inFlight.removeAll { $0.state == .completed } }
        lock.unlock()
        task.resume()
    }

    private func answer(_ id: UInt64, _ bytes: Data?, _ status: Answer) {
        // Under the lock, so a handle closing mid-answer cannot be answered
        // into. lookout_tile_respond does not take a lock of its own, so nothing can
        // deadlock behind this.
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else { return }
        if let bytes, status == .bytes {
            bytes.withUnsafeBytes { raw in
                lookout_tile_respond(h, id, raw.baseAddress, raw.count, status.rawValue)
            }
        } else {
            lookout_tile_respond(h, id, nil, 0, status.rawValue)
        }
    }

    private enum Note { case ask, fail }

    /// True the first time `name` is seen for `kind`. Diagnostics only — one
    /// line per source, not one per tile. Not `inout` on the sets: they are
    /// touched from the render thread and from URLSession completions, and
    /// handing out an exclusive reference to a property under a lock is the
    /// kind of thing that is fine until it isn't.
    private func noteFirst(_ kind: Note, _ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .ask: return loggedAsk.insert(name).inserted
        case .fail: return loggedFail.insert(name).inserted
        }
    }

    /// Fill a style's url template for one tile.
    static func url(for src: Source, z: Int32, x: Int32, y: Int32) -> URL? {
        guard !src.templates.isEmpty else { return nil }
        // Deterministic pick across a publisher's subdomains, so the same tile
        // keeps hitting the same host and stays cached there.
        let template = src.templates[Int(abs(x &+ y)) % src.templates.count]
        let ty = src.flipY ? (1 << z) - 1 - y : y
        let filled = template
            .replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(ty))
        return URL(string: filled)
    }
}

/// The C entry point. Copies the name out at once — it is lookout's memory and
/// is only valid for this call.
private let altChartTileRequest: lookout_tile_request = { user, source, reqID, z, x, y in
    guard let user, let source else { return }
    let tiles = Unmanaged<AltChartTiles>.fromOpaque(user).takeUnretainedValue()
    tiles.request(source: String(cString: source), id: reqID, z: z, x: x, y: y)
}
