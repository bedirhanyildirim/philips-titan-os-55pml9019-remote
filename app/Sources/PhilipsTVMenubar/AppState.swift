import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var client: PhilipsClient?
    @Published var needsPairing: Bool
    @Published var isOn: Bool = false
    @Published var modelName: String = ""
    @Published var statusMessage: String = ""

    // pairing flow
    @Published var pairingHost: String = "192.168.0.45"
    @Published var pairingPIN: String = ""
    @Published var pairingAwaitingPIN: Bool = false
    private var pairingTimestamp: Int = 0

    // Titan OS app control (MQTT :8883) — separate pairing from JointSpace
    @Published var titan: TitanClient.Credentials? = TitanClient.loadSaved()
    @Published var tvApps: [TitanApp] = AppState.defaultApps
    @Published var titanAwaitingPIN = false
    @Published var titanPIN = ""
    private var titanPairing: TitanClient?

    // UI
    @Published var lastLaunched: TitanApp?
    @Published var nowOn: NowOn?

    /// What's on screen right now, from TV context + Titan `channels/state` + DIAL states.
    struct NowOn: Equatable {
        var title: String
        var detail: String? = nil
        var icon: String = "tv"
        var app: TitanApp? = nil
    }
    private var prevDial: [String: String] = [:]

    // YouTube app on the TV (Lounge API — see YouTubeLounge.swift)
    let youtube = YouTubeLounge(tvHost: PhilipsClient.loadSaved()?.host ?? "192.168.0.45", deviceName: "Mac")
    @Published var ytNow: YouTubeLounge.NowPlaying?

    func yt(_ label: String, _ op: @escaping (YouTubeLounge) async throws -> Void) {
        let y = youtube
        Task {
            do { try await op(y) }
            catch { AppState.log("youtube \(label) ERROR: \(error)"); statusMessage = "YouTube \(label) failed" }
        }
    }
    @Published var glow: Color = Theme.accent  // last Ambilight colour, for the TV preview
    @Published var favorites: [String] =
        UserDefaults.standard.stringArray(forKey: "favorites") ?? ["youtube", "netflix", "disney", "max"] {
        didSet { UserDefaults.standard.set(favorites, forKey: "favorites") }
    }

    var favoriteApps: [TitanApp] { favorites.compactMap { c in tvApps.first { $0.code == c } } }

    func toggleFavorite(_ app: TitanApp) {
        if let i = favorites.firstIndex(of: app.code) { favorites.remove(at: i) }
        else { favorites.append(app.code) }
    }

    /// Shown until the TV's own list loads (codes/urls from /v1/me/user_apps, PL market).
    static let defaultApps: [TitanApp] = [
        TitanApp(code: "youtube", name: "YouTube", url: "https://www.youtube.com/tv"),
        TitanApp(code: "netflix", name: "Netflix", url: "localfunction:gotonetflix"),
        TitanApp(code: "disney", name: "Disney+", url: "disneyplus"),
        TitanApp(code: "max", name: "HBO Max", url: "https://titan.play.max.com"),
        TitanApp(code: "prime_video", name: "Prime Video", url: "localfunction:gotoaiv"),
    ]

    init() {
        let c = PhilipsClient.loadSaved()
        self.client = c
        self.needsPairing = (c == nil)
        Task { await startup() }
    }

    /// The first launch after a rebuild can briefly hit "Local network prohibited"
    /// while macOS re-checks the permission — retry a few times before giving up.
    private func startup() async {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            if client != nil { await refresh() }
            if statusMessage.isEmpty { break }
        }
        await loadApps()
        youtube.onUpdate = { [weak self] np in Task { @MainActor in self?.ytNow = np } }
        youtube.start()                                // idles while YouTube isn't open
        // Live "now on" — every 8 s while the TV is on (Titan's JointSpace HTTPS server
        // wedges under rapid requests; keep polling light).
        Task {
            while !Task.isCancelled {
                if isOn { await refreshNowOn() }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
        // Keep power state fresh: the TV can be switched off by its remote or by the
        // Orange box over HDMI-CEC, and nothing notifies us.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await refresh()
            await refreshOrange()
        }
    }

    func refresh() async {
        guard let c = client else { AppState.log("refresh: no client"); return }
        do {
            let state = try await c.powerState()
            isOn = (state == "On")
            if modelName.isEmpty, let name = try? await c.systemInfo()["name"] as? String { modelName = name }
            statusMessage = ""
        } catch {
            // In deep standby the TV drops off the network entirely ("Host is down").
            // (In quick standby it still answers and reports "On" — see ROADMAP.)
            if isOn { AppState.log("refresh ERROR: \(error)") }
            isOn = false
            statusMessage = "TV off or unreachable"
        }
    }

    nonisolated static func log(_ msg: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".philips-tv-remote/app.log")
        let line = "\(Date()) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // fire-and-forget command with light error surfacing
    func run(_ label: String = "", _ body: @escaping (PhilipsClient) async throws -> Void) {
        guard let c = client else { return }
        Task {
            do { try await body(c) }
            catch { statusMessage = "\(label) failed" }
        }
    }

    // MARK: remote keys / keyboard (Titan MQTT `rc`, JointSpace fallback)

    private var titanRemote: TitanClient?
    private var keyChain: Task<Void, Never>?

    /// Send a remote key. Prefers Titan MQTT (keeps working even if JointSpace hangs),
    /// falls back to JointSpace input/key for keys without a known keycode.
    func key(_ k: String) {
        if let creds = titan, let code = TitanClient.keyCodes[k] {
            titanSend(creds, "rc", ["key_code": code], label: k)
        } else {
            run(k) { try await $0.sendKey(k) }
        }
    }

    func type(_ text: String) {
        if let creds = titan {
            for ch in text { titanSend(creds, "keyboard", ["opcode": 0, "text": String(ch)], label: "keyboard") }
        } else {
            run("keyboard") { try await $0.textEntry(text) }
        }
    }

    /// Serialised so key presses keep their order and share one connection.
    /// `delay` (seconds) is waited after the publish, before the next queued one.
    private func titanSend(_ creds: TitanClient.Credentials, _ topic: String, _ payload: [String: Any],
                           label: String, delay: Double = 0) {
        let prev = keyChain
        let remote = titanRemote ?? TitanClient(host: creds.host)
        titanRemote = remote
        keyChain = Task {
            await prev?.value
            do {
                try await remote.publish(creds, topic, payload)
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            } catch {
                AppState.log("titan \(topic) ERROR: \(error)")
                statusMessage = "\(label) failed"
            }
        }
    }

    // MARK: now on

    func refreshNowOn() async {
        guard isOn, let c = client else { nowOn = nil; return }
        let level1 = (try? await c.context()) ?? "NetTv"
        if level1 == "WatchExtension" {
            if orangeReachable, let o = orangeStatus, o.isOn {
                nowOn = NowOn(title: "Orange TV", detail: o.channelId.map { "HDMI 1 · channel #\($0)" } ?? "HDMI 1",
                              icon: "tv.and.mediabox")
            } else {
                nowOn = NowOn(title: "HDMI input", detail: currentSource?.name, icon: "cable.connector")
            }
            lastLaunched = nil
            return
        }
        if level1.hasPrefix("Watch") {                 // WatchSatellite, WatchTv, …
            let src = String(level1.dropFirst(5))
            nowOn = NowOn(title: src == "Satellite" ? "Satellite TV" : "Live TV",
                          detail: src == "Satellite" ? nil : src, icon: "antenna.radiowaves.left.and.right")
            lastLaunched = nil
            return
        }
        // NetTv: home screen or an app. Titan says reliably whether the launcher is up.
        if let creds = titan,
           let st = (try? await TitanClient.retained(creds, "channels/state"))??["state"] as? String,
           st == "launcher" {
            nowOn = NowOn(title: "Home screen", icon: "house.fill")
            lastLaunched = nil
            return
        }
        // Which app? DIAL knows YouTube/Netflix/Prime; a stopped→running flip means it
        // was just opened (e.g. from the TV remote).
        var started: String?
        var running = Set<String>()
        for (code, (name, _)) in Self.dial {
            guard let st = await c.dialState(name) else { continue }
            if st == "running" {
                running.insert(code)
                if prevDial[code] != nil, prevDial[code] != "running" { started = code }
            }
            prevDial[code] = st
        }
        var app = lastLaunched
        if let code = started ?? (app == nil && running.count == 1 ? running.first : nil) {
            app = tvApps.first { $0.code == code }
        } else if let a = app, Self.dial[a.code] != nil, !running.contains(a.code) {
            app = nil                                  // the DIAL app we launched isn't running any more
        }
        lastLaunched = app
        nowOn = app.map { a in
            NowOn(title: a.name, detail: a.code == "youtube" ? ytNow?.title : nil, icon: "play.tv", app: a)
        }
            ?? NowOn(title: "An app", detail: "Opened from the TV remote", icon: "app")
    }

    // MARK: power

    /// Off/unreachable → Wake-on-LAN (deep standby takes the TV off the network);
    /// on → Standby key. Re-checks state shortly after.
    func togglePower() {
        if isOn {
            key("Standby")
        } else {
            statusMessage = "Waking the TV…"
            WakeOnLAN.wake(WakeOnLAN.tvMACs)
            WakeOnLAN.wake(WakeOnLAN.tvMACs, broadcast: "192.168.0.255")
        }
        Task {
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
                if isOn == true, statusMessage.isEmpty { break }
            }
        }
    }

    // MARK: Orange TV box (HDMI 1)

    let orange = OrangeClient(host: UserDefaults.standard.string(forKey: "orangeHost") ?? OrangeClient.defaultHost)
    @Published var orangeStatus: OrangeClient.Status?
    @Published var orangeReachable = true

    func refreshOrange() async {
        do {
            orangeStatus = try await orange.status()
            orangeReachable = true
        } catch {
            orangeStatus = nil
            orangeReachable = false
        }
    }

    func orangeKey(_ code: Int) {
        Task {
            do {
                try await orange.press(code)
                try? await Task.sleep(nanoseconds: 700_000_000)
                await refreshOrange()
            } catch {
                AppState.log("orange key \(code) ERROR: \(error)")
                orangeReachable = false
                statusMessage = "Can't reach the Orange box"
            }
        }
    }

    func orangeKey(_ key: OrangeClient.Key) { orangeKey(key.rawValue) }

    /// Show the box on the TV (HDMI 1 via the Sources drawer).
    func watchOrange() {
        if let hdmi1 = TVSource.hdmi.first(where: { $0.id == "hdmi1" }) { select(hdmi1) }
    }

    // MARK: sources (HDMI etc.)

    /// JointSpace /sources is 403 on Titan OS, so select an input through the Sources
    /// drawer: open it, pin focus to an end of the list (it doesn't wrap, and focus
    /// starts on the current source), step to the row, OK. Keys are paced so none get
    /// dropped — a short count could leave focus on "Screen mirroring", which drops
    /// the TV off the network.
    @Published var currentSource: TVSource?

    func select(_ source: TVSource) {
        guard let creds = titan else {
            statusMessage = "Source switching needs Titan pairing"
            return
        }
        currentSource = source
        let rc = { (k: String, d: Double) in
            self.titanSend(creds, "rc", ["key_code": TitanClient.keyCodes[k]!], label: "Source", delay: d)
        }
        let arrows: [String]
        switch source.path {
        case .home:                              // home screen == Streaming
            rc("Home", 0)
            return
        case .top(let down):
            arrows = Array(repeating: "CursorUp", count: 12) + Array(repeating: "CursorDown", count: down)
        case .bottom(let up):
            arrows = Array(repeating: "CursorDown", count: 12) + Array(repeating: "CursorUp", count: up)
        }
        rc("Home", 2.0)                          // settle first: Source on an open drawer closes it
        rc("Source", 2.0)
        for (i, a) in arrows.enumerated() { rc(a, i == arrows.count - 1 ? 0.9 : 0.4) }
        rc("Confirm", 0)
    }

    // MARK: apps (Titan MQTT, DIAL fallback)

    func loadApps() async {
        guard let creds = titan else { return }
        do {
            let apps = try await TitanClient.installedApps(creds)
            if !apps.isEmpty { tvApps = apps }
        } catch {
            AppState.log("titan apps ERROR: \(error)")
        }
    }

    // DIAL names + required Origin, for launching without Titan pairing
    private static let dial: [String: (String, String?)] = [
        "youtube": ("YouTube", "https://www.youtube.com"),
        "netflix": ("Netflix", "https://www.netflix.com"),
        "prime_video": ("AmazonInstantVideo", nil),
    ]

    func launch(_ app: TitanApp) {
        Task {
            do {
                if let creds = titan {
                    try await TitanClient.launch(creds, code: app.code, url: app.url)
                } else if let (name, origin) = Self.dial[app.code], let c = client {
                    try await c.launchDIAL(name, origin: origin)
                } else {
                    statusMessage = "\(app.name) needs Titan pairing"
                    return
                }
                statusMessage = ""
                lastLaunched = app
                nowOn = NowOn(title: app.name, icon: "play.tv", app: app)
            } catch {
                AppState.log("launch \(app.code) ERROR: \(error)")
                statusMessage = "Couldn't open \(app.name)"
            }
        }
    }

    func startTitanPairing() {
        let t = TitanClient(host: client?.host ?? pairingHost)
        titanPairing = t
        statusMessage = "Contacting the TV…"
        Task {
            do {
                try await t.startPairing()
                titanAwaitingPIN = true
                statusMessage = "Enter the PIN shown on the TV"
            } catch {
                AppState.log("titan pair start ERROR: \(error)")
                statusMessage = "Titan pairing failed"
            }
        }
    }

    func finishTitanPairing() {
        guard let t = titanPairing else { return }
        let pin = titanPIN
        Task {
            do {
                titan = try await t.finishPairing(pin: pin)
                statusMessage = ""
                await loadApps()
            } catch {
                AppState.log("titan pair finish ERROR: \(error)")
                statusMessage = "Invalid PIN — try again"
            }
            titanAwaitingPIN = false
            titanPIN = ""
            titanPairing = nil
        }
    }

    // MARK: pairing

    func startPairing() {
        let c = PhilipsClient(host: pairingHost)
        client = c
        statusMessage = "Contacting the TV…"
        Task {
            do {
                let (_, ts) = try await c.pairRequest()
                pairingTimestamp = ts
                pairingAwaitingPIN = true
                statusMessage = "Enter the PIN shown on the TV"
            } catch {
                statusMessage = "Request failed — is the IP right?"
            }
        }
    }

    func finishPairing() {
        guard let c = client else { return }
        let pin = pairingPIN
        Task {
            do {
                try await c.pairGrant(pin: pin, timestamp: pairingTimestamp)
                needsPairing = false
                pairingAwaitingPIN = false
                pairingPIN = ""
                statusMessage = ""
                await refresh()
            } catch {
                statusMessage = "Invalid / expired PIN — try again"
                pairingAwaitingPIN = false
            }
        }
    }
}
