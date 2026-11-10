import Foundation
import Testing
@testable import MarqueeCore

struct FormatBadgeTests {
    private func stream(_ json: String) throws -> PlexStream {
        try JSONDecoder().decode(PlexStream.self, from: Data(json.utf8))
    }

    private func route(_ kind: PlaybackRoute.Kind = .directPlay, reasons: [RouteReason] = [], converts: Bool = false,
                       reencodes: Bool = false, size: String? = nil) -> PlaybackRoute {
        PlaybackRoute(
            kind: kind, reasons: reasons, audio: nil, audioIsStandIn: false, convertsAudio: converts,
            reencodesVideo: reencodes, maxVideoBitrateKbps: nil, videoResolution: size, subtitle: .none
        )
    }

    @Test func sizeComesFromTheWidthSoWidescreenFilmsAreNotDemoted() throws {
        let scope = try stream(#"{"streamType":1,"width":1920,"height":800}"#)
        #expect(FormatBadge.make(video: scope, media: nil, audio: nil, route: route()).resolution == .p1080)
        let uhd = try stream(#"{"streamType":1,"width":3840,"height":1600}"#)
        #expect(FormatBadge.make(video: uhd, media: nil, audio: nil, route: route()).resolution == .uhd4K)
        let dvd = try stream(#"{"streamType":1,"width":720,"height":480}"#)
        #expect(FormatBadge.make(video: dvd, media: nil, audio: nil, route: route()).resolution == .sd)
    }

    @Test func rangesAreReadFromTheTransferAndDolbyVisionRecord() throws {
        let hdr = try stream(#"{"streamType":1,"width":3840,"colorTrc":"smpte2084"}"#)
        #expect(FormatBadge.make(video: hdr, media: nil, audio: nil, route: route()).range == .hdr10)
        let plus = try stream(#"{"streamType":1,"width":3840,"colorTrc":"smpte2084","extendedDisplayTitle":"4K (HEVC Main 10 HDR10+)"}"#)
        #expect(FormatBadge.make(video: plus, media: nil, audio: nil, route: route()).range == .hdr10Plus)
        let hlg = try stream(#"{"streamType":1,"width":1920,"colorTrc":"arib-std-b67"}"#)
        #expect(FormatBadge.make(video: hlg, media: nil, audio: nil, route: route()).range == .hlg)
        let dv = try stream(#"{"streamType":1,"width":3840,"colorTrc":"smpte2084","DOVIPresent":true,"DOVIProfile":8}"#)
        #expect(FormatBadge.make(video: dv, media: nil, audio: nil, route: route()).range == .dolbyVision)
        let sdr = try stream(#"{"streamType":1,"width":1920,"colorTrc":"bt709"}"#)
        #expect(FormatBadge.make(video: sdr, media: nil, audio: nil, route: route()).range == nil)
    }

    @Test func dolbyVisionProfile7ShowsItsHDR10BaseLayer() throws {
        let dv = try stream(#"{"streamType":1,"width":3840,"colorTrc":"smpte2084","DOVIPresent":true,"DOVIProfile":7}"#)
        let badge = FormatBadge.make(video: dv, media: nil, audio: nil, route: route(.remux, reasons: [.dolbyVisionBaseLayer]))
        #expect(badge.range == .hdr10)
    }

    @Test func aServerReencodeShowsTheEncodedSizeAndNoRange() throws {
        let hdr = try stream(#"{"streamType":1,"width":3840,"colorTrc":"smpte2084"}"#)
        let badge = FormatBadge.make(video: hdr, media: nil, audio: nil, route: route(.serverTranscode, reencodes: true, size: "1280x720"))
        #expect(badge.resolution == .p720)
        #expect(badge.range == nil)
    }

    @Test func soundNeedsAPassedThroughTrack() throws {
        let atmos = try stream(#"{"streamType":2,"channels":8,"codec":"eac3","extendedDisplayTitle":"English (Dolby Digital Plus + Dolby Atmos 7.1)"}"#)
        #expect(FormatBadge.make(video: nil, media: nil, audio: atmos, route: route()).sound == .atmos)
        let five = try stream(#"{"streamType":2,"channels":6,"codec":"ac3"}"#)
        #expect(FormatBadge.make(video: nil, media: nil, audio: five, route: route()).sound == .surround51)
        let seven = try stream(#"{"streamType":2,"channels":8,"codec":"dts"}"#)
        #expect(FormatBadge.make(video: nil, media: nil, audio: seven, route: route(.remux)).sound == .surround71)
        let stereo = try stream(#"{"streamType":2,"channels":2,"codec":"aac"}"#)
        #expect(FormatBadge.make(video: nil, media: nil, audio: stereo, route: route()).sound == nil)
        #expect(FormatBadge.make(video: nil, media: nil, audio: five, route: route(.remux, converts: true)).sound == nil)
        #expect(FormatBadge.make(video: nil, media: nil, audio: atmos, route: route(.serverTranscode)).sound == nil)
    }

    @Test func spokenNamesEveryPart() {
        let badge = FormatBadge(resolution: .uhd4K, range: .dolbyVision, sound: .atmos)
        #expect(badge.spoken == "4K, Dolby Vision, Dolby Atmos")
        #expect(FormatBadge().isEmpty)
    }
}
