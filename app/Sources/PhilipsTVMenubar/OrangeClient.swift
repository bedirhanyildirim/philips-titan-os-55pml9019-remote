import Foundation

/// Orange TV decoder (Orange Polska Sagemcom / SoftAtHome; same API as Orange France
/// Livebox decoders). Optional: found by SSDP at startup; the UI only shows it when found.
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

    /// Find an Orange decoder on the LAN: SSDP M-SEARCH for its remote-control service.
    /// Returns the box's IP, or nil if none answered within `timeout` seconds.
    static func discover(timeout: Double = 3) async -> String? {
        await Task.detached { ssdpSearch(st: "urn:schemas-orange-com:service:X_OrangeSTBRemoteControl:1",
                                         timeout: timeout) }.value
    }

    private static func ssdpSearch(st: String, timeout: Double) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dst.sin_addr)
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
        let bytes = Array(msg.utf8)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSend = Date.distantPast
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            if Date().timeIntervalSince(lastSend) > 1 {          // resend once a second
                _ = withUnsafePointer(to: &dst) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                lastSend = Date()
            }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let reply = String(decoding: buf[0..<n], as: UTF8.self)
            guard reply.localizedCaseInsensitiveContains(st) else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            return String(cString: ip)
        }
        return nil
    }

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
