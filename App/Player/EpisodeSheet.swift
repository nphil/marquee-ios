import MarqueeCore
import SwiftUI

/// The show's episodes, opened from the player: a season menu and rows as on the show's page (DESIGN
/// §8.4). A tap plays the episode from where it was left; the menu offers the beginning.
struct EpisodeSheet: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var seasons: [PlexMetadata] = []
    @State private var season: String?
    @State private var episodes: [PlexMetadata]?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let episodes {
                    ForEach(episodes) { episode in
                        row(episode)
                            .listRowBackground(theme.sheet)
                    }
                }
            }
            .themedList(theme)
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
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if seasons.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        seasonMenu
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadSeasons() }
        .task(id: season) { await loadEpisodes() }
        .accessibilityIdentifier("player.episodeSheet")
    }

    private var seasonMenu: some View {
        Menu {
            Picker("Season", selection: $season) {
                ForEach(seasons) { entry in
                    Text(entry.title).tag(Optional(entry.ratingKey))
                }
            }
        } label: {
            HStack(spacing: Space.s1) {
                Text(seasons.first { $0.ratingKey == season }?.title ?? "Season")
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
        }
        .accessibilityLabel("Season")
        .accessibilityValue(seasons.first { $0.ratingKey == season }?.title ?? "")
    }

    private func row(_ episode: PlexMetadata) -> some View {
        let playing = episode.ratingKey == model.item.ratingKey
        return Button {
            Haptics.impact(.light)
            model.play(episode: episode, fromStart: false)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                EpisodeStill(episode: episode)
                VStack(alignment: .leading, spacing: 2) {
                    Text([episode.index.map(String.init), episode.title].compactMap { $0 }.joined(separator: " · "))
                        .textRole(.headline)
                        .foregroundStyle(theme.ink)
                    HStack(spacing: Space.s1) {
                        if playing {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(theme.accentText)
                            Text("Playing")
                                .foregroundStyle(theme.accentText)
                        } else if episode.isWatched {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Watched")
                        } else if episode.duration > 0 {
                            Text(runtime(episode))
                        }
                    }
                    .textRole(.caption)
                    .foregroundStyle(theme.ink2)
                    if !episode.summary.isEmpty {
                        Text(episode.summary)
                            .textRole(.caption)
                            .foregroundStyle(theme.ink2)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityAddTraits(playing ? .isSelected : [])
        .accessibilityAction(named: "Play from beginning") {
            model.play(episode: episode, fromStart: true)
            dismiss()
        }
        .accessibilityIdentifier("player.episode.\(episode.ratingKey)")
    }

    private func runtime(_ episode: PlexMetadata) -> String {
        let minutes = max(1, episode.duration / 60_000)
        if episode.viewOffset > 0 {
            return "\(max(1, (episode.duration - episode.viewOffset) / 60_000)) min left"
        }
        return "\(minutes) min"
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
    @Environment(\.theme) private var theme

    var body: some View {
        PlexArtView(path: episode.thumb, size: CGSize(width: 128, height: 72), placeholder: "tv")
            .frame(width: 128, height: 72)
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
