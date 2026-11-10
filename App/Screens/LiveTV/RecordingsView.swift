import MarqueeCore
import SwiftUI

/// Recordings (docs/LIVE-TV.md §6.10). Scheduled: the series rules, then the airings due by day, each
/// taken off with a swipe. Recorded: the newest items the DVR recorded, which play in the normal player.
struct RecordingsView: View {
    let store: LiveTVStore

    private enum Page: String, CaseIterable, Identifiable {
        case scheduled = "Scheduled"
        case recorded = "Recorded"

        var id: Self { self }
    }

    @Environment(\.theme) private var theme
    @State private var page = Page.scheduled

    var body: some View {
        Group {
            switch page {
            case .scheduled: ScheduledList(store: store)
            case .recorded: RecordedList(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Recordings", selection: $page) {
                    ForEach(Page.allCases) { page in
                        Text(page.rawValue).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("livetv.recordings.pages")
            }
        }
        // Pushed outside the stack's routes, so it carries its own toasts.
        .overlay(alignment: .bottom) { ToastOverlay() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("livetv.recordings.screen")
    }
}

// MARK: - Scheduled

private struct ScheduledList: View {
    let store: LiveTVStore

    @Environment(ToastCenter.self) private var toasts
    @Environment(\.theme) private var theme
    @State private var editing: RecordingRule?
    @State private var deleting: RecordingRule?
    @State private var stopping: ScheduledRecording?
    /// Rules and airings taken off, hidden at once while the server confirms (DESIGN §11).
    @State private var hidden: Set<String> = []

    var body: some View {
        let rules = store.seriesRules.filter { !hidden.contains($0.id) }
        let days = ScheduleDay.group(
            store.upcoming.filter { !hidden.contains($0.id) && !hidden.contains($0.ruleID ?? "") },
            now: store.now
        )
        Group {
            if rules.isEmpty, days.isEmpty {
                EmptyState(
                    title: "Nothing scheduled",
                    message: "Programmes set to record show here. Open one in the guide and choose Record.",
                    systemImage: "record.circle"
                )
                .accessibilityIdentifier("livetv.scheduled.empty")
            } else {
                List {
                    if !rules.isEmpty {
                        Section("Series") {
                            ForEach(rules) { rule in
                                Button {
                                    editing = rule
                                } label: {
                                    RuleRow(rule: rule, scheduled: scheduledCount(rule))
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Delete", systemImage: "trash") { deleting = rule }
                                        .tint(theme.danger)
                                }
                                .accessibilityIdentifier("livetv.rule.\(rule.id)")
                            }
                        }
                        .listRowBackground(theme.sheet)
                    }
                    ForEach(days) { day in
                        Section(day.title) {
                            ForEach(day.recordings) { recording in
                                let mark = store.recordings.mark(of: recording)
                                ScheduledRow(recording: recording, mark: mark, now: store.now)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: mark != .recording) {
                                        swipeAction(recording, mark: mark)
                                    }
                                    .accessibilityIdentifier("livetv.scheduled.\(recording.id)")
                            }
                        }
                        .headerProminence(.increased)
                        .listRowBackground(theme.sheet)
                    }
                }
                .themedList(theme)
                .refreshable { await store.loadRecordings() }
            }
        }
        .task { await store.loadRecordings() }
        .sheet(item: $editing) { rule in
            RuleSheet(store: store, rule: rule, scheduled: scheduledCount(rule)) { delete($0) }
        }
        .confirmationDialog(
            deleting.map { "Delete the series recording of \($0.title)?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { rule in
            Button("Delete Series", role: .destructive) { delete(rule) }
        } message: { _ in
            Text("Its scheduled airings are cancelled. Recordings already made stay in the library.")
        }
        .confirmationDialog(
            stopping.map { "Stop recording \($0.title)?" } ?? "",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible,
            presenting: stopping
        ) { recording in
            Button("Stop Recording", role: .destructive) { unschedule(recording) }
            if store.offersSeriesDeletion(recording) {
                Button("Stop and Delete the Series Rule", role: .destructive) { unschedule(recording, deletingSeries: true) }
            }
        } message: { _ in
            Text("The tuner is freed at once.")
        }
    }

    private func scheduledCount(_ rule: RecordingRule) -> Int {
        store.upcoming.count { $0.ruleID == rule.id && $0.isUpcoming }
    }

    /// Stop while recording; Skip under a series, which keeps the rest; Cancel for a one-off.
    @ViewBuilder
    private func swipeAction(_ recording: ScheduledRecording, mark: RecordingMark?) -> some View {
        switch mark {
        case .recording?:
            Button("Stop", systemImage: "stop.fill") { stopping = recording }
                .tint(theme.danger)
        case .series?:
            Button("Skip", systemImage: "forward.end") { unschedule(recording) }
        case .scheduled?:
            Button("Cancel", systemImage: "xmark") { unschedule(recording) }
                .tint(theme.danger)
        case .failed?, .recorded?, nil:
            EmptyView()
        }
    }

    private func unschedule(_ recording: ScheduledRecording, deletingSeries: Bool = false) {
        withAnimation { _ = hidden.insert(recording.id) }
        Task {
            do {
                try await store.unschedule(recording, deletingSeries: deletingSeries)
                Haptics.success()
                toasts.show("\(recording.title) won't record")
            } catch {
                Haptics.error()
                toasts.show(LiveText.recordingProblem(error, server: store.serverName))
            }
            withAnimation { _ = hidden.remove(recording.id) }
        }
    }

    private func delete(_ rule: RecordingRule) {
        withAnimation { _ = hidden.insert(rule.id) }
        Task {
            do {
                try await store.delete(rule)
                Haptics.success()
                toasts.show("Deleted the series recording of \(rule.title)")
            } catch {
                Haptics.error()
                toasts.show(LiveText.recordingProblem(error, server: store.serverName))
            }
            withAnimation { _ = hidden.remove(rule.id) }
        }
    }
}

/// One day of the schedule. An airing under way, or one that failed, files under today.
private struct ScheduleDay: Identifiable {
    let id: Date
    let title: String
    var recordings: [ScheduledRecording]

    static func group(_ recordings: [ScheduledRecording], now: Date) -> [ScheduleDay] {
        let calendar = Calendar.current
        var days: [ScheduleDay] = []
        for recording in recordings.sorted(by: { $0.start < $1.start }) {
            let shown = max(recording.start, now)
            let day = calendar.startOfDay(for: shown)
            if days.last?.id == day {
                days[days.count - 1].recordings.append(recording)
            } else {
                days.append(ScheduleDay(id: day, title: LiveText.day(shown, now: now), recordings: [recording]))
            }
        }
        return days
    }
}

/// A series rule: the show's poster, its title, which airings it takes and how many are booked.
private struct RuleRow: View {
    let rule: RecordingRule
    let scheduled: Int

    @Environment(\.theme) private var theme

    private static let poster = CGSize(width: 40, height: 60)

    var body: some View {
        HStack(spacing: Space.s3) {
            PlexArtView(path: rule.thumb, size: Self.poster, placeholder: "tv")
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                Text(detail)
                    .textRole(.label)
                    .foregroundStyle(theme.ink2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s1)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the series settings")
    }

    private var detail: String {
        let airings = rule.settings.first { $0.id == "onlyNewAirings" }.map {
            RecordSettingFields.summary([$0], values: [:])
        } ?? rule.airingsType
        let count = scheduled == 0 ? "none scheduled" : "\(scheduled) scheduled"
        return [airings, count].compactMap(\.self).joined(separator: " · ")
    }
}

/// An airing due to record: title, episode, time and channel, and its record state.
private struct ScheduledRow: View {
    let recording: ScheduledRecording
    let mark: RecordingMark?
    let now: Date

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                if let subtitle = LiveText.subtitle(recording) {
                    Text(subtitle)
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                }
                Text(line)
                    .textRole(.label)
                    .foregroundStyle(mark == .failed ? theme.danger : theme.ink2)
            }
            Spacer(minLength: 0)
            if let mark {
                RecordGlyph(mark: mark)
            }
        }
        .padding(.vertical, Space.s1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var channel: String? {
        let label = [recording.channelNumber, recording.channelCallSign].compactMap(\.self).joined(separator: " ")
        return label.isEmpty ? nil : label
    }

    /// "10:00 – 11:00 PM · 2.1 WMRQ", led by "Recording now" or "Didn't record".
    private var line: String {
        let state: String? = switch mark {
        case .recording?, .failed?: mark.map(LiveText.status)
        default: nil
        }
        return [state, LiveText.range(recording.start, recording.end), channel].compactMap(\.self).joined(separator: " · ")
    }

    private var spoken: String {
        [
            recording.title,
            LiveText.subtitle(recording),
            "\(LiveText.day(max(recording.start, now), now: now)) \(LiveText.range(recording.start, recording.end))",
            channel,
            LiveText.mark(mark),
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
    }
}

/// A series rule's settings, saved together, and Delete Series. A partial sheet keeps the system glass;
/// at full height the list takes the canvas (DESIGN §6).
private struct RuleSheet: View {
    let store: LiveTVStore
    let rule: RecordingRule
    let scheduled: Int
    let delete: @MainActor (RecordingRule) -> Void

    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium
    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var problem: String?
    @State private var confirmsDelete = false

    private var settings: [RecordSetting] { RecordSettingFields.settings(rule.settings) }

    /// The values that differ from the rule's, which are all Save sends.
    private var changes: [String: String] {
        values.filter { id, value in rule.settings.first { $0.id == id }?.value != value }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if settings.isEmpty {
                        Text("\(store.serverName) offers no settings for this series.")
                            .foregroundStyle(theme.ink2)
                    } else {
                        RecordSettingFields(settings: settings, values: $values)
                    }
                } footer: {
                    Text(footer)
                }
                .listRowBackground(theme.sheet)
                if let problem {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(theme.danger)
                                .accessibilityHidden(true)
                            Text(problem)
                                .foregroundStyle(theme.ink)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .listRowBackground(theme.sheet)
                }
                Section {
                    Button("Delete Series", role: .destructive) { confirmsDelete = true }
                        .foregroundStyle(theme.danger)
                        .accessibilityIdentifier("livetv.rule.delete")
                }
                .listRowBackground(theme.sheet)
            }
            .themedList(theme, onCanvas: detent == .large)
            .tint(theme.accent)
            .navigationTitle(rule.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("livetv.rule.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(changes.isEmpty || saving)
                        .accessibilityIdentifier("livetv.rule.save")
                }
            }
            .confirmationDialog("Delete the series recording of \(rule.title)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Series", role: .destructive) {
                    dismiss()
                    delete(rule)
                }
            } message: {
                Text("Its scheduled airings are cancelled. Recordings already made stay in the library.")
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .preferredColorScheme(themes.presentationScheme(for: theme))
        .onAppear { values = RecordSettingFields.values(settings) }
    }

    private var footer: String {
        let count = scheduled == 1 ? "1 airing scheduled." : "\(scheduled) airings scheduled."
        guard let library = rule.librarySectionTitle else { return count }
        return "\(count) Recordings go to \(library)."
    }

    private func save() {
        saving = true
        problem = nil
        Task {
            do {
                try await store.update(rule, values: changes)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.error()
                problem = LiveText.recordingProblem(error, server: store.serverName)
            }
            saving = false
        }
    }
}

// MARK: - Recorded

private struct RecordedList: View {
    let store: LiveTVStore

    private enum Load {
        case loading
        case ready([PlexMetadata])
        case failed(String)
    }

    @Environment(\.sessionActions) private var sessionActions
    @Environment(\.theme) private var theme
    @State private var load = Load.loading
    @State private var attempt = 0

    var body: some View {
        Group {
            switch load {
            case .loading:
                RecordedSkeleton()
            case .ready(let items) where items.isEmpty:
                EmptyState(
                    title: "No identifiable recordings",
                    message: "Only recordings Plex still identifies as DVR appear here. Others may be in your library.",
                    systemImage: "film.stack"
                )
                .accessibilityIdentifier("livetv.recorded.empty")
            case .ready(let items):
                List {
                    ForEach(items) { item in
                        Button {
                            if let index = item.recordedMediaIndex {
                                sessionActions.play(item, mediaIndex: index)
                            }
                        } label: {
                            RecordedRow(item: item)
                        }
                        .accessibilityHint("Plays the recording")
                        .accessibilityIdentifier("livetv.recorded.\(item.ratingKey)")
                    }
                    .listRowBackground(theme.sheet)
                }
                .themedList(theme)
                .refreshable { await reload() }
            case .failed(let message):
                EmptyState(
                    title: "Recordings didn't load",
                    message: message,
                    systemImage: "exclamationmark.triangle",
                    action: EmptyState.Action(title: "Try Again", systemImage: "arrow.clockwise") { attempt += 1 }
                )
                .accessibilityIdentifier("livetv.recorded.failed")
            }
        }
        .task(id: attempt) { await reload() }
    }

    private func reload() async {
        do {
            load = .ready(try await store.recorded())
        } catch {
            load = .failed(LiveText.problem(error, server: store.serverName))
        }
    }
}

/// A recording: its still with progress along the bottom, the show, the episode, and its length and
/// when it was recorded. At accessibility sizes the text goes under the still.
private struct RecordedRow: View {
    let item: PlexMetadata

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let still = CGSize(width: 112, height: 63)

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
            : AnyLayout(HStackLayout(spacing: Space.s3))
        layout {
            PlexArtView(path: item.thumb ?? item.backdropPath, size: Self.still, placeholder: "tv")
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressLine(progress: progress)
                            .padding(.horizontal, Space.s2)
                            .padding(.bottom, Space.s1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.posterTitle)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .textRole(.label)
                        .foregroundStyle(theme.ink2)
                }
                if let detail {
                    Text(detail)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                }
            }
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s1)
        .accessibilityElement(children: .combine)
    }

    /// "S1 · E3 · Sintel" for an episode, the year for a movie.
    private var subtitle: String? {
        let parts = item.type == .episode
            ? [item.episodeCode, item.title == item.posterTitle ? nil : item.title]
            : [item.year.map(String.init)]
        let line = parts.compactMap(\.self).joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// "28 min · Recorded 6 Nov".
    private var detail: String? {
        let recorded = item.recordedAt.map { "Recorded \($0.formatted(.dateTime.day().month(.abbreviated)))" }
        let line = [ItemText.runtime(item.duration), recorded].compactMap(\.self).joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}

/// Static fills where the recordings will be (DESIGN §11), never a spinner.
private struct RecordedSkeleton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s4) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: Space.s3) {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(theme.trackOff)
                        .frame(width: 112, height: 63)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Capsule().fill(theme.trackOff).frame(width: 140, height: 12)
                        Capsule().fill(theme.trackOff).frame(width: 96, height: 10)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Space.inset)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }
}
