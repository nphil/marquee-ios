import Foundation
import Testing
@testable import MarqueeCore

struct NetworkPlaceTests {
    static let lan = PlexConnection(uri: URL(string: "https://192-168-1-5.abc.plex.direct:32400")!, isLocal: true)
    static let wan = PlexConnection(uri: URL(string: "https://81-2-3-4.abc.plex.direct:32400")!, isLocal: false)
    static let relay = PlexConnection(uri: URL(string: "https://5-6-7-8.abc.plex.direct:8443")!, isLocal: false, isRelay: true)
    static let named = PlexConnection(uri: URL(string: "https://plex.example.com")!, isLocal: true)

    @Test func theServersOwnNetworkIsHomeAndItsLANAddressFromElsewhereIsATunnel() {
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: true, localAddress: "192.168.1.20", roundTrip: 0.004) == .home)
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: false, localAddress: "10.0.0.7", roundTrip: 0.004) == .away(.tunnel))
        #expect(NetworkPlace.of(Self.wan, onPhoneNetwork: false, localAddress: "10.0.0.7", roundTrip: 0.004) == .away(.remote))
        #expect(NetworkPlace.of(Self.relay, onPhoneNetwork: true, localAddress: nil, roundTrip: nil) == .away(.relay))
    }

    @Test func aTailscaleAddressOnEitherEndIsATunnel() {
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: true, localAddress: "100.101.5.6", roundTrip: 0.004) == .away(.tunnel))
        #expect(NetworkPlace.of(Self.lan, onPhoneNetwork: true, localAddress: "fd7a:115c:a1e0::12", roundTrip: 0.004) == .away(.tunnel))
        let tailnet = PlexConnection(uri: URL(string: "http://100.88.1.2:32400")!, isLocal: true)
        #expect(NetworkPlace.of(tailnet, onPhoneNetwork: nil, localAddress: nil, roundTrip: nil) == .away(.tunnel))
        // Carrier-grade NAT space is 100.64.0.0/10.
        #expect(!NetworkPlace.isTunnel("100.63.0.1") && !NetworkPlace.isTunnel("100.128.0.1"))
    }

    @Test func aHostNameIsHomeOnlyWhenPlexCallsItLocalAndItAnswersFast() {
        #expect(Self.named.ipAddress == nil)
        #expect(NetworkPlace.of(Self.named, onPhoneNetwork: nil, localAddress: "192.168.1.20", roundTrip: 0.006) == .home)
        #expect(NetworkPlace.of(Self.named, onPhoneNetwork: nil, localAddress: "192.168.1.20", roundTrip: 0.06) == .away(.remote))
        var remoteName = Self.named
        remoteName.isLocal = false
        #expect(NetworkPlace.of(remoteName, onPhoneNetwork: nil, localAddress: "192.168.1.20", roundTrip: 0.006) == .away(.remote))
    }
}
