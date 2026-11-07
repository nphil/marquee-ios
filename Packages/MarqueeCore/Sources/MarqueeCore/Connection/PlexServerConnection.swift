import Foundation

/// Picks and remembers the address used to reach one server.
///
/// The first request probes every address at once with `GET /identity` and takes the best-ranked one that
/// answers as this server (`ConnectionRanking`); a LAN address still gets `grace` after a remote one
/// answers first. The winner is kept until a request through it fails; the next request then probes
/// again. A remembered LAN address from an earlier launch is tried alone first, so a phone at home skips
/// the probe; a remembered remote one is not (`ConnectionRanking.triesAlone`). While a remote or relay
/// address is in use, `preferLocal()` probes the better ones again: the app calls it when it comes to the
/// foreground, which is also when iOS's Local Network prompt closes, and `refresh()` when the network
/// changes.
public actor PlexServerConnection {
    public nonisolated let server: PlexServer
    private let identity: PlexClientIdentity
    private let transport: any PlexTransport
    private let probeTimeout: TimeInterval
    private let grace: Duration
    private var remembered: URL?
    private var current: PlexConnection?
    private var probe: Task<PlexConnection, any Error>?
    /// The latest probe rounds, oldest first.
    public private(set) var probeRounds: [ProbeRound] = []

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

    /// While a remote or relay address is in use, probes the better-ranked addresses and moves to the
    /// best one that answers. Requests keep the current address meanwhile. Returns the address in use.
    public func preferLocal() async -> PlexConnection? {
        guard let before = current else { return nil }
        let better = ConnectionRanking.upgrades(from: before, in: ordered)
        guard !better.isEmpty else { return current }
        let round = await probeAll(better)
        log(round)
        guard let found = round.picked else { return current }
        // A failure report or a refresh during the probe has already decided.
        if current == before {
            current = found
            remembered = found.uri
        }
        return current
    }

    private var ordered: [PlexConnection] {
        ConnectionRanking.ordered(server.connections, httpsRequired: server.httpsRequired)
    }

    private func choose() async throws -> PlexConnection {
        let ordered = self.ordered
        guard !ordered.isEmpty else { throw PlexError.noConnections }
        if let remembered, let previous = ordered.first(where: { $0.uri == remembered }),
           ConnectionRanking.triesAlone(previous) {
            let round = await probeAll([previous])
            log(round)
            if let picked = round.picked { return picked }
        }
        let round = await probeAll(ordered)
        log(round)
        guard let picked = round.picked else { throw PlexError.unreachable(.cannotConnect) }
        return picked
    }

    private func log(_ round: ProbeRound) {
        probeRounds.append(round)
        if probeRounds.count > 8 { probeRounds.removeFirst(probeRounds.count - 8) }
    }

    private enum ProbeEvent: Sendable {
        case answered(Int, ProbeRound.Probe.Outcome)
        case graceOver
    }

    private nonisolated func probeAll(_ ordered: [PlexConnection]) async -> ProbeRound {
        let started = Date()
        let clock = ContinuousClock()
        let start = clock.now
        return await withTaskGroup(of: ProbeEvent.self) { group in
            for (index, connection) in ordered.enumerated() {
                group.addTask { .answered(index, await self.identify(connection)) }
            }
            var probes = [ProbeRound.Probe?](repeating: nil, count: ordered.count)
            var graceStarted = false
            var graceExpired = false
            var picked: Int?
            pick: while let event = await group.next() {
                switch event {
                case .answered(let index, let outcome):
                    probes[index] = ProbeRound.Probe(connection: ordered[index], outcome: outcome, seconds: (clock.now - start) / .seconds(1))
                case .graceOver:
                    graceExpired = true
                }
                let outcomes = probes.map { entry in entry.map { $0.outcome == .answered ? ConnectionRanking.ProbeOutcome.reachable : .failed } }
                switch ConnectionRanking.pick(outcomes, graceExpired: graceExpired) {
                case .use(let index):
                    picked = index
                    break pick
                case .noneReachable:
                    break pick
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
            group.cancelAll()
            let pickedAt = (clock.now - start) / .seconds(1)
            return ProbeRound(
                started: started,
                probes: ordered.indices.map { probes[$0] ?? ProbeRound.Probe(connection: ordered[$0], outcome: .pending, seconds: pickedAt) },
                picked: picked.map { ordered[$0] }
            )
        }
    }

    /// How `connection` answers `/identity`. Probes carry no token: an address can belong to a different
    /// machine, and `/identity` needs none.
    private nonisolated func identify(_ connection: PlexConnection) async -> ProbeRound.Probe.Outcome {
        guard let url = PlexURL.make(base: connection.uri, path: "/identity") else { return .failed(.other) }
        let request = PlexRequest(url: url, headers: identity.headers(token: nil), timeout: probeTimeout, isIdempotent: false)
        let response: PlexHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let failure as NetworkFailure {
            return .failed(failure)
        } catch {
            return .pending
        }
        guard (200..<300).contains(response.status) else { return .status(response.status) }
        let identifier = (try? PlexJSON.decode(PlexEnvelope.self, from: response.body))?.container.machineIdentifier
        return identifier == nil || identifier == server.clientIdentifier ? .answered : .otherServer
    }
}
