import Foundation
import Testing
@testable import MarqueeCore

private let inviter = LinkID("00112233445566778899aabbccddeeff")!
private let guest = LinkID("ffeeddccbbaa99887766554433221100")!

struct LinkInviteTests {
    @Test func theCodeRoundTripsANameWithQueryCharacters() throws {
        let invite = LinkInvite(id: inviter, name: "Anu’s iPhone & Co = 1+1 ✨", secret: Data(0..<32))
        #expect(invite.url.absoluteString.hasPrefix("marquee-link://pair?v=1&id=00112233445566778899aabbccddeeff&n="))
        let read = try #require(LinkInvite(string: invite.url.absoluteString))
        #expect(read == invite)
        #expect(read.name == "Anu’s iPhone & Co = 1+1 ✨")
    }

    @Test func otherCodesAreRefused() {
        let secret = Data(0..<32).base64URL
        let id = inviter.description
        #expect(LinkInvite(string: "marquee-link://pair?v=1&id=\(id)&n=A&s=\(secret)") != nil)
        #expect(LinkInvite(string: "lumaremote://pair?v=1&id=\(id)&n=A&s=\(secret)") == nil)
        #expect(LinkInvite(string: "marquee-link://pair?v=2&id=\(id)&n=A&s=\(secret)") == nil)
        #expect(LinkInvite(string: "marquee-link://pair?v=1&id=0011&n=A&s=\(secret)") == nil)
        #expect(LinkInvite(string: "marquee-link://pair?v=1&id=\(id)&n=A&s=\(Data(0..<16).base64URL)") == nil)
        #expect(LinkInvite(string: "marquee-link://pair?v=1&id=\(id)&n=A") == nil)
        #expect(LinkInvite(string: "https://example.com") == nil)
    }

    @Test func namesAreOneShortLine() {
        #expect(LinkName.clean("  Nitin’s\niPhone\t ") == "Nitin’s iPhone")
        #expect(LinkName.clean(String(repeating: "a", count: 60)).count == LinkName.maxLength)
        #expect(LinkName.clean("👨‍👩‍👧 Home") == "👨‍👩‍👧 Home")
    }

    @Test func idsAreHexAndOrderByTheirBytes() throws {
        #expect(LinkID("00112233445566778899AABBCCDDEEFF") == inviter)
        #expect(LinkID("00112233445566778899aabbccddeef") == nil)
        #expect(LinkID("00112233445566778899aabbccddeefg") == nil)
        #expect(inviter < guest)
        let json = try JSONEncoder().encode([inviter])
        #expect(String(decoding: json, as: UTF8.self) == "[\"00112233445566778899aabbccddeeff\"]")
        #expect(try JSONDecoder().decode([LinkID].self, from: json) == [inviter])
        #expect(LinkID.random() != LinkID.random())
    }
}

struct LinkKeysTests {
    @Test func derivationIsHKDFSHA256() {
        // RFC 5869, test case 1.
        let okm = LinkKeys.derive(Data(repeating: 0x0b, count: 22), salt: Data(0..<13), info: Data(0xf0...0xf9), length: 42)
        #expect(okm.linkHex == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    @Test func keysMatchVectorsWorkedOutApart() {
        let secret = Data(0..<32)
        let link = LinkKeys.linkKey(
            secret: secret, inviter: inviter, inviterShare: Data(repeating: 0xaa, count: 32),
            guest: guest, guestShare: Data(repeating: 0x55, count: 32)
        )
        #expect(LinkKeys.pairingKey(secret: secret).linkHex == "50ee511dcf3e4b7d2f92e16e2ff7a11ef28c85bdd03e06ec1b0a46b66ac3c8d7")
        #expect(link.linkHex == "334f627d733b40fe8d2ca32ec2a445a5b3794c78587c1768ec8093d9e6e85e64")
        #expect(LinkKeys.sessionKey(linkKey: link).linkHex == "435448be15685f0f39341ad43f5e7147b87656613531e578106dbbe6977ac38c")
    }

