import MarqueeCore
import SwiftUI

/// Search and current-subtitle management share the item-scoped state.
struct SubtitleFixSheet: View {
    let model: PlayerModel
    let fix: SubtitleFix
    let start: PlayerModel.SubtitleSheet
    @State private var path: [SubtitleFixPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch start {
                case .wrong: WrongSubtitlesView(model: model, fix: fix)
                case .search: SubtitleSearchView(model: model, fix: fix)
                }
            }
            .navigationDestination(for: SubtitleFixPage.self) { page in
                switch page {
                case .search: SubtitleSearchView(model: model, fix: fix)
                }
            }
        }
    }
}

enum SubtitleFixPage: Hashable {
    case search
}

/// The subtitle on screen, removing its file from Plex, and a search for another.
struct WrongSubtitlesView: View {
    let model: PlayerModel
    let fix: SubtitleFix
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
                NavigationLink("Search Subtitles", value: SubtitleFixPage.search)
                    .accessibilityIdentifier("subtitleFix.findAnother")
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
                } else {
                    Text("Deletes the file from Plex. It can't be undone.")
                }
            }
            .foregroundStyle(theme.ink2)
        }
    }
}

struct SubtitleSearchView: View {
    let model: PlayerModel
    let fix: SubtitleFix
    @Environment(\.theme) private var theme

    private var bazarrRows: BazarrSearchRows { .init(model: model, fix: fix, theme: theme) }
    private var plexRows: PlexSearchRows { .init(model: model, fix: fix, theme: theme) }

    /// Scroll targets for the requests list, one per request. A tapped result leaves its provider's
    /// section and is listed under "Subtitle requests" at the top, which can be far from the list's offset.
    private var requestTargets: [String] {
        fix.requestedBazarr.map { "request.bazarr.\($0.id)" } + fix.requestedPlex.map { "request.plex.\($0.id)" }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: requestTargets) { old, new in
                    // Only a request that was not listed before; removals and reopening keep the offset.
                    guard let added = new.last(where: { !old.contains($0) }) else { return }
                    proxy.scrollTo(added, anchor: .top)
                }
        }
    }

    private var list: some View {
        List {
            Section {
                NavigationLink {
                    LanguagePickerView(title: "Language", noneTitle: nil, selection: language)
                } label: {
                    LabeledContent("Language") {
                        Text(fix.language.name ?? "Unknown").foregroundStyle(theme.ink2)
                    }
                }
                .disabled(fix.plexAddUnresolved)
                .accessibilityIdentifier("subtitleSearch.language")
            }.listRowBackground(theme.sheet)

            if !fix.requestedBazarr.isEmpty || !fix.requestedPlex.isEmpty {
                Section("Subtitle requests") {
                    ForEach(fix.requestedBazarr) { bazarrRows.row($0).id("request.bazarr.\($0.id)") }
                    ForEach(fix.requestedPlex) { plexRows.row($0).id("request.plex.\($0.id)") }
                }.listRowBackground(theme.sheet)
            }
            if fix.plexAddUnresolved {
                Section {
                    Text("Finish checking the requested subtitle in Plex before changing language or searching Plex again.")
                        .foregroundStyle(theme.ink2)
                    if fix.canSetAsidePlexCheck {
                        Button("Stop Waiting for Plex") { fix.setAsidePlexCheck() }
                            .accessibilityIdentifier("subtitleSearch.setAsidePlexCheck")
                    }
                }.listRowBackground(theme.sheet)
            } else if fix.plexSearch == nil && fix.results.isEmpty && (fix.search != nil || model.bazarr == nil) {
                Section {
                    Button("Search Plex") { fix.searchPlex(in: fix.language) }
                }.listRowBackground(theme.sheet)
            }

            if model.bazarr != nil {
                bazarrResults.listRowBackground(theme.sheet)
            }
            if fix.plexSearch != nil {
                plexResults.listRowBackground(theme.sheet)
            }
        }
        .themedList(theme)
        .navigationTitle("Search Subtitles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SubtitleFixDone(model: model) }
        .onAppear { fix.searchIfNeeded() }
        .accessibilityIdentifier("subtitleFix.search")
    }

    private var language: Binding<TrackLanguage?> {
        Binding { fix.language } set: { if let selected = $0 { fix.selectLanguage(selected) } }
    }

    @ViewBuilder private var bazarrResults: some View {
        switch fix.search {
        case nil, .searching?:
            Section { ProgressView("Searching subtitles…") }
        case .failed?:
            Section("Bazarr") {
                ProblemLine(text: fix.plexAddUnresolved ? "Bazarr couldn't search." : "Bazarr couldn't search. Trying Plex instead.")
                Button("Retry Bazarr") { fix.searchAgain() }
                    .accessibilityIdentifier("bazarr.retry")
            }
        case .found?:
            Section("Bazarr") {
                if fix.results.isEmpty {
                    Text(fix.plexAddUnresolved ? "No results in this language." : "No results in this language. Searching Plex instead.").foregroundStyle(theme.ink2)
                }
                ForEach(fix.results.filter { fix.downloads[$0.id] == nil }) { bazarrRows.row($0) }
                if !fix.results.isEmpty && fix.plexSearch == nil {
                    Button("Search more") { fix.searchPlex(in: fix.language) }
                        .accessibilityIdentifier("subtitleSearch.more")
                }
            }
        }
    }

    @ViewBuilder private var plexResults: some View {
        switch fix.plexSearch {
        case nil: EmptyView()
        case .searching?:
            Section("Plex") { ProgressView("Searching Plex…") }
        case .failed(let unreachable)?:
            Section("Plex") {
                ProblemLine(text: unreachable ? "Couldn't reach Plex." : "Plex couldn't search for subtitles.")
                Button("Retry Plex") { fix.searchPlex(in: fix.language) }
                    .accessibilityIdentifier("plex.retry")
            }
        case .found(let candidates)?:
            Section("Plex") {
                if candidates.isEmpty { Text("No results in this language.").foregroundStyle(theme.ink2) }
                ForEach(candidates.filter { fix.plexAttempt(for: $0) == nil }) { plexRows.row($0) }
            }
        }
    }
}

/// Provider result rows used by the shared search page.
@MainActor struct PlexSearchRows {
    let model: PlayerModel
    let fix: SubtitleFix
    let theme: Theme

    @ViewBuilder func row(_ candidate: PlexSubtitleCandidate) -> some View {
        let listed = model.tracks?.listed(candidate).map { SubtitleFix.Download.listed(track: $0.id) }
        if let download = fix.plexAttempt(for: candidate) ?? listed {
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

@MainActor struct BazarrSearchRows {
    let model: PlayerModel
    let fix: SubtitleFix
    let theme: Theme

    @ViewBuilder func row(_ result: BazarrSubtitle) -> some View {
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
