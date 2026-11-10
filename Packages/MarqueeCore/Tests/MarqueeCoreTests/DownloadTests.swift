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
             "Part": [["id": 11, "key": "/library/parts/11/1700000000/file.mkv", "size": 2_000_000_000, "container": "mkv"]]],
            ["id": 2, "duration": 3_600_000, "bitrate": 25000, "width": 3840, "height": 2160, "container": "mkv",
             "Part": [["id": 21, "key": "/library/parts/21/1700000000/file.mkv", "size": 9_000_000_000]]],
        ],
    ] }

    static func record(quality: DownloadQuality = .original) throws -> DownloadRecord {
        let item = try decode(PlexMetadata.self, episode)
        return DownloadRecord(item: item, scope: DownloadScope(server: "machine-1", profile: ""), quality: quality, mediaIndex: 0, addedAt: Date(timeIntervalSince1970: 0))
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

    @Test func rangeAnswersAreJudged() {
        let asked: Range<Int64> = 100..<200
        #expect(RangeReply.judge(status: 206, contentRange: "bytes 100-199/4096", contentLength: 100, retryAfter: nil, requested: asked) == .partial(length: 4096))
        #expect(RangeReply.judge(status: 206, contentRange: "bytes 0-99/4096", contentLength: 100, retryAfter: nil, requested: asked) == .whole(length: nil))
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

    @Test func storeKeepsRecordsAndBuildsTheOfflineTitle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(root: root)
        var record = try Self.record(quality: .converted(.mbps4))
        record.scope = DownloadScope(server: "../machine", profile: "uuid-1")
        record.received = ByteSpans([0..<10])
        try store.makeFolder(for: record)
        let snapshot = try JSONSerialization.data(withJSONObject: ["MediaContainer": ["Metadata": [Self.episode]]])
        try snapshot.write(to: store.metadataFile(for: record))
        let decision: [String: Any] = ["MediaContainer": ["Metadata": [["ratingKey": "301", "Media": [["id": 9, "container": "mp4"]]]]]]
        try JSONSerialization.data(withJSONObject: decision).write(to: store.decisionFile(for: record))

        try store.saveIndex([record])

        #expect(store.loadIndex() == [record])
        #expect(store.folder(for: record).path().hasSuffix("/___machine/uuid-1/301/"))
        #expect(try store.offlineItem(for: record).media.map(\.id) == [9])
        #expect(store.bytesOnDisk() > 0)
        try store.remove(record)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: record).path()))
    }
}