    @Test func theLinkKeyDependsOnRolesSecretAndShares() {
        let secret = Data(0..<32)
        let a = Data(repeating: 0xaa, count: 32)
        let b = Data(repeating: 0x55, count: 32)
        let key = LinkKeys.linkKey(secret: secret, inviter: inviter, inviterShare: a, guest: guest, guestShare: b)
        #expect(key != LinkKeys.linkKey(secret: secret, inviter: guest, inviterShare: b, guest: inviter, guestShare: a))
        #expect(key != LinkKeys.linkKey(secret: Data(1...32), inviter: inviter, inviterShare: a, guest: guest, guestShare: b))
        #expect(key != LinkKeys.linkKey(secret: secret, inviter: inviter, inviterShare: a, guest: guest, guestShare: a))
        #expect(LinkKeys.randomBytes(32).count == 32)
        #expect(LinkKeys.randomBytes(32) != LinkKeys.randomBytes(32))
    }
}

struct LinkMessageTests {
    @Test func everyMessageRoundTrips() throws {
        let playing = LinkNowPlaying(
            title: "Dune", detail: "2021", isPlaying: true, position: 61.5, duration: 9000, hasNext: true,
            subtitles: [LinkSubtitle(id: 7, label: "English")], subtitle: 7
        )
        let messages: [LinkMessage] = [
            .join(LinkIntroduction(id: guest, name: "Anu’s iPhone", share: Data(repeating: 1, count: 32))),
            .welcome(LinkIntroduction(id: inviter, name: "Nitin’s iPhone", share: Data(repeating: 2, count: 32))),
            .hello(name: "Nitin’s iPhone"),
            .input(.move(.left)), .input(.select), .input(.back), .input(.holdBegan), .input(.holdEnded),
            .input(.slide(dx: -12.5, width: 390)), .input(.nudge(seconds: 1.5)),
            .input(.pan(dx: 3.5, dy: -41.25), at: 10_234.5), .input(.panEnded(vx: 0, vy: -840.5), at: 10_234.6),
            .input(.panBegan, at: 10_234.4), .input(.select, at: 10_234.7), .ping(sent: 10_000.25), .pong(sent: 10_000.25, host: 55_000.5),
            .command(.playPause), .command(.skip(seconds: -10)), .command(.next), .command(.subtitle(7)), .command(.subtitle(nil)),
            .command(.volume(step: 1)), .command(.volume(step: -1)), .command(.setVolume(0.375)),
            .cue(.scrubDetent), .cue(.volumeStep), .cue(.volumeLimit),
            .status(LinkStatus(screen: .tv, focus: "Dune", focusDetail: "2021", inPlayer: true, nowPlaying: playing, volume: 0.75)),
            .status(LinkStatus()),
            .unlink,
        ]
        for message in messages {
            #expect(LinkMessage.decode(try message.encoded()) == message)
        }
    }

    @Test func theWireFormStaysReadable() {
        func read(_ json: String) -> LinkMessage? { LinkMessage.decode(Data(json.utf8)) }
        #expect(read(#"{"type":"input","input":"move","move":"up"}"#) == .input(.move(.up)))
        #expect(read(#"{"type":"command","command":"subtitle"}"#) == .command(.subtitle(nil)))
        #expect(read(#"{"type":"cue","cue":"edge"}"#) == .cue(.edge))
        #expect(read(#"{"type":"status","status":{"screen":"glasses","inPlayer":false}}"#) == .status(LinkStatus(screen: .glasses)))
        #expect(read(#"{"type":"command","command":"volume","step":-1}"#) == .command(.volume(step: -1)))
        #expect(read(#"{"type":"command","command":"volume"}"#) == nil)
        #expect(read(#"{"type":"command","command":"setVolume","level":0.5}"#) == .command(.setVolume(0.5)))
        #expect(read(#"{"type":"status","status":{"inPlayer":false,"volume":0.25}}"#) == .status(LinkStatus(volume: 0.25)))
        #expect(read(#"{"type":"input","input":"pan","dx":1,"dy":-2,"at":3.5}"#) == .input(.pan(dx: 1, dy: -2), at: 3.5))
        #expect(read(#"{"type":"input","input":"pan","dx":1}"#) == nil)
        #expect(read(#"{"type":"pong","sent":1}"#) == nil)
        #expect(read(#"{"type":"teleport"}"#) == nil)
        #expect(read(#"{"type":"input","input":"wiggle"}"#) == nil)
        #expect(read(#"{"type":"input","input":"move","move":"sideways"}"#) == nil)
        #expect(read("not json") == nil)
    }

