import Foundation
import Testing
@testable import MarqueeCore

struct PlaybackRouteTests {
    /// A player with an on-device remux that does everything except draw picture subtitles.
    static let remuxer = DeviceCapabilities(
        dolbyVisionProfiles: [5, 8], canRemux: true, remuxConvertsAudio: true, remuxKeepsDolbyVision: true,
        remuxCarriesTextSubtitles: true
    )
    static let playerOnly = DeviceCapabilities()

    struct File {
        var media: PlexMedia
        var part: PlexPart
        var tracks: MediaTracks
    }

    static func file(
        _ container: String,
        video: [String: Any] = Fixture.video(),
        streams: [[String: Any]] = [Fixture.audio(2, "eng", isDefault: true)],
        bitrate: Int = 10_000
    ) throws -> File {
        let media = try decode(PlexMedia.self, [
            "id": 1, "container": container, "bitrate": bitrate,
            "Part": [["id": 7, "container": container, "Stream": [video] + streams]],
        ])
        let part = try #require(media.parts.first)
        return File(media: media, part: part, tracks: MediaTracks(part: part))
    }

    static func route(
        _ file: File,
        audio: Int? = nil,
        subtitle: SubtitleDecision = SubtitleDecision(track: nil, source: .setting),
        capabilities: DeviceCapabilities = PlaybackRouteTests.remuxer,
        limits: RouteLimits = RouteLimits(),
        sampleEntry: String? = nil
    ) -> PlaybackRoute {
        PlaybackRouteDecider.decide(
            media: file.media, part: file.part, tracks: file.tracks,
            audio: audio.flatMap(file.tracks.audioTrack(id:)) ?? file.tracks.audio.first,
            subtitle: subtitle, capabilities: capabilities, limits: limits, hevcSampleEntry: sampleEntry
        )
    }

    static func subtitle(_ id: Int, in file: File, _ source: SubtitleDecision.Source) -> SubtitleDecision {
        SubtitleDecision(track: file.tracks.subtitle(id: id), source: source)
    }

    // MARK: Video and container

    @Test func playableMP4PlaysDirectly() throws {
        let hevc = try Self.file("mp4", video: Fixture.video("hevc", bitDepth: 10, colorTrc: "smpte2084"))
        let av1 = try Self.file("mp4", video: Fixture.video("av1", bitDepth: 10))

        let plain = Self.route(try Self.file("mp4"), capabilities: Self.playerOnly)
        #expect(plain.kind == .directPlay && plain.reasons.isEmpty && !plain.reencodesVideo)
        #expect(Self.route(hevc, sampleEntry: "hvc1").kind == .directPlay)
        #expect(Self.route(try Self.file("mov", video: Fixture.video("hevc"))).kind == .directPlay)
        #expect(Self.route(av1, capabilities: DeviceCapabilities(av1: true)).kind == .directPlay)
    }

    @Test func untaggedHEVCInMP4IsRemuxed() throws {
        let hevc = try Self.file("mp4", video: Fixture.video("hevc"))

        let route = Self.route(hevc)
        #expect(route.kind == .remux && route.reasons == [.hevcTag])
        #expect(Self.route(hevc, sampleEntry: "hev1").reasons == [.hevcTag])
    }

    @Test func otherContainersRemuxOnThePhoneOrCopyOnTheServer() throws {
        let mkv = try Self.file("mkv", video: Fixture.video("hevc", bitDepth: 10, colorTrc: "smpte2084"))

        let remux = Self.route(mkv)
        let server = Self.route(mkv, capabilities: Self.playerOnly)

        #expect(remux.kind == .remux && remux.reasons == [.container("mkv")])
        #expect(server.kind == .serverTranscode && !server.reencodesVideo && server.reasons == [.container("mkv")])
    }

    struct Undecodable: Sendable, CustomTestStringConvertible {
        var codec: String
        var bitDepth = 8
        var chroma = "4:2:0"
        var reason: RouteReason
        var testDescription: String { reason.description }
    }

    @Test(arguments: [
        Undecodable(codec: "vc1", reason: .videoCodec("vc1")),
        Undecodable(codec: "mpeg2video", reason: .videoCodec("mpeg2video")),
        Undecodable(codec: "h264", bitDepth: 10, reason: .videoFormat("10-bit H.264")),
        Undecodable(codec: "hevc", chroma: "4:2:2", reason: .videoFormat("HEVC 4:2:2")),
        Undecodable(codec: "hevc", bitDepth: 12, reason: .videoFormat("12-bit HEVC")),
        Undecodable(codec: "av1", reason: .videoCodec("av1")),
    ])
    func videoThePhoneCannotDecodeIsReencoded(_ video: Undecodable) throws {
        let file = try Self.file("mkv", video: Fixture.video(video.codec, bitDepth: video.bitDepth, chroma: video.chroma))

        let route = Self.route(file)

        #expect(route.kind == .serverTranscode && route.reencodesVideo)
        #expect(route.reasons.first == video.reason)
    }

