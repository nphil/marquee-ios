import Foundation
import Testing
@testable import MarqueeCore

struct DownloadTests {
    static var episode: [String: Any] { [
        "ratingKey": "301", "key": "/library/metadata/301", "type": "episode", "title": "Pilot",
        "grandparentTitle": "The Show", "grandparentRatingKey": "300", "parentRatingKey": "302",
        "parentIndex": 1, "index": 1, "duration": 3_600_000, "viewOffset": 60_000,
        "Media": [
            ["id": 1, "duration": 3_600_000, "bitrate": 6000, "width": 1920, "height": 800, "container": "mkv",
             "Part": [["id": 11, "key": "/library/parts/11/1700000000/file.mkv", "size": 2_000_000_000, "container": "mkv",
                       "Stream": [["id": 77, "streamType": 3, "codec": "srt", "key": "/library/streams/77"]]]]],
            ["id": 2, "duration": 3_600_000, "bitrate": 25000, "width": 3840, "height": 2160, "container": "mkv",
             "Part": [["id": 21, "key": "/library/parts/21/1700000000/file.mkv", "size": 9_000_000_000]]],
        ],
    ] }

    static func record(_ json: [String: Any]? = nil, quality: DownloadQuality = .original) throws -> DownloadRecord {
        let item = try decode(PlexMetadata.self, json ?? episode)
        return DownloadRecord(item: item, scope: DownloadScope(server: "machine-1", profile: ""), quality: quality, mediaIndex: 0, addedAt: Date(timeIntervalSince1970: 0))
    }

    /// An episode of show `show`, or a movie without one, in `phase`; finished at `finished` seconds.
    static func entry(_ key: String, show: String? = nil, episode: Int = 1, phase: DownloadRecord.Phase = .done, finished: TimeInterval = 0) throws -> DownloadRecord {
        var json = Self.episode
        json["ratingKey"] = key
        json["title"] = "Title \(key)"
        json["index"] = episode
        if let show {
            json["grandparentRatingKey"] = show
            json["grandparentTitle"] = "Show \(show)"
        } else {
            json["type"] = "movie"
            json.removeValue(forKey: "grandparentRatingKey")
            json.removeValue(forKey: "grandparentTitle")
        }
        var record = try Self.record(json)
        record.phase = phase
        record.length = 100
        if phase == .done { record.finishedAt = Date(timeIntervalSince1970: finished) }
        return record
    }

    // MARK: Bytes

    @Test func spansJoinWhatTouchesAndKeepGapsInOrder() {
        var spans = ByteSpans([20..<30, 0..<10])
        spans.insert(10..<12)
        spans.insert(25..<40)
        #expect(spans.ranges == [0..<12, 20..<40])
        #expect(spans.byteCount == 32)
        spans.insert(12..<20)
        #expect(spans.isComplete(length: 40) && !spans.isComplete(length: 41))
    }

    @Test func spansSurviveSaving() throws {
        let spans = ByteSpans([0..<5, 9..<12])
        let saved = try JSONEncoder().encode(spans)
        #expect(try JSONDecoder().decode(ByteSpans.self, from: saved) == spans)
    }

    @Test func nextRangeSkipsBytesOnDiskAndInFlight() {
        let spans = ByteSpans([0..<10])
        #expect(spans.next(length: 100, size: 16) == 10..<26)
        #expect(spans.next(length: 100, size: 16, busy: [10..<26]) == 26..<42)
        #expect(spans.next(length: 100, size: 16, busy: [10..<26, 30..<50]) == 26..<30)
        #expect(spans.next(length: 30, size: 64, busy: [10..<26]) == 26..<30)
        #expect(spans.next(length: 10, size: 16) == nil)
    }

    @Test func retriesBackOffToAMinute() {
        #expect((1...7).map(TransferPlan.retryDelay) == [2, 4, 8, 16, 32, 60, 60])
    }

