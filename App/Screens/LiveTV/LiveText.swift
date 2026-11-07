import Foundation
import MarqueeCore

/// The words and times the Live TV screens show, in the phone's locale and time zone.
enum LiveText {
    /// "8:00 PM".
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "8:00 – 8:30 PM", and "10:35 PM – 12:30 AM" across midnight, where the interval style would
    /// print both dates.
    static func range(_ start: Date, _ end: Date) -> String {
        let end = max(end, start)
        guard Calendar.current.isDate(start, inSameDayAs: end) else {
            return "\(time(start))\u{2009}–\u{2009}\(time(end))"
        }
        return (start..<end).formatted(date: .omitted, time: .shortened)
    }

    static func range(_ airing: LiveAiring) -> String {
        range(airing.start, airing.end)
    }

    /// "12 min left", "1 hr 5 min left".
    static func left(_ airing: LiveAiring, at now: Date) -> String {
        let minutes = max(1, Int((airing.end.timeIntervalSince(now) / 60).rounded(.up)))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left"
    }

    /// "Today", "Tonight" (from 5 PM), "Tomorrow", or "Monday" within the week and a date after it.
    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) >= 17 ? "Tonight" : "Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day, (0..<7).contains(days) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Tonight 8:00 – 8:30 PM".
    static func when(_ airing: LiveAiring, now: Date) -> String {
        "\(day(airing.start, now: now)) \(range(airing))"
    }

    /// "S2 E5 · Episode title", "1998" for a movie, or nil.
    static func subtitle(_ airing: LiveAiring) -> String? {
        switch airing.kind {
        case .movie:
            return airing.year.map(String.init)
        case .episode, .other:
            let parts = [airing.episodeCode, airing.episodeTitle == airing.title ? nil : airing.episodeTitle].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// "S2 E5 · Episode title" for an airing due to record, or nil.
    static func subtitle(_ recording: ScheduledRecording) -> String? {
        let parts = [recording.episodeCode, recording.episodeTitle == recording.title ? nil : recording.episodeTitle].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The record state in words, for VoiceOver and the programme sheet.
    static func mark(_ mark: RecordingMark?) -> String? {
        switch mark {
        case .scheduled: "will record"
        case .series: "will record, series"
        case .recording: "recording"
        case .failed: "recording failed"
        case .recorded: "recorded"
        case nil: nil
        }
    }

    /// "2.1 WXXX, Evening News, 8:00 – 8:30 PM, 12 min left, recording" (docs/LIVE-TV.md §6.6).
    static func spoken(_ channel: LiveChannel, airing: LiveAiring?, at now: Date, mark: RecordingMark?) -> String {
        guard let airing else { return "\(channel.label), \(channel.title), no guide data" }
        var parts = [channel.label, airing.title]
        if let subtitle = subtitle(airing) { parts.append(subtitle) }
        parts.append(airing.isOn(at: now) ? range(airing) : when(airing, now: now))
        if airing.isOn(at: now) { parts.append(left(airing, at: now)) }
        if airing.isNew { parts.append("new") }
        if let mark = self.mark(mark) { parts.append(mark) }
        return parts.joined(separator: ", ")
    }

    /// A sentence for a failed load.
    static func problem(_ error: any Error, server: String) -> String {
        switch error as? PlexError {
        case .unauthorized?:
            return "\(server) didn't accept this profile for Live TV."
        case .unreachable?:
            return "\(server) can't be reached right now."
        case .server(let status, _)?:
            return "\(server) couldn't load the guide (error \(status))."
        default:
            if error is URLError { return "\(server) can't be reached right now." }
            return "The guide from \(server) couldn't be read."
        }
    }

    /// A sentence for a recording change the server turned down.
    static func recordingProblem(_ error: any Error, server: String) -> String {
        switch error as? PlexError {
        case .unauthorized?:
            return "\(server) doesn't let this profile record."
        case .server(let status, _)? where status == 401 || status == 403:
            return "\(server) doesn't let this profile record."
        case .unreachable?:
            return "\(server) can't be reached right now."
        case .server(let status, _)?:
            return "\(server) turned the change down (error \(status))."
        default:
            if error is URLError { return "\(server) can't be reached right now." }
            return "\(server) didn't confirm the change."
        }
    }

    /// The record state as the programme sheet and Recordings write it.
    static func status(_ mark: RecordingMark) -> String {
        switch mark {
        case .scheduled, .series: "Will record"
        case .recording: "Recording now"
        case .failed: "Didn't record"
        case .recorded: "Recorded"
        }
    }

    /// "Record This Airing", "Record All Episodes" or "Record Movie" (template types 4, 2 and 1); a
    /// whole-show rule over sports reads "Record All Events", as Plex names it.
    static func recordTitle(_ option: RecordOption) -> String {
        switch option.kind {
        case .episode?: "Record This Airing"
        case .show?: option.title.localizedCaseInsensitiveContains("event") ? "Record All Events" : "Record All Episodes"
        case .movie?: "Record Movie"
        case nil: "Record \(option.title)"
        }
    }

    /// How early a recording starts or how late it ends, mid-sentence: "on time", "2 min early",
    /// "1 hr late".
    static func padding(minutes: Int, early: Bool) -> String {
        guard minutes > 0 else { return "on time" }
        let amount = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(amount) \(early ? "early" : "late")"
    }
}