    // MARK: HDR

    @Test func dolbyVisionPlaysOnlyWhereItsProfileSurvives() throws {
        func dolbyVision(_ profile: Int, compatibility: Int, in container: String, codec: String = "hevc") throws -> File {
            try Self.file(container, video: Fixture.video(codec, bitDepth: 10, dolbyVision: (profile, compatibility)))
        }
        let keepsNothing = DeviceCapabilities(canRemux: true, remuxConvertsAudio: true)

        let p5 = try dolbyVision(5, compatibility: 0, in: "mp4")
        #expect(Self.route(p5, sampleEntry: "dvh1").kind == .directPlay)
        #expect(Self.route(p5, capabilities: Self.playerOnly, sampleEntry: "dvh1").reasons == [.dolbyVision(profile: 5)])

        let p5mkv = try dolbyVision(5, compatibility: 0, in: "mkv")
        #expect(Self.route(p5mkv).kind == .remux)
        let lost = Self.route(p5mkv, capabilities: keepsNothing)
        #expect(lost.kind == .serverTranscode && lost.reencodesVideo && lost.reasons.first == .dolbyVision(profile: 5))

        let p7 = Self.route(try dolbyVision(7, compatibility: 6, in: "mkv"))
        #expect(p7.kind == .remux && p7.reasons == [.container("mkv"), .dolbyVisionBaseLayer])

        #expect(Self.route(try dolbyVision(8, compatibility: 1, in: "mkv")).reasons == [.container("mkv")])
        #expect(Self.route(try dolbyVision(9, compatibility: 2, in: "mp4", codec: "h264")).reasons == [.dolbyVision(profile: 9)])
    }

    @Test func hdrOnAnSDRScreenIsToneMappedOnlyWhenTheVideoIsCopiedToHLS() throws {
        let sdrScreen = DeviceCapabilities(hdrDisplay: false, canRemux: true)
        let hdr10 = Fixture.video("hevc", bitDepth: 10, colorTrc: "smpte2084")

        let copied = Self.route(try Self.file("mkv", video: hdr10), capabilities: sdrScreen)
        let direct = Self.route(try Self.file("mp4", video: hdr10), capabilities: sdrScreen, sampleEntry: "hvc1")

        #expect(copied.kind == .serverTranscode && copied.reencodesVideo && copied.reasons.first == .hdrOnSDRScreen)
        #expect(direct.kind == .directPlay)
    }

    @Test func hlsLimitsApplyOnlyToCopiedVideo() throws {
        let highLevel = Self.route(try Self.file("mkv", video: Fixture.video("hevc", level: 156)))
        let highFrameRate = Self.route(try Self.file("mkv", video: Fixture.video(frameRate: 119.88)))
        let direct = Self.route(try Self.file("mp4", video: Fixture.video(level: 52, frameRate: 119.88)))

        #expect(highLevel.kind == .serverTranscode && highLevel.reasons.first == .levelOrFrameRate)
        #expect(highFrameRate.reencodesVideo)
        #expect(direct.kind == .directPlay)
    }

    // MARK: Audio

    @Test func unplayableAudioIsSwappedForASameLanguageTrackFirst() throws {
        let dtsAndAC3 = try Self.file("mp4", streams: [
            Fixture.audio(2, "eng", codec: "dts", channels: 6, isDefault: true),
            Fixture.audio(3, "eng", codec: "aac", channels: 2),
            Fixture.audio(4, "eng", codec: "ac3", channels: 6),
        ])
        let route = Self.route(dtsAndAC3, audio: 2, capabilities: Self.playerOnly)

        #expect(route.kind == .directPlay && route.audio?.id == 4 && route.audioIsStandIn)
    }

    @Test func audioWithoutAStandInIsConvertedOnThePhoneOrByTheServer() throws {
        let noMatch = try Self.file("mp4", streams: [
            Fixture.audio(2, "eng", codec: "truehd", channels: 8),
            Fixture.audio(3, "eng", title: "Commentary", codec: "aac"),
            Fixture.audio(4, "eng", title: "English Dub", codec: "aac"),
            Fixture.audio(5, "jpn", codec: "aac"),
        ])

        let remux = Self.route(noMatch, audio: 2)
        let server = Self.route(noMatch, audio: 2, capabilities: Self.playerOnly)

        #expect(remux.kind == .remux && remux.convertsAudio && remux.audio?.id == 2 && !remux.audioIsStandIn)
        #expect(remux.reasons == [.audio("truehd")])
        #expect(server.kind == .serverTranscode && !server.reencodesVideo)
    }

