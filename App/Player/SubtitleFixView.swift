import MarqueeCore
import SwiftUI

/// What "Wrong Subtitles?" and "Search Subtitles" open (DESIGN §8.6). A search is a page pushed inside the
/// sheet, as long tasks are (DESIGN §7).
struct SubtitleFixSheet: View {
    let model: PlayerModel
    let fix: SubtitleFix
    let start: PlayerModel.SubtitleSheet
    @State private var path: [SubtitleFixPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch start {
                case .wrong: WrongSubtitlesView(model: model, fix: fix) { path = [.bazarr] }
                case .plex: PlexSearchView(model: model, fix: fix)
                case .bazarr: BazarrSearchView(model: model, fix: fix)
                }
            }
            .navigationDestination(for: SubtitleFixPage.self) { page in
                switch page {
                case .plex: PlexSearchView(model: model, fix: fix)
                case .bazarr: BazarrSearchView(model: model, fix: fix)
                }
            }
        }
    }
}

enum SubtitleFixPage: Hashable {
    case plex
    case bazarr
}

/// The subtitle on screen, removing its file from Plex, and a search for another.
struct WrongSubtitlesView: View {
    let model: PlayerModel
    let fix: SubtitleFix
    let findAnother: @MainActor () -> Void
    @Environment(\.theme) private var theme
    @State private var confirmsRemove = false

