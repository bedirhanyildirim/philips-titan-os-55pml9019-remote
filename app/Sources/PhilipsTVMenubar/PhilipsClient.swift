import Foundation
import CryptoKit

/// JointSpace v6 client for Philips Titan OS TVs.
/// Mirrors the Python client: secure PIN pairing + HTTP Digest auth over TLS.
final class PhilipsClient: NSObject, URLSessionDelegate, @unchecked Sendable {

    struct Credentials: Codable {
        var host: String
        var deviceId: String
        var authKey: String
        enum CodingKeys: String, CodingKey {
            case host
            case deviceId = "device_id"
            case authKey = "auth_key"
        }
    }

    // ha-philipsjs shared key (works on Titan OS); base64, decoded before HMAC use.
    private static let sharedKeyB64 =
        "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA=="

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".philips-tv-remote/credentials.json")
    }

    private(set) var host: String
    // current digest auth pair (device id + key); swapped during pairing
    private var authUser: String?
    private var authPass: String?

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    init(host: String, deviceId: String? = nil, authKey: String? = nil) {
        self.host = host
        self.authUser = deviceId
        self.authPass = authKey
    }

    var isPaired: Bool { authUser != nil && authPass != nil }

    // MARK: - persistence

    static func loadSaved() -> PhilipsClient? {
        guard let data = try? Data(contentsOf: credentialsURL),
              let c = try? JSONDecoder().decode(Credentials.self, from: data) else { return nil }
        return PhilipsClient(host: c.host, deviceId: c.deviceId, authKey: c.authKey)
    }

    func save() throws {
        guard let user = authUser, let pass = authPass else { return }
        let c = Credentials(host: host, deviceId: user, authKey: pass)
        let dir = Self.credentialsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try enc.encode(c).write(to: Self.credentialsURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.credentialsURL.path)
    }

    // MARK: - low level

    private func url(_ path: String) -> URL { URL(string: "https://\(host):1926/6/\(path)")! }

    @discardableResult
    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil, authed: Bool = true) async throws -> Data {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        func build(auth: String?) -> URLRequest {
            var req = URLRequest(url: url(path))
            req.httpMethod = method
            if let bodyData = bodyData {
                req.httpBody = bodyData
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let auth = auth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
            return req
        }

        // 1) initial request (no auth). The TV answers 401 with a Digest challenge.
        var (data, resp) = try await session.data(for: build(auth: nil))
        var http = resp as? HTTPURLResponse

        // 2) compute the Digest response ourselves and retry (URLSession's built-in
        //    digest handling doesn't work reliably with this TV).
        if authed, http?.statusCode == 401,
           let www = http?.value(forHTTPHeaderField: "Www-Authenticate")
                    ?? http?.value(forHTTPHeaderField: "WWW-Authenticate"),
           let user = authUser, let pass = authPass {
            let header = Self.digestHeader(www: www, method: method,
                                           uri: url(path).path, user: user, pass: pass)
            (data, resp) = try await session.data(for: build(auth: header))
            http = resp as? HTTPURLResponse
        }

        let code = http?.statusCode ?? -1
        if code < 200 || code >= 300 { AppState.log("HTTP \(code) \(method) \(path)") }
        return data
    }

    // MARK: - manual HTTP Digest (matches Python requests' HTTPDigestAuth)

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func digestHeader(www: String, method: String, uri: String, user: String, pass: String) -> String {
        var p: [String: String] = [:]
        let scanner = www.replacingOccurrences(of: "Digest ", with: "")
        let re = try! NSRegularExpression(pattern: "(\\w+)=(\"[^\"]*\"|[^,]+)")
        for m in re.matches(in: scanner, range: NSRange(scanner.startIndex..., in: scanner)) {
            guard let kr = Range(m.range(at: 1), in: scanner),
                  let vr = Range(m.range(at: 2), in: scanner) else { continue }
            let k = String(scanner[kr])
            var v = String(scanner[vr]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            p[k] = v
        }
        let realm = p["realm"] ?? ""
        let nonce = p["nonce"] ?? ""
        let qop = p["qop"]
        let ha1 = md5("\(user):\(realm):\(pass)")
        let ha2 = md5("\(method):\(uri)")
        let cnonce = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        let nc = "00000001"
        let response: String
        if let qop = qop, qop.contains("auth") {
            response = md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        } else {
            response = md5("\(ha1):\(nonce):\(ha2)")
        }
        var h = "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
        if let qop = qop, qop.contains("auth") { h += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\"" }
        if let opaque = p["opaque"] { h += ", opaque=\"\(opaque)\"" }
        if let algo = p["algorithm"] { h += ", algorithm=\(algo)" }
        return h
    }

    private func json(_ path: String) async throws -> [String: Any] {
        let data = try await request(path)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - pairing

    private static func signature(timestamp: Int, pin: String) -> String {
        let keyData = Data(base64Encoded: sharedKeyB64)!
        var hmac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: keyData))
        hmac.update(data: Data("\(timestamp)\(pin)".utf8))
        return Data(hmac.finalize()).base64EncodedString()
    }

    private func deviceSpec(_ id: String) -> [String: Any] {
        ["device_name": "macbook", "device_os": "Android", "type": "native",
         "id": id, "app_id": "app.id", "app_name": "PhilipsTVMenubar"]
    }

    /// Step 1: ask the TV to display a PIN. Returns the pairing timestamp.
    func pairRequest() async throws -> (deviceId: String, timestamp: Int) {
        let deviceId = Self.randomDeviceId()
        var access: [String: Any] = ["scope": ["read", "write", "control"]]
        if let feat = (try? await systemInfo())?["featuring"] { access["featuring"] = feat }
        let payload: [String: Any] = ["access": access, "device": deviceSpec(deviceId)]
        let data = try await request("pair/request", method: "POST", body: payload, authed: false)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let authKey = obj["auth_key"] as? String,
              let ts = obj["timestamp"] as? Int else {
            throw PhilipsError.pairing("pair/request failed")
        }
        authUser = deviceId
        authPass = authKey // temporary key, used to sign the grant
        return (deviceId, ts)
    }

    /// Step 2: send the PIN + signature to finish pairing.
    func pairGrant(pin: String, timestamp: Int) async throws {
        guard let deviceId = authUser else { throw PhilipsError.pairing("no pending pairing") }
        let payload: [String: Any] = [
            "auth": ["auth_appId": "1", "auth_timestamp": timestamp,
                     "auth_signature": Self.signature(timestamp: timestamp, pin: pin),
                     "pin": pin],
            "device": deviceSpec(deviceId)
        ]
        let data = try await request("pair/grant", method: "POST", body: payload)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let err = obj?["error_id"] as? String, err != "SUCCESS" {
            throw PhilipsError.pairing("INVALID PIN")
        }
        try save()
    }

    static func randomDeviceId() -> String {
        let hex = "0123456789abcdef"
        return String((0..<32).map { _ in hex.randomElement()! })
    }

    // MARK: - commands

    func systemInfo() async throws -> [String: Any] { try await json("system") }
    func sendKey(_ key: String) async throws { try await request("input/key", method: "POST", body: ["key": key]) }
    func powerState() async throws -> String { (try await json("powerstate"))["powerstate"] as? String ?? "?" }
    func textEntry(_ text: String) async throws { try await request("input/textentry", method: "POST", body: ["textentry": text]) }
    func pointerMove(_ dx: Int, _ dy: Int) async throws { try await request("input/pointer", method: "POST", body: ["x": dx, "y": dy]) }
    func currentActivity() async throws -> String { (try await json("activities/current"))["id"] as? String ?? "" }

    /// `styleName: OFF` is accepted but doesn't turn the lights off; power does.
    func setAmbilightPower(_ on: Bool) async throws {
        try await request("ambilight/power", method: "POST", body: ["power": on ? "On" : "Off"])
    }

    func setAmbilight(style: String, menu: String? = nil, algorithm: String? = nil) async throws {
        var cfg: [String: Any] = ["styleName": style, "isExpert": false]
        if let menu = menu { cfg["menuSetting"] = menu }
        if let algorithm = algorithm { cfg["algorithm"] = algorithm }
        try await request("ambilight/currentconfiguration", method: "POST", body: cfg)
    }

    // MARK: - DIAL (app launch)

    /// Launch an app through the TV's DIAL server (plain HTTP on :56789, no pairing).
    /// JointSpace's /applications is 403 on Titan OS, but DIAL is open. The TV keeps a
    /// per-app Origin allow-list: a POST without the right Origin gets 403
    /// (e.g. YouTube → https://www.youtube.com, Netflix → https://www.netflix.com).
    func launchDIAL(_ app: String, origin: String?) async throws {
        var req = URLRequest(url: URL(string: "http://\(host):56789/apps/\(app)")!)
        req.httpMethod = "POST"
        req.httpBody = Data()
        req.setValue("text/plain; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        if let origin = origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        let (_, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // 201 = launched, 200 = already running and brought to front
        guard code == 200 || code == 201 else {
            AppState.log("HTTP \(code) DIAL \(app)")
            throw PhilipsError.launch("\(app): HTTP \(code)")
        }
    }

    // MARK: - URLSessionDelegate (self-signed TLS + HTTP Digest)

    // Task-level: HTTP Digest challenges are delivered here.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    // Session-level: server-trust (self-signed cert) is delivered here.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else if method == NSURLAuthenticationMethodHTTPDigest {
            // We compute Digest manually in request(); let URLSession return the raw 401.
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum PhilipsError: LocalizedError {
    case pairing(String)
    case launch(String)
    var errorDescription: String? {
        switch self { case .pairing(let m), .launch(let m): return m }
    }
}
