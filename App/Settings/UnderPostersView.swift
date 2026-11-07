import MarqueeCore
import SwiftUI

/// Settings › Under Posters (behaviour spec §1): what shows under the posters of movies and shows, for
/// the active profile, over a preview of the library last opened.
struct UnderPostersView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.plexLibrary) private var library
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("library.section") private var lastLibrary = ""
    @State private var samples = PosterLabelsPreview.placeholders

    var body: some View {
        @Bindable var session = session
        let labels = session.settings.posterLabels
        List {
            Section {
                PosterLabelsPreview(items: samples, labels: labels)
                    .animation(Motion.spring(reduceMotion: reduceMotion), value: labels)
            } footer: {
                Text("The library you last opened")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(Color.clear)

            Section {
                Toggle(isOn: $session.settings.posterLabels.showsTitle) {
                    Text("Title")
                    Text("The name, in bold.")
                }
                .accessibilityIdentifier("posters.title")
                NavigationLink {
                    PosterDetailsPicker(selection: $session.settings.posterLabels.details)
                } label: {
                    LabeledContent {
                        Text(labels.details.title)
                    } label: {
                        Text("Details")
                        Text("One line, worded for a movie or a TV show.")
                    }
                }
                .accessibilityIdentifier("posters.details")
                Toggle(isOn: $session.settings.posterLabels.showsSortValue) {
                    Text("Sort Value")
                    Text("Replaces the details line while a library is sorted.")
                }
                .accessibilityIdentifier("posters.sortValue")
            } footer: {
                Text("Choose what appears under posters, for movies and TV shows alike.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)

            Section {
                Button("Reset to Default") {
                    session.settings.posterLabels = PosterLabels()
                }
                .disabled(labels == PosterLabels())
                .accessibilityIdentifier("posters.reset")
            } footer: {
                Text("Title, and the sort value while a library is sorted.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Under Posters")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library?.instance) {
            guard let library else { return }
            if let items = await Self.recent(in: library, preferring: lastLibrary), !items.isEmpty {
                samples = items
            }
        }
    }

    /// The three newest titles of the library last opened, else of the first movie or TV library.
    private static func recent(in library: PlexLibrary, preferring key: String) async -> [PlexMetadata]? {
        guard let sections = try? await library.sections() else { return nil }
        let browsable = sections.filter { $0.type == .movie || $0.type == .show }
        guard let section = browsable.first(where: { $0.key == key }) ?? browsable.first else { return nil }
        let query = SectionQuery(type: section.type, sort: .recentlyAdded)
        return try? await library.items(in: section.key, query: query, start: 0, size: 3).items
    }
}

/// Three posters labelled as `labels` would label them in a grid.
struct PosterLabelsPreview: View {
    let items: [PlexMetadata]
    let labels: PosterLabels

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            ForEach(items.prefix(3)) { item in
                PosterCell(item: item, width: 92)
            }
        }
        .frame(maxWidth: .infinity)
        .environment(\.posterLabels, labels)
        .environment(\.posterSort, nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
    }

    /// Stand-ins shown until the library answers, or when it has nothing: a movie, a show and a movie.
    static let placeholders: [PlexMetadata] = [
        sample("preview.1", type: "movie", title: "Movie", extra: [
            "duration": 8_040_000, "contentRating": "PG-13", "audienceRating": 7.8,
            "Media": [["id": 1, "videoResolution": "4k"]],
        ]),
        sample("preview.2", type: "show", title: "Show", extra: ["childCount": 6, "leafCount": 60, "contentRating": "TV-14", "audienceRating": 8.4]),
        sample("preview.3", type: "movie", title: "Movie", extra: [
            "duration": 6_300_000, "contentRating": "R", "audienceRating": 6.9,
            "Media": [["id": 2, "videoResolution": "1080"]],
        ]),
    ].compactMap(\.self)

    private static func sample(_ key: String, type: String, title: String, extra: [String: Any]) -> PlexMetadata? {
        var json: [String: Any] = ["ratingKey": key, "type": type, "title": title, "year": 2019, "Genre": [["tag": "Drama"]]]
        json.merge(extra) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(PlexMetadata.self, from: data)
    }
}

/// The Details choices, each with what it shows.
private struct PosterDetailsPicker: View {
    @Binding var selection: PosterLabels.Details
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                ForEach(PosterLabels.Details.allCases, id: \.self) { details in
                    Button {
                        selection = details
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Space.s1) {
                                Text(details.title)
                                    .foregroundStyle(theme.ink)
                                if details == .video {
                                    Text("A TV show has no single video quality; it shows its year.")
                                        .textRole(.caption)
                                        .foregroundStyle(theme.ink2)
                                }
                            }
                            Spacer()
                            if details == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.accentText)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(details == selection ? .isSelected : [])
                    .accessibilityIdentifier("posters.details.\(details.rawValue)")
                }
            } footer: {
                Text(
                    "Each choice fits the poster: a movie shows 2019 · 2 h 14 m, a TV show 2019 · 6 seasons, or 4 new episodes once you have started it. Started, upcoming and collection titles show time left, the release date or how many titles they hold instead."
                )
                .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}
