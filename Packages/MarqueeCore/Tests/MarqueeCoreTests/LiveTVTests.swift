import Foundation
import Testing
@testable import MarqueeCore

struct LiveTVTests {
    static let epg = "tv.plex.providers.epg.cloud:5"

    /// A server answering the live endpoints from `LiveFixtures`; `extra` answers first when it returns one.
    static func live(_ extra: @escaping @Sendable (PlexRequest) -> PlexHTTPResponse? = { _ in nil }) -> (PlexLiveTV, FakeTransport) {
        let (library, transport) = PlexLibraryTests.library { request in
            if let answer = extra(request) { return answer }
            return switch request.url.path {
            case "/livetv/dvrs": container(LiveFixtures.dvrs)
            case "/\(epg)/lineups/dvr/channels": container(LiveFixtures.channels)
            case "/\(epg)/grid": container(LiveFixtures.grid)
            case "/livetv/dvrs/12/channels/aaa-0201/tune": container(LiveFixtures.tune)
            case "/media/subscriptions/template": container(LiveFixtures.template)
            case "/media/subscriptions": container(LiveFixtures.subscriptions)
            case "/media/subscriptions/scheduled": container(LiveFixtures.scheduled)
            case "/media/providers": container(LiveFixtures.providers)
            default: container([:])
            }
        }
        return (PlexLiveTV(library: library), transport)
    }

    static func lineup(_ live: PlexLiveTV) async throws -> (LiveDVR, [LiveChannel]) {
        let dvr = try #require(try await live.dvrs().first)
        return (dvr, try await live.channels(dvr))
    }

    static func at(_ minutes: Double) -> Date { LiveFixtures.at(minutes: minutes) }

    @Test func channelsAreTheLineupsEnabledOnesInNumberOrder() async throws {
        let (live, _) = Self.live()

        let (dvr, channels) = try await Self.lineup(live)

        #expect(dvr.key == "12" && dvr.title == "Antenna" && dvr.epgIdentifier == Self.epg)
        #expect(dvr.startOffsetMinutes == 2 && dvr.endOffsetMinutes == 5)
        #expect(dvr.devices.map(\.tunerCount) == [1, 2] && dvr.devices.map(\.isAlive) == [true, false])
        // 5.1 is mapped but disabled; 2.1 is on both devices and the live one receives it.
        #expect(channels.map(\.number) == ["2.1", "4.1", "7.1", "10.1"])
        #expect(channels.map(\.device.key) == ["21", "21", "22", "21"])
        #expect(channels[0].label == "2.1 WAAA" && channels[0].logo == "https://provider-static.plex.tv/epg/logos/waaa.png")
    }

    @Test func guideAsksForOneWindowAndKeepsMappedChannels() async throws {
        let (live, transport) = Self.live()
        let (dvr, channels) = try await Self.lineup(live)

        let airings = try await live.guide(dvr, channels: channels, from: Self.at(0), to: Self.at(120))

        #expect(airings.map(\.id) == ["902", "901", "904"])
        let movie = airings[0], news = airings[1], quiz = airings[2]
        #expect(movie.kind == .movie && movie.year == 1998 && !movie.isHD && movie.start == Self.at(-15))
        #expect(news.title == "Evening News" && news.episodeTitle == "Storm Watch" && news.episodeCode == "S3 E12")
        #expect(news.isNew && news.isHD && news.genres == ["News"] && news.end == Self.at(30))
        #expect(news.thumb == "https://metadata-static.plex.tv/show-news.jpg")
        #expect(quiz.title == "Quiz Night" && quiz.episodeTitle == nil)
        let request = try #require(await transport.requests(to: "/\(Self.epg)/grid").first)
        #expect(request.url.query("type") == "1,4" && request.url.query("sort") == "beginsAt")
        #expect(request.url.query("endsAt>") == String(LiveFixtures.seconds(0)))
        #expect(request.url.query("beginsAt<") == String(LiveFixtures.seconds(120)))
    }

