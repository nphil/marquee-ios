import MarqueeCore
import SwiftUI

struct RequestsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openRoute) private var openRoute
    @State private var page = Page.discover
    @State private var text = ""
    @State private var feed = DiscoverFeed()
    @State private var requests: [SeerrRequestItem]?
    @State private var searchResults: [SeerrTitle]?
    @State private var searchQuery = ""
    @State private var requestsError: String?
    @State private var searchError: String?
    @State private var requestsAttempt = 0
    @State private var searchAttempt = 0

    private enum Page: Hashable { case discover, requests }
    private struct LoadID: Hashable {
        var client: ObjectIdentifier?
        var attempt: Int
        var extra: String = ""
    }
    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let client = session.seerr.client
        let clientID = client.map(ObjectIdentifier.init)
        WidthReader { width in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if let client {
                        Picker("Requests", selection: $page) {
                            Text("Discover").tag(Page.discover)
                            Text("My Requests").tag(Page.requests)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, Space.inset)
                        if !query.isEmpty {
                            searchContent(width: width)
                        } else if page == .discover {
                            discoverContent(client)
                        } else {
                            requestsContent
                        }
                    } else {
                        EmptyState(title: "Set up Seerr", message: "Add Seerr in Settings under Integrations to discover and request movies and series.", systemImage: "plus.rectangle.on.folder")
                    }
                }
                .padding(.top, Space.s2)
                .padding(.bottom, Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .refreshable { await refreshDiscover(client) }
            .scrollHeader()
            .tabBarFollowsScroll()
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle("Requests")
        .toolbarTitleDisplayMode(.inlineLarge)
        .background(theme.canvas)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search movies and series")
        .task(id: clientID) {
            if let client { feed.use(client) }
        }
        .onChange(of: session.seerr.requestsSent) {
            feed.invalidate()
        }
        .task(id: LoadID(client: clientID, attempt: requestsAttempt, extra: String(session.seerr.requestsSent))) {
            guard let client else { return }
            await loadRequests(client)
        }
        .task(id: LoadID(client: clientID, attempt: searchAttempt, extra: query)) {
            guard let client, !query.isEmpty else { return }
            let words = query
            searchResults = nil
            searchError = nil
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let titles = try await client.search(words)
                guard !Task.isCancelled else { return }
                searchQuery = words
                searchResults = titles
            } catch {
                guard !Task.isCancelled else { return }
                searchError = SeerrView.message(for: error)
            }
        }
    }

    @ViewBuilder private func discoverContent(_ client: SeerrClient) -> some View {
        if feed.hasFailed {
            if let error = feed.failure {
                failure(SeerrView.message(for: error)) { feed.reset() }
            } else {
                EmptyState(title: "Nothing to discover", message: "There are no titles to show right now.", systemImage: "film.stack")
            }
        } else {
            DiscoverRows(feed: feed, client: client)
        }
    }

    /// Pull to refresh on Discover asks every row again; the other pages have nothing to refresh.
    private func refreshDiscover(_ client: SeerrClient?) async {
        guard let client, page == .discover, query.isEmpty else { return }
        await feed.refresh(using: client)
    }

    @ViewBuilder private func searchContent(width: CGFloat) -> some View {
        let metrics = PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize)
        if let searchResults, searchQuery == query {
            if searchResults.isEmpty {
                EmptyState(title: "No results for “\(query)”", message: "Check the spelling or try another word.", systemImage: "magnifyingglass")
            } else {
                LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
                    ForEach(searchResults) { title in SeerrTitleButton(title: title, width: metrics.cellWidth) }
                }
                .padding(.horizontal, Space.inset)
            }
        } else if let searchError {
            failure(searchError) { searchAttempt += 1 }
        } else {
            Skeleton.Grid(metrics: metrics).padding(.horizontal, Space.inset)
        }
    }

    @ViewBuilder private var requestsContent: some View {
        if let requests {
            if requests.isEmpty {
                EmptyState(title: "No requests yet", message: "Movies and series requested from Seerr will appear here.", systemImage: "text.badge.plus")
            } else {
                LazyVStack(spacing: Space.s3) {
                    ForEach(requests) { item in
                        if let title = item.title {
                            Button { openRoute(.seerrTitle(title)) } label: { requestRow(item) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("seerr.request.\(item.id)")
                        } else {
                            requestRow(item)
                                .accessibilityIdentifier("seerr.request.\(item.id)")
                        }
                    }
                }
                .padding(.horizontal, Space.inset)
            }
        } else if let requestsError {
            failure(requestsError) { requestsAttempt += 1 }
        } else {
            Skeleton.Rows(artSize: CGSize(width: 56, height: 84)).padding(.horizontal, Space.inset)
        }
    }

    private func requestRow(_ item: SeerrRequestItem) -> some View {
        let request = item.request
        let details = [request.seasons.isEmpty ? nil : "Season\(request.seasons.count == 1 ? "" : "s") \(request.seasons.sorted().map(String.init).joined(separator: ", "))", request.is4K ? "4K" : nil].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: Space.s3) {
            PlexArtView(path: TMDBImage.url(item.title?.posterPath, pixels: 168)?.absoluteString, size: CGSize(width: 56, height: 84))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(item.title?.name ?? "Unavailable title").foregroundStyle(theme.ink)
                if !details.isEmpty { Text(details).foregroundStyle(theme.ink2) }
                if let date = request.createdAt { Text(date, style: .date).foregroundStyle(theme.ink2) }
                if let badge = request.badge { Chip(title: badge.title) }
            }
            .textRole(.caption)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func failure(_ message: String, retry: @escaping @MainActor () -> Void) -> some View {
        EmptyState(title: "Couldn't load Seerr", message: message, systemImage: "exclamationmark.triangle", action: .init(title: "Try Again", systemImage: "arrow.clockwise", perform: retry))
    }

    private func loadRequests(_ client: SeerrClient) async {
        requests = nil
        requestsError = nil
        do {
            let user = try await client.me()
            let loaded = try await client.requests(of: user)
            guard !Task.isCancelled else { return }
            requests = loaded
        } catch {
            guard !Task.isCancelled else { return }
            requestsError = SeerrView.message(for: error)
        }
    }
}
