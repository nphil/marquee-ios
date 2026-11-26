import Foundation

/// What a rule records.
public enum RecordingScope: String, Sendable, Hashable, CaseIterable, Codable {
    /// One airing of one episode.
    case episode
    /// Every first showing.
    case new
    /// Every airing, repeats too.
    case all
    case movie
}

/// A library the DVR can save into, from `/library/sections`.
public struct RecordingLibrary: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case show, movie
    }

    public var id: Int
    /// The folder recordings go into (`Location.id`); the server picks its first when unknown.
    public var locationID: Int?
    public var title: String
    public var kind: Kind

    public init(id: Int, locationID: Int? = nil, title: String, kind: Kind) {
        self.id = id
        self.locationID = locationID
        self.title = title
        self.kind = kind
    }
}

/// How long recordings are kept.
public enum KeepPolicy: Hashable, Sendable {
    case all
    case latest(Int)
    case days(Int)
    case deleteWhenWatched

    /// Stable across platforms: "all", "latest:5", "days:7", "watched".
    public var id: String {
        switch self {
        case .all: "all"
        case .latest(let count): "latest:\(count)"
        case .days(let days): "days:\(days)"
        case .deleteWhenWatched: "watched"
        }
    }

    public var label: String {
        switch self {
        case .all: "Keep all"
        case .latest(let count): "Keep the latest \(count)"
        case .days(let days): "Keep \(days) days"
        case .deleteWhenWatched: "Delete when watched"
        }
    }

    /// The clause of the summary; nil for keeping everything, which is the plain case.
    var clause: String? {
        switch self {
        case .all: nil
        case .latest(let count): "keeps the latest \(count)"
        case .days(let days): "keeps the last \(days) days"
        case .deleteWhenWatched: "deletes each one once it is watched"
        }
    }

    /// Plex's `autoDeletionItemPolicyUnwatchedLibrary`: 0 keeps everything, N the latest N, -N the past N days.
    static func unwatched(_ value: String) -> KeepPolicy? {
        guard let number = Int(value) else { return nil }
        return number == 0 ? .all : number > 0 ? .latest(number) : .days(-number)
    }

    var unwatchedValue: String {
        switch self {
        case .all, .deleteWhenWatched: "0"
        case .latest(let count): String(count)
        case .days(let days): String(-days)
        }
    }

    static let fallback: [KeepPolicy] = [.all, .latest(1), .latest(3), .latest(5), .days(3), .days(7), .days(30)]
}

/// What the sheet shows for one row.
public enum DraftRowID: String, Sendable, Hashable, CaseIterable {
    case channel, resolution, replace, start, end, keep, commercials, library, partials
}

public struct DraftChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
}

public struct DraftRow: Identifiable, Hashable, Sendable {
    public enum Control: Hashable, Sendable {
        case toggle(Bool)
        case menu(selected: String)
    }

    public var id: DraftRowID
    public var title: String
    public var control: Control
    /// The menu's choices; empty for a toggle.
    public var choices: [DraftChoice]
    public var note: String?
}

/// One of the three big choices at the top of the sheet.
public struct ScopeChoice: Identifiable, Hashable, Sendable {
    public var id: RecordingScope { scope }
    public var scope: RecordingScope
    public var title: String
    public var detail: String
}

/// What goes to the server.
public struct RecordingSubmission: Hashable, Sendable {
    public var option: RecordOption
    /// The settings the user changed, by id.
    public var values: [String: String]
}

public enum RecordingDefaults {
    /// Minutes of end padding a sports or live event gets when the rule is made, since broadcasts run over.
    public static let liveEventEndPadding = 60
    /// The padding choices, besides the current value.
    public static let paddingChoices = [0, 2, 5, 15, 30]
}

/// The Record sheet: a new rule for an airing, or an existing rule. The sheet only draws `scopes` and `rows` and
/// calls `choose` and `set`; which settings exist, what they are called on the server and what the plain
/// sentence says live here.
public struct RecordingDraft: Hashable, Sendable {
    public enum Noun: Hashable, Sendable {
        case episode, event, movie
    }

    /// What is recorded, for the sheet's title and the summary.
    public struct Subject: Hashable, Sendable {
        public var title: String
        public var noun: Noun
        /// The airing's channel, for "this channel only".
        public var channelKey: String?
        public var channelLabel: String?
    }

