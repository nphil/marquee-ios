import Foundation
import Testing
@testable import MarqueeCore

struct ConnectionTests {
    static let local = PlexConnection(uri: URL(string: "https://192-168-1-5.abc.plex.direct:32400")!, isLocal: true)
    static let localHTTP = PlexConnection(uri: URL(string: "http://192.168.1.5:32400")!, isLocal: true)
    static let remote = PlexConnection(uri: URL(string: "https://81-2-3-4.abc.plex.direct:32400")!, isLocal: false)
    static let remoteV6 = PlexConnection(uri: URL(string: "https://2a00--1.abc.plex.direct:32400")!, isLocal: false, isIPv6: true)
    static let relay = PlexConnection(uri: URL(string: "https://5-6-7-8.abc.plex.direct:8443")!, isLocal: false, isRelay: true)

    static func server(_ connections: [PlexConnection]) -> PlexServer {
        PlexServer(name: "Home", clientIdentifier: "machine-1", accessToken: "server-token", connections: connections)
    }

    /// `/identity` as the given machine.
    static func identity(_ machine: String = "machine-1") -> PlexHTTPResponse {
        container(["machineIdentifier": machine])
    }

    @Test func addressesRankLocalThenRemoteThenRelay() {
        let all = [Self.relay, Self.remoteV6, Self.localHTTP, Self.remote, Self.local, Self.remote]

        #expect(ConnectionRanking.ordered(all, httpsRequired: false)
            == [Self.local, Self.localHTTP, Self.remote, Self.remoteV6, Self.relay])
        #expect(ConnectionRanking.ordered(all, httpsRequired: true)
            == [Self.local, Self.remote, Self.remoteV6, Self.relay])
    }

    @Test func betterRankedAddressIsAwaitedUntilGraceRunsOut() {
        #expect(ConnectionRanking.pick([nil, .reachable]) == .wait)
        #expect(ConnectionRanking.pick([nil, .reachable], graceExpired: true) == .use(1))
        #expect(ConnectionRanking.pick([.failed, .reachable, nil]) == .use(1))
        #expect(ConnectionRanking.pick([.failed, .failed]) == .noneReachable)
    }

    @Test func probeSkipsAnAddressAnsweringAsAnotherServer() async throws {
        let transport = FakeTransport { request, _ in
            request.url.host == Self.local.uri.host ? Self.identity("other-machine") : Self.identity()
        }
        let connection = PlexServerConnection(
            server: Self.server([Self.relay, Self.remote, Self.local]), identity: testIdentity, transport: transport
        )

        let winner = try await connection.connection()
        let probes = await transport.requests.count
        let again = try await connection.connection()

        #expect(winner == Self.remote && again == Self.remote)
        #expect(await transport.requests.count == probes)
        #expect(await transport.requests.allSatisfy { $0.headers[PlexHeader.token] == nil })
    }

    @Test func rememberedAddressIsTriedAloneUntilItFails() async throws {
        let transport = FakeTransport { _, _ in Self.identity() }
        let connection = PlexServerConnection(
            server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport,
            remembered: Self.remote.uri
        )

        #expect(try await connection.connection() == Self.remote)
        #expect(await transport.requests.map(\.url.host) == [Self.remote.uri.host])

        await connection.reportFailure(of: Self.remote)

        #expect(try await connection.connection() == Self.local)
    }
}
