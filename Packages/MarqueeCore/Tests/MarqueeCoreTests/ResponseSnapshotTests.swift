import Foundation
import Synchronization
import Testing
@testable import MarqueeCore

struct ResponseSnapshotTests {
    final class Now: Sendable {
        let date = Mutex(Date(timeIntervalSince1970: 1_000_000))
        func advance(_ seconds: TimeInterval) { date.withLock { $0.addTimeInterval(seconds) } }
    }

    let now = Now()
    let folder = FileManager.default.temporaryDirectory.appending(path: "snapshots-\(UUID().uuidString)")
    let alex = SnapshotScope(server: "machine-1", profile: "alex")
    let sam = SnapshotScope(server: "machine-1", profile: "sam")

    func store(_ limits: SnapshotStore.Limits = .init()) -> SnapshotStore {
        let now = now
        return SnapshotStore(directory: folder, limits: limits) { now.date.withLock { $0 } }
    }

    func bytes(_ count: Int) -> Data { Data(repeating: 0x61, count: count) }

    @Test func keyHasNoTokenAndNoOrder() {
        let key = ResponseSnapshot.requestKey(
            path: "/hubs/promoted",
            query: [URLQueryItem(name: "count", value: "12"), URLQueryItem(name: "X-Plex-Token", value: "secret"), URLQueryItem(name: "a", value: "1")],
            headers: [PlexHeader.containerStart: "0", PlexHeader.containerSize: "20"]
        )
        #expect(key == "/hubs/promoted?a=1&count=12 #0+20")
    }

    @Test func aProfileNeverReadsAnotherProfilesSnapshot() {
        let store = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.write(Data("alex rows".utf8), for: "/hubs/promoted", in: alex, epoch: store.epoch)

        #expect(store.read("/hubs/promoted", in: alex)?.body == Data("alex rows".utf8))
        #expect(store.read("/hubs/promoted", in: sam) == nil)
        #expect(store.read("/hubs/promoted", in: SnapshotScope(server: "machine-2", profile: "alex")) == nil)
    }

    @Test func leavingAProfileDropsItsSnapshotsOnEveryServerAndKeepsTheOthers() {
        let store = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = SnapshotScope(server: "machine-2", profile: "alex")
        for scope in [alex, sam, other] { store.write(bytes(10), for: "/x", in: scope, epoch: store.epoch) }

        store.remove(profile: "alex")

        #expect(store.read("/x", in: alex) == nil && store.read("/x", in: other) == nil)
        #expect(store.read("/x", in: sam) != nil)
    }

    @Test func aWriteStartedBeforeASignOutLandsNowhere() {
        let store = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = store.epoch

        store.removeAll()
        store.write(bytes(10), for: "/x", in: alex, epoch: before)

        #expect(store.read("/x", in: alex) == nil)
    }

    @Test func aResponseOverItsBoundIsNotKept() {
        var limits = SnapshotStore.Limits()
        limits.entryBytes = 100
        let store = store(limits)
        defer { try? FileManager.default.removeItem(at: folder) }

        store.write(bytes(101), for: "/big", in: alex, epoch: store.epoch)
        store.write(bytes(100), for: "/fits", in: alex, epoch: store.epoch)

        #expect(store.read("/big", in: alex) == nil && store.read("/fits", in: alex) != nil)
    }

    @Test func aScopeDropsItsOldestResponsesFirst() {
        var limits = SnapshotStore.Limits()
        limits.scopeBytes = 400
        let store = store(limits)
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["/a", "/b", "/c"] {
            store.write(bytes(150), for: name, in: alex, epoch: store.epoch)
            now.advance(1)
        }

        #expect(store.read("/a", in: alex) == nil)
        #expect(store.read("/b", in: alex) != nil && store.read("/c", in: alex) != nil)
    }

    @Test func theStoreDropsTheLeastRecentScopeFirstAndKeepsTheOneJustWritten() {
        var limits = SnapshotStore.Limits()
        limits.totalBytes = 400
        let store = store(limits)
        defer { try? FileManager.default.removeItem(at: folder) }

        for scope in [alex, sam] {
            store.write(bytes(250), for: "/x", in: scope, epoch: store.epoch)
            now.advance(1)
        }

        #expect(store.read("/x", in: alex) == nil && store.read("/x", in: sam) != nil)
    }

    @Test func aSnapshotPastItsAgeIsNotServed() {
        var limits = SnapshotStore.Limits()
        limits.maxAge = 60
        let store = store(limits)
        defer { try? FileManager.default.removeItem(at: folder) }
        store.write(bytes(10), for: "/x", in: alex, epoch: store.epoch)

        now.advance(60)
        #expect(store.read("/x", in: alex) != nil)
        now.advance(1)
        #expect(store.read("/x", in: alex) == nil)
    }

    @Test func replayDecodesWhatRecordingKeptAndSendsNothing() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, transport) = PlexLibraryTests.library { request in
            switch request.url.path {
            case "/hubs/promoted":
                container(["Hub": [["hubIdentifier": "home.movies.recent", "title": "Recently Added", "Metadata": [["ratingKey": "7", "type": "movie", "title": "Sintel"]]]]])
            default:
                container([:])
            }
        }
        let recording = library.snapshotting(ResponseSnapshot(store: store, scope: alex, mode: .record))
        let live = try await recording.promotedHubs()
        // The write runs in the background.
        for _ in 0..<200 where store.read("/hubs/promoted?count=12", in: alex) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let before = await transport.requests.count

        let replay = ResponseSnapshot(store: store, scope: alex, mode: .replay)
        let stored = try await library.snapshotting(replay).promotedHubs()

        #expect(stored.map(\.identifier) == live.map(\.identifier))
        #expect(stored.first?.items.map(\.ratingKey) == ["7"])
        #expect(replay.savedAt == Date(timeIntervalSince1970: 1_000_000))
        #expect(await transport.requests.count == before)
    }

    @Test func replayOfAnotherProfileFindsNothing() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.write(Data(#"{"MediaContainer":{"Hub":[]}}"#.utf8), for: "/hubs/promoted?count=12", in: alex, epoch: store.epoch)
        let (library, _) = PlexLibraryTests.library { _ in container([:]) }

        await #expect(throws: SnapshotUnavailable.self) {
            _ = try await library.snapshotting(ResponseSnapshot(store: store, scope: sam, mode: .replay)).promotedHubs()
        }
    }
}
