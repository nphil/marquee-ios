import Foundation
import Testing
@testable import MarqueeCore

struct CastTests {
    typealias File = PlaybackRouteTests.File

    static let hd = CastReceiver(modelName: "Chromecast")
    static let ultra = CastReceiver(modelName: "Chromecast Ultra")

    static func route(
        _ file: File,
        audio: Int? = nil,
        subtitle: Int? = nil,
        receiver: CastReceiver = hd,
        limits: RouteLimits = RouteLimits()
    ) -> PlaybackRoute {
        CastRouteDecider.decide(
            media: file.media, part: file.part, tracks: file.tracks,
            audio: audio.flatMap(file.tracks.audioTrack(id:)) ?? file.tracks.audio.first,
            subtitle: SubtitleDecision(track: subtitle.flatMap(file.tracks.subtitle(id:)), source: .setting),
            receiver: receiver, limits: limits
        )
    }

    static func uhd(_ codec: String) -> [String: Any] {
        var video = Fixture.video(codec, bitDepth: 10)
        video["width"] = 3840
        video["height"] = 2160
        return video
    }

    @Test func fileTheReceiverDecodesPlaysDirectly() throws {
        let plain = Self.route(try PlaybackRouteTests.file("mp4"))
        #expect(plain.kind == .directPlay && plain.reasons.isEmpty)
        #expect(Self.route(try PlaybackRouteTests.file("mp4", video: Self.uhd("hevc")), receiver: Self.ultra).kind == .directPlay)
    }

    @Test func serverCopiesH264AndConvertsTheRest() throws {
        let mkv = Self.route(try PlaybackRouteTests.file("mkv", streams: [Fixture.audio(2, "eng", codec: "dts")]))
        #expect(mkv.kind == .serverTranscode && !mkv.reencodesVideo)
        #expect(mkv.reasons == [.container("mkv"), .audio("dts")])

        let second = try PlaybackRouteTests.file("mp4", streams: [Fixture.audio(2, "eng"), Fixture.audio(3, "fra")])
        let french = Self.route(second, audio: 3)
        #expect(french.reasons == [.notFirstAudioTrack] && !french.reencodesVideo && french.audio?.id == 3)
    }

    @Test func videoTheServerCannotCopyIsReencodedTo1080p() throws {
        let hevc = Self.route(try PlaybackRouteTests.file("mp4", video: Self.uhd("hevc")))
        #expect(hevc.reasons == [.videoCodec("hevc"), .videoFormat("2160p")])
        #expect(hevc.reencodesVideo && hevc.videoResolution == "1920x1080" && hevc.maxVideoBitrateKbps == 20_000)
        // An Ultra decodes it, but the server sends H.264 only.
        let mkv = Self.route(try PlaybackRouteTests.file("mkv", video: Self.uhd("hevc")), receiver: Self.ultra)
        #expect(mkv.reasons == [.container("mkv")] && mkv.reencodesVideo && mkv.videoResolution == "1920x1080")

        let level = Self.route(try PlaybackRouteTests.file("mp4", video: Fixture.video(level: 42)))
        #expect(level.reasons == [.videoFormat("H.264 level 4.2")] && level.reencodesVideo)
    }

    @Test func subtitleIsBurnedIn() throws {
        let file = try PlaybackRouteTests.file("mp4", streams: [Fixture.audio(2, "eng"), Fixture.subtitle(4, "eng", external: true)])
        let route = Self.route(file, subtitle: 4)
        #expect(route.kind == .serverTranscode && route.reencodesVideo && route.reasons == [.burnsSubtitle])
        #expect(route.subtitle == .burnedIn(try #require(file.tracks.subtitle(id: 4))))
    }

    @Test func qualityAndSettingsSendItThroughTheServer() throws {
        let file = try PlaybackRouteTests.file("mp4", bitrate: 10_000)
        let capped = Self.route(file, limits: RouteLimits(quality: .mbps4))
        #expect(capped.reasons == [.bitrateLimit(kbps: 4_000)] && capped.maxVideoBitrateKbps == 4_000 && capped.videoResolution == "1280x720")

        #expect(Self.route(file, limits: RouteLimits(serverReason: .directPlayOff)).kind == .serverTranscode)
        // Force Direct Play and the phone's own failures concern the phone only.
        #expect(Self.route(file, limits: RouteLimits(phoneOnly: true)).kind == .directPlay)
        #expect(Self.route(file, limits: RouteLimits(serverReason: .onDeviceFailed)).kind == .directPlay)
    }

    // MARK: Stream

    static let plain = PlexConnection(uri: URL(string: "http://192.168.1.71:32400")!, isLocal: true)
    static let secure = PlexConnection(uri: URL(string: "https://192-168-1-71.abc.plex.direct:32400")!, isLocal: true)
    static let otherSecure = PlexConnection(uri: URL(string: "https://10-0-0-9.abc.plex.direct:32400")!, isLocal: true)
    static let remote = PlexConnection(uri: URL(string: "https://81-2-3-4.abc.plex.direct:32400")!, isLocal: false)

    @Test func receiverGetsAnHTTPSAddressForTheSameMachine() {
        #expect(CastStream.address(current: Self.plain, among: [Self.remote, Self.otherSecure, Self.secure, Self.plain]) == Self.secure)
        #expect(CastStream.address(current: Self.plain, among: [Self.remote, Self.otherSecure, Self.plain]) == Self.otherSecure)
        #expect(CastStream.address(current: Self.plain, among: [Self.remote, Self.plain]) == Self.plain)
        #expect(CastStream.address(current: Self.remote, among: [Self.secure, Self.remote]) == Self.remote)
    }

    @Test func serverStreamIsAskedForAsChromecastWithTheTransientToken() throws {
        let file = try PlaybackRouteTests.file("mkv")
        let item = try decode(PlexMetadata.self, ["ratingKey": "12", "type": "movie", "title": "Film"])
        let request = TranscodeRequest(item: item, route: Self.route(file), offset: 0, session: "cast-1")
        let stream = try #require(CastStream.transcode(request, base: Self.secure.uri, identity: testIdentity, isLocal: true, token: "transient-1"))

        #expect(stream.url.path == "/video/:/transcode/universal/start.m3u8" && stream.session == "cast-1")
        #expect(stream.url.query("X-Plex-Platform") == "Chromecast" && stream.url.query("X-Plex-Client-Identifier") == "client-1")
        #expect(stream.url.query("X-Plex-Client-Profile-Extra")?.contains("videoCodec=h264&audioCodec=aac,mp3") == true)
        #expect(stream.url.query("X-Plex-Token") == "transient-1" && stream.url.query("location") == "lan")
        #expect(stream.url.query("offset") == "0.0" && stream.contentType == "application/x-mpegURL")

        let direct = try #require(CastStream.file(part: file.part, base: Self.secure.uri, token: "transient-1"))
        #expect(direct.url.query("X-Plex-Token") == "transient-1" && direct.session == nil)
    }

    @Test func transientTokenComesFromTheServer() async throws {
        let (library, transport) = PlexLibraryTests.library { request in
            request.url.query("type") == "delegation" ? container(["token": "transient-abc"]) : json([:], status: 404)
        }
        #expect(try await library.transientToken() == "transient-abc")
        #expect(await transport.requests(to: "/security/token").count == 1)
    }
}
