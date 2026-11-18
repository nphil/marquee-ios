import Foundation
import os
import Synchronization

/// The `live-*` lines and signposts of a direct stream, under the app's subsystem and category `LiveTV`
/// (docs/LIVE-TV.md §4.3), so one log stream holds a whole tune: `live-slate after=0.72`.
enum LiveLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "MarqueeLive"
    static let logger = Logger(subsystem: subsystem, category: "LiveTV")
    static let signposter = OSSignposter(subsystem: subsystem, category: "LiveTV")

    static func line(_ tag: String, _ fields: KeyValuePairs<String, String> = [:]) {
        let text = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.info("live-\(tag, privacy: .public) \(text, privacy: .public)")
        if let handler = LiveDiagnostics.sink.withLock({ $0 }) {
            handler(tag, fields.map { ($0.key, $0.value) })
        }
    }

    static func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "-"
    }
}

/// Hands every `live-*` line to the app's diagnostic log as well as the unified log.
public enum LiveDiagnostics {
    public typealias Sink = @Sendable (_ tag: String, _ fields: [(String, String)]) -> Void

    static let sink = Mutex<Sink?>(nil)

    public static func install(_ handler: Sink?) {
        sink.withLock { $0 = handler }
    }
}
