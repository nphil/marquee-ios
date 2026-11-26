import Foundation

/// The four parts of the Recordings screen, named alike on every platform.
public enum RecordingsSection: String, CaseIterable, Identifiable, Sendable {
    case upcoming, rules, recorded, history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .upcoming: "Upcoming"
        case .rules: "Rules"
        case .recorded: "Recorded"
        case .history: "History"
        }
    }
}

/// Whether the Recordings screen puts the list and the details side by side.
public enum RecordingsLayout: Sendable {
    /// A phone: the list, then the details on a screen of their own.
    case stack
    /// A tablet or a phone on its side: the list on the left, the details on the right.
    case split

    /// Points of width from which the list and the details sit side by side.
    public static let splitMinWidth = 600.0

    public static func layout(width: Double) -> RecordingsLayout {
        width >= splitMinWidth ? .split : .stack
    }
}

/// Where a dragged rule lands. Plex records the rules higher in the list first.
public enum RuleOrder {
    /// `rules` with the one at `from` moved so that it ends at `index`, and the rule it now follows, which is the
    /// `after` Plex wants (nil: first place). Nil when the move changes nothing.
    public static func move(_ rules: [RecordingRule], from: Int, to index: Int) -> (rules: [RecordingRule], after: RecordingRule?)? {
        guard rules.indices.contains(from), index >= 0, index < rules.count, from != index else { return nil }
        var moved = rules
        moved.insert(moved.remove(at: from), at: index)
        return (moved, index == 0 ? nil : moved[index - 1])
    }
}

extension UpcomingDay {
    /// "Today", "Tomorrow" or "Thursday, Nov 26".
    public func heading(now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if start == today { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), start == tomorrow { return "Tomorrow" }
        let parts = calendar.dateComponents([.month, .day, .weekday], from: start)
        let weekday = calendar.weekdaySymbols[(parts.weekday ?? 1) - 1]
        let month = calendar.shortMonthSymbols[(parts.month ?? 1) - 1]
        return "\(weekday), \(month) \(parts.day ?? 1)"
    }
}

extension RecordingRule {
    /// The rule in a sentence: "Records new episodes of Jimmy Kimmel Live! on any channel, starts 2 min early."
    public var summary: String { RecordingDraft(editing: self).summary }
}