    var body: some View {
        let track = model.subtitle?.track
        List {
            Section("Now Showing") {
                if let track {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(track.label)
                            .foregroundStyle(theme.ink)
                        Text(track.isExternal ? "A separate file next to the video" : "Inside the video file")
                            .foregroundStyle(theme.ink2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("subtitleFix.showing")
                } else {
                    Text("No subtitle is showing.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)

            Section {
                Button("Remove This Subtitle", role: .destructive) { confirmsRemove = true }
                    .foregroundStyle(theme.danger)
                    .disabled(track?.isExternal != true || fix.removal == .removing)
                    .accessibilityIdentifier("subtitleFix.remove")
            } footer: {
                removalLine(track)
                    .accessibilityIdentifier("subtitleFix.removal")
            }
            .listRowBackground(theme.sheet)

            Section {
                NavigationLink("Find Another with Plex", value: SubtitleFixPage.plex)
                    .accessibilityIdentifier("subtitleFix.searchPlex")
                NavigationLink("Find Another with Bazarr", value: SubtitleFixPage.bazarr)
                    .disabled(model.bazarr == nil)
                    .accessibilityIdentifier("subtitleFix.findAnother")
            } footer: {
                if model.bazarr == nil {
                    Text("Set up Bazarr in Settings, Integrations.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Wrong Subtitles?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SubtitleFixDone(model: model) }
        .confirmationDialog(removeTitle(track), isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("Remove Subtitle", role: .destructive) {
                if let track { fix.remove(track) }
            }
            .accessibilityIdentifier("subtitleFix.confirmRemove")
        } message: {
            Text("The file next to “\(model.item.title)” is deleted from Plex. The video file is not changed.")
        }
        .onChange(of: fix.removal) { _, removal in
            if removal == .removed, model.bazarr != nil { findAnother() }
        }
        .accessibilityIdentifier("subtitleFix.wrong")
    }

    private func removeTitle(_ track: SubtitleTrack?) -> String {
        "Remove the \(track?.languageName ?? "") subtitle from Plex?"
    }

    @ViewBuilder
    private func removalLine(_ track: SubtitleTrack?) -> some View {
        switch fix.removal {
        case .removing?:
            HStack(spacing: Space.s2) {
                ProgressView()
                Text("Removing…")
                    .foregroundStyle(theme.ink2)
            }
        case .removed?:
            StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: "Removed from Plex.")
        case .refused?:
            ProblemLine(text: "The server would not remove it.")
        case .unreachable?:
            ProblemLine(text: "Couldn't reach the server.")
        case nil:
            Group {
                if let track, !track.isExternal {
                    Text("Part of the video file, so it can't be removed.")
                } else if track == nil {
                    Text("No subtitle is showing.")
                } else if model.bazarr != nil {
                    Text("Deletes the file from Plex, then looks for another with Bazarr. It can't be undone.")
                } else {
                    Text("Deletes the file from Plex. It can't be undone.")
                }
            }
            .foregroundStyle(theme.ink2)
        }
    }
}

/// Plex's own subtitle agents (OpenSubtitles and the like) for the playing item, one language per search,
/// best match first. A tap adds one to Plex; once Plex lists it, it shows.
struct PlexSearchView: View {
    let model: PlayerModel
    let fix: SubtitleFix
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LanguagePickerView(title: "Language", noneTitle: nil, selection: language)
                } label: {
                    LabeledContent("Language") {
                        Text(fix.plexLanguage.name ?? "")
                            .foregroundStyle(theme.ink2)
                    }
                }
                .disabled(fix.isDownloading)
                .accessibilityIdentifier("plex.language")
            }
            .listRowBackground(theme.sheet)

            results
                .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Plex")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SubtitleFixDone(model: model) }
        .onAppear { fix.searchPlexIfNeeded() }
        .accessibilityIdentifier("subtitleFix.plex")
    }

    private var language: Binding<TrackLanguage?> {
        Binding { fix.plexLanguage } set: { if let language = $0 { fix.searchPlex(in: language) } }
    }

    @ViewBuilder
    private var results: some View {
        switch fix.plexSearch {
        case nil, .searching?:
            Section {
                HStack(spacing: Space.s2) {
                    ProgressView()
                    Text("Searching Plex…")
                        .foregroundStyle(theme.ink2)
                }
                .accessibilityElement(children: .combine)
            } footer: {
                Text("Plex asks its subtitle agents, such as OpenSubtitles.")
                    .foregroundStyle(theme.ink2)
            }
        case .failed(let unreachable)?:
            Section {
                ProblemLine(text: unreachable ? "Couldn't reach the server." : "The server couldn't search for subtitles.")
                Button("Try Again") { fix.searchPlex(in: fix.plexLanguage) }
                    .accessibilityIdentifier("plex.retry")
            }
        case .found(let candidates)?:
            Section {
                if candidates.isEmpty {
                    Text("Plex found nothing in \(fix.plexLanguage.name ?? "this language").")
                        .foregroundStyle(theme.ink2)
                }
                ForEach(candidates) { candidate in
                    row(candidate)
                }
            } header: {
                Text(candidates.count == 1 ? "1 Result" : "\(candidates.count) Results")
            } footer: {
                if !candidates.isEmpty {
                    Text("Best match first. Plex adds the file to this video, then it shows here.")
                        .foregroundStyle(theme.ink2)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ candidate: PlexSubtitleCandidate) -> some View {
        let listed = model.tracks?.listed(candidate).map { SubtitleFix.Download.listed(track: $0.id) }
        if let download = fix.plexDownloads[candidate.id] ?? listed {
            VStack(alignment: .leading, spacing: Space.s2) {
                label(candidate)
                DownloadStatus(model: model, download: download, source: "plex") { fix.checkPlexAgain(candidate) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("plex.result")
        } else {
            Button { fix.add(candidate) } label: {
                label(candidate)
            }
            .disabled(!fix.canAdd(candidate))
            .accessibilityHint("Adds it to Plex, then shows it.")
            .accessibilityIdentifier("plex.result")
        }
    }

    private func label(_ candidate: PlexSubtitleCandidate) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(candidate.title ?? candidate.language.name ?? "Subtitle")
                .foregroundStyle(theme.ink)
                .lineLimit(3)
            Text([candidate.provider, candidate.language.name].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(theme.ink2)
        }
        .padding(.vertical, Space.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Bazarr's search for the playing item: the results in one language, best match first. A tap downloads
/// one; once Plex lists the file, it shows.
struct BazarrSearchView: View {
    let model: PlayerModel
    @Bindable var fix: SubtitleFix
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .navigationTitle("Bazarr")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SubtitleFixDone(model: model) }
            .onAppear { fix.searchIfNeeded() }
            .accessibilityIdentifier("subtitleFix.search")
    }

    @ViewBuilder
    private var content: some View {
        switch fix.search {
        case nil, .searching?:
            EmptyState(
                title: "Searching Bazarr…",
                message: "Bazarr asks each of its subtitle providers. This can take half a minute.",
                systemImage: nil
            )
        case .failed(let error)?:
            failure(error)
        case .found?:
            results
        }
    }

    private var results: some View {
        let shown = fix.results
        let languageName = fix.language.name ?? "this language"
        return List {
            Section {
                Picker("Language", selection: $fix.language) {
                    ForEach(fix.languages, id: \.self) { language in
                        Text(language.name ?? language.code ?? "Unknown").tag(language)
                    }
                }
                .accessibilityIdentifier("bazarr.language")
            }
            .listRowBackground(theme.sheet)

            Section {
                if shown.isEmpty {
                    Text("Bazarr found nothing in \(languageName).")
                        .foregroundStyle(theme.ink2)
                }
                ForEach(shown) { result in
                    row(result)
                }
            } header: {
                Text(shown.count == 1 ? "1 Result" : "\(shown.count) Results")
            } footer: {
                if !shown.isEmpty {
                    Text("Best match first. Bazarr saves the file next to the video, then it shows here.")
                        .foregroundStyle(theme.ink2)
                }
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
    }

    @ViewBuilder
    private func row(_ result: BazarrSubtitle) -> some View {
        if let download = fix.downloads[result.id] {
            VStack(alignment: .leading, spacing: Space.s2) {
                label(result)
                DownloadStatus(model: model, download: download, source: "bazarr") { fix.checkPlexAgain(result) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bazarr.result")
        } else {
            Button { fix.download(result) } label: {
                label(result)
            }
            .disabled(!fix.canDownload(result))
            .accessibilityHint("Downloads it to Plex, then shows it.")
            .accessibilityIdentifier("bazarr.result")
        }
    }

    private func label(_ result: BazarrSubtitle) -> some View {
        let score = Int(result.score.rounded())
        let chips = [result.kind == .captions ? "Captions" : nil, result.kind == .onScreenText ? "On-Screen Text" : nil]
            .compactMap { $0 }
        return VStack(alignment: .leading, spacing: Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(result.name)
                    .foregroundStyle(theme.ink)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(score)%")
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
                    .accessibilityLabel("\(score) percent match")
            }
            Text("\(result.providerName) · \(result.trackLanguage.name ?? result.language)")
                .foregroundStyle(theme.ink2)
            if !chips.isEmpty {
                ChipFlow {
                    ForEach(chips, id: \.self) { Chip(title: $0) }
                }
            }
        }
        .padding(.vertical, Space.s1)
        .accessibilityElement(children: .combine)
    }

    private func failure(_ error: BazarrError) -> some View {
        let retry = EmptyState.Action(title: "Try Again", systemImage: "arrow.clockwise") { fix.searchAgain() }
        return switch error {
        case .unreachable, .timedOut:
            EmptyState(
                title: "Can't Reach Bazarr",
                message: "No answer from its address. Check that this iPhone is on the same network.",
                systemImage: "wifi.exclamationmark", action: retry
            )
        case .badKey:
            EmptyState(
                title: "Bazarr Refused the Key",
                message: "Check the API key in Settings, Integrations, Bazarr.",
                systemImage: "exclamationmark.triangle"
            )
        case .notBazarr:
            EmptyState(
                title: "Not Bazarr",
                message: "That address does not answer like Bazarr. Check it in Settings, Integrations, Bazarr.",
                systemImage: "exclamationmark.triangle"
            )
        case .notFound:
            EmptyState(
                title: "Not in Bazarr",
                message: "Bazarr doesn't have this title. It lists what Sonarr and Radarr manage.",
                systemImage: "magnifyingglass", action: retry
            )
        case .searchFailed, .badCandidate, .downloadFailed:
            EmptyState(
                title: "Search Failed",
                message: "Bazarr couldn't search. Check its providers.",
                systemImage: "exclamationmark.triangle", action: retry
            )
        }
    }
}

/// Where one download stands, with Check Plex Again while Plex may hold the file already. `source`
/// prefixes the accessibility identifiers.
private struct DownloadStatus: View {
    let model: PlayerModel
    let download: SubtitleFix.Download
    let source: String
    let checkPlexAgain: @MainActor () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch download {
            case .requesting:
                progress("Requesting download…")
            case .waiting(let afterBazarr):
                progress(afterBazarr ? "Waiting for Bazarr and Plex…" : "Waiting for Plex…")
            case .loading:
                progress("Loading in player…")
            case .notVisible:
                StatusLine(symbol: "clock", tint: theme.ink2, text: "Not yet visible in Plex.")
            case .checkFailed:
                ProblemLine(text: "Could not check Plex.")
            case .listed(let track) where model.subtitle?.track?.id == track:
                StatusLine(symbol: "checkmark.circle.fill", tint: theme.positive, text: "Active in player")
            case .listed:
                StatusLine(symbol: "checkmark.circle", tint: theme.ink2, text: "Available in Plex")
            case .playerFailed:
                ProblemLine(text: "The player could not load this subtitle. Try another.")
            case .failed(let error):
                ProblemLine(text: Self.text(for: error))
            case .notAdded(let unreachable):
                ProblemLine(text: unreachable ? "Couldn't reach the server." : "The server would not add it.")
            }
        }
        .accessibilityIdentifier("\(source).state")
        if download.canCheckPlex {
            Button("Check Plex Again", action: checkPlexAgain)
                .buttonStyle(.borderless)
                .disabled(model.subtitleFix?.isDownloading == true)
                .accessibilityIdentifier("\(source).checkPlex")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Space.s2) {
            ProgressView()
            Text(text)
                .foregroundStyle(theme.ink2)
        }
        .accessibilityElement(children: .combine)
    }

    static func text(for error: BazarrError) -> String {
        switch error {
        case .timedOut: "The request timed out."
        case .badCandidate: "This subtitle cannot be added. Try another."
        case .downloadFailed: "Bazarr could not download this subtitle. Try another."
        case .badKey: "Bazarr refused the API key."
        case .notBazarr: "That address does not answer like Bazarr."
        case .unreachable, .notFound, .searchFailed: "Can't reach Bazarr."
        }
    }
}

/// Closes the whole sheet from any of its pages; `dismiss` on a pushed page only goes back.
private struct SubtitleFixDone: ToolbarContent {
    let model: PlayerModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { model.subtitleSheet = nil }
                .accessibilityIdentifier("subtitleFix.done")
        }
    }
}