    public let subject: Subject
    /// The rule being edited; nil for a new one.
    public let editing: RecordingRule?
    public private(set) var scope: RecordingScope
    /// True when the end padding was raised for a sports or live event and not yet touched.
    public private(set) var padsLiveEvent = false
    public var libraries: [RecordingLibrary]
    private let options: [RecordOption]
    private var values: [String: String] = [:]
    private var libraryID: Int?

    // MARK: Creating

    /// The sheet for recording `airing` on `channel`, from the template's `options`; nil when Plex offers none.
    public init?(
        airing: LiveAiring,
        channel: LiveChannel?,
        options: [RecordOption],
        libraries: [RecordingLibrary] = []
    ) {
        guard !options.isEmpty else { return nil }
        let noun: Noun = airing.isLiveEvent ? .event : airing.kind == .movie ? .movie : .episode
        subject = Subject(
            title: airing.title,
            noun: noun,
            channelKey: channel?.id ?? airing.channelKey,
            channelLabel: channel?.label
        )
        editing = nil
        self.options = options
        self.libraries = libraries
        scope = Self.available(options).first ?? .all
        if airing.isLiveEvent, let end = option?.setting("endOffsetMinutes"),
           (Int(end.value) ?? 0) < RecordingDefaults.liveEventEndPadding {
            values["endOffsetMinutes"] = String(RecordingDefaults.liveEventEndPadding)
            padsLiveEvent = true
        }
    }

    /// The sheet for changing `rule`.
    public init(editing rule: RecordingRule) {
        let noun: Noun = rule.type == RecordOption.Kind.movie.rawValue ? .movie : .episode
        let upcoming = rule.recordings.first { $0.isUpcoming }
        subject = Subject(
            title: rule.title, noun: noun, channelKey: upcoming?.channelKey,
            channelLabel: upcoming.flatMap(RecordingJournal.channel)
        )
        editing = rule
        options = [RecordOption(type: rule.type, title: rule.title, settings: rule.settings)]
        libraries = []
        let oneOff = rule.type == RecordOption.Kind.episode.rawValue
        let movie = rule.type == RecordOption.Kind.movie.rawValue
        let onlyNew = ["1", "true"].contains(rule.setting("onlyNewAirings")?.value ?? "1")
        scope = oneOff ? .episode : movie ? .movie : onlyNew ? .new : .all
    }

    /// The scopes a template offers: this episode when it has a one-off, a movie, and new or all episodes when
    /// there is a whole-show rule that can tell them apart.
    private static func available(_ options: [RecordOption]) -> [RecordingScope] {
        var scopes: [RecordingScope] = []
        if options.contains(where: { $0.kind == .episode }) || options.contains(where: { $0.kind == nil && $0.isOneShot }) {
            scopes.append(.episode)
        }
        if options.contains(where: { $0.kind == .movie }) { scopes.append(.movie) }
        if let show = options.first(where: { $0.kind == .show }) {
            if show.setting("onlyNewAirings") != nil { scopes.append(.new) }
            scopes.append(.all)
        }
        return scopes
    }

    // MARK: Scope

    public var scopes: [ScopeChoice] {
        if let editing {
            if editing.isSeries { return [choice(.new), choice(.all)] }
            return [choice(scope)]
        }
        return Self.available(options).map(choice)
    }

    private func choice(_ scope: RecordingScope) -> ScopeChoice {
        let noun: String
        switch subject.noun {
        case .episode: noun = "Episode"
        case .event: noun = "Event"
        case .movie: noun = "Movie"
        }
        switch scope {
        case .episode: return ScopeChoice(scope: scope, title: "This \(noun)", detail: "Just this airing")
        case .new: return ScopeChoice(scope: scope, title: "New \(noun)s", detail: "Every first showing")
        case .all: return ScopeChoice(scope: scope, title: "All \(noun)s", detail: "Every airing, repeats too")
        case .movie: return ScopeChoice(scope: scope, title: "This Movie", detail: "Just this airing")
        }
    }

