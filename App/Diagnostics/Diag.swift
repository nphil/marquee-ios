import Foundation
import MarqueeCore
import MarqueeLive
import Synchronization
import os

/// The diagnostic log (DESIGN §8.12): what every part of the app does, in order, in the unified log, in a
/// journal on the phone and, while Diagnostic Logs sends live, on the ntfy topic. Values pass through
/// `DiagRedactor`, and a field named like a secret is never written.
enum Diag {
    /// One event: `Diag.event(.player, "seek.request", ["to": target, "via": "farSeek"])`.
    static func event(
        _ category: DiagCategory, _ name: String, _ fields: KeyValuePairs<String, Any?> = [:], _ level: DiagLevel = .info
    ) {
        DiagHub.emit(category, name, fields, level: level)
    }

    /// An event whose fields are only known at run time.
    static func event(_ category: DiagCategory, _ name: String, list: [(String, Any?)], _ level: DiagLevel = .info) {
        guard DiagHub.keeps(level) else { return }
        DiagHub.emit(category, name, pairs: list.map { ($0.0, DiagFormat.value($0.1)) }, level: level)
    }

    /// A key button, kept under Detailed only.
    static func tap(_ name: String, _ fields: KeyValuePairs<String, Any?> = [:]) {
        DiagHub.emit(.ui, "tap." + name, fields, level: .debug)
    }

    /// Detail is Detailed: taps, playhead samples and successful requests are kept too.
    static var detailed: Bool {
        DiagHub.keeps(.debug)
    }

    /// Starts the journal, the system watchers and the engines' routes into the log; first thing at launch.
    @MainActor
    static func start() {
        DiagLog.shared.start()
        SystemMonitor.shared.start()
    }

    /// Opens a playback. Its id goes on every player, audio, subtitle and offer event until `endPlayback`.
    @discardableResult
    static func beginPlayback() -> String {
        DiagLog.shared.beginPlayback()
    }

    static func endPlayback() {
        DiagLog.shared.endPlayback()
    }

    /// Whole milliseconds since `start`.
    static func ms(since start: ContinuousClock.Instant) -> Int {
        let elapsed = (ContinuousClock.now - start).components
        return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }

    /// Logs each stored setting that differs, old → new, by its stored key. A change waits half a second, so
    /// a slider's drag is one line from where it started to where it stopped.
    @MainActor
    static func changes<Value: Encodable>(_ scope: String, from old: Value, to new: Value) {
        guard let before = fields(old), let after = fields(new) else { return }
        for key in Set(before.keys).union(after.keys) where before[key] != after[key] {
            SettingChanges.add(scope: scope, key: key, from: before[key] ?? "-", to: after[key] ?? "-")
        }
    }

    /// Settings as sorted JSON, for a report.
    static func describe<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "-" }
        return DiagRedactor.redact(String(decoding: data, as: UTF8.self))
    }

    /// Each top-level key with its value as compact JSON.
    private static func fields<Value: Encodable>(_ value: Value) -> [String: String]? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any] else { return nil }
        return object.mapValues { value in
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return "\(value)"
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

@MainActor
private enum SettingChanges {
    private struct Change {
        var scope: String
        var key: String
        var from: String
        var to: String
    }

    private static var pending: [String: Change] = [:]
    private static var flush: Task<Void, Never>?

    static func add(scope: String, key: String, from: String, to: String) {
        let id = scope + "." + key
        pending[id] = Change(scope: scope, key: key, from: pending[id]?.from ?? from, to: to)
        flush?.cancel()
        flush = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            for (_, change) in pending.sorted(by: { $0.key < $1.key }) where change.from != change.to {
                Diag.event(.ui, "settings.change", ["scope": change.scope, "key": change.key, "from": change.from, "to": change.to])
            }
            pending = [:]
        }
    }
}

/// The build the log comes from, on the launch event, journal headers and reports.
enum AppBuild {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    /// Set by the release build; `local` elsewhere.
    static let commit = Bundle.main.object(forInfoDictionaryKey: "MarqueeCommit") as? String ?? "local"
}

/// Stamps each event and hands it, in order, to the unified log, the journal and the live sender. One serial
/// queue owns the journal and the sender, so the caller only pays for formatting the values.
final class DiagLog: @unchecked Sendable {
    static let shared = DiagLog()

    /// Where the live log goes and how its messages are titled. Before the settings have said, lines wait.
    struct Setup: Sendable, Equatable {
        var config: NtfyConfig?
        var live: Bool
        var title: String
    }

    /// Six characters naming this launch on its journal files and live messages.
    let launch: String
    /// Also carries Test Connection and reports, so none of them is logged as a request of its own.
    let session: URLSession
    private let queue: DispatchQueue
    private let journal: DiagJournal
    private let sender: NtfySender
    private let born = ProcessInfo.processInfo.systemUptime
    private let loggers: [DiagCategory: Logger]
    private let playback = Mutex(PlaybackStamp())
    private let started = Atomic(false)
    // The queue's own.
    private var coalescer = DiagCoalescer()
    private var folding = false

    private struct PlaybackStamp {
        var count = 0
        var current: String?
    }

