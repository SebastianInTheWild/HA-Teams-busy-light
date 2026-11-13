import Darwin

/// An IPv4 or IPv6 network in CIDR notation, e.g. 192.168.1.0/24. Without a
/// prefix length it stands for a single address.
struct IPNetwork {
    let bytes: [UInt8]
    let prefix: Int

    init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard let host = parts.first, parts.count <= 2, let bytes = IPNetwork.parse(String(host)) else { return nil }
        let maxPrefix = bytes.count * 8
        if parts.count == 2 {
            guard let prefix = Int(parts[1]), (0...maxPrefix).contains(prefix) else { return nil }
            self.prefix = prefix
        } else {
            prefix = maxPrefix
        }
        self.bytes = bytes
    }

    init(bytes: [UInt8], prefix: Int) {
        self.bytes = bytes
        self.prefix = prefix
    }

    private static func parse(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    func contains(_ address: [UInt8]) -> Bool {
        guard address.count == bytes.count else { return false }
        var bits = prefix
        for index in bytes.indices where bits > 0 {
            let mask = bits >= 8 ? UInt8(0xFF) : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if bytes[index] & mask != address[index] & mask {
                return false
            }
            bits -= 8
        }
        return true
    }

    /// Network address with prefix, e.g. "192.168.1.0/24"
    var description: String {
        var masked = bytes
        var bits = prefix
        for index in masked.indices {
            let mask = bits >= 8 ? UInt8(0xFF) : bits <= 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            masked[index] &= mask
            bits -= 8
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = masked.count == 4 ? AF_INET : AF_INET6
        _ = masked.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return "\(String(cString: buffer))/\(prefix)"
    }
}

/// "Send only in these networks": Teams Busy Light sends only while the Mac
/// has an address in one of the networks, so it does not send through an
/// externally reachable webhook URL while on the road.
enum HomeNetwork {
    /// Splits the entered list (commas, semicolons or spaces). Returns nil
    /// and the first invalid entry if an entry is not a valid network.
    static func parse(_ text: String) -> (networks: [IPNetwork]?, invalid: String?) {
        var networks: [IPNetwork] = []
        for entry in split(text) {
            guard let network = IPNetwork(entry) else { return (nil, entry) }
            networks.append(network)
        }
        return (networks, nil)
    }

    /// True when no networks are set or an active interface has an address in one of them
    static func isHome(_ text: String) -> Bool {
        guard let networks = parse(text).networks, !networks.isEmpty else { return true }
        return interfaces().contains { address in networks.contains { $0.contains(address.bytes) } }
    }

    /// IPv4 networks of the active local interfaces (no loopback, no VPN
    /// tunnels, no self-assigned addresses), for "Add Current Network"
    static func currentNetworks() -> [String] {
        var result: [String] = []
        for address in interfaces() where address.bytes.count == 4 && !address.pointToPoint && address.bytes[0..<2] != [169, 254] {
            let network = IPNetwork(bytes: address.bytes, prefix: address.prefix).description
            if !result.contains(network) {
                result.append(network)
            }
        }
        return result
    }

    /// Current networks that are neither covered by the home networks nor
    /// ignored; only while home networks are set (otherwise everything is sent)
    static func newNetworks(home: String, ignored: String) -> [String] {
        guard let homeNetworks = parse(home).networks, !homeNetworks.isEmpty else { return [] }
        let ignoredEntries = Set(split(ignored))
        return currentNetworks().filter { entry in
            guard let network = IPNetwork(entry) else { return false }
            return !ignoredEntries.contains(entry) && !homeNetworks.contains { $0.contains(network.bytes) }
        }
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
    }

    /// Appends networks to a list, without duplicates
    static func adding(_ networks: [String], to text: String) -> String {
        var entries = split(text)
        for network in networks where !entries.contains(network) {
            entries.append(network)
        }
        return entries.joined(separator: ", ")
    }

    private struct InterfaceAddress {
        let bytes: [UInt8]
        let prefix: Int
        let pointToPoint: Bool
    }

    private static func interfaces() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr
            else { continue }
            guard let bytes = addressBytes(of: address) else { continue }
            let mask = entry.pointee.ifa_netmask.flatMap { addressBytes(of: $0) } ?? []
            let prefix = mask.count == bytes.count ? mask.reduce(0) { $0 + $1.nonzeroBitCount } : bytes.count * 8
            result.append(InterfaceAddress(bytes: bytes, prefix: prefix, pointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        return result
    }

    private static func addressBytes(of address: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var value = pointer.pointee.sin_addr
                return withUnsafeBytes(of: &value) { Array($0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var value = pointer.pointee.sin6_addr
                return withUnsafeBytes(of: &value) { Array($0) }
            }
        default:
            return nil
        }
    }
}
