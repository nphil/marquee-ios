import Foundation
import MarqueeCore
import Observation

/// What the Recordings screen shows and what its buttons do (docs/LIVE-TV.md §6.10). MarqueeCore's `RecordingPlan`
/// and `RecordingJournal` decide the days, the conflicts, the badges and the history; this keeps them current and
/// sends the changes to the server.
@MainActor @Observable
final class RecordingsModel {
    /// What the details show.
    enum Selection: Hashable {
        case upcoming(String)
        case rule(String)
        case recorded(String)
        case history(String)
    }

    enum Recorded {
        case loading
        case ready([PlexMetadata])
        case failed(String)
    }

    /// A rule dragged to a new place, and the rule it now follows; nil when it came first.
    struct Move {
        let rule: RecordingRule
        let after: RecordingRule?
    }

    /// How often the DVR is read while the screen is open.
    static let refreshEvery = Duration.seconds(30)

    let store: LiveTVStore
    let alerts: RecordingAlerts
    var section = RecordingsSection.upcoming
    var selection: Selection?
    /// The rule whose Record sheet the list has open.
    var editing: RecordingRule?
    /// Rules show their drag handles while this is on.
    var isReordering = false
    private(set) var journal = RecordingJournal()
    private(set) var storage: RecordingStorage?
    private(set) var recorded = Recorded.loading
    /// Airings and rules taken off, hidden at once while the server confirms (DESIGN §11).
    private(set) var hidden: Set<String> = []
    /// The rules in the order just dragged, until the server has it.
    private var dragged: [RecordingRule]?

    init(store: LiveTVStore, alerts: RecordingAlerts) {
        self.store = store
        self.alerts = alerts
    }

    // MARK: What is shown

    var now: Date { store.now }

    /// The DVR's rules and airings without what was just taken off.
    private var visible: LiveRecordings {
        var all = store.recordings
        all.rules.removeAll { hidden.contains($0.id) }
        all.scheduled.removeAll { hidden.contains($0.id) || hidden.contains($0.ruleID ?? "") }
        return all
    }

    private var plan: RecordingPlan { RecordingPlan(visible, dvr: store.dvr) }

    var days: [UpcomingDay] { plan.upcoming(now: store.now) }

    var conflicts: [RecordingConflict] { plan.conflicts(now: store.now) }

    /// Every rule in priority order.
    var rules: [RecordingRule] { dragged ?? visible.rules }

    var history: [HistoryEntry] {
        journal.entries(recordings: visible, guide: store.guide.airings.values.flatMap { $0 }, now: store.now)
    }

    func upcoming(_ id: String) -> UpcomingRecording? {
        days.lazy.flatMap(\.items).first { $0.id == id }
    }

    func rule(_ id: String?) -> RecordingRule? {
        visible.rule(id)
    }

    func recordedItem(_ ratingKey: String) -> PlexMetadata? {
        guard case .ready(let items) = recorded else { return nil }
        return items.first { $0.ratingKey == ratingKey }
    }

    func scheduledCount(of rule: RecordingRule) -> Int {
        visible.scheduled.count { $0.ruleID == rule.id && $0.isUpcoming }
    }

    func upcoming(under rule: RecordingRule) -> [ScheduledRecording] {
        visible.scheduled.filter { $0.ruleID == rule.id && $0.isUpcoming }.sorted { $0.start < $1.start }
    }

    /// Other airings of the same episode that a losing recording could switch to.
    func alternatives(for grab: ScheduledRecording) -> [LiveAiring] {
        plan.alternatives(to: grab, in: store.guide.airings.values.flatMap { $0 }, now: store.now)
    }

    func channelLabel(_ airing: LiveAiring) -> String? {
        store.guide.channel(airing.channelKey)?.label
    }

    // MARK: Loading

    /// The saved journal, so History draws before the server answers.
    func loadJournal() {
        journal = alerts.journal(for: store.recordingKey)
    }

    /// Reads the recordings and the storage again and lets the journal see what changed.
    func refresh(includingRecorded: Bool = false) async {
        await store.loadRecordings()
        journal = alerts.observe(store.recordings, dvr: store.dvr, now: LiveClock.now(), key: store.recordingKey)
        if let fresh = try? await store.live.storage(for: store.recordings.rules) {
            storage = fresh
        }
        if includingRecorded { await loadRecorded(refresh: true) }
    }

    func loadRecorded(refresh: Bool = false) async {
        do {
            recorded = .ready(try await store.recorded(refresh: refresh))
        } catch {
            recorded = .failed(LiveText.problem(error, server: store.serverName))
        }
    }

    func setAlerts(_ on: Bool) async {
        await alerts.setOn(on, recordings: store.recordings, dvr: store.dvr, key: store.recordingKey)
    }

    // MARK: Changing

    /// Takes an airing off the schedule, or stops it while it records. `deletingSeries` ends its rule too.
    func unschedule(_ grab: ScheduledRecording, deletingSeries: Bool = false) async throws {
        hidden.insert(grab.id)
        defer { hidden.remove(grab.id) }
        try await store.unschedule(grab, deletingSeries: deletingSeries)
        journal = alerts.noteSkipped(grab, now: LiveClock.now(), key: store.recordingKey)
    }

    func delete(_ rule: RecordingRule) async throws {
        let grabs = visible.scheduled.filter { $0.ruleID == rule.id }
        hidden.insert(rule.id)
        defer { hidden.remove(rule.id) }
        try await store.delete(rule)
        alerts.noteRemoved(grabs, key: store.recordingKey)
        if selection == .rule(rule.id) { selection = nil }
    }

    func switchRecording(_ grab: ScheduledRecording, to airing: LiveAiring) async throws {
        try await store.switchRecording(grab, to: airing)
        journal = alerts.noteSkipped(grab, now: LiveClock.now(), key: store.recordingKey)
    }

    // MARK: Order

    /// Puts `rule` at index `to` of the rules and shows it there at once, returning what the server is told:
    /// the rule it now follows. The server answers `send`.
    func reorder(_ rule: RecordingRule, to index: Int) -> Move? {
        let all = rules
        guard let from = all.firstIndex(where: { $0.id == rule.id }),
              let moved = RuleOrder.move(all, from: from, to: index)
        else { return nil }
        dragged = moved.rules
        return Move(rule: rule, after: moved.after)
    }

    func send(_ move: Move) async throws {
        defer { dragged = nil }
        try await store.live.move(move.rule, after: move.after)
        await store.loadRecordings()
    }
}
