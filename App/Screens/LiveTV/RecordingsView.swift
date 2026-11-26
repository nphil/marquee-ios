import MarqueeCore
import SwiftUI

struct RecordingsView: View {
    let store: LiveTVStore
    @Environment(RecordingAlerts.self) private var alerts

    var body: some View {
        RecordingBrowser(initial: RecordingsModel(store: store, alerts: alerts))
    }
}

private struct RecordingBrowser: View {
    @State private var model: RecordingsModel
    @Environment(\.theme) private var theme
    @Environment(\.sessionActions) private var actions
    @State private var compactDetail: RecordingsModel.Selection?
    @State private var stopping: ScheduledRecording?
    @State private var errorMessage: String?

    init(initial: RecordingsModel) { _model = State(initialValue: initial) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Recordings", selection: $model.section) {
                ForEach(RecordingsSection.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, Space.inset)
            .padding(.vertical, Space.s2)
            GeometryReader { geometry in
                let wide = geometry.size.width >= splitWidth
                HStack(spacing: 0) {
                    list(wide: wide)
                        .frame(width: wide ? geometry.size.width * 0.46 : nil)
                    if wide {
                        Divider()
                        ScrollView { detail(model.selection).padding() }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbarBackground(theme.canvas, for: .navigationBar, .tabBar)
        .navigationTitle("Recordings").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Recording notifications", isOn: Binding(get: { model.alerts.isOn }, set: { on in
                        Task { await model.setAlerts(on); if on && model.alerts.isBlocked { errorMessage = "Allow notifications in iOS Settings first." } }
                    }))
                    if model.section == .rules {
                        Button(model.isReordering ? "Done reordering" : "Reorder rules") { model.isReordering.toggle() }
                    }
                    if let storage = model.storage {
                        Section("Recording libraries") { Text(storage.line) }
                    }
                } label: { Label("Recording options", systemImage: "ellipsis.circle") }
            }
        }
        .navigationDestination(item: $compactDetail) { selection in
            ScrollView { detail(selection).padding(Space.inset) }
                .background(theme.canvas.ignoresSafeArea())
        }
        .sheet(item: $model.editing) { rule in
            RecordingEditor(draft: RecordingDraft(editing: rule), save: { submission in
                try await model.store.update(rule, values: submission.values)
            }, remove: { try await model.delete(rule) })
        }
        .alert("Recording", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog("Stop this recording?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), presenting: stopping) { grab in
            Button("Stop Recording", role: .destructive) { run { try await model.unschedule(grab) } }
        }
        .onChange(of: model.section) { model.selection = nil; model.isReordering = false }
        .task(id: model.section) { if model.section == .recorded { await model.loadRecorded() } }
        .task {
            model.loadJournal()
            repeat {
                await model.refresh()
                do { try await Task.sleep(for: RecordingsModel.refreshEvery) } catch { break }
            } while !Task.isCancelled
        }
        .accessibilityIdentifier("livetv.recordings.screen")
    }

    private var splitWidth: CGFloat { CGFloat(RecordingsLayout.splitMinWidth) }

    private func select(_ value: RecordingsModel.Selection, wide: Bool) {
        if wide { model.selection = value } else { compactDetail = value }
    }

    private func list(wide: Bool) -> some View {
        List {
            Group {
            switch model.section {
            case .upcoming:
                if model.days.isEmpty { Text("Nothing scheduled") }
                ForEach(model.days) { day in
                    Section(day.heading(now: model.now)) {
                        ForEach(day.items) { item in
                            Button { select(.upcoming(item.id), wide: wide) } label: {
                                VStack(alignment: .leading) {
                                    ScheduledRow(recording: item.recording, mark: model.store.recordings.mark(of: item.recording), now: model.now)
                                    HStack {
                                        if let freshness = item.freshness { TagChip(text: freshness.badge) }
                                        if item.isConflict { Text("Conflict").foregroundStyle(theme.danger) }
                                    }
                                }
                            }
                            .contextMenu { if let rule = model.rule(item.recording.ruleID) { Button("Edit rule") { model.editing = rule } } }
                            .swipeActions {
                                if model.store.recordings.mark(of: item.recording) == .recording {
                                    Button("Stop") { stopping = item.recording }
                                } else { Button("Skip") { run { try await model.unschedule(item.recording) } } }
                            }
                            .accessibilityIdentifier("livetv.scheduled.\(item.id)")
                        }
                    }
                }
            case .rules:
                if model.rules.isEmpty { Text("No recording rules") }
                ForEach(model.rules) { rule in
                    Button { select(.rule(rule.id), wide: wide) } label: { RuleRow(rule: rule, scheduled: model.scheduledCount(of: rule)) }
                        .accessibilityIdentifier("livetv.rule.\(rule.id)")
                }.onMove { offsets, destination in
                    guard let index = offsets.first, let move = model.reorder(model.rules[index], to: destination > index ? destination - 1 : destination) else { return }
                    run { try await model.send(move) }
                }
            case .recorded:
                switch model.recorded {
                case .loading: RecordedSkeleton()
                case .failed(let message): Text(message)
                case .ready(let items):
                    if items.isEmpty { Text("No identifiable recordings") }
                    ForEach(items) { item in
                        Button { select(.recorded(item.ratingKey), wide: wide) } label: { RecordedRow(item: item) }
                            .accessibilityIdentifier("livetv.recorded.\(item.ratingKey)")
                    }
                }
            case .history:
                if model.history.isEmpty { Text("No recording history yet") }
                ForEach(model.history) { entry in
                    Button { select(.history(entry.id), wide: wide) } label: {
                        VStack(alignment: .leading) { Text(entry.title); Text(entry.outcome.label).foregroundStyle(theme.ink2) }
                    }
                }
            }
            }
            .listRowBackground(theme.sheet)
        }.themedList(theme)
        .environment(\.editMode, .constant(model.isReordering ? .active : .inactive))
        .refreshable { await model.refresh(includingRecorded: model.section == .recorded) }
    }

    @ViewBuilder private func detail(_ selection: RecordingsModel.Selection?) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            switch selection {
            case .upcoming(let id):
                if let item = model.upcoming(id) {
                    ScheduledRow(recording: item.recording, mark: model.store.recordings.mark(of: item.recording), now: model.now)
                    Text(item.status.label)
                    if let conflict = model.conflicts.first(where: { $0.id == item.conflictID }) {
                        Text(conflict.sentence).foregroundStyle(theme.danger)
                        if item.losesToConflict {
                            let alternatives = model.alternatives(for: item.recording)
                            if alternatives.isEmpty { Text("No other free airing in the loaded guide.") }
                            ForEach(alternatives) { airing in
                                Button("Switch to \(LiveText.when(airing, now: model.now))") { run { try await model.switchRecording(item.recording, to: airing) } }
                            }
                        }
                    }
                    if let rule = model.rule(item.recording.ruleID) { Button("Edit rule") { model.editing = rule } }
                }
            case .rule(let id):
                if let rule = model.rule(id) {
                    Text(rule.title).textRole(.title)
                    Text(RecordingDraft(editing: rule).summary)
                    Button("Edit rule") { model.editing = rule }
                    ForEach(model.upcoming(under: rule)) { grab in
                        ScheduledRow(recording: grab, mark: model.store.recordings.mark(of: grab), now: model.now)
                    }
                }
            case .recorded(let id):
                if let item = model.recordedItem(id) {
                    RecordedRow(item: item)
                    if let index = item.recordedMediaIndex { Button("Play recording") { actions.play(item, mediaIndex: index) } }
                }
            case .history(let id):
                if let entry = model.history.first(where: { $0.id == id }) {
                    Text(entry.title).textRole(.title); Text(entry.airedAt.formatted()); Text(entry.reason)
                }
            case nil: Text("Choose a recording or rule").foregroundStyle(theme.ink2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch { errorMessage = LiveText.recordingProblem(error, server: model.store.serverName) } }
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
        let airings = rule.airingsType
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
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(recording.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                Text(line)
                    .textRole(.label)
                    .foregroundStyle(mark == .failed ? theme.danger : theme.ink)
                if let subtitle = LiveText.subtitle(recording) {
                    Text(subtitle)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                }
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
