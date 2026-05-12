import Foundation
import Darwin

enum NetworkInterfaces {
    struct Interface: Identifiable, Hashable {
        let name: String
        let address: String
        var id: String { "\(name):\(address)" }
    }

    /// Returns active IPv4 addresses on the host, excluding loopback and down interfaces.
    static func activeIPv4Addresses() -> [Interface] {
        var result: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = current {
            defer { current = ptr.pointee.ifa_next }
            let entry = ptr.pointee

            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: entry.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let err = getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard err == 0 else { continue }
            let address = String(cString: host)
            result.append(Interface(name: name, address: address))
        }
        // Stable, predictable order
        return result.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.address < rhs.address : lhs.name < rhs.name
        }
    }
}