    // MARK: Subtitles

    @Test func subtitlesThatNeedABurnBurnOnlyForAHandPick() throws {
        let mkv = try Self.file("mkv", streams: [
            Fixture.audio(2, "eng"),
            Fixture.subtitle(3, "eng", codec: "pgs"),
            Fixture.subtitle(4, "eng", title: "Forced", codec: "ass", forced: true),
            Fixture.subtitle(5, "fra", external: true),
            Fixture.subtitle(6, "spa", codec: "pgs", external: true),
        ])

        let handPick = Self.route(mkv, subtitle: Self.subtitle(3, in: mkv, .handPick))
        #expect(handPick.kind == .serverTranscode && handPick.reencodesVideo)
        #expect(handPick.reasons.first == .burnsSubtitle && handPick.subtitle == .burnedIn(mkv.tracks.subtitles[0]))

        let remembered = Self.route(mkv, subtitle: Self.subtitle(3, in: mkv, .remembered))
        #expect(remembered.kind == .remux && remembered.subtitle == .notShown(mkv.tracks.subtitles[0]))
        #expect(Self.route(mkv, subtitle: Self.subtitle(3, in: mkv, .fileDefault)).subtitle == .notShown(mkv.tracks.subtitles[0]))

        #expect(Self.route(mkv, subtitle: Self.subtitle(4, in: mkv, .setting)).subtitle == .inStream(mkv.tracks.subtitles[1]))
        #expect(Self.route(mkv, subtitle: Self.subtitle(5, in: mkv, .server)).subtitle == .sidecar(mkv.tracks.subtitles[2]))
        #expect(Self.route(mkv, subtitle: Self.subtitle(6, in: mkv, .handPick)).subtitle == .burnedIn(mkv.tracks.subtitles[3]))
        var draws = Self.remuxer
        draws.drawsImageSubtitles = true
        #expect(Self.route(mkv, subtitle: Self.subtitle(6, in: mkv, .handPick), capabilities: draws).subtitle
            == .sidecar(mkv.tracks.subtitles[3]))
    }

    @Test func rememberedSubtitleBurnsWhenTheVideoIsReencodedAnyway() throws {
        let vc1 = try Self.file("mkv", video: Fixture.video("vc1"), streams: [
            Fixture.audio(2, "eng"),
            Fixture.subtitle(3, "eng", codec: "pgs"),
        ])

        let remembered = Self.route(vc1, subtitle: Self.subtitle(3, in: vc1, .remembered))
        let automatic = Self.route(vc1, subtitle: Self.subtitle(3, in: vc1, .server))

        #expect(remembered.subtitle == .burnedIn(vc1.tracks.subtitles[0]))
        #expect(!remembered.reasons.contains(.burnsSubtitle))
        #expect(automatic.subtitle == .notShown(vc1.tracks.subtitles[0]))
    }

    @Test func captionsInTheVideoLastOnlyWhileTheVideoIsCopied() throws {
        func file(_ video: [String: Any]) throws -> File {
            try Self.file("mkv", video: video, streams: [Fixture.audio(2, "eng"), Fixture.subtitle(3, "eng", codec: "eia_608", inVideo: true)])
        }
        let copied = try file(Fixture.video())
        let reencoded = try file(Fixture.video(bitDepth: 10))

        #expect(Self.route(copied, subtitle: Self.subtitle(3, in: copied, .setting)).subtitle == .inStream(copied.tracks.subtitles[0]))
        #expect(Self.route(reencoded, subtitle: Self.subtitle(3, in: reencoded, .setting)).subtitle
            == .notShown(reencoded.tracks.subtitles[0]))
    }

    // MARK: Limits

    @Test func qualityLimitAndFailedPlaybackGoToTheServer() throws {
        let file = try Self.file("mp4", bitrate: 20_000)

        let limited = Self.route(file, limits: RouteLimits(maxBitrateKbps: 8_000))
        let failed = Self.route(file, limits: RouteLimits(serverOnly: true))

        #expect(limited.kind == .serverTranscode && limited.reencodesVideo && limited.reasons == [.bitrateLimit(kbps: 8_000)])
        #expect(failed.kind == .serverTranscode && !failed.reencodesVideo && failed.reasons == [.onDeviceFailed])
    }
}
