import BackgroundTasks
import Foundation
import MarqueeCore
import Observation
import UIKit
import UserNotifications

/// Alerts for a recording that starts, finishes or fails (docs/LIVE-TV.md §6.10), and the journal that tells those
/// changes from a state. They are off until the person turns them on, which asks iOS for permission. While Marquee
/// is open the DVR is looked at every minute; in the background iOS decides when, at best every 15 minutes, and
/// may skip a refresh, so an alert can come late. The switch and the journal stay on this phone: backups leave
/// `marquee.recordings.` out.
@MainActor @Observable
final class RecordingAlerts {
    /// The server and profile whose DVR is watched.
    struct Key: Hashable, Sendable {
        let server: String
        let profile: String
    }

    /// What one look reads.
    struct Watch: Sendable {
        let live: PlexLiveTV
        let key: Key
    }

    static let pollEvery = Duration.seconds(60)
    private static let onKey = "marquee.recordings.alerts"
    private static let journalPrefix = "marquee.recordings.journal."

    private(set) var isOn: Bool
    /// iOS refused notifications: the switch stays off until Settings allows them.
    private(set) var isBlocked = false
    /// Where the DVR to watch comes from; the session sets it.
    @ObservationIgnored var watch: (@MainActor () -> Watch?)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let presenter = AlertPresenter()
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.onKey)
        UNUserNotificationCenter.current().delegate = presenter
        watchLifecycle()
    }

    // MARK: Switch

    /// Turns alerts on or off. On asks iOS for permission first, then looks at the DVR once without announcing
    /// anything, so what happened while they were off stays quiet.
    func setOn(_ on: Bool, recordings: LiveRecordings, dvr: LiveDVR?, key: Key) async {
        guard on else {
            isOn = false
            defaults.set(false, forKey: Self.onKey)
            stopPolling()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: RecordingRefresh.id)
            return
        }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        isBlocked = !granted
        guard granted else { return }
        var journal = self.journal(for: key)
        journal.look(recordings, dvr: dvr, now: LiveClock.now())
        save(journal, for: key)
        isOn = true
        defaults.set(true, forKey: Self.onKey)
        startPolling()
        RecordingRefresh.schedule()
    }

    // MARK: Journal

    func journal(for key: Key) -> RecordingJournal {
        RecordingJournal.decoded(defaults.data(forKey: storageKey(key)))
    }

    private func save(_ journal: RecordingJournal, for key: Key) {
        defaults.set(journal.encoded(), forKey: storageKey(key))
    }

    private func storageKey(_ key: Key) -> String {
        Self.journalPrefix + key.server + "." + key.profile
    }

    /// Compares the DVR with the last look and keeps the journal; with alerts on, what changed is announced.
    /// Every look goes through here, whether the screen, the minute timer or a background refresh made it.
    @discardableResult
    func observe(_ recordings: LiveRecordings, dvr: LiveDVR?, now: Date, key: Key) -> RecordingJournal {
        var journal = self.journal(for: key)
        let events = journal.observe(recordings, dvr: dvr, now: now)
        save(journal, for: key)
        if isOn, !events.isEmpty {
            Task { await post(events) }
        }
        return journal
    }

    /// Notes an airing the person took off, so it is not reported as one that went missing.
    @discardableResult
    func noteSkipped(_ grab: ScheduledRecording, now: Date, key: Key) -> RecordingJournal {
        var journal = self.journal(for: key)
        journal.noteSkipped(grab, at: now)
        save(journal, for: key)
        return journal
    }

    /// Forgets the airings of a rule the person deleted, so deleting it reports nothing.
    func noteRemoved(_ grabs: [ScheduledRecording], key: Key) {
        var journal = self.journal(for: key)
        journal.noteRemoved(grabs)
        save(journal, for: key)
    }

    // MARK: Looking

    /// One look at the DVR from the server's rules and scheduled airings.
    func look() async {
        guard let watch = watch?() else { return }
        do {
            async let rules = watch.live.rules()
            async let scheduled = watch.live.scheduled()
            async let dvrs = watch.live.dvrs()
            let recordings = try await LiveRecordings(rules: rules, scheduled: scheduled)
            let dvr = try? await dvrs.first
            observe(recordings, dvr: dvr, now: LiveClock.now(), key: watch.key)
        } catch {
            Diag.event(.live, "recordings.look.failed", ["error": String(describing: error)], .notice)
        }
    }

    func startPolling() {
        guard isOn, polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.look()
                try? await Task.sleep(for: Self.pollEvery)
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// The minute timer runs while Marquee is open; in the background iOS gets a refresh request instead.
    private func watchLifecycle() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.startPolling() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    stopPolling()
                    if isOn { RecordingRefresh.schedule() }
                }
            },
        ]
    }

    // MARK: Announcing

    private func post(_ events: [RecordingEvent]) async {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            content.threadIdentifier = "recordings"
            do {
                try await center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
            } catch {
                Diag.event(.live, "recordings.notify.failed", ["error": String(describing: error)], .notice)
            }
        }
    }
}

/// The background refresh that looks at the DVR while Marquee is closed.
enum RecordingRefresh {
    static let id = "com.nphil.marquee.recording-check"
    /// The earliest the next refresh may start; iOS picks the real time.
    static let after: TimeInterval = 15 * 60

    /// Hands the refresh to iOS. Called once while the app launches, before it finishes.
    static func register(_ alerts: RecordingAlerts) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            let handle = RefreshHandle(task)
            let work = Task { @MainActor in
                if alerts.isOn {
                    schedule()
                    await alerts.look()
                }
                handle.task.setTaskCompleted(success: !Task.isCancelled)
            }
            handle.task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: after)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Diag.event(.live, "recordings.refresh.failed", ["error": String(describing: error)], .notice)
        }
    }
}

/// A background task passed to the main actor, which is the only place that finishes it.
private final class RefreshHandle: @unchecked Sendable {
    let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }
}

/// Shows a recording alert as a banner while Marquee is open, which iOS otherwise keeps quiet.
private final class AlertPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
