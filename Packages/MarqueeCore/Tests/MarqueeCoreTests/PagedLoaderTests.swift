import Foundation
import Testing
@testable import MarqueeCore

@MainActor
struct PagedLoaderTests {
    struct Row: Identifiable, Sendable, Hashable {
        var id: Int
    }

    /// A list of rows numbered from 0 that records every page request.
    actor Server {
        private(set) var requests: [[Int]] = []
        private var rows: [Int]

        init(total: Int) {
            rows = Array(0..<total)
        }

        func insertAtFront(_ id: Int) {
            rows.insert(id, at: 0)
        }

        func page(_ start: Int, _ size: Int) -> PlexPage<Row> {
            requests.append([start, size])
            return PlexPage(items: rows.dropFirst(start).prefix(size).map(Row.init), totalSize: rows.count)
        }
    }

    @Test func nextPageLoadsOnlyNearTheEnd() async {
        let server = Server(total: 20)
        let loader = PagedLoader<Row>(pageSize: 8)
        await loader.reload { await server.page($0, $1) }

        await loader.loadMoreIfNeeded(after: 1)
        #expect(loader.items.count == 8)
        await loader.loadMoreIfNeeded(after: 2)
        await loader.loadMoreIfNeeded(after: 15)
        await loader.loadMoreIfNeeded(after: 19)

        #expect(loader.items.map(\.id) == Array(0..<20))
        #expect(await server.requests == [[0, 8], [8, 8], [16, 8]])
    }

    @Test func overlappingPageSkipsRowsAlreadyShown() async {
        let server = Server(total: 20)
        let loader = PagedLoader<Row>(pageSize: 8)
        await loader.reload { await server.page($0, $1) }
        await server.insertAtFront(100)

        await loader.loadMoreIfNeeded(after: 7)
        #expect(loader.items.map(\.id) == Array(0..<15))
        await loader.loadMoreIfNeeded(after: 14)

        #expect(loader.items.map(\.id) == Array(0..<20))
        #expect(await server.requests == [[0, 8], [8, 8], [16, 8]])
    }

    @Test func pageForAnOlderReloadIsDropped() async {
        let loader = PagedLoader<Row>(pageSize: 4)
        let started = Gate()
        let release = Gate()

        let slow = Task {
            await loader.reload { _, _ in
                await started.open()
                await release.wait()
                return PlexPage(items: [Row(id: 1)], totalSize: 1)
            }
        }
        await started.wait()
        await loader.reload { _, _ in PlexPage(items: [Row(id: 2)], totalSize: 1) }
        await release.open()
        await slow.value

        #expect(loader.items.map(\.id) == [2])
        #expect(!loader.isLoading)
    }

    @Test func jumpLoadsThroughTheTargetInOneRequest() async {
        let server = Server(total: 40)
        let loader = PagedLoader<Row>(pageSize: 4)
        await loader.reload { await server.page($0, $1) }

        await loader.ensureLoaded(through: 13)
        await loader.ensureLoaded(through: 10)

        #expect(loader.items.count == 17)
        #expect(await server.requests == [[0, 4], [4, 13]])
    }
}
