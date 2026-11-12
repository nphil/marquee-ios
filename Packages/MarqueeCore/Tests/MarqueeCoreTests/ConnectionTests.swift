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

    @Test func displayAddressReadsTheIPOutOfAPlexDirectName() {
        #expect(Self.remote.displayAddress == "81.2.3.4")
        #expect(Self.remoteV6.displayAddress == "2a00::1")
        #expect(Self.relay.displayAddress == "5.6.7.8:8443")
        #expect(Self.localHTTP.displayAddress == "192.168.1.5")
        #expect(PlexConnection(uri: URL(string: "http://[fe80::1]:8080")!, isLocal: true, isIPv6: true).displayAddress == "[fe80::1]:8080")
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

    @Test func rememberedLocalAddressIsTriedAlone() async throws {
        let transport = FakeTransport { _, _ in Self.identity() }
        let connection = PlexServerConnection(
            server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport,
            remembered: Self.local.uri
        )

        #expect(try await connection.connection() == Self.local)
        #expect(await transport.requests.map(\.url.host) == [Self.local.uri.host])
    }

    @Test func rememberedRemoteAddressStillLetsTheLANAddressWin() async throws {
        let transport = FakeTransport { _, _ in Self.identity() }
        let connection = PlexServerConnection(
            server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport,
            remembered: Self.remote.uri
        )

        #expect(try await connection.connection() == Self.local)
    }

    @Test func lanAddressTakesOverOnceItAnswers() async throws {
        let localHost = Self.local.uri.host
        // The first two LAN probes fail, as they do while iOS asks for Local Network access.
        let transport = FakeTransport { request, earlier in
            if request.url.host == localHost, earlier.filter({ $0.url.host == localHost }).count < 2 {
                throw NetworkFailure.cannotConnect
            }
            return Self.identity()
        }
        let connection = PlexServerConnection(
            server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport
        )

        #expect(try await connection.connection() == Self.remote)
        #expect(await connection.preferLocal() == Self.remote)
        #expect(await connection.preferLocal() == Self.local)
        #expect(await connection.currentConnection == Self.local)

        let probes = await transport.requests.count
        #expect(await connection.preferLocal() == Self.local)
        #expect(await transport.requests.count == probes)
    }

    @Test func probeRoundRecordsWhatEachAddressDid() async throws {
        // The LAN address never answers, as when a VPN routes it nowhere.
        let transport = FakeTransport { request, _ in
            if request.url.host == Self.local.uri.host { try await Task.sleep(for: .seconds(30)) }
            if request.url.host == Self.relay.uri.host { throw NetworkFailure.offline }
            return Self.identity()
        }
        let connection = PlexServerConnection(
            server: Self.server([Self.local, Self.remote, Self.relay]), identity: testIdentity, transport: transport,
            grace: .milliseconds(20)
        )

        #expect(try await connection.connection() == Self.remote)
        let round = try #require(await connection.probeRounds.last)
        #expect(round.picked == Self.remote)
        #expect(round.probes.map(\.connection) == [Self.local, Self.remote, Self.relay])
        #expect(round.probes.map(\.outcome) == [.pending, .answered, .failed(.offline)])
    }

    @Test func probeLinesNameEachAddressItsOutcomeAndTheOneUsed() {
        let round = ProbeRound(started: Date(), probes: [
            .init(connection: Self.local, outcome: .failed(.offline), seconds: 0.012),
            .init(connection: Self.remote, outcome: .answered, seconds: 0.2104),
            .init(connection: Self.relay, outcome: .pending, seconds: 0.2104),
        ], picked: Self.remote)

        #expect(round.lines == [
            "Local 192.168.1.5: offline after 12 ms",
            "Remote 81.2.3.4: answered in 210 ms (used)",
            "Relay 5.6.7.8:8443: no answer after 210 ms",
        ])
    }

    @Test func readMovesToAnotherAddressWhenTheChosenOneStopsAnswering() async throws {
        let localHost = Self.local.uri.host
        let transport = FakeTransport { request, earlier in
            let localUsed = earlier.contains { $0.url.host == localHost && $0.url.path != "/identity" }
            switch (request.url.host == localHost, request.url.path) {
            case (true, "/identity"):
                if localUsed { throw NetworkFailure.cannotConnect }
                return Self.identity()
            case (true, _):
                throw NetworkFailure.timedOut
            case (false, "/identity"):
                return Self.identity()
            default:
                return container(["Directory": [["key": "1", "title": "Films", "type": "movie"]]])
            }
        }
        let library = PlexLibrary(server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport)

        let sections = try await library.sections()

        #expect(sections.map(\.title) == ["Films"])
        #expect(await library.connection.currentConnection == Self.remote)
        let reads = await transport.requests(to: "/library/sections")
        #expect(reads.map(\.url.host) == [localHost, Self.remote.uri.host])
    }

    @Test func writeIsNotRepeatedAfterTheAddressFails() async throws {
        let transport = FakeTransport { request, _ in
            if request.url.path == "/identity" { return Self.identity() }
            throw NetworkFailure.timedOut
        }
        let library = PlexLibrary(server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport)

        await #expect(throws: PlexError.unreachable(.timedOut)) {
            try await library.markWatched("12")
        }
        #expect(await transport.requests(to: "/:/scrobble").count == 1)
    }

    @Test func transcodeStartsOnTheAddressThatAnsweredItsDecision() async throws {
        let localHost = Self.local.uri.host
        let transport = FakeTransport { request, earlier in
            let localUsed = earlier.contains { $0.url.host == localHost && $0.url.path != "/identity" }
            switch (request.url.host == localHost, request.url.path) {
            case (true, "/identity"):
                if localUsed { throw NetworkFailure.cannotConnect }
                return Self.identity()
            case (true, _):
                throw NetworkFailure.timedOut
            case (false, "/identity"):
                return Self.identity()
            default:
                return container([:])
            }
        }
        let library = PlexLibrary(server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport)
        let item = try decode(PlexMetadata.self, ["ratingKey": "12", "key": "/library/metadata/12", "Media": [["id": 1, "Part": [["id": 7]]]]])
        let route = PlaybackRoute(
            kind: .serverTranscode, reasons: [.videoCodec("vc1")], audio: nil, audioIsStandIn: false,
            convertsAudio: false, reencodesVideo: true, subtitle: .none
        )

        let url = try await library.transcodeURL(TranscodeRequest(item: item, route: route, session: "s-2"))

        let decisions = await transport.requests(to: "/video/:/transcode/universal/decision")
        #expect(decisions.map(\.url.host) == [localHost, Self.remote.uri.host])
        #expect(decisions.map { $0.url.query("location") } == ["lan", "wan"])
        #expect(decisions.allSatisfy { $0.url.query("session") == "s-2" })
        #expect(url.host == Self.remote.uri.host && url.path == "/video/:/transcode/universal/start.m3u8")
        #expect(url.query("location") == "wan" && url.query("session") == "s-2")
    }

    @Test func failedDownloadDropsOnlyTheAddressItWentTo() async throws {
        let transport = FakeTransport { _, _ in Self.identity() }
        let connection = PlexServerConnection(server: Self.server([Self.local, Self.remote]), identity: testIdentity, transport: transport)
        _ = try await connection.connection()
        let elsewhere = try #require(URL(string: "https://81-2-3-4.abc.plex.direct:32400/library/parts/7/file.mkv"))
        let here = try #require(URL(string: "https://192-168-1-5.abc.plex.direct:32400/library/parts/7/file.mkv?download=1"))

        await connection.reportFailure(at: elsewhere)
        let kept = await connection.currentConnection
        await connection.reportFailure(at: here)

        #expect(kept == Self.local)
        #expect(await connection.currentConnection == nil)
    }
}
