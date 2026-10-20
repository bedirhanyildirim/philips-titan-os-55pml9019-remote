import Foundation

/// YouTube "Lounge" (YouTube Remote / MDX) client for the TV's YouTube app.
///
/// No TV code needed:
///   1. DIAL  GET http://<tv>:56789/apps/YouTube → `<state>running</state>` + `<screenId>`
///   2. POST https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch
///      `screen_ids=<screenId>` → screens[0].loungeToken / .expiration (ms, ~14 days)
///   3. POST /api/lounge/bc/bind?RID=1&VER=8&CVER=1&auth_failure_option=send_error
///      form: app=web, mdx-version=3, name, id, device=REMOTE_CONTROL, loungeIdToken, …
///      → events `c` (SID) and `S` (gsessionid)
///   4. long-poll GET /bc/bind?…&SID&gsessionid&AID=<last event id>&RID=rpc&CI=0&TYPE=xmlhttp
///      streams `<len>\n[[id,["event",{…}]],…]\n` frames; noop ~every 25 s, server
///      closes it after ~4.5 min → poll again with the latest AID.
///   5. commands: POST /bc/bind?…&RID=<n> form count=1&ofs=<n>&req0__sc=<cmd>&req0_<k>=<v>
///      (play, pause, seekTo newTime, next, previous, setPlaylist videoId, getNowPlaying)
///
/// Errors: 400 "Unknown SID" / 410 → rebind; 401 → lounge token rejected, fetch a new one.
///
/// The `nowPlaying` / `onStateChange` events carry no periodic progress, so `NowPlaying.position`
/// interpolates from `currentTime` + elapsed while playing (resynced via `getNowPlaying`).
///
/// NB: never send `TYPE=terminate` — it clears the TV's lounge queue, which stops the
/// video and drops the TV back to the YouTube home screen. `disconnect()` just goes quiet
/// and lets the server expire the session.
final class YouTubeLounge: @unchecked Sendable {

    struct NowPlaying: Equatable, Sendable {
        enum State: Int, Sendable {
            case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5
            case ad = 1081
        }
        var videoId: String
        var title: String?
        var channel: String?
        var state: State
        var currentTime: Double     // seconds, as of `updatedAt`
        var duration: Double
        var hasPrevious = false
        var hasNext = false
        var updatedAt = Date()

        var isPlaying: Bool { state == .playing }

        /// Playback position now, extrapolated while playing.
        var position: Double {
            guard state == .playing else { return currentTime }
            let p = currentTime + Date().timeIntervalSince(updatedAt)
            return duration > 0 ? min(p, duration) : p
        }

        var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg") }
        var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(videoId)") }
    }