    @Test func genreFiltersComeFromTheGuideProvider() async throws {
        let (live, _) = Self.live { request in
            request.url.query("genre") == "genre_news"
                ? container(["Channel": [LiveFixtures.channel("aaa-0201", "2.1", "WAAA", "Network A", hd: true)]])
                : nil
        }
        let (dvr, _) = try await Self.lineup(live)

        let filters = try await live.channelFilters(dvr)

        #expect(filters.map(\.title) == ["News", "Movies"])
        #expect(try await live.channelKeys(in: filters[0]) == ["aaa-0201"])
    }

    @Test func tuneStreamTimelineAndStopNameOneSession() async throws {
        // The transcode has often ended by the time the player stops.
        let (live, transport) = Self.live { request in
            request.url.path == "/video/:/transcode/universal/stop" ? json([:], status: 404) : nil
        }
        let (_, channels) = try await Self.lineup(live)

        let session = try await live.tune(channels[0], session: "ts-1")
        let url = try await live.streamURL(TranscodeRequest(live: session))
        try await live.reportTimeline(LiveTimelineUpdate(session: session, state: .playing, time: 5_000))
        try await live.stopStream(session)

        #expect(session.id == "sess-1111" && session.ratingKey == "live-77")
        #expect(session.videoCodec == "mpeg2video" && session.isInterlaced && session.audioChannels == 6)
        // The transcoder reads the tuned stream under the tune's session name.
        let tune = try #require(await transport.requests(to: "/livetv/dvrs/12/channels/aaa-0201/tune").first)
        #expect(tune.method == .post && tune.headers[PlexHeader.sessionIdentifier] == "ts-1")
        // MPEG-2 has no decoder in AVPlayer, so the server converts the video.
        #expect(url.path == "/video/:/transcode/universal/start.m3u8" && url.query("session") == "ts-1")
        #expect(url.query("path") == "/livetv/sessions/sess-1111" && url.query("directStream") == "0")
        #expect(await transport.requests(to: "/video/:/transcode/universal/decision").first?.url.query("session") == "ts-1")
        let timeline = try #require(await transport.requests(to: "/:/timeline").first)
        #expect(timeline.headers[PlexHeader.sessionIdentifier] == "ts-1")
        #expect(timeline.url.query("key") == "/livetv/sessions/sess-1111" && timeline.url.query("ratingKey") == "live-77")
        #expect(await transport.requests(to: "/video/:/transcode/universal/stop").first?.url.query("session") == "ts-1")
        // Cancelling the grab is what frees the tuner.
        #expect(await transport.requests(to: "/media/grabbers/operations/aaa-0201-ts-1").first?.method == .delete)
    }

    @Test func recordingSendsBackTheTemplatesParametersAndSettings() async throws {
        let (live, transport) = Self.live()
        let airing = LiveAiring(
            id: "901", channelKey: "aaa-0201", guid: "plex://episode/news12", kind: .episode, title: "Evening News",
            start: Self.at(0), end: Self.at(30)
        )

        let options = try await live.recordOptions(airing)
        try await live.record(options[0], values: ["startOffsetMinutes": "2"])

        #expect(options.map(\.kind) == [.episode, .show] && options.map(\.title) == ["This Episode", "All Episodes"])
        #expect(options[1].setting("onlyNewAirings")?.choices.map(\.label) == ["New and Repeat Airings", "New Airings Only"])
        #expect(await transport.requests(to: "/media/subscriptions/template").first?.url.query("guid") == "plex://episode/news12")
        let post = try #require(await transport.requests(to: "/media/subscriptions").first { $0.method == .post })
        #expect(post.url.query("type") == "4")
        #expect(post.url.query("targetLibrarySectionID") == "2" && post.url.query("targetSectionLocationID") == "3")
        #expect(post.url.query("hints[guid]") == "plex://episode/news12")
        // The server decodes this value twice; only the query's own layer comes off here.
        #expect(post.url.query("params[airingChannels]") == "aaa-0201%3D2%252E1%2520WAAA")
        #expect(post.url.query("prefs[startOffsetMinutes]") == "2" && post.url.query("prefs[oneShot]") == "true")
    }

