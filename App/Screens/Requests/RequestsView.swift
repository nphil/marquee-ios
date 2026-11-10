import MarqueeCore
import SwiftUI

struct RequestsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openRoute) private var openRoute
    @State private var page = Page.discover
    @State private var text = ""
    @State private var shelves: [SeerrShelf: [SeerrTitle]]?
    @State private var requests: [SeerrRequestItem]?
    @State private var searchResults: [SeerrTitle]?
    @State private var searchQuery = ""
    @State private var discoverError: String?
    @State private var requestsError: String?
    @State private var searchError: String?
    @State private var discoverAttempt = 0
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
                    if client == nil {
                        EmptyState(title: "Set up Seerr", message: "Add Seerr in Settings under Integrations to discover and request movies and series.", systemImage: "plus.rectangle.on.folder")
                    } else {
                        Picker("Requests", selection: $page) {
                            Text("Discover").tag(Page.discover)
                            Text("My Requests").tag(Page.requests)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, Space.inset)
                        if !query.isEmpty {
                            searchContent(width: width)
                        } else if page == .discover {
                            discoverContent(width: width)
                        } else {
                            requestsContent
                        }
                    }
                }
                .padding(.top, Space.s2)
                .padding(.bottom, Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollHeader()
            .tabBarFollowsScroll()
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle("Requests")
        .toolbarTitleDisplayMode(.inlineLarge)
        .background(theme.canvas)
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search movies and series")
        .task(id: LoadID(client: clientID, attempt: discoverAttempt, extra: String(session.seerr.requestsSent))) {
            guard let client else { return }
            await loadDiscover(client)
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
                searchError = Self.message(error)
            }
        }
    }

    @ViewBuilder private func discoverContent(width: CGFloat) -> some View {
        if let shelves {
            let visible = SeerrShelf.allCases.filter { !(shelves[$0] ?? []).isEmpty }
            if visible.isEmpty {
                EmptyState(title: "Nothing to discover", message: "There are no titles to show right now.", systemImage: "film.stack")
            } else {
                ForEach(visible) { shelf in
                    VStack(alignment: .leading, spacing: Space.s2) {
                        ShelfHeader(title: shelf.title)
                            .padding(.horizontal, Space.inset)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: Space.s3) {
                                ForEach(shelves[shelf] ?? []) { title in
                                    titleButton(title, width: 120)
                                }
                            }
                            .padding(.horizontal, Space.inset)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
        } else if let discoverError {
            failure(discoverError) { discoverAttempt += 1 }
        } else {
            Skeleton.Shelf().padding(.horizontal, Space.inset)
        }
    }

    @ViewBuilder private func searchContent(width: CGFloat) -> some View {
        let metrics = PosterGridMetrics(width: width - Space.inset * 2, typeSize: typeSize)
        if let searchResults, searchQuery == query {
            if searchResults.isEmpty {
                EmptyState(title: "No results for “\(query)”", message: "Check the spelling or try another word.", systemImage: "magnifyingglass")
            } else {
                LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: Space.s4) {
                    ForEach(searchResults) { title in titleButton(title, width: metrics.cellWidth) }
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

    private func titleButton(_ title: SeerrTitle, width: CGFloat) -> some View {
        Button { openRoute(.seerrTitle(title)) } label: {
            SeerrPoster(title: title, width: width)
        }
        .buttonStyle(.press)
        .accessibilityIdentifier("seerr.poster.\(title.id)")
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

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        EmptyState(title: "Couldn't load Seerr", message: message, systemImage: "exclamationmark.triangle", action: .init(title: "Try Again", systemImage: "arrow.clockwise", perform: retry))
    }

    private static func message(_ error: any Error) -> String {
        if let error = error as? SeerrError { return SeerrView.text(for: error) }
        return "Couldn't reach Seerr. Try again."
    }

    private func loadDiscover(_ client: SeerrClient) async {
        shelves = nil
        discoverError = nil
        let result = await withTaskGroup(of: (SeerrShelf, Result<[SeerrTitle], any Error>).self) { group in
            for shelf in SeerrShelf.allCases {
                group.addTask {
                    do { return (shelf, .success(try await client.discover(shelf))) }
                    catch { return (shelf, .failure(error)) }
                }
            }
            var loaded: [SeerrShelf: [SeerrTitle]] = [:]
            var error: (any Error)?
            for await (shelf, result) in group {
                switch result {
                case .success(let titles): loaded[shelf] = titles
                case .failure(let failure): error = failure
                }
            }
            return (loaded, error)
        }
        guard !Task.isCancelled else { return }
        if result.0.isEmpty { discoverError = result.1.map(Self.message) ?? "Couldn't load Seerr." }
        else { shelves = result.0 }
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
            requestsError = Self.message(error)
        }
    }
}

private struct SeerrPoster: View {
    let title: SeerrTitle
    let width: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            PlexArtView(path: TMDBImage.url(title.posterPath, pixels: width * scale)?.absoluteString, size: PosterCell.artSize(width: width))
                .overlay(alignment: .topTrailing) {
                    if let badge = title.badge {
                        Image(systemName: symbol(badge))
                            .textRole(.caption)
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, Space.s2)
                            .padding(.vertical, Space.s1 / 2)
                            .background(theme.canvas, in: Capsule())
                            .padding(Space.s2)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: width >= 96 ? Radius.tile : Radius.control, style: .continuous))
            Text(title.name).textRole(.caption).fontWeight(.semibold).foregroundStyle(theme.ink).lineLimit(1)
            Text(title.badge?.title ?? title.year.map(String.init) ?? " ")
                .textRole(.caption).foregroundStyle(theme.ink2).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.name)
        .accessibilityValue(title.badge?.title ?? title.year.map(String.init) ?? "")
    }

    private func symbol(_ badge: SeerrBadge) -> String {
        switch badge {
        case .available: "checkmark"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .processing: "arrow.down"
        case .approved: "clock"
        case .pending: "hourglass"
        case .declined: "xmark"
        case .failed: "exclamationmark.triangle"
        case .blocklisted: "nosign"
        }
    }
}