    public mutating func choose(scope: RecordingScope) {
        guard scopes.contains(where: { $0.scope == scope }) else { return }
        self.scope = scope
        let base = options.first { $0.kind == .show }?.setting("onlyNewAirings")?.value
        switch scope {
        case .new: store("onlyNewAirings", "1", base: base)
        case .all: store("onlyNewAirings", "0", base: base)
        case .episode, .movie: values["onlyNewAirings"] = nil
        }
    }

    /// The template option the scope records through.
    private var option: RecordOption? {
        switch scope {
        case .episode: options.first { $0.kind == .episode } ?? options.first { $0.kind == nil && $0.isOneShot }
        case .movie: options.first { $0.kind == .movie }
        case .new, .all: options.first { $0.kind == .show } ?? options.first
        }
    }

    // MARK: Values

    private func setting(_ id: String) -> RecordSetting? {
        guard let setting = option?.setting(id), !setting.isHidden else { return nil }
        return setting
    }

    private func current(_ id: String) -> String {
        values[id] ?? option?.setting(id)?.value ?? ""
    }

    /// What the server does when the rule says nothing.
    private func base(_ id: String) -> String {
        option?.setting(id).map { $0.defaultValue ?? $0.value } ?? ""
    }

    /// Sets an override, or removes it when it says what the setting already says.
    private mutating func store(_ id: String, _ value: String, base original: String?) {
        values[id] = value == original ? nil : value
    }

    private mutating func put(_ id: String, _ value: String) {
        store(id, value, base: option?.setting(id)?.value)
    }

    // MARK: Rows

    public var rows: [DraftRow] {
        DraftRowID.allCases.compactMap(row)
    }

    private func row(_ id: DraftRowID) -> DraftRow? {
        switch id {
        case .channel: channelRow()
        case .resolution: resolutionRow()
        case .replace: switchRow(.replace, "Replace with better copy", "replaceLowerQuality")
        case .start: paddingRow(.start, "Start early", "startOffsetMinutes", "early")
        case .end: paddingRow(.end, "End late", "endOffsetMinutes", "late")
        case .keep: keepRow()
        case .commercials: switchRow(.commercials, "Remove commercials", "comskipEnabled")
        case .library: libraryRow()
        case .partials: switchRow(.partials, "Record partial airings", "recordPartials")
        }
    }

    public mutating func set(_ row: DraftRowID, on: Bool) {
        switch row {
        case .replace: setSwitch("replaceLowerQuality", on)
        case .commercials:
            setSwitch("comskipEnabled", on)
            if on, let method = setting("comskipMethod"),
               let removing = method.choices.first(where: { Self.matches($0.label, ["remov", "delet", "cut"]) }) {
                put("comskipMethod", removing.value)
            }
        case .partials: setSwitch("recordPartials", on)
        case .resolution:
            if let pair = resolutionToggle() { put("minVideoQuality", on ? pair.on : pair.off) }
        default: break
        }
    }

    public mutating func choose(_ row: DraftRowID, _ choice: String) {
        switch row {
        case .channel:
            guard let setting = setting("lineupChannel") else { return }
            put("lineupChannel", choice == "any" ? setting.defaultValue ?? "" : channelValue(setting))
        case .resolution: put("minVideoQuality", choice)
        case .start: put("startOffsetMinutes", choice)
        case .end:
            put("endOffsetMinutes", choice)
            padsLiveEvent = false
        case .keep:
            guard let policy = keepChoices().first(where: { $0.id == choice }) else { return }
            applyKeep(policy)
        case .library: libraryID = Int(choice)
        case .replace, .commercials, .partials: break
        }
    }

    // MARK: Channel

    private func channelRow() -> DraftRow? {
        guard let setting = setting("lineupChannel") else { return nil }
        let only = subject.channelLabel.map { "\($0) only" } ?? "This channel only"
        let chosen = current("lineupChannel")
        let isOnly = !chosen.isEmpty && chosen != (setting.defaultValue ?? "")
        guard subject.channelKey != nil || isOnly else { return nil }
        return DraftRow(
            id: .channel, title: "Channel", control: .menu(selected: isOnly ? "this" : "any"),
            choices: [DraftChoice(id: "any", label: "Any channel"), DraftChoice(id: "this", label: only)], note: nil
        )
    }

