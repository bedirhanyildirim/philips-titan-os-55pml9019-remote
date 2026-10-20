import Foundation

/// Wake-on-LAN magic packet. The TV drops off the network in deep standby (e.g. when the
/// Orange box turns it off over HDMI-CEC); a magic packet to its Ethernet or Wi-Fi MAC
/// powers it fully back on (verified on the 55PML9019, WoWLAN enabled).
enum WakeOnLAN {
    /// Default MACs of this TV (Titan `info` topic: eth_mac_addr / wlan_mac_addr).
    static let tvMACs = ["0c:ca:fb:7e:64:b2", "38:1b:9e:be:3e:86"]

    static func wake(_ macs: [String], broadcast: String = "255.255.255.255") {
        for mac in macs {
            let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 6 else { continue }
            var packet = [UInt8](repeating: 0xFF, count: 6)
            for _ in 0..<16 { packet += bytes }
            send(packet, to: broadcast)
        }
    }

    private static func send(_ packet: [UInt8], to host: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        _ = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
