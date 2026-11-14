import Foundation
import Testing
@testable import MarqueeCore

struct DownloadQualityTests {
    /// A one-hour version: H.264 video at `kbps`, 640 kbit/s of audio, 24 fps.
    static func media(
        id: Int = 1, width: Int = 1920, height: Int = 1080, resolution: String = "1080", kbps: Int = 10_000,
        codec: String = "h264", size: Int = 5_000_000_000
    ) throws -> PlexMedia {
        try decode(PlexMedia.self, [
            "id": id, "duration": 3_600_000, "bitrate": kbps + 640, "width": width, "height": height,
            "videoResolution": resolution, "videoCodec": codec, "videoFrameRate": "24p",
            "Part": [["id": 11, "key": "/library/parts/11/file.mkv", "size": size, "Stream": [
                ["id": 1, "streamType": 1, "codec": codec, "bitrate": kbps, "width": width, "height": height],
                ["id": 2, "streamType": 2, "codec": "eac3", "bitrate": 640, "selected": true],
            ]]],
        ])
    }

    static func plan(
        _ media: PlexMedia, animated: Bool = false, hevc: Bool = false, originalPlays: Bool = true, map: QualityMapEntry? = nil
    ) -> DownloadQualityPlan {
        DownloadQualityPlan(media: media, animated: animated, hevc: hevc, originalPlays: originalPlays, map: map)
    }

    /// "medium 720 4000 estimated" for each choice after Original.
    static func summary(_ plan: DownloadQualityPlan) -> [String] {
        plan.options.dropFirst().map { option in
            let basis = switch option.basis {
            case .original: "original"
            case .measured(let vmaf): "vmaf \(vmaf)"
            case .estimated: "estimated"
            }
            let target = option.target.map { "\($0.height) \($0.videoKbps) \($0.codec)" } ?? "-"
            return "\(option.quality.title.lowercased()) \(target) \(basis)"
        }
    }

    // MARK: Estimate

