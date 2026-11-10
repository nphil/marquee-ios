import MarqueeCore
import SwiftUI

/// What the Discover rows hold. Each row loads on its own as it comes near the screen, so rows show one by
/// one as their answers arrive and rows far down cost nothing until scrolled to. A row that fails or comes
/// back empty is hidden; the page counts as failed only when every row did.
///
/// The loads belong to the feed, not to the row views: a lazy stack drops views that scroll away, and a
/// load tied to one would end half-way.
@MainActor @Observable
final class DiscoverFeed {
    enum Content: Sendable {
        case titles([SeerrTitle])
        case genres([SeerrGenre])

        var isEmpty: Bool {
            switch self {
            case .titles(let titles): titles.isEmpty
            case .genres(let genres): genres.isEmpty
            }
        }
    }

    /// What each row shows; a row with nothing to show is absent.
    private(set) var content: [SeerrDiscoverRow: Content] = [:]
    /// The rows whose load has ended, with something to show or without.
    private(set) var settled: Set<SeerrDiscoverRow> = []
    /// The latest failure, for the page when every row failed.
    private(set) var failure: (any Error)?
    /// Bumped to load the rows again; a row's task restarts on it.
    private(set) var generation = 0

    /// How long an answer counts as fresh: coming back to the page within it asks Seerr nothing.
    static let freshFor: TimeInterval = 300

    private struct Start {
        let id: Int
        let at: Date
    }

    @ObservationIgnored private var client: ObjectIdentifier?
    @ObservationIgnored private var starts: [SeerrDiscoverRow: Start] = [:]
    @ObservationIgnored private var tasks: [SeerrDiscoverRow: Task<Void, Never>] = [:]
    @ObservationIgnored private var startCount = 0

    /// Every row answered and none had anything to show.
    var hasFailed: Bool {
        settled.count == SeerrDiscoverRow.all.count && content.isEmpty
    }

    /// Another Seerr, from a new address or profile, starts every row over.
    func use(_ client: SeerrClient) {
        let id = ObjectIdentifier(client)
        guard self.client != id else { return }
        let first = self.client == nil
        self.client = id
        if !first { reset() }
    }

    /// Loads `row` unless it was asked for lately.
    func load(_ row: SeerrDiscoverRow, using client: SeerrClient) {
        use(client)
        if let start = starts[row], Date.now.timeIntervalSince(start.at) < Self.freshFor { return }
        startCount += 1
        let id = startCount
        starts[row] = Start(id: id, at: .now)
        tasks[row] = Task { [weak self] in
            let result = await Self.fetch(row, from: client)
            self?.finish(row, id: id, result)
        }
    }

    /// Loads every row again, quietly: what the rows show stays until the new answer arrives.
    func invalidate() {
        starts = [:]
        generation += 1
    }

    /// Pull to refresh: loads the rows asked for so far again, and waits for them.
    func refresh(using client: SeerrClient) async {
        let asked = SeerrDiscoverRow.all.filter { starts[$0] != nil || settled.contains($0) }
        invalidate()
        for row in asked { load(row, using: client) }
        for row in asked {
            if let task = tasks[row] { await task.value }
        }
    }

    /// Forgets everything and loads afresh: Try Again, or another Seerr.
    func reset() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        starts = [:]
        content = [:]
        settled = []
        failure = nil
        generation += 1
    }

    private static func fetch(_ row: SeerrDiscoverRow, from client: SeerrClient) async -> Result<Content, any Error> {
        do {
            switch row {
            case .shelf(let shelf):
                let titles = try await client.discover(shelf)
                return .success(.titles(titles))
            case .genres(let kind):
                let genres = try await client.genreCards(kind)
                return .success(.genres(genres))
            }
        } catch {
            return .failure(error)
        }
    }

    private func finish(_ row: SeerrDiscoverRow, id: Int, _ result: Result<Content, any Error>) {
        guard starts[row]?.id == id else { return }
        tasks[row] = nil
        switch result {
        case .success(let loaded):
            content[row] = loaded.isEmpty ? nil : loaded
        case .failure(let error):
            // What the row showed before stays. Its next appearance asks again.
            if content[row] == nil { failure = error }
            starts[row] = nil
        }
        settled.insert(row)
    }
}