    @Test func onlyConnectionTroubleWaitsForARetry() {
        #expect(TransferPlan.isTransient(URLError(.timedOut)))
        #expect(TransferPlan.isTransient(URLError(.dataNotAllowed)))
        #expect(TransferPlan.isTransient(PlexError.unreachable(.connectionLost)))
        #expect(TransferPlan.isTransient(TransferStatusError(status: 502)))
        #expect(!TransferPlan.isTransient(TransferStatusError(status: 404)))
        #expect(!TransferPlan.isTransient(URLError(.badServerResponse)))
        #expect(!TransferPlan.isTransient(POSIXError(.ENOSPC)))
        #expect(!TransferPlan.isTransient(PlexError.unauthorized))
    }

    @Test func secondConnectionOnlyAwayFromHomeAndOnlyWhenClearlyFaster() {
        #expect(!TransferPlan.triesSecondConnection(isLocal: true))
        #expect(TransferPlan.triesSecondConnection(isLocal: false))
        #expect(TransferPlan.keepsSecondConnection(single: 10, dual: 13))
        #expect(!TransferPlan.keepsSecondConnection(single: 10, dual: 12))
        #expect(!TransferPlan.keepsSecondConnection(single: 0, dual: 5))
    }

    @Test func rangeAnswersAreJudged() {
        let asked: Range<Int64> = 100..<200
        #expect(RangeReply.judge(status: 206, contentRange: "bytes 100-199/4096", contentLength: 100, retryAfter: nil, requested: asked) == .partial(length: 4096))
        #expect(RangeReply.judge(status: 206, contentRange: "bytes 0-99/4096", contentLength: 100, retryAfter: nil, requested: asked) == .whole(length: 4096))
        #expect(RangeReply.judge(status: 206, contentRange: "bytes 50-149/4096", contentLength: 100, retryAfter: nil, requested: asked) == .failed(status: 206))
        #expect(RangeReply.judge(status: 200, contentRange: nil, contentLength: 4096, retryAfter: nil, requested: asked) == .whole(length: 4096))
        #expect(RangeReply.judge(status: 503, contentRange: nil, contentLength: nil, retryAfter: "10", requested: asked) == .notReady(retryAfter: 10))
        #expect(RangeReply.judge(status: 503, contentRange: nil, contentLength: nil, retryAfter: nil, requested: asked) == .notReady(retryAfter: 5))
        #expect(RangeReply.judge(status: 404, contentRange: nil, contentLength: nil, retryAfter: nil, requested: asked) == .failed(status: 404))
    }

    // MARK: Quality

    @Test func conversionNeverAsksForMoreThanTheSource() throws {
        let item = try decode(PlexMetadata.self, Self.episode)
        let scope = PresetTarget.target(for: .mbps20, media: item.media[0])
        #expect(scope == DownloadTarget(maxVideoBitrateKbps: 6000, width: 1920, height: 800))
        let uhd = PresetTarget.target(for: .mbps4, media: item.media[1])
        #expect(uhd == DownloadTarget(maxVideoBitrateKbps: 4000, width: 1280, height: 720))
    }

    @Test func sizeEstimates() throws {
        let item = try decode(PlexMetadata.self, Self.episode)
        let target = DownloadTarget(maxVideoBitrateKbps: 4000, width: 1280, height: 720)
        #expect(DownloadQuality.original.estimatedBytes(media: item.media[0], target: nil) == 2_000_000_000)
        // (4000 + 192) kbps for an hour.
        #expect(DownloadQuality.converted(.mbps4).estimatedBytes(media: item.media[0], target: target) == 1_886_400_000)
    }

    // MARK: Watching offline

    @Test func offlineViewingIsToldInOrder() {
        var watch = OfflineWatch(offset: 60_000)
        let at = Date(timeIntervalSince1970: 1000)
        #expect(watch.sync(serverLastViewed: nil).isEmpty)
        watch.played(to: 120_000, at: at)
        #expect(watch.sync(serverLastViewed: nil) == [.resume(at: 120_000)])
        watch.finished(at: at, told: false)
        #expect(watch.sync(serverLastViewed: nil) == [.watched])
        watch.played(to: 5000, at: at)
        #expect(watch.sync(serverLastViewed: at.addingTimeInterval(-1)) == [.watched, .resume(at: 5000)])
        #expect(watch.sync(serverLastViewed: at.addingTimeInterval(1)).isEmpty)
        watch.synced()
        #expect(watch.sync(serverLastViewed: nil).isEmpty && watch.watched)
    }