    @Test func liveActionAt1080TakesTheCheapestSizeForEachScore() throws {
        let plan = Self.plan(try Self.media())
        #expect(Self.summary(plan) == [
            "high 1080 8000 h264 estimated", "medium 720 4000 h264 estimated", "low 720 2960 h264 estimated",
        ])
        #expect(plan.options.first?.quality == .original && plan.options.first?.bytes == 5_000_000_000)
        // (4000 + 192) kbit/s for an hour.
        #expect(plan.option(for: .tier(.medium))?.bytes == 1_886_400_000)
    }

    @Test func animationNeedsLessAndLowFoldsIntoMedium() throws {
        let plan = Self.plan(try Self.media(), animated: true)
        #expect(Self.summary(plan) == ["high 1080 6520 h264 estimated", "medium 720 2960 h264 estimated"])
        #expect(plan.option(for: .tier(.low)) == plan.option(for: .tier(.medium)))
        #expect(DownloadQualityPlan.isAnimated(genres: ["Comedy", "Anime"]) && !DownloadQualityPlan.isAnimated(genres: ["Drama"]))
    }

    @Test func aTierAtTheOriginalsBitrateIsTheOriginal() throws {
        let lean = try Self.media(kbps: 5000)
        let plays = Self.plan(lean)
        #expect(Self.summary(plays) == ["medium 720 3500 h264 estimated", "low 720 2960 h264 estimated"])
        #expect(plays.option(for: .tier(.high))?.quality == .original)
        // An original the phone cannot play is still converted, at its own bitrate.
        let converts = Self.plan(lean, originalPlays: false)
        #expect(Self.summary(converts).first == "high 720 5000 h264 estimated")
    }

    @Test func smallerOriginalsScaleDown() throws {
        let plan = Self.plan(try Self.media(width: 1280, height: 720, resolution: "720", kbps: 5000))
        #expect(Self.summary(plan) == [
            "high 720 4400 h264 estimated", "medium 480 2200 h264 estimated", "low 480 1450 h264 estimated",
        ])
    }

    @Test func fourKAddsHighInHEVCOnlyWhereThePhoneDecodesIt() throws {
        let uhd = try Self.media(width: 3840, height: 2160, resolution: "4k", kbps: 60_000, codec: "hevc")
        #expect(Self.summary(Self.plan(uhd, hevc: true)) == [
            "high 2160 18000 hevc estimated", "high 1080 9600 h264 estimated", "medium 720 4800 h264 estimated",
            "low 720 3150 h264 estimated",
        ])
        #expect(Self.plan(uhd, hevc: true).option(for: .tier(.high))?.target?.height == 1080)
        // The menu names each choice by its picture size and tells the two High choices apart by id.
        let choices = Self.plan(uhd, hevc: true).options
        #expect(choices.map(\.resolution) == ["4K", "4K", "1080p", "720p", "720p"])
        #expect(Set(choices.map(\.id)).count == choices.count)
        #expect(Self.summary(Self.plan(uhd)).first == "high 1080 9600 h264 estimated")
    }

    // MARK: Measured

    static func entry(mediaID: String = "1", high: Int = 7400) -> QualityMapEntry {
        QualityMapEntry(ratingKey: "301", mediaID: mediaID, tiers: [
            .high: .init(kbps: high, vmaf: 95.2, height: 1080),
            .medium: .init(kbps: 3600, vmaf: 90.1, height: 720),
            .low: .init(kbps: 3600, vmaf: 90.1, height: 720),
        ])
    }

    @Test func measuredScoresReplaceTheEstimate() throws {
        let plan = Self.plan(try Self.media(), map: Self.entry())
        #expect(Self.summary(plan) == ["high 1080 7400 h264 vmaf 95.2", "medium 720 3600 h264 vmaf 90.1"])
        #expect(Self.summary(Self.plan(try Self.media(kbps: 7000), map: Self.entry())) == ["medium 720 3600 h264 vmaf 90.1"])
    }

    @Test func scoresOfAnotherVersionAreIgnored() throws {
        let plan = Self.plan(try Self.media(), map: Self.entry(mediaID: "2"))
        #expect(Self.summary(plan).allSatisfy { $0.hasSuffix("estimated") })
    }

    // MARK: Saved settings

    @Test func qualitiesSavedBeforeTheTiersBecomeTiers() throws {
        func load(_ text: String) throws -> DownloadQuality {
            try JSONDecoder().decode(DownloadQuality.self, from: Data(text.utf8))
        }
        #expect(try load(#"{"converted":{"_0":20000}}"#) == .tier(.high))
        #expect(try load(#"{"converted":{"_0":4000}}"#) == .tier(.medium))
        #expect(try load(#"{"converted":{"_0":2000}}"#) == .tier(.low))
        #expect(try load(#"{"original":{}}"#) == .original)
        for quality in DownloadQuality.choices {
            #expect(try JSONDecoder().decode(DownloadQuality.self, from: JSONEncoder().encode(quality)) == quality)
        }
    }

    @Test func conversionsSavedBeforeTheTiersStillLoad() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(DownloadTests.record())) as? [String: Any])
        json["quality"] = ["converted": ["_0": 4000]]
        json["conversion"] = ["queue": 7, "item": 42, "status": "processing",
                              "target": ["maxVideoBitrateKbps": 4000, "width": 1280, "height": 720]]
        let old = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.quality == .tier(.medium) && old.target == nil && old.stream == nil)
        #expect(old.conversion?.target.videoKbps == 4000 && old.conversion?.target.codec == "h264")
    }

    // MARK: Finding the cap

    @Test func theFirstCapUsuallyAnswers() async throws {
        var asked: [Int] = []
        let found = try await TranscodeLadder.search(for: DownloadTarget(videoKbps: 4000, height: 720)) { cap in
            asked.append(cap)
            return TranscodeLadder.Answer(videoKbps: cap * 919 / 1000 - 257, height: 720)
        }
        #expect(asked == [4650] && found.cap == 4650)
    }

    @Test func searchFollowsTheLineToTheRateAtTheRightSize() async throws {
        var asked: [Int] = []
        let found = try await TranscodeLadder.search(for: DownloadTarget(videoKbps: 6520, height: 1080)) { cap in
            asked.append(cap)
            return TranscodeLadder.Answer(videoKbps: cap * cap / 12_000, height: 1080)
        }
        #expect(asked == [7050, 11100, 8650, 8850])
        #expect(found.cap == 8850 && found.answer.videoKbps == 6526)
    }

    @Test func searchRaisesACapThatMakesTooSmallAPicture() async throws {
        let found = try await TranscodeLadder.search(for: DownloadTarget(videoKbps: 6520, height: 1080)) { cap in
            TranscodeLadder.Answer(videoKbps: cap * 93 / 100, height: cap < 7500 ? 720 : 1080)
        }
        #expect(found.answer.height == 1080 && found.cap >= 7500)
    }

    // MARK: Playlists

    static let media = """
    #EXTM3U
    #EXT-X-VERSION:3
    #EXT-X-TARGETDURATION:8
    #EXT-X-MEDIA-SEQUENCE:0
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXTINF:8, nodesc
    00000.ts
    #EXTINF:8, nodesc
    00001.ts
    #EXTINF:4.5, nodesc
    00002.ts
    #EXT-X-ENDLIST
    """

    @Test func playlistsListTheTitleFromItsStart() throws {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1280x720\nsession/abc/base/index.m3u8\n"
        #expect(HLSPlaylist.variant(in: master) == "session/abc/base/index.m3u8")
        let segments = try #require(HLSPlaylist.segments(in: Self.media))
        #expect(segments.map(\.uri) == ["00000.ts", "00001.ts", "00002.ts"])
        #expect(segments.map(\.start) == [0, 8, 16] && segments.last?.end == 20.5)
        #expect(HLSPlaylist.next(after: 0, in: segments) == 0)
        #expect(HLSPlaylist.next(after: 8, in: segments) == 1)
        #expect(HLSPlaylist.next(after: 9.5, in: segments) == 1)
        #expect(HLSPlaylist.next(after: 20.5, in: segments) == nil)
        #expect(HLSPlaylist.segments(in: master) == nil)
    }

    // MARK: Joining sessions

    /// One 188-byte packet: a PES start with `pts` when `stream` is set, else a continuation.
    static func packet(pid: Int, stream: UInt8? = nil, pts: Int64 = 0, keyframe: Bool = false) -> Data {
        var bytes = [UInt8](repeating: 0xFF, count: 188)
        bytes[0] = 0x47
        bytes[1] = UInt8(pid >> 8) | (stream == nil ? 0 : 0x40)
        bytes[2] = UInt8(pid & 0xFF)
        bytes[3] = 0x30
        bytes[4] = 1
        bytes[5] = keyframe ? 0x40 : 0
        if let stream {
            let pes: [UInt8] = [
                0, 0, 1, stream, 0, 0, 0x80, 0x80, 5,
                UInt8(0x21 | ((pts >> 29) & 0x0E)), UInt8((pts >> 22) & 0xFF), UInt8(0x01 | ((pts >> 14) & 0xFE)),
                UInt8((pts >> 7) & 0xFF), UInt8(0x01 | ((pts << 1) & 0xFE)),
            ]
            bytes.replaceSubrange(6..<6 + pes.count, with: pes)
        }
        return Data(bytes)
    }

    static func video(_ pts: Int64, keyframe: Bool = false) -> Data { packet(pid: 256, stream: 0xE0, pts: pts, keyframe: keyframe) }
    static func audio(_ pts: Int64) -> Data { packet(pid: 257, stream: 0xC0, pts: pts) }

    @Test func aNewSessionsRepeatIsDroppedUpToTheNextKeyframe() {
        let saved = TransportStream.Timestamps(video: 900_000, audio: 901_000)
        let pat = Self.packet(pid: 0)
        let repeated = Self.video(890_000, keyframe: true) + Self.packet(pid: 256) + Self.audio(899_000)
        let late = Self.video(903_000) + Self.audio(902_000)
        let next = Self.video(990_000, keyframe: true) + Self.packet(pid: 256)
        let segment = pat + repeated + late + next

        let joined = TransportStream.trimmed(segment, after: saved)

        #expect(joined.data == pat + Self.audio(902_000) + next && joined.resumed)
        #expect(TransportStream.latest(in: joined.data, after: saved) == TransportStream.Timestamps(video: 990_000, audio: 902_000))
        #expect(!TransportStream.trimmed(pat + late, after: saved).resumed)
    }

    @Test func segmentsOnAnotherTimelineOrCutShortStayWhole() {
        let saved = TransportStream.Timestamps(video: 90_000_000, audio: 90_000_000)
        let restarted = Self.video(0, keyframe: true) + Self.audio(0)
        #expect(TransportStream.trimmed(restarted, after: saved).data == restarted)
        let cut = Self.video(1, keyframe: true).dropLast()
        #expect(TransportStream.trimmed(Data(cut), after: saved).data == Data(cut))
    }

    // MARK: Saving segments

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "streamed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func aWriteCutShortIsDroppedOnResume() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "download-1.part")
        var stream = DownloadRecord.Stream(session: "s")
        try StreamedFile.prepare(file, stream: &stream)
        try StreamedFile.append(Data("first".utf8), ending: 8, to: file, stream: &stream)
        #expect(stream.bytes == 5 && stream.pieces == 1 && stream.saved == 8)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("half".utf8))
        try handle.close()
        try StreamedFile.prepare(file, stream: &stream)
        try StreamedFile.append(Data("second".utf8), ending: 16, to: file, stream: &stream)

        #expect(try Data(contentsOf: file) == Data("firstsecond".utf8))
        var lost = stream
        lost.bytes = 99
        try StreamedFile.prepare(file, stream: &lost)
        #expect(lost.bytes == 0 && lost.saved == 0)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func piecesFetchedInTheBackgroundJoinInOrder() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "download-1.part")
        var stream = DownloadRecord.Stream(session: "s")
        try StreamedFile.prepare(file, stream: &stream)
        func piece(_ number: Int, _ end: Double, _ text: String) throws {
            try Data(text.utf8).write(to: folder.appending(path: StreamedFile.pieceName(of: file, number: number, end: end)))
        }
        try piece(0, 8, "a")
        try piece(2, 24, "c")

        let first = try StreamedFile.absorb(into: file, stream: &stream)
        #expect(first.map(\.lastPathComponent) == ["download-1.part.0-8000.ts"] && stream.saved == 8)
        first.forEach { try? FileManager.default.removeItem(at: $0) }
        try piece(1, 16, "b")
        _ = try StreamedFile.absorb(into: file, stream: &stream)

        #expect(try Data(contentsOf: file) == Data("abc".utf8))
        #expect(stream.pieces == 3 && stream.saved == 24)
    }

    // MARK: HomeLabber

    static let config = HomeLabberConfig(address: URL(string: "https://homelabber.example.net")!, token: "hl_0123456789abcdef0123")

    static func client(_ answer: @escaping @Sendable (PlexRequest) throws -> PlexHTTPResponse) -> (HomeLabberClient, FakeTransport) {
        let transport = FakeTransport { request, _ in try answer(request) }
        return (HomeLabberClient(config: config, transport: transport), transport)
    }

    @Test func parseAcceptsHTTPSAnywhereAndHTTPOnlyAtHome() throws {
        let token = "hl_0123456789abcdef0123"
        #expect(try HomeLabberConfig.parse(address: " https://homelabber.example.net/ ", token: token).get().token == token)
        #expect((try? HomeLabberConfig.parse(address: "http://192.168.1.69:3009", token: token).get()) != nil)
        #expect(HomeLabberConfig.parse(address: "http://homelabber.example.net", token: token) == .failure(.plaintext))
        #expect(HomeLabberConfig.parse(address: "homelabber.example.net", token: token) == .failure(.scheme))
        #expect(HomeLabberConfig.parse(address: "https://homelabber.example.net", token: "short") == .failure(.token))
        #expect(HomeLabberConfig.parse(address: "https://homelabber.example.net", token: "has a space in it ok") == .failure(.token))
    }

    @Test func entryReadsTheTiersWithTheBearerToken() async throws {
        let (client, transport) = Self.client { _ in
            json([
                "ratingKey": "301", "mediaId": 1, "scoredAt": "2026-11-12T03:00:00Z", "encoder": "h264_vaapi",
                "sourceHeight": 1080, "fps": 23.976,
                "tiers": [
                    "high": ["kbps": 7400, "vmaf": 95.2, "height": 1080],
                    "medium": ["kbps": 3600, "vmaf": 90.1, "height": 720],
                    "low": ["kbps": 2960, "vmaf": 86.4, "height": 720],
                ],
                "curve": [["kbps": 2960, "vmaf": 86.4, "height": 720], ["kbps": 7400, "vmaf": 95.2, "height": 1080]],
            ])
        }

        let entry = try #require(try await client.entry(server: "machine-1", ratingKey: "301"))

        #expect(entry.mediaID == "1" && entry.encoder == "h264_vaapi" && entry.fps == 23.976 && entry.curve.count == 2)
        #expect(entry.tiers[.medium] == QualityMapEntry.Point(kbps: 3600, vmaf: 90.1, height: 720))
        #expect(entry.scoredAt == Date(timeIntervalSince1970: 1_794_452_400))
        let request = try #require(await transport.requests(to: "/api/media-quality/v1/servers/machine-1/items/301").first)
        #expect(request.headers["Authorization"] == "Bearer \(Self.config.token)")
    }

    @Test func entryAnswersNothingUntilScoredAndNamesFailures() async throws {
        #expect(try await Self.client { _ in json([:], status: 404) }.0.entry(server: "m", ratingKey: "1") == nil)
        await #expect(throws: HomeLabberError.badToken) { try await Self.client { _ in json([:], status: 401) }.0.entry(server: "m", ratingKey: "1") }
        await #expect(throws: HomeLabberError.notHomeLabber) {
            try await Self.client { _ in PlexHTTPResponse(status: 200, body: Data("<html>".utf8)) }.0.entry(server: "m", ratingKey: "1")
        }
        await #expect(throws: HomeLabberError.timedOut) { try await Self.client { _ in throw NetworkFailure.timedOut }.0.status() }
        await #expect(throws: HomeLabberError.unreachable) { try await Self.client { _ in throw NetworkFailure.offline }.0.status() }
    }

    @Test func statusSaysHowFarScoringHasCome() async throws {
        let (client, _) = Self.client { _ in
            json(["enabled": true, "scored": 120, "total": 239, "running": true, "lastRun": NSNull(), "encoder": "h264_vaapi"])
        }
        #expect(try await client.status() == QualityMapStatus(enabled: true, scored: 120, total: 239, running: true, lastRun: nil, encoder: "h264_vaapi"))
    }
}
