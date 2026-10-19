import Foundation

/// Orange Polska TV decoder (Sagemcom, SoftAtHome middleware) on HDMI 1.
///
/// The box exposes the same local HTTP remote API as Orange France's Livebox decoders
/// (advertised over SSDP as urn:schemas-orange-com:service:X_OrangeSTBRemoteControl:1),
/// no auth:
///   GET http://<box>:8080/remoteControl/cmd?operation=10                 → status
///   GET http://<box>:8080/remoteControl/cmd?operation=01&key=<code>&mode=0 → key press
/// Keys are Linux input keycodes. Status: activeStandbyState "0" = on, "1" = standby;
/// osdContext e.g. HOMEPAGE / LIVE; playedMediaId = current channel id.
/// The box reports wolSupport "0": once it drops off the network it can't be woken remotely.
struct OrangeClient: Sendable {
    let host: String

    static let defaultHost = "192.168.0.244"

    enum Key: Int {
        case power = 116, ok = 352, back = 158, menu = 139
        case up = 103, down = 108, left = 105, right = 106
        case channelUp = 402, channelDown = 403
        case volumeUp = 115, volumeDown = 114, mute = 113
        case playPause = 164, rewind = 168, forward = 159, record = 167, vod = 393
        // digits 0–9 = 512…521 (Orange France mapping; untested here)
        static func digit(_ n: Int) -> Int { 512 + n }
    }

    struct Status {
        var isOn: Bool
        var context: String      // HOMEPAGE, LIVE, …
        var channelId: String?
        var playing: String?     // PLAY / PAUSE
    }

    private func call(_ query: String) async throws -> [String: Any] {
        let url = URL(string: "http://\(host):8080/remoteControl/cmd?\(query)")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let result = obj?["result"] as? [String: Any] ?? [:]
        guard (result["responseCode"] as? String) == "0" else {
            throw OrangeError.remote(result["message"] as? String ?? "hata")
        }
        return result["data"] as? [String: Any] ?? [:]
    }

    func status() async throws -> Status {
        let d = try await call("operation=10")
        return Status(isOn: (d["activeStandbyState"] as? String) == "0",
                      context: d["osdContext"] as? String ?? "",
                      channelId: d["playedMediaId"] as? String,
                      playing: d["playedMediaState"] as? String)
    }

    func press(_ code: Int) async throws {
        _ = try await call("operation=01&key=\(code)&mode=0")
    }

    func press(_ key: Key) async throws { try await press(key.rawValue) }
}

enum OrangeError: LocalizedError {
    case remote(String)
    var errorDescription: String? {
        switch self { case .remote(let m): return m }
    }
}
