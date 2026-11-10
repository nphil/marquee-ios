import Foundation
import Network

/// The parts of the phone's network that decide which server address works. Joining another Wi-Fi
/// network changes the gateway but not the interface, so both are compared.
struct NetworkPath: Equatable, Sendable {
    let isConnected: Bool
    let interfaces: [String]
    let gateways: [String]

    private init(_ path: NWPath) {
        isConnected = path.status == .satisfied
        interfaces = path.availableInterfaces.map(\.name)
        gateways = path.gateways.map { "\($0)" }
    }

    /// The current path, then every change to it.
    static func updates() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            let monitor = Monitor()
            monitor.start { continuation.yield(NetworkPath($0)) }
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }

    /// Whether the link is metered, now and on each change: cellular, a personal hotspot or Low Data Mode.
    static func meteredUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = Monitor()
            monitor.start { continuation.yield($0.isExpensive || $0.isConstrained) }
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }

    /// Whether an IPv4 address is on a network one of the phone's own interfaces is attached to; nil for a host
    /// name or IPv6. VPN tunnels are point-to-point and do not count, so an address reached through a VPN's route
    /// into the home network is not attached.
    nonisolated static func isOnAttachedNetwork(_ host: String?) -> Bool? {
        guard let host else { return nil }
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            let flags = Int32(bitPattern: current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = current.pointee.ifa_netmask
            else { continue }
            let own = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if own & mask == target.s_addr & mask { return true }
        }
        return false
    }

    /// NWPathMonitor is thread-safe; the box only lets the stream's termination handler reach it.
    private final class Monitor: @unchecked Sendable {
        private let monitor = NWPathMonitor()

        func start(_ handler: @escaping @Sendable (NWPath) -> Void) {
            monitor.pathUpdateHandler = handler
            monitor.start(queue: DispatchQueue(label: "com.nphil.marquee.network"))
        }

        func cancel() {
            monitor.cancel()
        }
    }
}
