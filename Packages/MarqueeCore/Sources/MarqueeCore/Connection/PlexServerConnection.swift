import Foundation

/// Picks and remembers the address used to reach one server.
///
/// The first request probes every address at once with `GET /identity` and takes the best-ranked one that
/// answers as this server (`ConnectionRanking`). The winner is kept until a request through it fails;
/// the next request then probes again. A remembered address from an earlier launch is tried alone first,
/// which skips waiting on LAN addresses while away from home. The app calls `refresh()` when the network
/// changes, so a phone that comes home moves back to the LAN address.
public actor PlexServerConnection {
    public nonisolated let server: PlexServer
    private let identity: PlexClientIdentity
    private let transport: any PlexTransport
    private let probeTimeout: TimeInterval
    private let grace: Duration
    private var remembered: URL?
    private var current: PlexConnection?
    private var probe: Task<PlexConnection, any Error>?

    /// - Parameters:
    ///   - remembered: The address that won last time, from `current`.
    ///   - probeTimeout: Seconds an address gets to answer `/identity`.
    ///   - grace: Once some address answered, how long better-ranked ones still get.
    public init(
        server: PlexServer,
        identity: PlexClientIdentity,
        transport: any PlexTransport = URLSessionTransport(),
        remembered: URL? = nil,
        probeTimeout: TimeInterval = 3,
        grace: Duration = .milliseconds(750)
    ) {
        self.server = server
        self.identity = identity
        self.transport = transport
        self.remembered = remembered
        self.probeTimeout = probeTimeout
        self.grace = grace
    }

    /// The address in use, if one was chosen. Persist its `uri` to pass back as `remembered`.
    public var currentConnection: PlexConnection? { current }

    /// The address to use, probing first when none is chosen. Concurrent callers share one probe.
    public func connection() async throws -> PlexConnection {
        if let current { return current }
        if let probe { return try await probe.value }
        let task = Task { try await self.choose() }
        probe = task
        defer { probe = nil }
        let winner = try await task.value
        current = winner
        remembered = winner.uri
        return winner
    }

    /// Records that a request through `connection` got no answer; the next request probes again.
    public func reportFailure(of connection: PlexConnection) {
        if current == connection { current = nil }
        if remembered == connection.uri { remembered = nil }
    }

    /// Probes every address again, e.g. after the phone changed networks.
    public func refresh() async throws -> PlexConnection {
        current = nil
        remembered = nil
        return try await connection()
    }

    private func choose() async throws -> PlexConnection {
        let ordered = ConnectionRanking.ordered(server.connections, httpsRequired: server.httpsRequired)
        guard !ordered.isEmpty else { throw PlexError.noConnections }
        if let remembered, let previous = ordered.first(where: { $0.uri == remembered }), await answers(previous) {
            return previous
        }
        return try await probeAll(ordered)
    }

    private enum ProbeEvent: Sendable {
        case answered(Int, Bool)
        case graceOver
    }

    private nonisolated func probeAll(_ ordered: [PlexConnection]) async throws -> PlexConnection {
        try await withThrowingTaskGroup(of: ProbeEvent.self) { group in
            for (index, connection) in ordered.enumerated() {
                group.addTask { .answered(index, await self.answers(connection)) }
            }
            var outcomes = [ConnectionRanking.ProbeOutcome?](repeating: nil, count: ordered.count)
            var graceStarted = false
            var graceExpired = false
            while let event = try await group.next() {
                switch event {
                case .answered(let index, let reachable): outcomes[index] = reachable ? .reachable : .failed
                case .graceOver: graceExpired = true
                }
                switch ConnectionRanking.pick(outcomes, graceExpired: graceExpired) {
                case .use(let index):
                    group.cancelAll()
                    return ordered[index]
                case .noneReachable:
                    group.cancelAll()
                    throw PlexError.unreachable(.cannotConnect)
                case .wait:
                    if !graceStarted, outcomes.contains(.reachable) {
                        graceStarted = true
                        let grace = self.grace
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .graceOver
                        }
                    }
                }
            }
            throw PlexError.unreachable(.cannotConnect)
        }
    }

    /// Whether `connection` answers as this server. Probes carry no token: an address can belong to a
    /// different machine, and `/identity` needs none.
    private nonisolated func answers(_ connection: PlexConnection) async -> Bool {
        guard let url = PlexURL.make(base: connection.uri, path: "/identity") else { return false }
        let request = PlexRequest(url: url, headers: identity.headers(token: nil), timeout: probeTimeout, isIdempotent: false)
        guard let response = try? await transport.send(request), (200..<300).contains(response.status) else { return false }
        let identifier = (try? PlexJSON.decode(PlexEnvelope.self, from: response.body))?.container.machineIdentifier
        return identifier == nil || identifier == server.clientIdentifier
    }
}