    /// The setting's value for the airing's channel: the listed choice that names it, or its key.
    private func channelValue(_ setting: RecordSetting) -> String {
        let key = subject.channelKey ?? ""
        if let editing, subject.channelKey == nil {
            return editing.setting("lineupChannel")?.value ?? ""
        }
        let words = (subject.channelLabel ?? "").lowercased().split(separator: " ").map(String.init)
        let listed = setting.choices.first { $0.value == key }
            ?? setting.choices.first { choice in !words.isEmpty && words.allSatisfy { choice.label.lowercased().contains($0) } }
        return listed?.value ?? key
    }

    // MARK: Switches

    private struct Switch {
        let on: String
        let off: String
    }

    /// The values a yes-or-no setting takes: true and false for a bool, the listed choices that say so for an
    /// int with a menu, 1 and 0 for a bare int. Nil when the menu has no choice for either.
    private static func switchValues(_ setting: RecordSetting) -> Switch? {
        if setting.type == "bool" || ["true", "false"].contains(setting.value.lowercased()) {
            return Switch(on: "true", off: "false")
        }
        guard !setting.choices.isEmpty else { return Switch(on: "1", off: "0") }
        let on = setting.choices.first { matches($0.label, ["enabled", "enable", "on", "yes", "true"], exactly: true) }
        let off = setting.choices.first { matches($0.label, ["disabled", "disable", "off", "no", "never", "false"], exactly: true) }
        guard let on, let off else { return nil }
        return Switch(on: on.value, off: off.value)
    }

    private static func matches(_ label: String, _ words: [String], exactly: Bool = false) -> Bool {
        let text = label.lowercased()
        return words.contains { exactly ? text == $0 || text.hasPrefix($0 + " ") : text.contains($0) }
    }

    private func isOn(_ setting: RecordSetting, _ pair: Switch) -> Bool {
        let value = current(setting.id)
        if value == pair.on { return true }
        if value == pair.off { return false }
        return ["true", "1"].contains(value.lowercased())
    }

    private func switchRow(_ id: DraftRowID, _ title: String, _ settingID: String) -> DraftRow? {
        guard let setting = setting(settingID) else { return nil }
        guard let pair = Self.switchValues(setting) else {
            return DraftRow(
                id: id, title: title, control: .menu(selected: current(settingID)),
                choices: setting.choices.map { DraftChoice(id: $0.value, label: $0.label) }, note: nil
            )
        }
        return DraftRow(id: id, title: title, control: .toggle(isOn(setting, pair)), choices: [], note: nil)
    }

    private mutating func setSwitch(_ settingID: String, _ on: Bool) {
        guard let setting = setting(settingID), let pair = Self.switchValues(setting) else { return }
        put(settingID, on ? pair.on : pair.off)
    }

    // MARK: Resolution

    /// Prefer HD as a switch when the server offers only two resolutions: the one that names HD is on.
    private func resolutionToggle() -> Switch? {
        guard let setting = setting("minVideoQuality"), setting.choices.count == 2 else { return nil }
        let hd = setting.choices.first { Self.matches($0.label, ["prefer"]) && Self.matches($0.label, ["hd"]) }
            ?? setting.choices.first { Self.matches($0.label, ["hd"]) }
            ?? setting.choices.max { (Int($0.value) ?? 0) < (Int($1.value) ?? 0) }
        guard let hd, let other = setting.choices.first(where: { $0.value != hd.value }) else { return nil }
        return Switch(on: hd.value, off: other.value)
    }

    private func resolutionRow() -> DraftRow? {
        guard let setting = setting("minVideoQuality"), !setting.choices.isEmpty else { return nil }
        if let pair = resolutionToggle() {
            return DraftRow(id: .resolution, title: "Prefer HD", control: .toggle(current(setting.id) == pair.on), choices: [], note: nil)
        }
        return DraftRow(
            id: .resolution, title: setting.label.isEmpty ? "Resolution" : setting.label,
            control: .menu(selected: current(setting.id)),
            choices: setting.choices.map { DraftChoice(id: $0.value, label: $0.label) }, note: nil
        )
    }

    // MARK: Padding