    @Test func scheduleMarksTheGuideAndCancelsOneAiring() async throws {
        let (live, transport) = Self.live()

        let recordings = LiveRecordings(rules: try await live.rules(), scheduled: try await live.scheduled())
        let tonight = LiveAiring(id: "901", channelKey: "aaa-0201", title: "Evening News", start: Self.at(0), end: Self.at(30))
        let tomorrow = LiveAiring(id: "905", channelKey: "aaa-0201", title: "Evening News", start: Self.at(1440), end: Self.at(1470))
        let elsewhere = LiveAiring(id: "906", channelKey: "aaa-0401", title: "Evening News", start: Self.at(1440), end: Self.at(1470))

        #expect(recordings.rules.map(\.title) == ["Evening News"] && recordings.rules[0].isSeries)
        #expect(recordings.rules[0].targetLibrarySectionID == 2)
        #expect(recordings.rules[0].recordings.map(\.id) == ["grab-2"])
        #expect(recordings.scheduled.map(\.id) == ["grab-1", "grab-2"])
        #expect(recordings.scheduled[0].episodeTitle == "Storm Watch" && recordings.scheduled[0].ruleID == "31")
        #expect(recordings.mark(for: tonight) == .recording)
        #expect(recordings.mark(for: tomorrow) == .series)
        #expect(recordings.mark(for: elsewhere) == nil)
        try await live.cancel(try #require(recordings.recording(of: tomorrow)))
        #expect(await transport.requests(to: "/media/grabbers/operations/grab-2").first?.method == .delete)
    }

    @Test func tunerAPIReadsLumaTunerAndHDHomeRunLineups() async throws {
        let transport = FakeTransport { request, _ in
            request.url.path == "/discover.json"
                ? json(["DeviceID": "1055AAAA", "FriendlyName": "LumaTuner", "TunerCount": 1, "BaseURL": "http://192.0.2.42:5004"])
                : json([
                    ["GuideNumber": "2.1", "GuideName": "WAAA", "URL": "http://192.0.2.42:5004/auto/v2.1"],
                    ["GuideNumber": "9.1", "GuideName": "WFFF", "VideoCodec": "HEVC", "AudioCodec": "AC4", "HD": 1, "DRM": 1],
                ])
        }
        let client = HDHomeRunClient(transport: transport)
        let base = URL(string: "http://192.0.2.42:5004")!

        let device = try await client.discover(base)
        let lineup = try await client.lineup(base)

        #expect(device.friendlyName == "LumaTuner" && device.tunerCount == 1)
        #expect(await transport.requests(to: "/discover.json").first?.timeout == 0.5)
        #expect(lineup.map(\.number) == ["2.1", "9.1"])
        #expect(lineup[0].phoneDecodes && !lineup[0].isProtected)
        #expect(!lineup[1].phoneDecodes && lineup[1].isProtected && lineup[1].isHD)
    }
}

// MARK: - Route

struct RouteCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    var channel = RouteCase.channel
    var context = RouteContext(isOnHomeNetwork: true, tunerReachable: true, dvr: RouteCase.dvr, now: LiveFixtures.eight)
    let expected: LiveRoute

    static let luma = TunerDevice(
        key: "21", uuid: "device://tv.plex.grabbers.hdhomerun/1055AAAA", uri: URL(string: "http://192.0.2.42:5004")!,
        name: "LumaTuner", tunerCount: 1, isAlive: true
    )
    static let channel = LiveChannel(
        id: "aaa-0201", dvrKey: "12", number: "2.1", callSign: "WAAA", title: "Network A", logo: nil, isHD: true, device: luma
    )
    static let dvr = LiveDVR(
        key: "12", uuid: "dvr-uuid-1", title: "Antenna", epgIdentifier: LiveTVTests.epg, devices: [luma],
        mappings: [LiveChannelMapping(channelKey: "aaa-0201", deviceKey: "21", number: "2.1", isEnabled: true)]
    )

