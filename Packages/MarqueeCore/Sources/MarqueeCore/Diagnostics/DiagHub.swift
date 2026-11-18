import Foundation
import Synchronization

/// Where diagnostic events enter the log. The app installs the sink that stamps, journals and sends them;
/// Core's own parts, such as the HTTP transport and the connection probes, report through the same door.
/// Without a sink, events go nowhere.
public enum DiagHub {
    public typealias Sink = @Sendable (DiagLevel, DiagCategory, String, [DiagField]) -> Void

    private static let sink = Mutex<Sink?>(nil)
    /// The lowest level kept: info normally, debug under the Detailed setting. Read before any value is
    /// formatted, so a debug event costs nothing unless it is kept.
    private static let threshold = Atomic<Int>(DiagLevel.info.rawValue)

    public static func install(_ handler: Sink?) {
        sink.withLock { $0 = handler }
    }

    public static func setThreshold(_ level: DiagLevel) {
        threshold.store(level.rawValue, ordering: .relaxed)
    }

    public static func keeps(_ level: DiagLevel) -> Bool {
        level.rawValue >= threshold.load(ordering: .relaxed)
    }

    /// Records an event. Values are formatted in order and redacted; a field named like a secret
    /// (`token`, `password`, …) is never written.
    public static func emit(_ category: DiagCategory, _ name: String, _ fields: KeyValuePairs<String, Any?> = [:], level: DiagLevel = .info) {
        guard keeps(level), let handler = sink.withLock({ $0 }) else { return }
        handler(level, category, name, format(fields))
    }

    /// Records an event whose values are already text, such as the video engine's own log lines.
    public static func emit(_ category: DiagCategory, _ name: String, pairs: [(String, String)], level: DiagLevel = .info) {
        guard keeps(level), let handler = sink.withLock({ $0 }) else { return }
        handler(level, category, name, pairs.map { key, value in
            DiagField(key, DiagRedactor.isSecretName(key) ? DiagRedactor.mark : DiagFormat.cut(DiagRedactor.redact(value)))
        })
    }

    public static func format(_ fields: KeyValuePairs<String, Any?>) -> [DiagField] {
        fields.map { key, value in
            DiagField(key, DiagRedactor.isSecretName(key) ? DiagRedactor.mark : DiagFormat.value(value))
        }
    }
}
