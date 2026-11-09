import MarqueeCore
import SwiftUI

/// The show's episodes, opened from the player over the playing picture: a season menu and rows as on the
/// show's page (DESIGN §8.4). The playing episode is marked and scrolled into view. A tap plays the
/// episode from where it was left; the menu offers the beginning.
struct EpisodeSheet: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var seasons: [PlexMetadata] = []
    @State private var season: String?
    @State private var episodes: [PlexMetadata]?
    @State private var failed = false
    private let prefetch = ArtPrefetcher()

    /// How many rows below the one on screen have their stills loaded ahead of the scroll.
    private static let prefetchAhead = 6

    private var stillSize: CGSize {
        typeSize.isAccessibilitySize ? CGSize(width: 256, height: 144) : CGSize(width: 128, height: 72)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.s2) {
                        if seasons.count > 1 {
                            seasonMenu
                        }
                        if let episodes {
                            ForEach(Array(episodes.enumerated()), id: \.element.ratingKey) { position, episode in
                                row(episode)
                                    .id(episode.ratingKey)
                                    .onAppear { prefetchStills(after: position, in: episodes) }
                            }
                        }
                    }
                    .padding(.horizontal, Space.inset)
                    .padding(.bottom, Space.s4)
                }
                .background(theme.sheet)
                .overlay {
                    if failed {
                        EmptyState(
                            title: "Can't load episodes",
                            message: "Check the connection to the server.",
                            systemImage: "wifi.exclamationmark",
                            action: .init(title: "Retry", systemImage: "arrow.clockwise") { failed = false; reload() }
                        )
                    }
                }
                .onChange(of: episodes?.map(\.ratingKey)) { _, keys in
                    guard let keys, let first = keys.first else { return }
                    let playing = model.item.ratingKey
                    // A turn later, once the list holds the new rows.
                    Task {
                        if keys.contains(playing) {
                            proxy.scrollTo(playing, anchor: .center)
                        } else {
                            proxy.scrollTo(first, anchor: .top)
                        }
                    }
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadSeasons() }
        .task(id: season) { await loadEpisodes() }
        .accessibilityIdentifier("player.episodeSheet")
    }

    private var seasonTitle: String {
        seasons.first { $0.ratingKey == season }?.title ?? "Season"
    }

    /// Full width and wrapping, so a long season name never clips at large text.
    private var seasonMenu: some View {
        Menu {
            Picker("Season", selection: $season) {
                ForEach(seasons) { entry in
                    Text(entry.title).tag(Optional(entry.ratingKey))
                }
            }
        } label: {
            HStack(spacing: Space.s2) {
                Text(seasonTitle)
                    .textRole(.headline)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .frame(maxWidth: .infinity, minHeight: Size.target, alignment: .leading)
            .background(theme.glass, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .accessibilityLabel("Season")
        .accessibilityValue(seasonTitle)
    }

    private func row(_ episode: PlexMetadata) -> some View {
        let playing = episode.ratingKey == model.item.ratingKey
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s3))
        return Button {
            Haptics.impact(.light)
            model.play(episode: episode, fromStart: false)
            dismiss()
        } label: {
            layout {
                EpisodeStill(episode: episode, size: stillSize)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text([episode.index.map(String.init), episode.title].compactMap { $0 }.joined(separator: " · "))
                        .textRole(.headline)
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: Space.s1) {
                        if playing {
                            Image(systemName: "speaker.wave.2.fill")
                            Text("Now playing")
                        } else if episode.isWatched {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Watched")
                        } else if episode.duration > 0 {
                            Text(runtime(episode))
                        }
                    }
                    .textRole(.caption)
                    .foregroundStyle(playing ? theme.accentText : theme.ink2)
                    if !episode.summary.isEmpty {
                        Text(episode.summary)
                            .textRole(.caption)
                            .foregroundStyle(theme.ink2)
                            .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Space.s2)
            .frame(minHeight: Size.rowMin)
            .background {
                if playing {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(theme.glass)
                }
            }
            .overlay {
                if playing {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: Space.s1 / 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.play(episode: episode, fromStart: true)
                dismiss()
            } label: {
                Label("Play from Beginning", systemImage: "arrow.counterclockwise")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(episode, playing: playing))
        .accessibilityAddTraits(playing ? .isSelected : [])
        .accessibilityAction(named: "Play from beginning") {
            model.play(episode: episode, fromStart: true)
            dismiss()
        }
        .accessibilityIdentifier("player.episode.\(episode.ratingKey)")
    }

    private func accessibilityLabel(_ episode: PlexMetadata, playing: Bool) -> String {
        var parts: [String] = []
        if let index = episode.index { parts.append("Episode \(index)") }
        parts.append(episode.title)
        if playing {
            parts.append("Now playing")
        } else if episode.isWatched {
            parts.append("Watched")
        } else if episode.viewOffset > 0, episode.duration > 0 {
            parts.append("In progress, \(runtime(episode))")
        } else if episode.duration > 0 {
            parts.append(runtime(episode))
        }
        return parts.joined(separator: ", ")
    }

    private func runtime(_ episode: PlexMetadata) -> String {
        let minutes = max(1, episode.duration / 60_000)
        if episode.viewOffset > 0 {
            return "\(max(1, (episode.duration - episode.viewOffset) / 60_000)) min left"
        }
        return "\(minutes) min"
    }

    /// Stills of the next rows, requested at the size the rows draw, so they are in memory on arrival.
    private func prefetchStills(after position: Int, in episodes: [PlexMetadata]) {
        let next = episodes.dropFirst(position + 1).prefix(Self.prefetchAhead)
        prefetch(next.map(\.thumb), size: stillSize)
    }

    private func reload() {
        Task {
            if seasons.isEmpty { await loadSeasons() }
            await loadEpisodes()
        }
    }

    private func loadSeasons() async {
        let item = model.item
        if season == nil { season = item.parentRatingKey }
        guard let show = item.grandparentRatingKey else { return }
        do {
            seasons = try await model.library.children(of: show).filter { $0.type == .season }
        } catch {
            // The current season's episodes still show; only the season menu is missing.
        }
    }

    private func loadEpisodes() async {
        guard let season else { return }
        do {
            episodes = try await model.library.children(of: season)
            failed = false
        } catch {
            if !Task.isCancelled { failed = episodes == nil }
        }
    }
}

/// A 16:9 still with the watched part of a started episode under it.
private struct EpisodeStill: View {
    let episode: PlexMetadata
    let size: CGSize
    @Environment(\.theme) private var theme

    var body: some View {
        PlexArtView(path: episode.thumb, size: size, placeholder: "tv")
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .overlay(alignment: .bottom) {
                if episode.viewOffset > 0, episode.duration > 0, !episode.isWatched {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.trackOff)
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: proxy.size.width * min(1, Double(episode.viewOffset) / Double(episode.duration)))
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, Space.s2)
                    .padding(.bottom, Space.s1)
                }
            }
            .accessibilityHidden(true)
    }
}
