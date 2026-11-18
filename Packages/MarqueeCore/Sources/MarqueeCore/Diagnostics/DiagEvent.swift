import Foundation

/// How much an event matters. Debug lines are kept only under the Detailed setting; a warning or an
/// error sends the live log at once.
public enum DiagLevel: Int, Sendable, Comparable, CaseIterable, Codable {
    case debug, info, notice, warning, error

    public static func < (lhs: DiagLevel, rhs: DiagLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The mark a line carries; info has none, so the common case stays short.
    var mark: String? {
        switch self {
        case .debug: "D"
        case .info: nil
        case .notice: "N"
        case .warning: "W"
        case .error: "E"
        }
    }
}

/// The part of the app an event comes from; also the unified log's category.
public enum DiagCategory: String, Sendable, CaseIterable, Codable {
    case app, ui, nav, net, plex, player, audio, subtitles, offers, download, live, link, bigscreen, integration

    /// The categories whose events belong to the playback in progress.
    public var followsPlayback: Bool {
        switch self {
        case .player, .audio, .subtitles, .offers: true
        default: false
        }
    }
}

/// One named value of an event, already formatted and redacted.
public struct DiagField: Sendable, Hashable {
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// One diagnostic event: when, how serious, where from, what, and its values in the order given.
public struct DiagEvent: Sendable, Equatable {
    public var wall: Date
    /// Seconds since this launch began.
    public var uptime: TimeInterval
    public var level: DiagLevel
    public var category: DiagCategory
    public var name: String
    public var fields: [DiagField]
    /// Short random id of the launch; message headers and the journal's launch line carry it.
    public var launch: String
    /// The playback the event belongs to (`p3`), shown as `id=` on its line.
    public var playback: String?

    public init(
        wall: Date, uptime: TimeInterval, level: DiagLevel, category: DiagCategory, name: String,
        fields: [DiagField] = [], launch: String = "", playback: String? = nil
    ) {
        self.wall = wall
        self.uptime = uptime
        self.level = level
        self.category = category
        self.name = name
        self.fields = fields
        self.launch = launch
        self.playback = playback
    }

    /// `09:41:03.123 +12.34s player seek.request id=p3 from=8 to=35 via=seekItem`; levels other than
    /// info put their letter before the category.
    public func line(in calendar: Calendar = .current) -> String {
        var parts = [DiagFormat.clock(wall, calendar: calendar), "+" + DiagFormat.seconds(uptime, digits: 2) + "s"]
        if let mark = level.mark { parts.append(mark) }
        parts.append(category.rawValue)
        parts.append(name)
        if let playback { parts.append("id=" + playback) }
        for field in fields { parts.append(field.key + "=" + DiagFormat.quoted(field.value)) }
        return parts.joined(separator: " ")
    }

    /// Two events are repeats when only their times differ.
    func repeats(_ other: DiagEvent) -> Bool {
        level == other.level && category == other.category && name == other.name && fields == other.fields
            && playback == other.playback
    }
}

/// How event values are written: short, unambiguous and free of secrets.
public enum DiagFormat {
    /// A value longer than this is cut, so one event cannot crowd out the rest.
    public static let maxValue = 300

    /// Formats any value an event is given: numbers trimmed, booleans as yes/no, URLs and text redacted,
    /// errors as domain and code.
    public static func value(_ value: Any?) -> String {
        guard let value else { return "-" }
        let text: String
        switch value {
        case let optional as OptionalProtocol:
            return optional.wrapped.map(Self.value) ?? "-"
        case let string as String: text = DiagRedactor.redact(string)
        case let substring as Substring: text = DiagRedactor.redact(String(substring))
        case let bool as Bool: return bool ? "yes" : "no"
        case let int as Int: return String(int)
        case let int as Int64: return String(int)
        case let int as Int32: return String(int)
        case let int as UInt64: return String(int)
        case let double as Double: return seconds(double, digits: 3)
        case let float as Float: return seconds(Double(float), digits: 3)
        case let float as CGFloat: return seconds(Double(float), digits: 3)
        case let duration as Duration: return seconds(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18, digits: 3)
        case let url as URL: text = DiagRedactor.redact(url: url)
        case let date as Date: return clock(date, calendar: .current)
        case let error as any Error: text = describe(error)
        case let convertible as CustomStringConvertible: text = DiagRedactor.redact(convertible.description)
        default: text = DiagRedactor.redact(String(describing: value))
        }
        return cut(text)
    }

    /// `NSURLErrorDomain -1001` plus the underlying error's, the shape AVFoundation and URLSession failures
    /// are told apart by, then the error's own words.
    public static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " < \(underlying.domain) \(underlying.code)"
        }
        let words = String(describing: error)
        // An NSError's own description repeats the domain and code and dumps its user info.
        let reason = words.contains("Domain=")
            ? ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? ns.userInfo[NSLocalizedDescriptionKey] as? String
            : words
        if let reason, !reason.isEmpty { text += " " + DiagRedactor.redact(reason) }
        return text
    }

    /// Up to `digits` decimals with trailing zeros dropped: 35, 35.2, 0.125.
    public static func seconds(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value > 0 ? "inf" : "-inf") }
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    /// `HH:MM:SS.mmm` in the phone's time zone.
    public static func clock(_ date: Date, calendar: Calendar) -> String {
        // Whole milliseconds first, so a time stored as 03.12299… still reads .123.
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        let whole = (millis / 1000).rounded(.down)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: whole))
        return String(format: "%02d:%02d:%02d.%03d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, Int(millis - whole * 1000))
    }

    /// Values with spaces, quotes or `=` are quoted, so a line splits back into its fields.
    static func quoted(_ value: String) -> String {
        guard value.isEmpty || value.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" || $0.isNewline }) else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "")
        return "\"" + escaped + "\""
    }

    static func cut(_ text: String) -> String {
        guard text.count > maxValue else { return text }
        return String(text.prefix(maxValue - 1)) + "…"
    }
}

/// Lets `value(_:)` see through an optional wrapped in `Any`.
private protocol OptionalProtocol {
    var wrapped: Any? { get }
}

extension Optional: OptionalProtocol {
    fileprivate var wrapped: Any? {
        switch self {
        case .some(let value): value
        case .none: nil
        }
    }
}
