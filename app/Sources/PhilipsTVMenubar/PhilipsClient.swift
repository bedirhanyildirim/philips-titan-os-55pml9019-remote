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
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await session.data(for: req)
        return data
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

    func setAmbilight(style: String, menu: String? = nil, algorithm: String? = nil) async throws {
        var cfg: [String: Any] = ["styleName": style, "isExpert": false]
        if let menu = menu { cfg["menuSetting"] = menu }
        if let algorithm = algorithm { cfg["algorithm"] = algorithm }
        try await request("ambilight/currentconfiguration", method: "POST", body: cfg)
    }

    // MARK: - URLSessionDelegate (self-signed TLS + HTTP Digest)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else if method == NSURLAuthenticationMethodHTTPDigest {
            if challenge.previousFailureCount > 0 {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            if let user = authUser, let pass = authPass {
                completionHandler(.useCredential,
                                  URLCredential(user: user, password: pass, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum PhilipsError: LocalizedError {
    case pairing(String)
    var errorDescription: String? {
        switch self { case .pairing(let m): return m }
    }
}
