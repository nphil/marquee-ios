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
