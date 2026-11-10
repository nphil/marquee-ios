import Foundation
import Testing
@testable import MarqueeCore

struct NetworkPlaceTests {
    static let lan = PlexConnection(uri: URL(string: "https://192-168-1-5.abc.plex.direct:32400")!, isLocal: true)
    static let wan = PlexConnection(uri: URL(string: "https://81-2-3-4.abc.plex.direct:32400")!, isLocal: false)
    static let relay = PlexConnection(uri: URL(string: "https://5-6-7-8.abc.plex.direct:8443")!, isLocal: false, isRelay: true)
    static let named = PlexConnection(uri: URL(string: "https://plex.example.com")!, isLocal: true)

    @Test func subnetLatencyAndLocalFlagNeverProveHome() {
        for network in [true, false, nil] as [Bool?] {
            for latency in [0.0, 0.006, 0.06, nil] as [TimeInterval?] {
                for connection in [Self.lan, Self.wan, Self.named] {
                    let place = NetworkPlace.of(connection, onPhoneNetwork: network, localAddress: "192.168.1.20", roundTrip: latency)
                    #expect(!place.isHome)
                }
            }
        }
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: true, localAddress: nil, roundTrip: nil) == .away(.remote))
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: false, localAddress: nil, roundTrip: nil) == .away(.tunnel))
        #expect(NetworkPlace.of(Self.wan, onPhoneNetwork: false, localAddress: nil, roundTrip: nil) == .away(.remote))
        #expect(NetworkPlace.of(Self.named, onPhoneNetwork: nil, localAddress: nil, roundTrip: nil) == .away(.remote))
    }

    @Test func relayAndTunnelClassificationTakesPrecedence() {
        #expect(NetworkPlace.of(Self.relay, onPhoneNetwork: true, localAddress: "100.101.5.6", roundTrip: 0) == .away(.relay))
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: true, localAddress: "100.101.5.6", roundTrip: 0) == .away(.tunnel))
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: true, localAddress: "fd7a:115c:a1e0::12", roundTrip: 0) == .away(.tunnel))
        let tailnet = PlexConnection(uri: URL(string: "http://100.88.1.2:32400")!, isLocal: true)
        #expect(NetworkPlace.of(tailnet, onPhoneNetwork: nil, localAddress: nil, roundTrip: nil) == .away(.tunnel))
        #expect(NetworkPlace.isTunnel("100.64.0.0"))
        #expect(NetworkPlace.isTunnel("100.127.255.255"))
        #expect(!NetworkPlace.isTunnel("100.63.0.1"))
        #expect(!NetworkPlace.isTunnel("100.128.0.1"))
    }
}

struct HomePresenceTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func unknownFailureAndProofTransitions() {
        var presence = HomePresence(gracePeriod: 10)
        #expect(presence.verdict == .unknown)
        #expect(presence.verdict(at: start) == .unknown)
        presence.proofFailed(at: start)
        #expect(presence.verdict == .away)
        presence.proofSucceeded(at: start)
        #expect(presence.verdict == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(100)) == .home)
        presence.proofFailed(at: start.addingTimeInterval(100))
        #expect(presence.verdict == .away)
        presence.proofSucceeded(at: start.addingTimeInterval(101))
        #expect(presence.verdict == .home)
    }

    @Test func graceRunsFromLastSuccessAndExpiresAtBoundary() {
        var presence = HomePresence(gracePeriod: 10)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(2))
        #expect(presence.verdict == .home)
        presence.proofFailed(at: start.addingTimeInterval(9))
        #expect(presence.verdict(at: start.addingTimeInterval(9.999)) == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(10)) == .away)
        presence.proofFailed(at: start.addingTimeInterval(11))
        #expect(presence.verdict == .away)
        presence.proofSucceeded(at: start.addingTimeInterval(12))
        presence.proofFailed(at: start.addingTimeInterval(21))
        #expect(presence.verdict == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(22)) == .away)
    }

    @Test func successDuringGraceRestartsIt() {
        var presence = HomePresence(gracePeriod: 10)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(5))
        presence.proofSucceeded(at: start.addingTimeInterval(6))
        #expect(presence.verdict(at: start.addingTimeInterval(10)) == .home)
        presence.proofFailed(at: start.addingTimeInterval(15))
        #expect(presence.verdict == .home)
        #expect(presence.verdict(at: start.addingTimeInterval(16)) == .away)
    }

    @Test func invalidationImmediatelyForgetsProofOnNetworkChange() {
        var presence = HomePresence(gracePeriod: 10)
        presence.invalidate()
        #expect(presence.verdict == .unknown)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(1))
        presence.invalidate()
        #expect(presence.verdict == .unknown)
        #expect(presence.verdict(at: start.addingTimeInterval(2)) == .unknown)
        presence.proofFailed(at: start.addingTimeInterval(2))
        #expect(presence.verdict == .away)
        presence.invalidate()
        #expect(presence.verdict == .unknown)
        presence.proofSucceeded(at: start.addingTimeInterval(3))
        #expect(presence.verdict == .home)
    }

    @Test func zeroGraceAndClockMovingBackwardsFailClosed() {
        var immediate = HomePresence(gracePeriod: 0)
        immediate.proofSucceeded(at: start)
        immediate.proofFailed(at: start)
        #expect(immediate.verdict == .away)

        var presence = HomePresence(gracePeriod: 10)
        presence.proofSucceeded(at: start)
        presence.proofFailed(at: start.addingTimeInterval(-1))
        #expect(presence.verdict == .away)
        #expect(presence.verdict(at: start.addingTimeInterval(1)) == .away)
    }
}