    static func recording(on channelKey: String, inMinutes minutes: Double) -> ScheduledRecording {
        ScheduledRecording(
            id: "grab-\(channelKey)", status: .scheduled, channelKey: channelKey, title: "Evening News",
            start: LiveFixtures.at(minutes: minutes), end: LiveFixtures.at(minutes: minutes + 30)
        )
    }

    static let all: [RouteCase] = {
        var setting = RouteCase(testDescription: "setting", expected: .plex(.setting))
        setting.context.prefersPlex = true
        var away = RouteCase(testDescription: "away from home", expected: .plex(.awayFromHome))
        away.context.isOnHomeNetwork = false
        var unreachable = RouteCase(testDescription: "tuner unreachable", expected: .plex(.tunerUnreachable))
        unreachable.context.tunerReachable = false
        var m3u = RouteCase(testDescription: "not HDHomeRun", expected: .plex(.notHDHomeRun))
        m3u.channel.device.uuid = "device://tv.plex.grabbers.m3u/proxy"
        var airPlay = RouteCase(testDescription: "AirPlay", expected: .plex(.airPlay))
        airPlay.context.usesAirPlayVideo = true
        var codec = RouteCase(testDescription: "ATSC 3.0 audio", expected: .plex(.unsupportedCodec))
        codec.context.lineup = HDHomeRunChannel(number: "2.1", name: "WAAA", videoCodec: "HEVC", audioCodec: "AC4")
        var protected = RouteCase(testDescription: "copy-protected", expected: .protectedChannel)
        protected.context.lineup = HDHomeRunChannel(number: "2.1", name: "WAAA", videoCodec: "MPEG2", isProtected: true)
        var recording = RouteCase(testDescription: "recording due", expected: .plex(.recording))
        recording.context.recordings = [Self.recording(on: "aaa-0201", inMinutes: 1)]
        // A recording 3 minutes out, and one of a channel this device does not carry, leave the tuner free.
        var direct = RouteCase(testDescription: "direct", expected: .direct(URL(string: "http://192.0.2.42:5004/auto/v2.1")!))
        direct.context.recordings = [Self.recording(on: "aaa-0201", inMinutes: 3), Self.recording(on: "aaa-0701", inMinutes: 0)]
        return [setting, away, unreachable, m3u, airPlay, codec, protected, recording, direct]
    }()
}

struct LiveRouteTests {
    @Test(arguments: RouteCase.all)
    func firstMatchingRuleDecides(_ route: RouteCase) {
        #expect(LiveRouteDecider().route(route.channel, route.context) == route.expected)
    }
}

// MARK: - Guide

struct LiveGuideTests {
    static let key = "aaa-0201"

    static func airing(_ id: String, _ from: Double, _ to: Double) -> LiveAiring {
        LiveAiring(id: id, channelKey: key, title: id, start: LiveFixtures.at(minutes: from), end: LiveFixtures.at(minutes: to))
    }

    static let guide = LiveGuide(
        channels: [RouteCase.channel],
        airings: [airing("c", 60, 90), airing("a", 0, 30), airing("b", 30, 60)],
        from: LiveFixtures.at(minutes: 0),
        to: LiveFixtures.at(minutes: 90)
    )

    @Test func findsNowAndNextOnAChannel() {
        let guide = Self.guide

        let (now, next) = guide.nowAndNext(on: Self.key, at: LiveFixtures.at(minutes: 45))

        #expect(now?.id == "b" && next?.id == "c")
        #expect(guide.airing(on: Self.key, at: LiveFixtures.at(minutes: 30))?.id == "b")
        #expect(guide.airing(on: Self.key, at: LiveFixtures.at(minutes: 95)) == nil)
        #expect(guide.airings(on: Self.key, from: LiveFixtures.at(minutes: 20), to: LiveFixtures.at(minutes: 61)).map(\.id) == ["a", "b", "c"])
    }