    @Test func volumeMovesInSixteenthsAndStopsAtTheEnds() {
        #expect(LinkVolume.stepped(0.5, by: 1) == 9.0 / 16)
        #expect(LinkVolume.stepped(0.5, by: -1) == 7.0 / 16)
        #expect(LinkVolume.stepped(0.53, by: 1) == 9.0 / 16)
        #expect(LinkVolume.stepped(0.53, by: -1) == 0.5)
        #expect(LinkVolume.stepped(0.98, by: 1) == 1)
        #expect(LinkVolume.stepped(0.02, by: -1) == 0)
        #expect(LinkVolume.stepped(.nan, by: 1) == 1.0 / 16)
        #expect(LinkVolume.stepped(0.3, by: 0) == 0.3)
        #expect(LinkVolume.hitsLimit(1, step: 1) && LinkVolume.hitsLimit(0, step: -1))
        #expect(!LinkVolume.hitsLimit(1, step: -1) && !LinkVolume.hitsLimit(0.5, step: 1))
        let loud = LinkStatus(volume: 7).limited()
        #expect(loud.volume == 1)
        #expect(LinkStatus(volume: .infinity).limited().volume == nil)
    }

    @Test func thePreambleCarriesModeAndCaller() {
        let preamble = LinkPreamble(mode: .pairing, caller: guest)
        #expect(preamble.bytes.count == LinkPreamble.length)
        #expect(LinkPreamble(bytes: preamble.bytes) == preamble)
        var otherVersion = preamble.bytes
        otherVersion[4] = 2
        #expect(LinkPreamble(bytes: otherVersion) == nil)
        #expect(LinkPreamble(bytes: Data("LRMT".utf8) + preamble.bytes.dropFirst(4)) == nil)
        #expect(LinkPreamble(bytes: preamble.bytes.dropLast()) == nil)
    }

    @Test func aLimitedStatusFitsOneFrame() throws {
        let long = String(repeating: "x", count: 500)
        let status = LinkStatus(screen: .tv, focus: long, inPlayer: true, nowPlaying: LinkNowPlaying(
            title: long, isPlaying: true, position: 0, duration: 1,
            subtitles: (0..<200).map { LinkSubtitle(id: $0, label: long) }
        )).limited()
        #expect(status.nowPlaying?.subtitles.count == LinkStatus.maxSubtitles)
        #expect(status.focus?.count == LinkStatus.maxText)
        // The encrypted frame's plaintext limit.
        #expect(try LinkMessage.status(status).encoded().count <= 8192)
    }
}

struct LinkTimingTests {
    @Test func bothPhonesKeepTheSameConnection() {
        #expect(LinkDialing.delay(me: inviter, peer: guest) == .zero)
        #expect(LinkDialing.delay(me: guest, peer: inviter) > .zero)
        // The smaller id's call wins whichever arrived first; a phone's newer call replaces its older one.
        #expect(LinkDialing.keepsNew(existingCaller: guest, newCaller: inviter))
        #expect(!LinkDialing.keepsNew(existingCaller: inviter, newCaller: guest))
        #expect(LinkDialing.keepsNew(existingCaller: guest, newCaller: guest))
        #expect((1...7).map { LinkDialing.retryDelay(failures: $0) } == [2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
    }

    @Test func statusGoesOutOnChangesWhenThePlayheadStraysAndAsAHeartbeat() {
        var pacer = LinkStatusPacer()
        func send(_ status: LinkStatus, at now: TimeInterval) -> Bool { pacer.shouldSend(status, now: now) }
        var status = LinkStatus(screen: .glasses, focus: "Dune", inPlayer: true, nowPlaying: LinkNowPlaying(
            title: "Dune", isPlaying: true, position: 100, duration: 9000
        ))
        #expect(send(status, at: 0))
        status.nowPlaying?.position = 102
        #expect(!send(status, at: 2))
        status.nowPlaying?.position = 105
        #expect(send(status, at: 3))
        status.nowPlaying?.position = 109
        #expect(send(status, at: 8))
        status.nowPlaying?.isPlaying = false
        #expect(send(status, at: 8.5))
        #expect(!send(status, at: 12))
        #expect(send(status, at: 13.5))
        status.focus = "Arrival"
        #expect(send(status, at: 14))
        pacer.reset()
        #expect(send(status, at: 14.5))
    }

    @Test func theControllerRunsThePlayheadOnUpToTheEnd() {
        var playing = LinkNowPlaying(title: "Dune", isPlaying: true, position: 8990, duration: 9000)
        #expect(playing.position(after: 4) == 8994)
        #expect(playing.position(after: 60) == 9000)
        playing.isPlaying = false
        #expect(playing.position(after: 60) == 8990)
    }
}
