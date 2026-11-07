import MarqueeCore
import SwiftUI

/// Home (DESIGN §8.1): Continue Watching as 16:9 cards, then the server's shelves in its order.
struct HomeView: View {
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(LibraryChanges.self) private var changes
    @State private var hubs = Remote<[PlexHub]>()

    var body: some View {
        WidthReader { width in
            RemoteContent(remote: hubs) { hubs in
                content(hubs, width: width)
            } skeleton: {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s7) {
                        ContinueSkeleton(cardWidth: Self.cardWidth(for: width))
                        Skeleton.Shelf()
                        Skeleton.Shelf()
                    }
                    .padding(.vertical, Space.s3)
                }
                .scrollDisabled(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ProfileButton() }
        }
        .task(id: LoadKey(library: library?.instance, attempt: hubs.attempt, extra: changes.revision)) {
            await load()
        }
    }

    @ViewBuilder
    private func content(_ hubs: [PlexHub], width: CGFloat) -> some View {
        let continuing = hubs.first(where: Self.isContinueWatching)
        let shelves = Self.shelves(hubs)
        if (continuing?.items.isEmpty ?? true) && shelves.isEmpty {
            EmptyState(
                title: "Nothing here yet",
                message: "Add some on the server.",
                systemImage: "film.stack",
                action: EmptyState.Action(title: "Refresh", systemImage: "arrow.clockwise") { self.hubs.retry() }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.s7) {
                    if let continuing, !continuing.items.isEmpty, width > 0 {
                        ContinueShelf(hub: continuing, cardWidth: Self.cardWidth(for: width), setShown: setShown)
                    }
                    ForEach(shelves) { hub in
                        PosterShelf(hub: hub)
                    }
                }
                .padding(.vertical, Space.s3)
            }
            .refreshable { await load() }
        }
    }

    /// About 82% of a phone's width, so the next card peeks (DESIGN §4.1); on a wide screen (landscape)
    /// about a third, so a card and its caption stay above the floating tab bar (402 pt of height on its
    /// side) and nearly three show.
    private static func cardWidth(for width: CGFloat) -> CGFloat {
        let shown = max(width, 320)
        return (shown * (shown < 600 ? 0.82 : 0.33)).rounded()
    }

    private func load() async {
        guard let library else { return }
        await hubs.load { try await library.promotedHubs() }
    }

    /// Takes a card out of Continue Watching, or puts it back where it was, ahead of the server.
    private func setShown(_ shown: Bool, _ item: PlexMetadata, at index: Int) {
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
            hubs.update { hubs in
                guard let row = hubs.firstIndex(where: Self.isContinueWatching) else { return }
                hubs[row].items.removeAll { $0.ratingKey == item.ratingKey }
                if shown { hubs[row].items.insert(item, at: min(index, hubs[row].items.count)) }
            }
        }
    }

    nonisolated static func isContinueWatching(_ hub: PlexHub) -> Bool {
        hub.style == "hero" || hub.identifier == "home.continue"
    }

    /// The hubs after Continue Watching that hold films or TV, in server order, without empty ones.
    nonisolated static func shelves(_ hubs: [PlexHub]) -> [PlexHub] {
        hubs.compactMap { hub in
            guard !isContinueWatching(hub), hub.type.map(videoHubTypes.contains) ?? true else { return nil }
            var hub = hub
            hub.items.removeAll { $0.type == .playlist || $0.type == .unknown }
            return hub.items.isEmpty ? nil : hub
        }
    }

    private nonisolated static let videoHubTypes: Set<String> = ["movie", "show", "season", "episode", "mixed", "clip"]
}

/// The Continue Watching row: snapping 16:9 cards. A tap resumes; a long press offers Details, Mark
/// Watched and Remove from Continue Watching.
private struct ContinueShelf: View {
    let hub: PlexHub
    let cardWidth: CGFloat
    let setShown: @MainActor (Bool, PlexMetadata, Int) -> Void

    @Environment(\.sessionActions) private var session
    @Environment(\.openRoute) private var openRoute
    private let actions = ItemActions()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ShelfHeader(title: hub.title.isEmpty ? "Continue Watching" : hub.title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.s3) {
                    ForEach(Array(hub.items.enumerated()), id: \.element.id) { index, item in
                        let zoomID = "continue/\(item.ratingKey)"
                        Button {
                            session.play(item)
                        } label: {
                            ContinueCard(item: item, width: cardWidth, zoomID: zoomID)
                        }
                        .buttonStyle(PressButtonStyle(cornerRadius: Radius.card))
                        .contextMenu { menu(item, index: index, zoomID: zoomID) }
                        .accessibilityHint("Resumes playback")
                        .accessibilityActions { menu(item, index: index, zoomID: zoomID) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Space.inset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private func menu(_ item: PlexMetadata, index: Int, zoomID: String) -> some View {
        Button("Details", systemImage: "info.circle") {
            openRoute(.item(ratingKey: item.ratingKey, zoomID: zoomID))
        }
        Button("Mark Watched", systemImage: "checkmark.circle") {
            actions.setWatched(true, item) { watched in setShown(!watched, item, index) }
        }
        Button("Remove from Continue Watching", systemImage: "minus.circle") {
            actions.removeFromContinueWatching(item) { hidden in setShown(!hidden, item, index) }
        }
    }
}

/// A Continue Watching card: the 16:9 art, then under it, never over it, the progress, the title and
/// "S2 · E5 · 42 min left" (DESIGN §8.1).
private struct ContinueCard: View {
    let item: PlexMetadata
    let width: CGFloat
    let zoomID: String

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            PlexArtView(path: item.cardArtPath, size: CGSize(width: width, height: (width * 9 / 16).rounded()))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .zoomSource(zoomID, cornerRadius: Radius.card)
            ProgressBar(value: item.progress ?? 0)
                .opacity(item.progress == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: Space.s1 / 2) {
                Text(item.posterTitle)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                if let line = item.continueLine {
                    Text(line)
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                        .monospacedDigit()
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenSummary)
    }
}

/// Fills in the shape of the Continue Watching row while Home loads.
private struct ContinueSkeleton: View {
    let cardWidth: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Capsule().fill(theme.trackOff).frame(width: 200, height: 20)
            HStack(spacing: Space.s3) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: cardWidth, height: (cardWidth * 9 / 16).rounded())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(.leading, Space.inset)
        .accessibilityHidden(true)
    }
}

private extension PlexMetadata {
    /// Wide art for a card: a show's backdrop for an episode, so a still never gives the plot away.
    var cardArtPath: String? {
        type == .episode ? (grandparentArt ?? art ?? thumb) : (art ?? thumb)
    }

    /// "S2 · E5 · 42 min left".
    var continueLine: String? {
        let parts = [episodeCode, minutesLeft.map(ItemText.left)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