    @Test func aRefreshedSpanReplacesItsAiringsAndCutsOverlaps() {
        let merged = Self.guide.merging(
            [Self.airing("b", 30, 50), Self.airing("b2", 50, 65)],
            from: LiveFixtures.at(minutes: 30),
            to: LiveFixtures.at(minutes: 60)
        )

        let list = merged.airings[Self.key] ?? []
        #expect(list.map(\.id) == ["a", "b", "b2", "c"])
        // b2 overran c's start; the later airing keeps its start.
        #expect(list[2].end == LiveFixtures.at(minutes: 60))
    }

    @Test func cachedGuideComesBackReanchoredToNow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = LiveGuide(
            channels: [RouteCase.channel],
            airings: [Self.airing("old", -240, -150), Self.airing("recent", -150, -60), Self.airing("now", -60, 60)],
            from: LiveFixtures.at(minutes: -240),
            to: LiveFixtures.at(minutes: 120)
        )
        await GuideCache(directory: directory, now: { LiveFixtures.eight }).save(saved, server: "machine-1", dvr: "12")

        let atEight = await GuideCache(directory: directory, now: { LiveFixtures.eight }).load(server: "machine-1", dvr: "12")
        let afterTheGuide = await GuideCache(directory: directory, now: { LiveFixtures.at(minutes: 121) }).load(server: "machine-1", dvr: "12")

        #expect(atEight?.airings[Self.key]?.map(\.id) == ["recent", "now"])
        #expect(atEight?.from == LiveFixtures.at(minutes: -120))
        #expect(afterTheGuide == nil)
    }
}

// MARK: - Record and stop

struct RecordingChoiceTests {
    static func option(_ kind: RecordOption.Kind, oneShot: Bool? = nil) -> RecordOption {
        RecordOption(
            type: kind.rawValue, title: "\(kind)",
            settings: oneShot.map { [RecordSetting(id: "oneShot", label: "", type: "bool", value: $0 ? "true" : "false", isHidden: true)] } ?? []
        )
    }

    @Test func plainRecordTakesThisEpisodeWhateverTheOrder() async throws {
        let (live, _) = LiveTVTests.live()
        let airing = LiveAiring(id: "901", channelKey: "aaa-0201", guid: "plex://episode/news12", title: "Evening News", start: LiveTVTests.at(0), end: LiveTVTests.at(30))

        let options = try await live.recordOptions(airing)

        #expect(options.defaultOption?.kind == .episode)
        #expect(Array(options.reversed()).defaultOption?.kind == .episode)
        #expect(options.wholeShow?.kind == .show)
    }

    @Test func aMovieIsTheDefaultWhenNoEpisodeIsOffered() {
        #expect([Self.option(.show), Self.option(.movie)].defaultOption?.kind == .movie)
    }

    @Test func aProgrammeOfferedOnlyAsAWholeShowHasNoDefault() {
        let events = [Self.option(.show, oneShot: false)]

        #expect(events.defaultOption == nil)
        #expect(events.wholeShow?.kind == .show)
    }

    @Test func anUnknownTypeIsTheDefaultOnlyWhenItIsAOneShot() {
        let other = RecordOption(type: 9, title: "This Event", settings: [RecordSetting(id: "oneShot", label: "", type: "bool", value: "true", isHidden: true)])

        #expect([Self.option(.show), other].defaultOption == other)
        #expect([RecordOption(type: 9, title: "All Events")].defaultOption == nil)
    }
}

struct StopRecordingTests {
    static func recordings(_ live: PlexLiveTV) async throws -> LiveRecordings {
        LiveRecordings(rules: try await live.rules(), scheduled: try await live.scheduled())
    }