    private struct Cache: Codable {
        var screenId: String
        var loungeToken: String
        var expiresAt: Double      // unix seconds
        var clientId: String       // our stable remote id, so the TV sees one device
    }

    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".philips-tv-remote/youtube_lounge.json")
    }

    private static let api = "https://www.youtube.com/api/lounge"

    let tvHost: String
    let deviceName: String
    private let session: URLSession
    private let lock = NSLock()

    // all below guarded by `lock`
    private var cache: Cache?
    private var sid: String?
    private var gsid: String?
    private var aid = -1
    private var rid = 1
    private var ofs = 0
    private var current: NowPlaying?
    private var prevNext = (prev: false, next: false)
    private var titles: [String: (title: String?, channel: String?)] = [:]
    private var lastResync = Date.distantPast
    private var loop: Task<Void, Never>?
    private var binding: Task<Void, Error>?
    private var _onUpdate: (@Sendable (NowPlaying?) -> Void)?

    /// Called (on a background thread) whenever now-playing changes; nil = nothing
    /// playing / YouTube not running / disconnected. Hop to the main actor yourself.
    var onUpdate: (@Sendable (NowPlaying?) -> Void)? {
        get { locked { _onUpdate } }
        set { locked { _onUpdate = newValue } }
    }

    init(tvHost: String, deviceName: String = "Mac") {
        self.tvHost = tvHost
        self.deviceName = deviceName
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60     // idle timeout; server sends noop every ~25 s
        cfg.timeoutIntervalForResource = 600   // long-poll is closed by the server after ~4.5 min
        session = URLSession(configuration: cfg)
        if let data = try? Data(contentsOf: Self.cacheURL) {
            cache = try? JSONDecoder().decode(Cache.self, from: data)
        }
    }

    deinit { loop?.cancel() }

    // MARK: - public

    func nowPlaying() -> NowPlaying? { locked { current } }

    var isConnected: Bool { locked { sid != nil && gsid != nil } }

    /// Bind now (throws `.notRunning` if YouTube isn't open) and start the background
    /// event loop.
    func connect() async throws {
        try await ensureSession()
        start()
    }

    /// Start background monitoring without throwing: waits for YouTube to be running,
    /// binds, long-polls, rebinds on expiry, publishes nil when YouTube closes.
    func start() {
        locked {
            guard loop == nil else { return }
            loop = Task.detached { [weak self] in await self?.run() }
        }
    }

    /// Stop polling and forget the session (deliberately no `terminate` — see type doc).
    func disconnect() {
        let t: Task<Void, Never>? = locked {
            let t = loop
            loop = nil
            dropSessionLocked()
            current = nil
            return t
        }
        t?.cancel()
        publish()
    }

    func play() async throws { try await command("play") }
    func pause() async throws { try await command("pause") }
    func next() async throws { try await command("next") }
    func previous() async throws { try await command("previous") }

    func togglePlayPause() async throws {
        if nowPlaying()?.state == .playing { try await pause() } else { try await play() }
    }

    func seek(to seconds: Double) async throws {
        try await command("seekTo", ["newTime": String(format: "%.1f", max(0, seconds))])
    }

    func seek(by delta: Double) async throws {
        guard let np = nowPlaying() else { return }
        try await seek(to: np.position + delta)
    }

    /// Plays a video on the TV (on whichever YouTube profile is active). If YouTube
    /// isn't running it is launched via DIAL with the video.
    func playVideo(id: String) async throws {
        if await dialState().running {
            try await command("setPlaylist", ["videoId": id])
        } else {
            try await launchViaDIAL(body: "v=\(id)")
            start()
        }
    }

    /// Ask the TV to re-send `nowPlaying` (read-only).
    func refresh() async throws { try await command("getNowPlaying") }

    // MARK: - DIAL

    func dialState() async -> (running: Bool, screenId: String?) {
        var req = URLRequest(url: URL(string: "http://\(tvHost):56789/apps/YouTube")!)
        req.timeoutInterval = 4
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8) else { return (false, nil) }
        return (Self.tag("state", in: xml) == "running", Self.tag("screenId", in: xml))
    }

    private func launchViaDIAL(body: String) async throws {
        var req = URLRequest(url: URL(string: "http://\(tvHost):56789/apps/YouTube")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201 else { throw YouTubeLoungeError.http(code) }
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let a = xml.range(of: "<\(name)>"),
              let b = xml.range(of: "</\(name)>", range: a.upperBound..<xml.endIndex) else { return nil }
        return String(xml[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - token

    private func loungeToken(screenId: String, forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let c = locked({ cache }), c.screenId == screenId,
           !c.loungeToken.isEmpty, c.expiresAt > Date().timeIntervalSince1970 + 3600 {
            return c.loungeToken
        }
        var req = URLRequest(url: URL(string: "\(Self.api)/pairing/get_lounge_token_batch")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.form([("screen_ids", screenId)]).utf8)
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screen = (obj["screens"] as? [[String: Any]])?.first,
              let token = screen["loungeToken"] as? String else {
            throw YouTubeLoungeError.http(code)
        }
        let expMs = Self.num(screen["expiration"])
            ?? (Date().timeIntervalSince1970 + 13 * 86400) * 1000
        let c: Cache = locked {
            let c = Cache(screenId: screenId, loungeToken: token, expiresAt: expMs / 1000,
                          clientId: cache?.clientId ?? UUID().uuidString.lowercased())
            cache = c
            return c
        }
        saveCache(c)
        return token
    }

    private func saveCache(_ c: Cache) {
        let dir = Self.cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try? enc.encode(c).write(to: Self.cacheURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.cacheURL.path)
    }

    // MARK: - session

    /// Single-flight bind: concurrent callers share one in-progress bind.
    private func ensureSession() async throws {
        let t: Task<Void, Error>? = locked {
            if sid != nil && gsid != nil { return nil }
            if let b = binding { return b }
            let b = Task<Void, Error> {
                defer { self.locked { self.binding = nil } }
                try await self.bind()
            }
            binding = b
            return b
        }
        try await t?.value
    }

    private func bind() async throws {
        let dial = await dialState()
        guard dial.running, let screenId = dial.screenId else { throw YouTubeLoungeError.notRunning }

        for attempt in 0..<2 {
            let token = try await loungeToken(screenId: screenId, forceRefresh: attempt > 0)
            let clientId = locked { cache?.clientId } ?? "mac-remote"
            var req = URLRequest(url: URL(string:
                "\(Self.api)/bc/bind?RID=1&VER=8&CVER=1&auth_failure_option=send_error")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Self.form([
                ("app", "web"), ("mdx-version", "3"), ("name", deviceName), ("id", clientId),
                ("device", "REMOTE_CONTROL"), ("capabilities", "que,dsdtr,atp,vsp"),
                ("magnaKey", "cloudPairedDevice"), ("ui", "false"), ("theme", "cl"),
                ("loungeIdToken", token),
            ]).utf8)
            req.timeoutInterval = 15
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 && attempt == 0 { continue }       // token rejected → fetch a new one
            guard code == 200 else { throw YouTubeLoungeError.http(code) }

            locked {
                dropSessionLocked()
                rid = 1
                ofs = 0
            }
            var buf = data
            for batch in Self.extractFrames(&buf) { _ = handle(batch) }
            guard isConnected else { throw YouTubeLoungeError.bad("bind: no SID") }
            // ask for the current state right away (arrives on the long-poll)
            Task { try? await self.command("getNowPlaying") }
            return
        }
        throw YouTubeLoungeError.tokenRejected
    }

    private func dropSessionLocked() {
        sid = nil
        gsid = nil
        aid = -1
    }

    private func commonParams() -> [(String, String)] {
        locked {
            [("name", deviceName), ("loungeIdToken", cache?.loungeToken ?? ""),
             ("SID", sid ?? ""), ("AID", String(aid)), ("gsessionid", gsid ?? ""),
             ("device", "REMOTE_CONTROL"), ("app", "youtube-desktop"), ("VER", "8"), ("v", "2")]
        }
    }

    // MARK: - commands

    private func command(_ name: String, _ params: [String: String] = [:]) async throws {
        for attempt in 0..<2 {
            try await ensureSession()
            let (r, o): (Int, Int) = locked {
                rid += 1
                defer { ofs += 1 }
                return (rid, ofs)
            }
            var body: [(String, String)] = [("count", "1"), ("ofs", String(o)), ("req0__sc", name)]
            for (k, v) in params { body.append(("req0_\(k)", v)) }
            let query = Self.form(commonParams() + [("RID", String(r))])
            var req = URLRequest(url: URL(string: "\(Self.api)/bc/bind?\(query)")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Self.form(body).utf8)
            req.timeoutInterval = 10
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return
            case 400, 404, 410:                     // Unknown SID / Gone → rebind
                locked { dropSessionLocked() }
            case 401:                               // token expired → new token + rebind
                locked { dropSessionLocked(); cache?.expiresAt = 0 }
            default:
                throw YouTubeLoungeError.http(code)
            }
            if attempt == 1 { throw YouTubeLoungeError.sessionLost }
        }
    }

    // MARK: - event loop

    private func run() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            do {
                try await ensureSession()
                try await pollWhileRunning()
                backoff = 2
            } catch YouTubeLoungeError.notRunning {
                let changed: Bool = locked {
                    dropSessionLocked()
                    defer { current = nil }
                    return current != nil
                }
                if changed { publish() }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            } catch YouTubeLoungeError.sessionLost {
                locked { dropSessionLocked() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } catch YouTubeLoungeError.tokenRejected {
                locked { dropSessionLocked(); cache?.expiresAt = 0 }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                if Task.isCancelled { break }
                // network hiccup / poll timeout: keep the session, the next poll tells us
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    /// One long-poll, raced against a DIAL watcher (YouTube closed / TV off → `.notRunning`).
    private func pollWhileRunning() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.pollOnce() }
            group.addTask {
                var misses = 0
                while true {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    misses = await self.dialState().running ? 0 : misses + 1
                    if misses >= 2 { throw YouTubeLoungeError.notRunning }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func pollOnce() async throws {
        let query = Self.form(commonParams() + [("RID", "rpc"), ("CI", "0"), ("TYPE", "xmlhttp")])
        let req = URLRequest(url: URL(string: "\(Self.api)/bc/bind?\(query)")!)
        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 400, 404, 410: throw YouTubeLoungeError.sessionLost
        case 401: throw YouTubeLoungeError.tokenRejected
        default: throw YouTubeLoungeError.http(code)
        }
        var buf = Data()
        for try await byte in bytes {
            buf.append(byte)
            guard byte == 0x0A else { continue }
            for batch in Self.extractFrames(&buf) {
                if !handle(batch) { throw YouTubeLoungeError.sessionLost }
            }
            if buf.count > 1_000_000 { buf.removeAll() }
        }
    }

    /// Processes one `[[id, ["event", args…]], …]` batch. Returns false if the screen
    /// ended the session.
    private func handle(_ batch: [Any]) -> Bool {
        var alive = true
        var changed = false
        var fetchTitle: String?
        var resync = false
        lock.lock()
        for case let item as [Any] in batch {
            guard item.count >= 2, let payload = item[1] as? [Any],
                  let name = payload.first as? String else { continue }
            if let id = item[0] as? Int { aid = id }
            let args = Array(payload.dropFirst())
            let d = args.first as? [String: Any] ?? [:]
            switch name {
            case "c": sid = args.first as? String
            case "S": gsid = args.first as? String
            case "nowPlaying":
                if let vid = d["videoId"] as? String, !vid.isEmpty {
                    let same = current?.videoId == vid ? current : nil
                    let known = titles[vid]
                    current = NowPlaying(
                        videoId: vid,
                        title: known?.title ?? same?.title,
                        channel: known?.channel ?? same?.channel,
                        state: Self.num(d["state"]).flatMap { NowPlaying.State(rawValue: Int($0)) }
                            ?? same?.state ?? .buffering,
                        currentTime: Self.num(d["currentTime"]) ?? same?.position ?? 0,
                        duration: Self.num(d["duration"]) ?? same?.duration ?? 0,
                        hasPrevious: prevNext.prev, hasNext: prevNext.next)
                    if known == nil { fetchTitle = vid }
                } else {
                    current = nil      // only `listId` → nothing playing
                }
                changed = true
            case "onStateChange":
                guard var np = current else { break }
                if let s = Self.num(d["state"]).flatMap({ NowPlaying.State(rawValue: Int($0)) }) { np.state = s }
                if let t = Self.num(d["currentTime"]) { np.currentTime = t }
                if let t = Self.num(d["duration"]), t > 0 { np.duration = t }
                np.updatedAt = Date()
                current = np
                changed = true
            case "onHasPreviousNextChanged":
                prevNext = ((d["hasPrevious"] as? String) == "true", (d["hasNext"] as? String) == "true")
                if current != nil {
                    current?.hasPrevious = prevNext.prev
                    current?.hasNext = prevNext.next
                    changed = true
                }
            case "onPlaybackSpeedChanged":
                // arrives ~every 60 s while playing: cheap moment to resync the position
                if Date().timeIntervalSince(lastResync) > 30 { lastResync = Date(); resync = true }
            case "loungeScreenDisconnected":
                dropSessionLocked()
                current = nil
                changed = true
                alive = false
            default: break
            }
        }
        lock.unlock()
        if changed { publish() }
        if let vid = fetchTitle { Task { await self.loadTitle(vid) } }
        if resync && alive { Task { try? await self.command("getNowPlaying") } }
        return alive
    }

    private func publish() {
        let (cb, np) = locked { (_onUpdate, current) }
        cb?(np)
    }

    /// Title + channel via oEmbed (no API key).
    private func loadTitle(_ vid: String) async {
        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(vid)"),
                            URLQueryItem(name: "format", value: "json")]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 8
        var title: String?, channel: String?
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = obj["title"] as? String
            channel = obj["author_name"] as? String
        }
        let changed: Bool = locked {
            titles[vid] = (title, channel)
            guard current?.videoId == vid, title != nil else { return false }
            current?.title = title
            current?.channel = channel
            return true
        }
        if changed { publish() }
    }

    // MARK: - helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private static let formAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func form(_ items: [(String, String)]) -> String {
        items.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }

    private static func num(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Pulls complete `<len>\n[...]` frames off the front of `buf`. The length prefix
    /// isn't trusted (it counts the trailing newline); the JSON array end is found by
    /// bracket matching, which is UTF-8-safe since multibyte sequences are ≥ 0x80.
    static func extractFrames(_ buf: inout Data) -> [[Any]] {
        let b = [UInt8](buf)
        var out: [[Any]] = []
        var i = 0
        while true {
            var j = i
            while j < b.count, b[j] == 0x0A || b[j] == 0x0D || b[j] == 0x20 { j += 1 }
            var k = j
            while k < b.count, (0x30...0x39).contains(b[k]) { k += 1 }
            guard k > j, k + 1 < b.count, b[k] == 0x0A, b[k + 1] == 0x5B else { break }
            var p = k + 1, depth = 0, inString = false, escaped = false, end = -1
            while p < b.count {
                let c = b[p]
                if inString {
                    if escaped { escaped = false }
                    else if c == 0x5C { escaped = true }
                    else if c == 0x22 { inString = false }
                } else if c == 0x22 { inString = true }
                else if c == 0x5B { depth += 1 }
                else if c == 0x5D {
                    depth -= 1
                    if depth == 0 { end = p + 1; break }
                }
                p += 1
            }
            guard end > 0 else { break }
            if let arr = try? JSONSerialization.jsonObject(with: Data(b[(k + 1)..<end])) as? [Any] {
                out.append(arr)
            }
            i = end
        }
        if i > 0 { buf = Data(b[i...]) }
        return out
    }
}

enum YouTubeLoungeError: LocalizedError {
    case notRunning, sessionLost, tokenRejected
    case http(Int)
    case bad(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "YouTube is not running on the TV"
        case .sessionLost: return "YouTube session lost"
        case .tokenRejected: return "YouTube lounge token rejected"
        case .http(let c): return "YouTube lounge: HTTP \(c)"
        case .bad(let m): return m
        }
    }
}
