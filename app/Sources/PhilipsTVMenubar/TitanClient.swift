import Foundation
import Network
import CryptoKit
import Security

/// Titan OS local control channel: MQTT v5 over TLS on port 8883.
///
/// This is what the official "Titan OS Mobile" app uses (reverse-engineered from
/// tv.titanos.eos.mobile 1.4.4). Unlike JointSpace (where /applications is 403),
/// it can launch ANY installed app — Disney+, HBO Max, … — via the `deeplink` topic.
///
/// - TLS: server cert chains to the bundled "Titanos Root CA"; no client cert, no
///   hostname check (we connect by IP).
/// - Pairing: anonymous connect → request `pairing/start {"type":"mobile"}` → TV shows
///   a 4-digit PIN → `pairing/finish {"username", "challenge_result"}` where
///   challenge_result = hex(HMAC-SHA256(key: PIN, msg: challenge)) → returns a password.
/// - Requests: subscribe `<topic>/<uuid>`, publish to `<topic>` with MQTT5
///   ResponseTopic + CorrelationData = that topic, wait for the reply.
final class TitanClient: @unchecked Sendable {

    struct Credentials: Codable {
        var host: String
        var username: String
        var password: String
    }

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".philips-tv-remote/titan_mqtt.json")
    }

    static func loadSaved() -> Credentials? {
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private static func save(_ c: Credentials) throws {
        let dir = credentialsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try enc.encode(c).write(to: credentialsURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: credentialsURL.path)
    }

    // "Titanos Root CA" (C=ES, O=TitanOS), DER, bundled in the Titan OS Mobile app.
    // SHA-256 BC:91:11:1A:19:E8:21:6E:14:59:58:2C:CC:97:74:55:74:FC:7C:5F:85:8C:DE:54:AA:1B:7C:26:C8:0D:DE:DA
    private static let rootCADER = """
    MIIFszCCA5ugAwIBAgIUKKf5oPbMLyZOQKygD5UL0iixNVowDQYJKoZIhvcNAQELBQAwYTELMAkGA1UEBhMCRVMxEjAQBgNVBAgMCUJhcmNlbG9uYTESMBAGA1UEBwwJQmFyY2Vsb25hMRAwDgYDVQQKDAdUaXRhbk9TMRgwFgYDVQQDDA9UaXRhbm9zIFJvb3QgQ0EwHhcNMjQxMTE4MDg0MjM3WhcNNDYxMDE0MDg0MjM3WjBhMQswCQYDVQQGEwJFUzESMBAGA1UECAwJQmFyY2Vsb25hMRIwEAYDVQQHDAlCYXJjZWxvbmExEDAOBgNVBAoMB1RpdGFuT1MxGDAWBgNVBAMMD1RpdGFub3MgUm9vdCBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALUdzSkFl/+utLPy1TcOWo951L+ACx5JfRu+kpso3RBu59YGFeWsj+N2VQ633qWeNB1HwawbwLmtrt5dLHQQzC8UsAf6XJnG3ritoJV0bIA3GFYhgQ2sLYZv1Y1lWsSSxMGDbJU/y8+iWTUhvKVCN9flUSYnpoZwVCvKBpLh7rBm53zTP2TvUCCakZmey7C2zIRXmWj/gLbHbxXqKB44xjKp1Y9Gy5QtvKOHxY61W+hhKOuaaSTbV+I/EitILzjm3bh8RytPP+HZsXgEdPj7izwLkzoSXKGWb0v1qnNtu8SP7t9/tSpbAMOUmcR9hTVJ2Fl57CnT/4otFVjXirMd6RvsxRvBpdBLqawO4h1nG+GIQdkqKaI7q8hrXqZa5pwnqttzei16T8LzUw6BxM9eJziykahfKorkkCm27u9+b1ABrTMjrPtyRXuzaN7c8Id/3ILetn+ErGzyNd2P1Ey8yTyc5sPsVFdJdRQ1MLN4igoDr8iVc6ODkzJq8y9pM3q2QLAwkY7rXx/UWt9CIhFBwL2aedEUBAQ104aJIYjo5E6QzGUu6ATKg3K8Rhnw55N9YINPOnWJS7OXIy0We4EwYHBKI0yzxSzwQrAl7hYOxfe3RbjBDnjx8kUVUmJXVihtOXLcxvA53ZChP2HSLCieBlibxiKcFKffzdeTwsBZWgClAgMBAAGjYzBhMB0GA1UdDgQWBBQu2FmLX8AfqTYuaCvnZEOemgSsMjAfBgNVHSMEGDAWgBQu2FmLX8AfqTYuaCvnZEOemgSsMjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAgEATvARxcgSy/i3/sX0IL1sIwkvP/Orv3Hofj0rBuW/zwB/xu+g+i5n121GsTXDefgpspfUCIjcfMWgjj4MYQKs0xwSaiWdIeHvWe6z4SWz/2r/Tly2tRsdfs71g3V62OZFlldYHAglqAS+AmGevi2CPPqXHWoKZgvH4iuPKuwaTyHYh6BizcJlJaXsFn7FUwU7uQn8B7mZJACmEDhtBEO/7RvqJy8uTe8q6LYkT36mfySYx3JUBjEVMRcir+YNILomqfBVxBUYLakY9ES95o1/aUMGLekwDnBiNNCfXEyrLeZrq0RNm6Uua9h+VOTuL118DuK6QQZceeQMoDoOCH6h52n9A2l/67VpfsEbV5AcaSxpA9xpMwd3iNy7E4XmsEyPheZnVf8gHDMiVsAhOPGYuJD1yEsOl6LnDvtUdpHnSC/KBzYajToaWt2d4p6SRGNT0gP1qk39A3mvt5X7NUEc1/TiZN3owYAdV35YzqhDYnJKsjSVw2Uh3UzYzY99cDdqsOUNOOKJWSWX0b7XRSEh94j9a2zRi08pS1WJWve1VdgUuxXZLpjBb9oXIseMiLQIcdYcemUP+KCt9AUaeZ36gOXeK5kFHEONPS01gt4+I1JPL/grmry54AyHK/CrqxsM7Tzp0UNe1NdIMEEK6k/nerFuPlrcS37OXQVgLqKTAdY=
    """

    private let host: String
    private let queue = DispatchQueue(label: "titan.mqtt")
    private var conn: NWConnection?
    private var buffer = Data()
    private var packetId: UInt16 = 0
    private var pendingChallenge: String?

    init(host: String) { self.host = host }

    // MARK: - high level

    /// Launch an installed app by its Titan catalog code + url (from /v1/me/user_apps).
    static func launch(_ creds: Credentials, code: String, url: String) async throws {
        let c = TitanClient(host: creds.host)
        try await c.open(user: creds.username, pass: creds.password)
        defer { c.close() }
        let reply = try await c.request("deeplink", ["app_code": code, "url": url])
        if let err = reply["error"] as? [String: Any] {
            throw TitanError.remote(err["message"] as? String ?? "deeplink error")
        }
    }

    /// The TV's installed apps (home-screen order), fetched through the TV's own
    /// authenticated cloud proxy.
    static func installedApps(_ creds: Credentials) async throws -> [TitanApp] {
        let c = TitanClient(host: creds.host)
        try await c.open(user: creds.username, pass: creds.password)
        defer { c.close() }
        let reply = try await c.request("proxy", [
            "endpoint": "/v1/me/user_apps", "method": "GET", "headers": [String: String](),
            "query_params": ["page": "1", "per_page": "50"], "authenticated": true, "api": "gaea",
        ])
        var body = (reply["data"] as? [String: Any])?["body"]
        if let s = body as? String {
            body = try? JSONSerialization.jsonObject(with: Data(s.utf8))
        }
        let items = (body as? [String: Any])?["collection"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let app = item["app"] as? [String: Any],
                  let code = app["code"] as? String, let name = app["name"] as? String,
                  let url = app["url"] as? String else { return nil }
            return TitanApp(code: code, name: name.trimmingCharacters(in: .whitespaces),
                            url: url.trimmingCharacters(in: .whitespaces),
                            icon: (app["icon"] as? String).flatMap(URL.init(string:)))
        }
    }

    // MARK: - persistent session (remote keys / keyboard)

    /// Linux input keycodes the TV expects on the `rc` topic, keyed by JointSpace key
    /// name. From the Titan OS Mobile app, except those marked (evdev) which are the
    /// standard linux/input-event-codes.h values.
    static let keyCodes: [String: Int] = [
        "Confirm": 352, "Back": 158, "Home": 102,
        "CursorUp": 103, "CursorDown": 108, "CursorLeft": 105, "CursorRight": 106,
        "VolumeUp": 115, "VolumeDown": 114, "Mute": 113, "Standby": 116,
        "Play": 207, "Pause": 119, "PlayPause": 164, "Stop": 128,
        "Options": 357, "QuickMenu": 139, "Source": 394, "TvGuide": 365,
        "ChannelStepUp": 402, "ChannelStepDown": 403,
        "RedColour": 398, "GreenColour": 399, "YellowColour": 400, "BlueColour": 401,
        // (evdev) — WatchTV = KEY_TV, verified: jumps to the last tuner source
        "WatchTV": 377, "Next": 163, "Previous": 165, "FastForward": 208, "Rewind": 168, "Info": 358,
    ]

    /// Fire-and-forget publish on a long-lived connection (reconnects as needed).
    /// Callers must serialise calls.
    func publish(_ creds: Credentials, _ topic: String, _ payload: [String: Any]) async throws {
        for attempt in 0..<2 {
            if conn?.state != .ready {
                close()
                buffer = Data()
                try await open(user: creds.username, pass: creds.password)
            }
            do {
                let json = try JSONSerialization.data(withJSONObject: payload)
                try await send(0x30, Self.str(topic) + Self.varint(0) + json)
                return
            } catch {
                close()
                if attempt == 1 { throw error }
            }
        }
    }

    /// Latest retained message on a topic (e.g. `channels/state`: {"state":"launcher"} on
    /// the home screen, "inactive" when an app or another source is in front).
    static func retained(_ creds: Credentials, _ topic: String) async throws -> [String: Any]? {
        let c = TitanClient(host: creds.host)
        try await c.open(user: creds.username, pass: creds.password)
        defer { c.close() }
        c.packetId &+= 1
        let sub = Data([UInt8(c.packetId >> 8), UInt8(c.packetId & 0xFF)]) + Self.varint(0)
            + Self.str(topic) + Data([0x00])
        try await c.send(0x82, sub)
        _ = try await c.withTimeout(4) { try await c.readPacket(type: 9) }
        return try? await c.withTimeout(2.5) {
            while true {
                let (t, p) = try await c.readPublish()
                if t == topic { return (try? JSONSerialization.jsonObject(with: p)) as? [String: Any] ?? [:] }
            }
        }
    }

    /// Pairing step 1: TV shows a 4-digit PIN. Keeps the connection open for step 2.
    func startPairing() async throws {
        try await open(user: nil, pass: nil)
        let reply = try await request("pairing/start", ["type": "mobile"])
        guard let challenge = (reply["data"] as? [String: Any])?["challenge"] as? String else {
            close()
            throw TitanError.remote((reply["error"] as? [String: Any])?["message"] as? String ?? "pairing/start failed")
        }
        pendingChallenge = challenge
    }

    /// Pairing step 2: answer the challenge with the PIN; saves credentials.
    func finishPairing(pin: String) async throws -> Credentials {
        defer { close() }
        guard let challenge = pendingChallenge else { throw TitanError.remote("no pending pairing") }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8),
                                                  using: SymmetricKey(data: Data(pin.utf8)))
        let result = mac.map { String(format: "%02x", $0) }.joined()
        let username = UUID().uuidString.lowercased()
        let reply = try await request("pairing/finish", ["username": username, "challenge_result": result])
        guard let data = reply["data"] as? [String: Any], let pw = data["password"] as? String else {
            throw TitanError.remote("Invalid PIN")
        }
        let creds = Credentials(host: host, username: data["username"] as? String ?? username, password: pw)
        try Self.save(creds)
        return creds
    }

    // MARK: - connection

    private func open(user: String?, pass: String?) async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let der = Data(base64Encoded: Self.rootCADER.replacingOccurrences(of: "\n", with: "")),
                  let ca = SecCertificateCreateWithData(nil, der as CFData) else { complete(false); return }
            SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(secTrust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
            complete(SecTrustEvaluateWithError(secTrust, nil))
        }, queue)
        let params = NWParameters(tls: tls)
        let c = NWConnection(host: NWEndpoint.Host(host), port: 8883, using: params)
        conn = c

        try await withTimeout(8) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                c.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready: resumed = true; cont.resume()
                    case .failed(let e), .waiting(let e): resumed = true; cont.resume(throwing: e)
                    case .cancelled: resumed = true; cont.resume(throwing: TitanError.closed)
                    default: break
                    }
                }
                c.start(queue: self.queue)
            }
        }

        // CONNECT (MQTT 5, clean start, keepalive 30)
        var flags: UInt8 = 0x02
        if user != nil { flags |= 0x80 }
        if pass != nil { flags |= 0x40 }
        var body = Self.str("MQTT") + Data([5, flags, 0, 30]) + Self.varint(0)
        body += Self.str("eos-" + (user ?? UUID().uuidString.lowercased()))
        if let user = user { body += Self.str(user) }
        if let pass = pass { body += Self.bin(Data(pass.utf8)) }
        try await send(0x10, body)

        let ack = try await withTimeout(6) { try await self.readPacket(type: 2) }
        let reason = ack.count > 1 ? ack[ack.startIndex + 1] : 0xFF
        guard reason == 0 else { close(); throw TitanError.remote("CONNACK \(reason) (pairing invalid?)") }
    }

    private func close() {
        conn?.send(content: Data([0xE0, 0x00]), completion: .idempotent)
        conn?.cancel()
        conn = nil
    }

    private func request(_ topic: String, _ payload: [String: Any]) async throws -> [String: Any] {
        let responseTopic = "\(topic)/\(UUID().uuidString.lowercased())"

        packetId &+= 1
        let sub = Data([UInt8(packetId >> 8), UInt8(packetId & 0xFF)]) + Self.varint(0)
            + Self.str(responseTopic) + Data([0x00])
        try await send(0x82, sub)
        _ = try await withTimeout(6) { try await self.readPacket(type: 9) }

        let props = Data([0x08]) + Self.str(responseTopic) + Data([0x09]) + Self.bin(Data(responseTopic.utf8))
        let json = try JSONSerialization.data(withJSONObject: payload)
        try await send(0x30, Self.str(topic) + Self.varint(props.count) + props + json)

        return try await withTimeout(8) {
            while true {
                let (t, p) = try await self.readPublish()
                if t == responseTopic {
                    return (try? JSONSerialization.jsonObject(with: p)) as? [String: Any] ?? [:]
                }
            }
        }
    }

    // MARK: - wire format

    private func send(_ header: UInt8, _ body: Data) async throws {
        guard let c = conn else { throw TitanError.closed }
        let packet = Data([header]) + Self.varint(body.count) + body
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: packet, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    /// Next packet of the given type (others are skipped).
    private func readPacket(type: UInt8) async throws -> Data {
        while true {
            let (t, _, body) = try await nextPacket()
            if t == type { return body }
        }
    }

    private func readPublish() async throws -> (String, Data) {
        while true {
            let (t, flags, body) = try await nextPacket()
            guard t == 3 else { continue }
            var i = body.startIndex
            let tlen = Int(body[i]) << 8 | Int(body[i + 1]); i += 2
            let topic = String(decoding: body[i..<(i + tlen)], as: UTF8.self); i += tlen
            if (flags >> 1) & 0x3 > 0 { i += 2 } // packet id for QoS > 0
            let (plen, n) = Self.readVarint(body, at: i); i += n + plen
            return (topic, Data(body[i...]))
        }
    }

    private func nextPacket() async throws -> (UInt8, UInt8, Data) {
        while true {
            if buffer.count >= 2 {
                let (len, n) = Self.readVarint(buffer, at: buffer.startIndex + 1)
                if n > 0, buffer.count >= 1 + n + len {
                    let first = buffer[buffer.startIndex]
                    let start = buffer.startIndex + 1 + n
                    let body = Data(buffer[start..<(start + len)])
                    buffer = Data(buffer[(start + len)...])
                    return (first >> 4, first & 0x0F, body)
                }
            }
            guard let c = conn else { throw TitanError.closed }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                    if let err = err { cont.resume(throwing: err) }
                    else if let data = data, !data.isEmpty { cont.resume(returning: data) }
                    else if done { cont.resume(throwing: TitanError.closed) }
                    else { cont.resume(returning: Data()) }
                }
            }
            buffer += chunk
        }
    }

    private static func varint(_ n: Int) -> Data {
        var n = n, out = Data()
        repeat {
            var b = UInt8(n % 128); n /= 128
            if n > 0 { b |= 0x80 }
            out.append(b)
        } while n > 0
        return out
    }

    /// Returns (value, bytesUsed); bytesUsed == 0 if incomplete.
    private static func readVarint(_ d: Data, at start: Int) -> (Int, Int) {
        var value = 0, mult = 1, i = start
        while i < d.endIndex, i - start < 4 {
            let b = d[i]; value += Int(b & 0x7F) * mult; i += 1
            if b & 0x80 == 0 { return (value, i - start) }
            mult *= 128
        }
        return (0, 0)
    }

    private static func str(_ s: String) -> Data { bin(Data(s.utf8)) }
    private static func bin(_ d: Data) -> Data { Data([UInt8(d.count >> 8), UInt8(d.count & 0xFF)]) + d }

    private func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TitanError.timeout
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch {
                // unblock a pending receive so the op task can finish
                if case TitanError.timeout = error { self.conn?.cancel() }
                throw error
            }
        }
    }
}

struct TitanApp: Identifiable, Hashable {
    let code: String
    let name: String
    let url: String
    var icon: URL? = nil
    var id: String { code }
}

enum TitanError: LocalizedError {
    case remote(String), timeout, closed
    var errorDescription: String? {
        switch self {
        case .remote(let m): return m
        case .timeout: return "timed out"
        case .closed: return "connection closed"
        }
    }
}
