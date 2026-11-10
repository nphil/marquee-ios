import MarqueeCore
import SwiftUI

struct SeerrTitleView: View {
    let title: SeerrTitle

    @Environment(AppSession.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.plexLibrary) private var library
    @Environment(\.sessionActions) private var playback
    @Environment(\.openRoute) private var openRoute
    @Environment(\.theme) private var theme
    @State private var remote = Remote<Content>()
    @State private var showingRequest = false

    private struct Content: Sendable {
        let clientID: ObjectIdentifier
        let requestsSent: Int
        let details: SeerrDetails
        let user: SeerrUser
        let settings: SeerrServerSettings
        let plex: PlexMetadata?
    }

    var body: some View {
        WidthReader { width in
            Group {
                if let content = remote.value, content.clientID == clientID,
                   content.requestsSent == session.seerr.requestsSent {
                    page(content, width: width)
                } else if let error = remote.error, !remote.isLoading {
                    EmptyState(title: "Can't load title", message: message(error), systemImage: "exclamationmark.circle",
                               action: .init(title: "Retry", systemImage: "arrow.clockwise", perform: { remote.retry() }))
                } else {
                    DetailSkeleton(width: width)
                        .overlay { LoadingNote { remote.retry() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: LoadKey(library: library?.instance, attempt: remote.attempt,
                          extra: LoadInputs(title: title.id, clientID: clientID, sent: session.seerr.requestsSent))) {
            await load()
        }
        .onChange(of: clientID) { _, _ in showingRequest = false }
        .sheet(isPresented: $showingRequest) {
            if let content = remote.value, content.clientID == clientID {
                SeerrRequestSheet(details: content.details, user: content.user, settings: content.settings,
                                  clientID: content.clientID) {
                    showingRequest = false
                    toasts.show("Requested")
                }
            }
        }
    }

    private struct LoadInputs: Hashable {
        let title: String
        let clientID: ObjectIdentifier?
        let sent: Int
    }

    private var clientID: ObjectIdentifier? {
        session.seerr.client.map(ObjectIdentifier.init)
    }

    @ViewBuilder
    private func page(_ content: Content, width: CGFloat) -> some View {
        let details = content.details
        let current = details.title
        let height = (max(width, 1) * 9 / 16).rounded()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHero(backdrop: TMDBImage.url(current.backdropPath, pixels: width * 2)?.absoluteString,
                           poster: TMDBImage.url(current.posterPath, pixels: width * 2)?.absoluteString,
                           size: CGSize(width: width, height: height))
                VStack(alignment: .leading, spacing: Space.s5) {
                    Text(current.name)
                        .textRole(.title)
                        .foregroundStyle(theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !metadata(details).isEmpty {
                        Text(metadata(details))
                            .textRole(.body)
                            .foregroundStyle(theme.ink2)
                    }
                    if let error = remote.error {
                        ProblemLine(text: message(error))
                        Button("Retry") { remote.retry() }
                    }
                    if let badge = current.media?.badge(is4K: false) {
                        StatusLine(symbol: "info.circle.fill", tint: theme.accent, text: badgeText(badge, media: current.media, is4K: false))
                    }
                    if let badge = current.media?.badge(is4K: true) {
                        StatusLine(symbol: "info.circle.fill", tint: theme.accent, text: "4K · " + badgeText(badge, media: current.media, is4K: true))
                    }
                    HStack(spacing: Space.s3) {
                        if let item = content.plex {
                            if let target = playTarget(item) {
                                Button { playback.play(target) } label: {
                                    Label("Play", systemImage: "play.fill")
                                }
                                .buttonStyle(.pill)
                            }
                            Button { openRoute(.item(ratingKey: item.ratingKey)) } label: {
                                Image(systemName: "arrow.up.right")
                            }
                            .buttonStyle(.round)
                            .accessibilityLabel("Open in Library")
                        }
                        if details.canRequest(is4K: false, user: content.user, settings: content.settings)
                            || details.canRequest(is4K: true, user: content.user, settings: content.settings) {
                            Button("Request", systemImage: "plus") { showingRequest = true }
                                .buttonStyle(.pill)
                        }
                    }
                    if details.watchlistAddRequests(user: content.user, pulsarr: session.seerr.pulsarr) {
                        Text("Adding this to the Watchlist requests it too.")
                            .textRole(.body)
                            .foregroundStyle(theme.ink2)
                    }
                    if let tagline = details.tagline, !tagline.isEmpty {
                        Text(tagline).textRole(.body).foregroundStyle(theme.ink2)
                    }
                    if !current.overview.isEmpty {
                        Synopsis(text: current.overview)
                    }
                }
                .padding(.horizontal, Space.inset)
                .padding(.top, -Space.s7)
            }
            .padding(.bottom, Space.s7)
        }
        .tabBarFollowsScroll()
    }

    private func metadata(_ details: SeerrDetails) -> String {
        var parts: [String] = []
        if let year = details.title.year { parts.append(String(year)) }
        if let runtime = details.runtime { parts.append("\(runtime) min") }
        if !details.genres.isEmpty { parts.append(details.genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func badgeText(_ badge: SeerrBadge, media: SeerrMedia?, is4K: Bool) -> String {
        guard let name = media?.openRequest(is4K: is4K)?.requesterName, !name.isEmpty else { return badge.title }
        return "\(badge.title) · Requested by \(name)"
    }

    private func playTarget(_ item: PlexMetadata) -> PlexMetadata? {
        switch item.type {
        case .movie: item
        case .show: item.onDeck
        default: nil
        }
    }

    private func load() async {
        guard let client = session.seerr.client else {
            await remote.load { throw SeerrError.unreachable }
            return
        }
        let library = library
        let title = title
        let requestsSent = session.seerr.requestsSent
        await remote.load {
            async let details = client.details(title.kind, tmdbID: title.tmdbID)
            async let user = client.me()
            async let settings = client.serverSettings()
            let (loaded, account, options) = try await (details, user, settings)
            var plex: PlexMetadata?
            if let library, let link = loaded.title.media?.plexLink(serverID: library.server.id) {
                switch link {
                case .item(let key):
                    plex = try? await library.metadata(key)
                case .unconfirmed(let key):
                    if let ids = try? await library.externalIDs(key), ids.contains("tmdb://\(title.tmdbID)") {
                        plex = try? await library.metadata(key)
                    }
                }
            }
            return Content(clientID: ObjectIdentifier(client), requestsSent: requestsSent,
                           details: loaded, user: account, settings: options, plex: plex)
        }
    }

    private func message(_ error: any Error) -> String {
        SeerrView.text(for: error as? SeerrError ?? .unreachable)
    }
}

private struct SeerrRequestSheet: View {
    let details: SeerrDetails
    let user: SeerrUser
    let settings: SeerrServerSettings
    let clientID: ObjectIdentifier
    let requested: @MainActor () -> Void

    @Environment(AppSession.self) private var session
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium
    @State private var is4K = false
    @State private var selected: Set<Int> = []
    @State private var sending = false
    @State private var problem: String?
    @State private var alreadyRequested = false

    private var choices: [SeerrSeasonChoice] {
        details.seasonChoices(is4K: is4K, settings: settings)
    }

    private var canSend: Bool {
        !alreadyRequested && session.seerr.client.map(ObjectIdentifier.init) == clientID
            && details.canRequest(is4K: is4K, user: user, settings: settings)
            && (details.title.kind == .movie || !settings.partialRequestsEnabled || !selected.isEmpty)
    }

    var body: some View {
        NavigationStack {
            List {
                if details.canRequest(is4K: true, user: user, settings: settings) {
                    Section {
                        Toggle("Request in 4K", isOn: $is4K)
                            .disabled(!details.canRequest(is4K: false, user: user, settings: settings))
                    }
                    .listRowBackground(theme.sheet)
                }
                if details.title.kind == .tv {
                    Section {
                        if settings.partialRequestsEnabled {
                            ForEach(choices) { choice in
                                Toggle(isOn: Binding(
                                    get: { selected.contains(choice.id) },
                                    set: { if $0 { selected.insert(choice.id) } else { selected.remove(choice.id) } }
                                )) {
                                    HStack {
                                        Text(choice.season.name)
                                        Spacer()
                                        if let badge = choice.badge {
                                            Text(badge.title).foregroundStyle(theme.ink2)
                                        }
                                    }
                                }
                                .disabled(!choice.isRequestable || sending)
                            }
                        } else {
                            Text("All available seasons will be requested.")
                                .foregroundStyle(theme.ink2)
                        }
                    } header: {
                        Text("Seasons")
                    }
                    .listRowBackground(theme.sheet)
                }
                if let problem {
                    Section { ProblemLine(text: problem) }
                        .listRowBackground(theme.sheet)
                }
            }
            .themedList(theme, onCanvas: detent == .large)
            .tint(theme.accent)
            .navigationTitle(details.title.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Request") { send() }.disabled(!canSend || sending)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .presentationDetents([.medium, .large], selection: $detent)
        .preferredColorScheme(themes.presentationScheme(for: theme))
        .onAppear {
            is4K = !details.canRequest(is4K: false, user: user, settings: settings)
            selectAvailable()
        }
        .onChange(of: is4K) { _, _ in selectAvailable() }
    }

    private func selectAvailable() {
        selected = Set(choices.filter(\.isRequestable).map(\.id))
    }

    private func send() {
        guard canSend, !sending else { return }
        sending = true
        problem = nil
        let order = details.order(seasons: selected, is4K: is4K, settings: settings)
        Task {
            guard session.seerr.client.map(ObjectIdentifier.init) == clientID else {
                sending = false
                return
            }
            do {
                try await session.seerr.request(order)
                Haptics.success()
                dismiss()
                requested()
            } catch {
                Haptics.error()
                problem = SeerrView.text(for: error as? SeerrError ?? .unreachable)
                if (error as? SeerrError) == .alreadyRequested {
                    alreadyRequested = true
                }
            }
            sending = false
        }
    }
}