    private init() {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let launch = String((0..<6).map { _ in alphabet.randomElement() ?? "0" })
        let queue = DispatchQueue(label: "com.nphil.marquee.diagnostics", qos: .utility)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        FakePlex.install(into: configuration)
        let session = URLSession(configuration: configuration)
        self.launch = launch
        self.queue = queue
        self.session = session
        journal = DiagJournal(folder: DiagJournal.folder, launch: launch)
        sender = NtfySender(folder: DiagJournal.folder, queue: queue, launch: launch, session: session)
        loggers = Dictionary(uniqueKeysWithValues: DiagCategory.allCases.map {
            ($0, Logger(subsystem: "com.nphil.marquee", category: $0.rawValue))
        })
    }

    func start() {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        DiagHub.install { [self] level, category, name, fields in
            record(level, category, name, fields)
        }
        LiveLogSink.install { tag, fields in
            DiagHub.emit(.live, "live." + tag, pairs: fields, level: Self.level(live: tag))
        }
        queue.async { [self] in
            sender.restore()
            if let previous = journal.open() { report(previous) }
        }
    }

    func beginPlayback() -> String {
        playback.withLock { stamp in
            stamp.count += 1
            let id = "p\(stamp.count)"
            stamp.current = id
            return id
        }
    }

    func endPlayback() {
        playback.withLock { $0.current = nil }
    }

    func configure(_ setup: Setup) {
        queue.async { [self] in sender.configure(setup) }
    }

    /// Hands the live sender's state to the settings page as it changes.
    func observeSender(_ handler: @escaping @Sendable (NtfySender.State) -> Void) {
        queue.async { [self] in sender.onState = handler }
    }

    /// Where the app stands, for the next launch to tell whether this one ended cleanly.
    func setPhase(_ phase: DiagJournal.Phase) {
        let current = playback.withLock { $0.current }
        queue.async { [self] in journal.mark(phase, playback: current) }
    }

    /// The app is being terminated: the marker is written before this returns.
    func end() {
        queue.sync {
            hold()
            journal.mark(.ended, playback: nil)
        }
    }

    /// Everything in the journal, oldest first, with any held repeat written out.
    func journalData() async -> Data {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                hold()
                continuation.resume(returning: journal.allData())
            }
        }
    }

    /// Sends what waits now; `done` runs once it is out or cannot go.
    func flushLive(_ done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            hold()
            sender.flush(done)
        }
    }

    /// Delete All Local Data: the journal and anything waiting to be sent.
    func erase() {
        queue.async { [self] in
            journal.erase()
            sender.clear()
        }
    }

    private func record(_ level: DiagLevel, _ category: DiagCategory, _ name: String, _ fields: [DiagField]) {
        let event = DiagEvent(
            wall: Date(), uptime: ProcessInfo.processInfo.systemUptime - born, level: level, category: category,
            name: name, fields: fields, launch: launch,
            playback: category.followsPlayback ? playback.withLock { $0.current } : nil
        )
        queue.async { [self] in write(event) }
    }

    /// Queue only.
    private func write(_ event: DiagEvent) {
        let line = event.line()
        loggers[event.category]?.log(level: event.level.osLogType, "\(line, privacy: .public)")
        let lines = coalescer.add(event)
        // A repeat is held; its count is written once the run ends or five seconds pass.
        if lines.isEmpty, !folding {
            folding = true
            queue.asyncAfter(deadline: .now() + 5) { [self] in
                folding = false
                hold()
            }
        }
        for line in lines { keep(line) }
    }

    /// Writes out a held repeat. Queue only.
    private func hold() {
        for line in coalescer.flush() { keep(line) }
    }

    private func keep(_ line: DiagLine) {
        journal.append(line.text)
        sender.enqueue(line)
    }

    /// How the launch before this one ended, from the marker it left: one that was in the foreground, or
    /// still launching, did not end on its own, so its last lines come along.
    private func report(_ previous: DiagJournal.Previous) {
        let unexpected = previous.phase == .launching || previous.phase == .foreground
        let tail = unexpected || (previous.phase == .background && previous.playback != nil)
        let name = unexpected ? "previous-session-ended-unexpectedly"
            : tail ? "previous-session-ended-in-background" : "previous-session"
        let event = DiagEvent(
            wall: Date(), uptime: ProcessInfo.processInfo.systemUptime - born,
            level: unexpected ? .warning : tail ? .notice : .info, category: .app, name: name,
            fields: DiagHub.format([
                "launch": previous.launch, "version": previous.version, "phase": previous.phase.rawValue,
                "playback": previous.playback, "last": previous.updated, "lines": tail ? previous.tail.count : nil,
            ]),
            launch: launch
        )
        write(event)
        guard tail else { return }
        for text in previous.tail { keep(DiagLine("| " + text, level: .info)) }
    }

    private static func level(live tag: String) -> DiagLevel {
        switch tag {
        case "servo": .debug
        case "failed", "lost", "refused": .warning
        case "underrun", "reanchor", "stalled": .notice
        default: .info
        }
    }
}

private extension DiagLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning, .error: .error
        }
    }
}