    @Test func stoppingDeletesTheGrabAndKeepsASeriesRuleUnlessAsked() async throws {
        let (live, transport) = LiveTVTests.live()
        let recordings = try await Self.recordings(live)
        let running = try #require(recordings.scheduled.first { $0.status == .inprogress })

        try await live.stop(running, deleting: recordings.rule(deletedWhenStopping: running, deletingSeries: false))

        let sent = await transport.requests.filter { $0.method == .delete }.map(\.url.path)
        #expect(sent == ["/media/grabbers/operations/grab-1"])
    }

    @Test func stoppingAndDeletingTheSeriesEndsTheGrabBeforeTheRule() async throws {
        let (live, transport) = LiveTVTests.live()
        let recordings = try await Self.recordings(live)
        let running = try #require(recordings.scheduled.first { $0.status == .inprogress })

        try await live.stop(running, deleting: recordings.rule(deletedWhenStopping: running, deletingSeries: true))

        let sent = await transport.requests.filter { $0.method == .delete }.map(\.url.path)
        #expect(sent == ["/media/grabbers/operations/grab-1", "/media/subscriptions/31"])
    }

    @Test func aOneOffRuleGoesWithItsStoppedAiring() {
        let rule = RecordingRule(id: "7", type: RecordOption.Kind.episode.rawValue, title: "Game")
        let grab = ScheduledRecording(id: "g", ruleID: "7", status: .inprogress, title: "Game", start: LiveTVTests.at(0), end: LiveTVTests.at(30))
        let recordings = LiveRecordings(rules: [rule], scheduled: [grab])

        #expect(recordings.rule(deletedWhenStopping: grab, deletingSeries: false) == rule)
    }

    @Test func deletingARuleEndsItsRunningAiringsFirst() async throws {
        let (live, transport) = LiveTVTests.live()
        let recordings = try await Self.recordings(live)
        let rule = try #require(recordings.rules.first)

        try await live.delete(rule, stopping: recordings.running(under: rule))

        let sent = await transport.requests.filter { $0.method == .delete }.map(\.url.path)
        #expect(sent == ["/media/grabbers/operations/grab-1", "/media/subscriptions/31"])
    }

    @Test func aRecordingHoldsTheTunerOnlyWhenItTakesTheLastOne() {
        let other = LiveChannel(id: "aaa-0701", dvrKey: "12", number: "7.1", callSign: "WGGG", title: "G", logo: nil, isHD: true, device: RouteCase.luma)
        var dvr = RouteCase.dvr
        dvr.mappings.append(LiveChannelMapping(channelKey: "aaa-0701", deviceKey: "21", number: "7.1", isEnabled: true))
        let grab = ScheduledRecording(id: "g", status: .inprogress, channelKey: "aaa-0701", channelNumber: "7.1", title: "College Football", start: LiveTVTests.at(-10), end: LiveTVTests.at(50))
        let later = ScheduledRecording(id: "h", status: .scheduled, channelKey: "aaa-0701", title: "College Football", start: LiveTVTests.at(60), end: LiveTVTests.at(90))

        #expect(grab.tunerHeldSentence == "Recording College Football on 7.1 is using the tuner")
        #expect(LiveRecordings(scheduled: [grab]).holdingTuner(for: RouteCase.channel, dvr: dvr) == grab)
        #expect(LiveRecordings(scheduled: [later]).holdingTuner(for: RouteCase.channel, dvr: dvr) == nil)
        // Plex shares a recording's tuner with a viewer of the same channel.
        #expect(LiveRecordings(scheduled: [grab]).holdingTuner(for: other, dvr: dvr) == nil)
        var twoTuners = RouteCase.channel
        twoTuners.device.tunerCount = 2
        #expect(LiveRecordings(scheduled: [grab]).holdingTuner(for: twoTuners, dvr: dvr) == nil)
    }
}