    private func paddingRow(_ id: DraftRowID, _ title: String, _ settingID: String, _ direction: String) -> DraftRow? {
        guard setting(settingID) != nil else { return nil }
        let now = Int(current(settingID)) ?? 0
        let minutes = Array(Set(RecordingDefaults.paddingChoices + [now])).sorted()
        let choices = minutes.map { DraftChoice(id: String($0), label: $0 == 0 ? "Off" : "\(Self.duration($0)) \(direction)") }
        let note = id == .end && padsLiveEvent
            ? "Sports and live events often run long, so the end is padded by an hour. Change it here."
            : nil
        return DraftRow(id: id, title: title, control: .menu(selected: String(now)), choices: choices, note: note)
    }

    /// "5 min", "1 hour", "1 hr 30 min".
    static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        let whole = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? whole : "\(hours) hr \(rest) min"
    }

    // MARK: Keep

    private func keepChoices() -> [KeepPolicy] {
        guard let unwatched = setting("autoDeletionItemPolicyUnwatchedLibrary") ?? setting("autoDeletionItemPolicyWatchedLibrary") else {
            return []
        }
        var policies: [KeepPolicy]
        if let list = setting("autoDeletionItemPolicyUnwatchedLibrary"), !list.choices.isEmpty {
            policies = list.choices.compactMap { KeepPolicy.unwatched($0.value) }
        } else if setting("autoDeletionItemPolicyUnwatchedLibrary") != nil {
            policies = KeepPolicy.fallback
        } else {
            policies = [.all]
        }
        if !policies.contains(.all) { policies.insert(.all, at: 0) }
        if setting("autoDeletionItemPolicyWatchedLibrary") != nil { policies.append(.deleteWhenWatched) }
        let currentPolicy = currentKeep(unwatched)
        if !policies.contains(currentPolicy) { policies.append(currentPolicy) }
        var seen = Set<String>()
        return policies.filter { seen.insert($0.id).inserted }
    }

    private func currentKeep(_ unwatched: RecordSetting) -> KeepPolicy {
        if setting("autoDeletionItemPolicyWatchedLibrary") != nil, current("autoDeletionItemPolicyWatchedLibrary") == watchedDeleteValue {
            return .deleteWhenWatched
        }
        return setting("autoDeletionItemPolicyUnwatchedLibrary") == nil
            ? .all : KeepPolicy.unwatched(current("autoDeletionItemPolicyUnwatchedLibrary")) ?? .all
    }

    /// The watched setting's value that deletes an episode once it is watched: Plex's "On next refresh" (100).
    private var watchedDeleteValue: String {
        let choices = setting("autoDeletionItemPolicyWatchedLibrary")?.choices ?? []
        return choices.first { Self.matches($0.label, ["refresh"]) }?.value
            ?? choices.first { Self.matches($0.label, ["watch"]) && !Self.matches($0.label, ["never"]) }?.value
            ?? "100"
    }

    private mutating func applyKeep(_ policy: KeepPolicy) {
        if setting("autoDeletionItemPolicyUnwatchedLibrary") != nil { put("autoDeletionItemPolicyUnwatchedLibrary", policy.unwatchedValue) }
        if setting("autoDeletionItemPolicyWatchedLibrary") != nil {
            let never = setting("autoDeletionItemPolicyWatchedLibrary")?.defaultValue ?? "0"
            put("autoDeletionItemPolicyWatchedLibrary", policy == .deleteWhenWatched ? watchedDeleteValue : never)
        }
    }

    private func keepRow() -> DraftRow? {
        guard let unwatched = setting("autoDeletionItemPolicyUnwatchedLibrary") ?? setting("autoDeletionItemPolicyWatchedLibrary") else {
            return nil
        }
        let choices = keepChoices().map { DraftChoice(id: $0.id, label: $0.label) }
        return DraftRow(id: .keep, title: "Keep", control: .menu(selected: currentKeep(unwatched).id), choices: choices, note: nil)
    }

    // MARK: Library

    private var libraryKind: RecordingLibrary.Kind {
        option?.kind == .movie ? .movie : .show
    }

    private var selectedLibrary: RecordingLibrary? {
        let kind = libraryKind
        let id = libraryID ?? option?.targetLibrarySectionID
        return libraries.first { $0.kind == kind && $0.id == id }
    }

    private func libraryRow() -> DraftRow? {
        let kind = libraryKind
        let choices = libraries.filter { $0.kind == kind }
        guard editing == nil, choices.count > 1 else { return nil }
        return DraftRow(
            id: .library, title: "Library", control: .menu(selected: selectedLibrary.map { String($0.id) } ?? ""),
            choices: choices.map { DraftChoice(id: String($0.id), label: $0.title) }, note: nil
        )
    }

    // MARK: Summary

    /// "Records new episodes of Jimmy Kimmel Live! on any channel, starts 2 min early, keeps the latest 5."
    public var summary: String {
        let title = subject.title
        let what: String
        switch (scope, subject.noun) {
        case (.movie, _), (_, .movie): what = title
        case (.episode, .event): what = "this event of \(title)"
        case (.new, .event): what = "new events of \(title)"
        case (.all, .event): what = "all events of \(title)"
        case (.episode, _): what = "this episode of \(title)"
        case (.new, _): what = "new episodes of \(title)"
        case (.all, _): what = "all episodes of \(title)"
        }
        let chosen = current("lineupChannel")
        let only = setting("lineupChannel").map { !chosen.isEmpty && chosen != ($0.defaultValue ?? "") } ?? false
        let channel = only ? "\(subject.channelLabel ?? "this channel") only" : "any channel"
        var parts = ["Records \(what) on \(channel)"]
        if let start = Int(current("startOffsetMinutes")), start > 0 { parts.append("starts \(Self.duration(start)) early") }
        if let end = Int(current("endOffsetMinutes")), end > 0 { parts.append("ends \(Self.duration(end)) late") }
        parts += switchClauses()
        if let unwatched = setting("autoDeletionItemPolicyUnwatchedLibrary") ?? setting("autoDeletionItemPolicyWatchedLibrary"),
           let clause = currentKeep(unwatched).clause {
            parts.append(clause)
        }
        if let library = selectedLibrary, library.id != option?.targetLibrarySectionID.map({ $0 }) ?? library.id {
            parts.append("saves to \(library.title)")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// The yes-or-no settings that differ from what the server does on its own.
    private func switchClauses() -> [String] {
        var clauses: [String] = []
        if let setting = setting("minVideoQuality"), current(setting.id) != base(setting.id),
           let label = setting.choices.first(where: { $0.value == current(setting.id) })?.label {
            if Self.matches(label, ["only"]) {
                let level = label.replacingOccurrences(of: " only", with: "", options: [.caseInsensitive])
                clauses.append("only records \(level)")
            } else if Self.matches(label, ["prefer"]) {
                clauses.append("prefers HD")
            }
        }
        let flags: [(String, String)] = [
            ("replaceLowerQuality", "swaps in a better copy when one airs"),
            ("comskipEnabled", "removes commercials"),
            ("recordPartials", "records partial airings"),
        ]
        for (id, clause) in flags {
            guard let setting = setting(id), let pair = Self.switchValues(setting) else { continue }
            if isOn(setting, pair), !isOn(setting, pair, using: base(id)) { clauses.append(clause) }
        }
        return clauses
    }

    private func isOn(_ setting: RecordSetting, _ pair: Switch, using value: String) -> Bool {
        value == pair.on || (value != pair.off && ["true", "1"].contains(value.lowercased()))
    }

    // MARK: Sending

    /// The template option and the settings to send: the option's own, the user's changes over them.
    public var submission: RecordingSubmission? {
        guard var option else { return nil }
        if let library = selectedLibrary, library.id != option.targetLibrarySectionID {
            option.targetLibrarySectionID = library.id
            option.targetSectionLocationID = library.locationID
        }
        return RecordingSubmission(option: option, values: values)
    }

    /// Whether the user changed anything from what the rule already has.
    public var isChanged: Bool {
        guard let editing else { return true }
        return values.contains { id, value in editing.setting(id)?.value != value }
    }

    /// The settings a plain Record from the guide's menu sends over the server's own: the padding a sports or
    /// live event gets, when the server's padding is shorter.
    public static func quickValues(for airing: LiveAiring, option: RecordOption) -> [String: String] {
        guard airing.isLiveEvent, let end = option.setting("endOffsetMinutes"),
              (Int(end.value) ?? 0) < RecordingDefaults.liveEventEndPadding
        else { return [:] }
        return ["endOffsetMinutes": String(RecordingDefaults.liveEventEndPadding)]
    }
}