    @Test func autoDeleteTakesOnlyFinishedWatchedCopiesNotPlaying() throws {
        var record = try Self.record()
        record.watch.finished(at: .now, told: true)
        #expect(!record.isSpent(autoDeleteWatched: true, playing: nil))
        record.phase = .done
        #expect(record.isSpent(autoDeleteWatched: true, playing: nil))
        #expect(!record.isSpent(autoDeleteWatched: true, playing: "301"))
        #expect(!record.isSpent(autoDeleteWatched: false, playing: nil))
    }

    @Test func autoDeleteIgnoresAViewingFromBeforeTheDownload() throws {
        var record = try Self.record()
        record.phase = .done
        record.watch = OfflineWatch(offset: 0, watched: true)
        record.watch.played(to: 30_000, at: .now)
        #expect(!record.isSpent(autoDeleteWatched: true, playing: nil))
        record.watch.finished(at: .now, told: false)
        record.watch.synced()
        #expect(record.isSpent(autoDeleteWatched: true, playing: nil))
    }

    @Test func watchStateFromOlderIndexesStillLoads() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(OfflineWatch(offset: 5, watched: true))) as? [String: Any])
        json.removeValue(forKey: "finishedHere")
        let watch = try JSONDecoder().decode(OfflineWatch.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(watch.watched && !watch.finishedHere)
    }

    // MARK: Playability

    @Test func originalTheServerMustReEncodeIsRefusedWithAWayOut() throws {
        let mpeg2 = try PlaybackRouteTests.file("mpegts", video: Fixture.video("mpeg2video"))
        let reason = DownloadPlayability.refusal(media: mpeg2.media, part: mpeg2.part, capabilities: PlaybackRouteTests.remuxer)
        #expect(reason?.contains("converted quality") == true)
        let mkv = try PlaybackRouteTests.file("mkv", streams: [Fixture.audio(2, "eng", codec: "dts", isDefault: true)])
        #expect(DownloadPlayability.refusal(media: mkv.media, part: mkv.part, capabilities: PlaybackRouteTests.remuxer) == nil)
    }

    // MARK: Server queue

    @Test func conversionIsQueuedAsAnMP4ForTheTarget() async throws {
        let (library, transport) = PlexLibraryTests.library { request in
            switch request.url.path {
            case "/downloadQueue": container(["DownloadQueue": [["id": 7]]])
            default: container(["AddedQueueItems": [["id": 42, "key": "/library/metadata/301"]]])
            }
        }
        let queue = try await library.downloadQueue()
        let target = DownloadTarget(maxVideoBitrateKbps: 4000, width: 1280, height: 720)

        let item = try await library.addToDownloadQueue(queue, ratingKey: "301", mediaIndex: 1, target: target)

        #expect(queue == 7 && item == 42)
        let add = try #require(await transport.requests(to: "/downloadQueue/7/add").first)
        #expect(add.method == .post)
        #expect(add.url.query("keys") == "/library/metadata/301")
        #expect(add.url.query("mediaIndex") == "1")
        #expect(add.url.query("maxVideoBitrate") == "4000")
        #expect(add.url.query("videoResolution") == "1280x720")
        #expect(add.url.query("location") == "lan")
        #expect(add.headers[PlexHeader.profileExtra]?.contains("container=mp4") == true)
    }

    @Test func queueItemReportsConversionShare() async throws {
        let (library, _) = PlexLibraryTests.library { _ in
            container(["DownloadQueueItem": [[
                "id": 42, "queueId": 7, "key": "/library/metadata/301", "status": "processing",
                "TranscodeSession": ["progress": 42.5, "speed": 3.1],
            ]]])
        }

        let item = try await library.downloadQueueItem(7, item: 42)

        #expect(item.status == .processing && item.progress == 0.425 && item.speed == 3.1)
    }

    @Test func downloadAddressCarriesNoToken() async throws {
        let (library, _) = PlexLibraryTests.library { _ in container([:]) }
        let item = try decode(PlexMetadata.self, Self.episode)

        let url = try await library.downloadURL(part: item.media[0].parts[0])

        #expect(url.path() == "/library/parts/11/1700000000/file.mkv")
        #expect(url.query(PlexHeader.token) == nil && url.query("download") == "1")
    }

    // MARK: Store

    @Test func partialPathsSurvivePersistenceAndDistinguishReaddedRecords() throws {
        let store = DownloadStore(root: URL(fileURLWithPath: "/downloads"))
        let original = try Self.record()
        let replacement = try Self.record()
        #expect(original.id == replacement.id)
        #expect(store.partialFile(for: original) != store.partialFile(for: replacement))
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(original))
        #expect(store.partialFile(for: restored) == store.partialFile(for: original))

        var legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacyJSON.removeValue(forKey: "partialID")
        let legacy = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        #expect(legacy.partialID == nil)
        #expect(store.partialFile(for: legacy).lastPathComponent == "download.part")
        #expect(store.partialFile(for: legacy) != store.partialFile(for: replacement))
    }

    @Test func relativePartIgnoresATrailingSlash() {
        let file = URL(fileURLWithPath: "/var/mobile/Library/Application Support/Downloads/server/account/12345/download-ABCD.part")
        let expected = "Downloads/server/account/12345/download-ABCD.part"
        for support in ["/var/mobile/Library/Application Support", "/var/mobile/Library/Application Support/"] {
            let base = URL(fileURLWithPath: support, isDirectory: true)
            #expect(DownloadStore.relativePart(of: file, under: base) == expected)
            #expect(DownloadStore.file(forPart: expected, under: base).path == file.path)
        }
        #expect(DownloadStore.relativePart(of: file, under: URL(fileURLWithPath: "/tmp/elsewhere")) == nil)
    }

    @Test func storeKeepsRecordsAndBuildsTheOfflineTitle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(root: root)
        var record = try Self.record(quality: .converted(.mbps4))
        record.scope = DownloadScope(server: "../machine", profile: "uuid-1")
        record.received = ByteSpans([0..<10])
        record.subtitles = [DownloadRecord.Subtitle(streamID: 77, fileName: "subtitle-77.srt")]
        try store.makeFolder(for: record)
        let snapshot = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [Self.episode]]])
        try snapshot.write(to: store.metadataFile(for: record))
        let decision: [String: Any] = ["MediaContainer": ["Metadata": [["ratingKey": "301", "Media": [
            ["id": 9, "container": "mp4", "Part": [["id": 90, "key": "/x", "Stream": [["id": 5, "streamType": 1, "codec": "h264"]]]]],
        ]]]]]
        try JSONSerialization.data(withJSONObject: decision).write(to: store.decisionFile(for: record))

        try store.saveIndex([record])

        #expect(store.loadIndex() == [record])
        #expect(store.folder(for: record).path().hasSuffix("/___machine/uuid-1/301/"))
        let offline = try store.offlineItem(for: record)
        #expect(offline.media.map(\.id) == [9])
        #expect(offline.media[0].parts[0].streams.map(\.id) == [5, 77])
        #expect(store.bytesOnDisk() > 0)
        try store.remove(record)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: record).path()))
    }

    @Test func downloadsFolderStaysOutOfBackups() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try DownloadStore(root: root).prepareRoot()
        #if canImport(Darwin)
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #endif
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test func sizeAndStillOfAnOlderDownloadComeFromItsSavedTitle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(root: root)
        var json = Self.episode
        json["thumb"] = "/library/metadata/301/thumb/1"
        var record = try Self.record(json, quality: .converted(.mbps4))
        record.frame = nil
        try store.makeFolder(for: record)
        #expect(store.savedFrame(for: record) == nil && store.savedStillPath(for: record) == nil)
        try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [json]]]).write(to: store.metadataFile(for: record))
        #expect(store.savedFrame(for: record) == DownloadRecord.Frame(width: 1280, height: 720))
        #expect(store.savedStillPath(for: record) == "/library/metadata/301/thumb/1")
        #expect(store.stillFile(for: record).lastPathComponent == "still.jpg" && store.stillFile(for: record).path().hasPrefix(store.folder(for: record).path()))
    }

    // MARK: Lists

    @Test func pictureSizeIsTheConversionsTargetOrTheVersionsOwn() throws {
        let original = try Self.record()
        #expect(original.frame == DownloadRecord.Frame(width: 1920, height: 800) && original.resolution == "1080p")
        let converted = try Self.record(quality: .converted(.mbps4))
        #expect(converted.frame == DownloadRecord.Frame(width: 1280, height: 720) && converted.resolution == "720p")
        var sizeless = Self.episode
        sizeless["Media"] = [["id": 1, "Part": [["id": 11, "key": "/library/parts/11/1700000000/file.mkv"]]]]
        let unknown = try Self.record(sizeless)
        #expect(unknown.frame == nil && unknown.resolution == nil)
    }

    @Test func indexesFromBeforeThePictureSizeStillLoad() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.record())) as? [String: Any])
        #expect(json["frame"] != nil)
        json.removeValue(forKey: "frame")
        let old = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.frame == nil)
    }

    @Test func rowFactsComeFromTheRecord() throws {
        var record = try Self.record()
        #expect(record.showID == "300" && record.seasonEpisode == "S1 E1")
        #expect(record.watchedFraction == 60_000.0 / 3_600_000)
        record.watch.finished(at: .now, told: true)
        #expect(record.watchedFraction == nil)
        record.seasonIndex = nil
        #expect(record.seasonEpisode == "E1")
        record.episodeIndex = nil
        #expect(record.seasonEpisode == nil)
        #expect(try Self.entry("9").showID == nil)
    }

    @Test func stillIsAnEpisodesOwnPictureOrAMoviesBackdrop() throws {
        var json = Self.episode
        #expect(DownloadRecord.stillPath(of: try decode(PlexMetadata.self, json)) == nil)
        json["grandparentArt"] = "/library/metadata/300/art/1"
        #expect(DownloadRecord.stillPath(of: try decode(PlexMetadata.self, json)) == "/library/metadata/300/art/1")
        json["thumb"] = "/library/metadata/301/thumb/1"
        #expect(DownloadRecord.stillPath(of: try decode(PlexMetadata.self, json)) == "/library/metadata/301/thumb/1")
        json["type"] = "movie"
        #expect(DownloadRecord.stillPath(of: try decode(PlexMetadata.self, json)) == nil)
        json["art"] = "/library/metadata/301/art/1"
        #expect(DownloadRecord.stillPath(of: try decode(PlexMetadata.self, json)) == "/library/metadata/301/art/1")
    }

    @Test func listGroupsEpisodesUnderTheirShowAndKeepsMoviesApart() throws {
        let library = DownloadLibrary([
            try Self.entry("1", show: "A", episode: 2, finished: 10),
            try Self.entry("2", show: "B", finished: 30),
            try Self.entry("3", show: "A", episode: 1, finished: 20),
            try Self.entry("4", finished: 5),
            try Self.entry("5", finished: 40),
            try Self.entry("6", show: "C", phase: .downloading),
            try Self.entry("7", show: "B", episode: 2, phase: .paused),
        ])
        #expect(library.shows.map(\.id) == ["B", "A"])
        #expect(library.shows.map(\.title) == ["Show B", "Show A"])
        #expect(library.show("A")?.records.map(\.id) == ["3", "1"] && library.show("A")?.bytes == 200)
        #expect(library.show("B")?.records.map(\.id) == ["2", "7"] && library.show("B")?.bytes == 100)
        #expect(library.show("B")?.poster.id == "2" && library.show("C")?.poster.id == "6")
        #expect(library.show("C") != nil && !library.shows.map(\.id).contains("C") && library.show("D") == nil)
        #expect(library.movies.map(\.id) == ["5", "4"])
        #expect(library.unfinished.map(\.id) == ["6", "7"])
    }

    @Test func storageBarSplitsDownloadsOtherAndFree() {
        let usage = StorageUsage(total: 100, free: 40, downloads: 10)
        #expect(usage.other == 50 && usage.downloadsShare == 0.1 && usage.otherShare == 0.5 && usage.freeShare == 0.4)
        // The free figure counts space iOS can reclaim, so it can leave less in use than the downloads take.
        let squeezed = StorageUsage(total: 100, free: 95, downloads: 20)
        #expect(squeezed.other == 0 && squeezed.downloadsShare == 0.05 && squeezed.freeShare == 0.95)
        #expect(!StorageUsage(total: 0, free: 0, downloads: 5).isKnown)
    }
}
