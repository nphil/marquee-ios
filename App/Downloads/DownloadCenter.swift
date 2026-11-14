import Foundation
import MarqueeCore
import Observation
import UIKit

struct DownloadSettings: Codable {
    var quality: DownloadQuality = .original
    var cellular = false
    var autoDeleteWatched = false
    var keepAlive = false
}

/// Why a download on its way is not moving, for its row.
enum DownloadHold: Equatable {
    /// Kept to Wi-Fi while the phone is on cellular only.
    case wifi
    /// The last tries in a row got no answer from the server; they go on.
    case unreachable(server: String)
}

@MainActor @Observable
final class DownloadCenter {
    let store: DownloadStore
    var settings: DownloadSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
            if !settings.keepAlive { keepAlive.stop() }
            // A slice iOS holds keeps the cellular rule it started with; one not yet begun starts again under the new one.
            if settings.cellular != oldValue.cellular { Task { [background] in await background.cancelUnstarted() } }
            if settings.cellular && !oldValue.cellular { wake() }
        }
    }
    var error: String?
    var records: [DownloadRecord] { allRecords.filter { $0.scope == scope } }
    var activeCount: Int { records.filter { $0.phase.isActive }.count }
    /// Counts up when a still is saved after its row was first drawn, so lists show it without a relaunch.
    private(set) var artVersion = 0
    /// The phone is up on cellular only.
    private(set) var cellularOnly = FakePlex.cellularOnly
    /// Downloads whose last two tries or more got no answer.
    private(set) var stalled: Set<String> = []

    /// Downloads kept to Wi-Fi are not fetched; a slice handed to iOS waits there for Wi-Fi.
    var waitingForWiFi: Bool { cellularOnly && !settings.cellular }

    func hold(for record: DownloadRecord) -> DownloadHold? {
        guard record.phase.isActive else { return nil }
        if waitingForWiFi { return .wifi }
        if stalled.contains(record.id) { return .unreachable(server: library?.server.name ?? "the server") }
        return nil
    }

    private static let settingsKey = "marquee.downloads.settings"
    private let defaults: UserDefaults
    private var allRecords: [DownloadRecord]
    private var scope: DownloadScope?
    private var library: PlexLibrary?
    private let meter = TransferMeter()
    private let keepAlive = DownloadKeepAlive()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var transferOwner = UUID()
    @ObservationIgnored private var enqueueOwner = UUID()
    /// Seasons and shows being queued, so a second tap does not walk the same episodes again.
    @ObservationIgnored private var batches: Set<String> = []
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var transferRecordID: String?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?
    private var playbackCount = 0
    private var removing: Set<String> = []
    private var backgroundHandoff = false
    /// Per download: failures in a row, and the earliest time of the next try.
    @ObservationIgnored private var retries: [String: Int] = [:]
    @ObservationIgnored private var holds: [String: Date] = [:]
    @ObservationIgnored private var backingOff = false
    @ObservationIgnored private var pathTask: Task<Void, Never>?
    /// Libraries in use since launch, by server, for removing a server's queue items after sign-out.
    @ObservationIgnored private var libraries: [String: PlexLibrary] = [:]
    @ObservationIgnored private var watchDirty = false
    @ObservationIgnored private var lastPersist = Date.distantPast
    @ObservationIgnored private var lastWatchPosition: [String: Int] = [:]
    private static let watchSaveInterval: TimeInterval = 30
    @ObservationIgnored private lazy var fetcher = RangeFetcher(meter: meter)
    /// Poster and subtitle fetches; the UI tests' fake Plex answers them, which `.shared` would bypass.
    @ObservationIgnored private lazy var metadataSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        FakePlex.install(into: configuration)
        return URLSession(configuration: configuration)
    }()
    @ObservationIgnored private lazy var background = BackgroundTransfer { [weak self] result in
        await self?.receivedBackground(result)
    }
    /// HomeLabber's quality map while its plugin is set up; AppSession keeps it current.
    @ObservationIgnored var qualityMap: HomeLabberClient? {
        didSet {
            guard qualityMap?.config != oldValue?.config else { return }
            qualityMaps = [:]
            unscored = []
        }
    }
    /// HomeLabber's scores fetched for the Download menus, by title.
    private(set) var qualityMaps: [String: QualityMapEntry] = [:]
    /// Whether a show is animation, which its episodes do not say themselves.
    private(set) var animatedShows: [String: Bool] = [:]
    @ObservationIgnored private var unscored: Set<String> = []
    /// After HomeLabber does not answer, the menus leave it alone for a minute: away from home every
    /// question would wait for its timeout.
    @ObservationIgnored private var qualityMapQuietUntil = Date.distantPast
    /// Segments handed to iOS at a time; at Plex's 8 s segments, most of an hour.
    private static let handoffSegments = 400
    /// Sessions begun again in a row without a segment saved before the download queue takes over.
    private static let sessionRestarts = 3

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let root: URL
        if FakePlex.isActive {
            let fixtures = FileManager.default.temporaryDirectory.appending(path: "MarqueeUITestDownloads", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: fixtures)
            root = fixtures.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Downloads", directoryHint: .isDirectory)
        }
        store = DownloadStore(root: root)
        // The folder is app data in iPhone Storage but never a backup: the videos can be fetched again.
        try? store.prepareRoot()
        allRecords = store.loadIndex()
        // The UI tests start every launch from the default settings.
        settings = FakePlex.isActive ? DownloadSettings() : defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DownloadSettings.self, from: $0) } ?? DownloadSettings()
        keepAlive.onSurrender = { [weak self] in self?.handoff() }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foreground() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enteredBackground() }
        }
        _ = background
        pathTask = Task { [weak self] in
            var previous: NetworkPath?
            for await path in NetworkPath.updates() {
                guard let self else { return }
                self.cellularOnly = path.isCellularOnly || FakePlex.cellularOnly
                if path.isConnected, path != previous {
                    self.wake()
                    self.backfill()
                }
                previous = path
            }
        }
    }

    func connect(library: PlexLibrary?, scope: DownloadScope?) {
        // An account refresh reconnects with what is already in use; restarting would cancel the
        // transfer and any Download tap still in flight.
        guard library?.server != self.library?.server || scope != self.scope else { return }
        transferOwner = UUID()
        enqueueOwner = UUID()
        worker?.cancel()
        keepAlive.stop()
        self.library = library
        self.scope = scope
        qualityMaps = [:]
        animatedShows = [:]
        unscored = []
        if let library { libraries[library.server.id] = library }
        // iOS relaunches the app in the background to deliver a finished slice; the in-app fetcher
        // would be suspended within seconds there.
        if UIApplication.shared.applicationState == .background { backgroundHandoff = true }
        kick()
        syncWatch()
        backfill()
    }

    /// - Parameter choice: The menu choice's `DownloadQualityPlan.Option.id`, which tells the 4K choice
    ///   from High; without one, the quality's choice.
    func enqueue(item: PlexMetadata, quality: DownloadQuality, choice: String? = nil, mediaIndex: Int, capabilities: DeviceCapabilities) async {
        if let message = await add(item: item, quality: quality, choice: choice, mediaIndex: mediaIndex, capabilities: capabilities) { error = message }
    }

    /// The Download menu's choices for one version of a title, from what is known now: HomeLabber's
    /// scores once `prepareChoices` has them, else the estimate. Unknown capabilities leave Original
    /// in the menu; the Download tap checks it.
    func plan(for item: PlexMetadata, mediaIndex: Int, capabilities: DeviceCapabilities?) -> DownloadQualityPlan? {
        guard item.media.indices.contains(mediaIndex) else { return nil }
        let media = item.media[mediaIndex]
        let originalPlays = media.parts.count == 1
            && capabilities.map { DownloadPlayability.refusal(media: media, part: media.parts[0], capabilities: $0) == nil } ?? true
        let animated = item.type == .episode
            ? item.grandparentRatingKey.flatMap { animatedShows[$0] } ?? false
            : DownloadQualityPlan.isAnimated(genres: item.genres)
        return DownloadQualityPlan(
            media: media, animated: animated, hevc: capabilities?.hevc ?? false, originalPlays: originalPlays, map: qualityMaps[item.ratingKey]
        )
    }

    /// Fetches what the choices need beyond the title's own answer: HomeLabber's scores for it and,
    /// for an episode, whether its show is animation.
    func prepareChoices(for item: PlexMetadata) async {
        guard let library else { return }
        if item.type == .episode, let show = item.grandparentRatingKey, animatedShows[show] == nil,
           let found = try? await library.metadata(show) {
            animatedShows[show] = DownloadQualityPlan.isAnimated(genres: found.genres)
        }
        guard let qualityMap, qualityMaps[item.ratingKey] == nil, !unscored.contains(item.ratingKey), qualityMapQuietUntil < .now else { return }
        do {
            if let entry = try await qualityMap.entry(server: library.server.clientIdentifier, ratingKey: item.ratingKey) {
                qualityMaps[item.ratingKey] = entry
            } else {
                unscored.insert(item.ratingKey)
            }
        } catch {
            qualityMapQuietUntil = Date.now.addingTimeInterval(60)
        }
    }

    /// Queues each episode of a season or show that is not already downloaded or queued, in episode order, at
    /// the default quality. The queue then runs them one at a time. Failures are reported once, together,
    /// since a phone that cannot play one Original episode cannot play the next.
    func enqueueEpisodes(under item: PlexMetadata, capabilities: DeviceCapabilities) async {
        guard let library, let scope, batches.insert(item.ratingKey).inserted else { return }
        defer { batches.remove(item.ratingKey) }
        let owner = enqueueOwner
        do {
            let leaves = item.type == .show ? try await library.allLeaves(of: item.ratingKey) : try await library.children(of: item.ratingKey)
            var messages: [String] = []
            var failed = 0
            for episode in leaves where episode.type == .episode {
                guard self.scope == scope, enqueueOwner == owner else { return }
                guard !records.contains(where: { $0.ratingKey == episode.ratingKey }) else { continue }
                guard let message = await add(item: episode, quality: settings.quality, mediaIndex: 0, capabilities: capabilities) else { continue }
                failed += 1
                if !messages.contains(message) { messages.append(message) }
            }
            guard self.scope == scope, enqueueOwner == owner, !messages.isEmpty else { return }
            if failed > 1 { messages.append("\(failed) episodes were not added.") }
            error = messages.joined(separator: "\n")
        } catch {
            if self.scope == scope, enqueueOwner == owner { self.error = error.localizedDescription }
        }
    }

    /// Queues one title; returns why it was refused, or nil when queued or when the sign-in changed meanwhile.
    private func add(item: PlexMetadata, quality: DownloadQuality, choice: String? = nil, mediaIndex: Int, capabilities: DeviceCapabilities) async -> String? {
        guard let library, let scope, !removing.contains(item.ratingKey), !records.contains(where: { $0.ratingKey == item.ratingKey }) else { return nil }
        let owner = enqueueOwner
        do {
            let snapshot = try await library.metadataSnapshot(item.ratingKey)
            guard self.scope == scope, enqueueOwner == owner, snapshot.item.media.indices.contains(mediaIndex) else { return nil }
            let media = snapshot.item.media[mediaIndex]
            guard !media.parts.isEmpty else { throw DownloadFailure.message("No media file is available.") }
            if quality != .original {
                await prepareChoices(for: snapshot.item)
                guard self.scope == scope, enqueueOwner == owner else { return nil }
            }
            // A tier above the original's bitrate comes to Original or to the tier above it.
            let choices = plan(for: snapshot.item, mediaIndex: mediaIndex, capabilities: capabilities)
            let option = choices?.options.first { $0.id == choice } ?? choices?.option(for: quality)
            let chosen = option?.quality ?? .original
            guard chosen != .original || media.parts.count == 1 else { throw DownloadFailure.message("Original downloads with multiple parts are not supported. Choose a converted quality.") }
            // Offline there is no server to re-encode, so the phone has to play the original itself.
            if chosen == .original, let reason = DownloadPlayability.refusal(media: media, part: media.parts[0], capabilities: capabilities) {
                throw DownloadFailure.message(reason)
            }
            var record = DownloadRecord(
                item: snapshot.item, scope: scope, quality: chosen, target: option?.target, mediaIndex: mediaIndex, addedAt: .now,
                expectedLength: option?.bytes
            )
            let poster: Data?
            if let thumb = record.thumb { poster = try? await PlexFetch.data(thumb, library: library, session: metadataSession) }
            else { poster = nil }
            let still: Data?
            if let path = DownloadRecord.stillPath(of: snapshot.item) { still = await fetchStill(path, library: library) }
            else { still = nil }
            guard self.scope == scope, enqueueOwner == owner else { return nil }
            var subtitles: [(DownloadRecord.Subtitle, Data)] = []
            for stream in media.parts.flatMap(\.streams) where stream.kind == .subtitle {
                guard let key = stream.key else { continue }
                let data = try? await PlexFetch.data(key, library: library, session: metadataSession)
                guard self.scope == scope, enqueueOwner == owner else { return nil }
                guard let data else { continue }
                let ext = (stream.format ?? stream.codec ?? "srt").filter { $0.isLetter || $0.isNumber }
                subtitles.append((DownloadRecord.Subtitle(streamID: stream.id, fileName: "subtitle-\(stream.id).\(ext)"), data))
            }
            guard self.scope == scope, enqueueOwner == owner, !removing.contains(item.ratingKey), !records.contains(where: { $0.ratingKey == item.ratingKey }) else { return nil }
            try store.makeFolder(for: record)
            try snapshot.data.write(to: store.metadataFile(for: record), options: .atomic)
            if let poster { try? poster.write(to: store.posterFile(for: record), options: .atomic) }
            if let still { try? still.write(to: store.stillFile(for: record), options: .atomic) }
            for (subtitle, data) in subtitles {
                try data.write(to: store.subtitleFile(for: record, subtitle), options: .atomic)
                record.subtitles.append(subtitle)
            }
            allRecords.append(record)
            persist()
            kick()
            return nil
        } catch {
            return self.scope == scope && enqueueOwner == owner ? error.localizedDescription : nil
        }
    }

    func pause(_ id: String) {
        guard let index = index(id), allRecords[index].phase.isActive else { return }
        let part = relativePart(for: allRecords[index])
        allRecords[index].phase = .paused
        persist()
        worker?.cancel()
        if let part { Task { await background.cancel(part: part) } }
        stopSession(of: allRecords[index])
    }

    func resume(_ id: String) {
        guard let index = index(id), allRecords[index].phase != .done else { return }
        allRecords[index].phase = .waiting
        persist()
        wake()
    }

    func remove(_ id: String) {
        guard let index = index(id) else { return }
        if transferRecordID == id { transferOwner = UUID() }
        let record = allRecords.remove(at: index)
        clearRetry(id)
        removing.insert(id)
        worker?.cancel()
        persist()
        do { try store.remove(record) } catch { self.error = error.localizedDescription }
        stopSession(of: record)
        let part = relativePart(for: record)
        Task {
            if let part { await background.cancel(part: part) }
            removing.remove(id)
            if let library, record.scope == scope, let conversion = record.conversion {
                try? await library.removeFromDownloadQueue(conversion.queue, item: conversion.item)
            }
            kick()
        }
    }

    func updateWatch(id: String, position: Int, duration: Int) {
        guard let index = index(id) else { return }
        // Position standing still means paused or stopped: the moment worth keeping on disk.
        var urgent = lastWatchPosition[id] == position
        lastWatchPosition[id] = position
        if duration > 0 && Double(position) / Double(duration) >= 0.9 {
            if !allRecords[index].watch.finishedUnsynced {
                allRecords[index].watch.finished(at: .now, told: false)
                urgent = true
            }
        } else {
            allRecords[index].watch.played(to: max(0, position), at: .now)
        }
        watchDirty = true
        if urgent || Date.now.timeIntervalSince(lastPersist) >= Self.watchSaveInterval { persist() }
    }

    func setPlaybackActive(_ active: Bool) {
        playbackCount = max(0, playbackCount + (active ? 1 : -1))
        if playbackCount > 0 { keepAlive.stop(restoringCategory: true) }
        else if UIApplication.shared.applicationState == .background { enteredBackground() }
        if playbackCount == 0 {
            lastWatchPosition = [:]
            flushWatch()
            syncWatch()
        }
    }

    private func flushWatch() {
        if watchDirty { persist() }
    }

    func eraseAll() {
        transferOwner = UUID()
        enqueueOwner = UUID()
        worker?.cancel()
        keepAlive.stop()
        let old = allRecords
        allRecords = []
        retries = [:]
        holds = [:]
        lastWatchPosition = [:]
        do { try store.eraseAll() } catch { self.error = error.localizedDescription }
        // Sign-out has dropped the current library by now, so the ones used since launch answer for
        // their servers' queues.
        let known = libraries
        libraries = [:]
        Task {
            for record in old {
                if let part = relativePart(for: record) { await background.cancel(part: part) }
                if let session = record.stream?.session, record.phase != .done, let library = known[record.scope.server] {
                    try? await library.stopTranscode(session: session)
                }
                // Best effort: an unreachable server keeps its converted file until it expires.
                if let conversion = record.conversion, let library = known[record.scope.server] {
                    try? await library.removeFromDownloadQueue(conversion.queue, item: conversion.item)
                }
            }
        }
    }

    private func index(_ id: String) -> Int? { allRecords.firstIndex { $0.scope == scope && $0.id == id } }
    private func transferIndex(_ id: String, scope: DownloadScope, owner: UUID) -> Int? {
        guard self.scope == scope, transferOwner == owner else { return nil }
        return allRecords.firstIndex { $0.scope == scope && $0.id == id }
    }
    private func persist() {
        watchDirty = false
        lastPersist = .now
        do { try store.saveIndex(allRecords) } catch { self.error = error.localizedDescription }
    }

    /// The title's still at the size the lists draw it, for showing offline; nil when the server has none or does not answer.
    private func fetchStill(_ path: String, library: PlexLibrary) async -> Data? {
        guard let url = try? await library.imageURL(path, width: 640, height: 360, scale: 1) else { return nil }
        var request = URLRequest(url: url)
        for (name, value) in library.authorizationHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await metadataSession.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    /// What an older download lacks for the Downloads screen: the picture's size and the still.
    private struct Missing: Sendable {
        let id: String
        var frame: DownloadRecord.Frame?
        var stillPath: String?
    }

    /// Downloads saved before the screen drew stills have neither: the size is read from each saved
    /// description, the still is fetched again. Retried when the network returns, as a first launch
    /// may be offline.
    private func backfill() {
        guard backfillTask == nil, let library, let scope else { return }
        let store = store
        let candidates = records
        backfillTask = Task { [weak self] in
            let missing = await Self.survey(candidates, in: store)
            guard let self else { return }
            defer { self.backfillTask = nil }
            guard self.scope == scope else { return }
            var sized = false
            for found in missing {
                guard let frame = found.frame, let i = self.index(found.id), self.allRecords[i].frame == nil else { continue }
                self.allRecords[i].frame = frame
                sized = true
            }
            if sized { self.persist() }
            for found in missing {
                guard let path = found.stillPath, let data = await self.fetchStill(path, library: library) else { continue }
                guard self.scope == scope, let i = self.index(found.id) else { continue }
                try? data.write(to: self.store.stillFile(for: self.allRecords[i]), options: .atomic)
                self.artVersion += 1
            }
        }
    }

    @concurrent private static func survey(_ records: [DownloadRecord], in store: DownloadStore) async -> [Missing] {
        records.compactMap { record in
            var found = Missing(id: record.id)
            if record.frame == nil { found.frame = store.savedFrame(for: record) }
            if !FileManager.default.fileExists(atPath: store.stillFile(for: record).path(percentEncoded: false)) {
                found.stillPath = store.savedStillPath(for: record)
            }
            return found.frame == nil && found.stillPath == nil ? nil : found
        }
    }

    func syncWatch() {
        guard syncTask == nil, let library, let scope else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            recordsLoop: for record in self.records where record.watch.unsynced != nil {
                do {
                    let item = try await library.metadata(record.id)
                    guard self.scope == scope, let i = self.index(record.id), self.allRecords[i].watch == record.watch else { continue }
                    for action in record.watch.sync(serverLastViewed: item.lastViewedAt) {
                        switch action {
                        case .watched:
                            try await library.markWatched(record.id)
                            guard self.scope == scope, let i = self.index(record.id), self.allRecords[i].watch.unsynced == record.watch.unsynced else { continue recordsLoop }
                            self.allRecords[i].watch.finishedUnsynced = false
                            self.persist()
                        case .resume(let offset):
                            try await library.reportTimeline(TimelineUpdate(item: item, state: .stopped, time: offset, duration: record.duration))
                        }
                    }
                    guard self.scope == scope, let current = self.index(record.id), self.allRecords[current].watch.unsynced == record.watch.unsynced else { continue }
                    self.allRecords[current].watch.synced()
                    self.persist()
                    if self.playbackCount == 0 && self.allRecords[current].isSpent(autoDeleteWatched: self.settings.autoDeleteWatched, playing: nil) { self.remove(record.id) }
                } catch { continue }
            }
            self.syncTask = nil
            if self.scope != scope { self.syncWatch() }
        }
    }
    private func kick() {
        guard worker == nil, library != nil, scope != nil, records.contains(where: { $0.phase.isActive }) else { return }
        worker = Task { [weak self] in
            let progressed = await self?.run() ?? false
            guard let self else { return }
            self.worker = nil
            if progressed || Task.isCancelled { self.kick() }
        }
    }

    private func run() async -> Bool {
        guard let library, let scope else { return false }
        // A request kept to Wi-Fi fails at once on cellular; iOS holds a background slice until Wi-Fi joins.
        if waitingForWiFi && !(backgroundHandoff && background.isAvailable) { return false }
        let owner = transferOwner
        let running = await background.running()
        guard !Task.isCancelled, self.scope == scope, transferOwner == owner else { return false }
        guard let record = records.first(where: { record in record.phase.isActive && !running.contains(where: { $0.part == relativePart(for: record) }) }) else { return false }
        transferRecordID = record.id
        defer { if transferOwner == owner { transferRecordID = nil } }
        if let until = holds[record.id], until > .now, !(backgroundHandoff && background.isAvailable) {
            backingOff = true
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            backingOff = false
            guard !Task.isCancelled, transferOwner == owner else { return false }
        }
        do { try await transfer(record.id, library: library, scope: scope, owner: owner) }
        catch is CancellationError { }
        catch {
            if !Task.isCancelled, let i = transferIndex(record.id, scope: scope, owner: owner), allRecords[i].phase.isActive {
                if TransferPlan.isTransient(error) {
                    scheduleRetry(at: i)
                } else {
                    allRecords[i].phase = .failed(error.localizedDescription)
                }
                persist()
            }
        }
        return true
    }

    /// Back to waiting with the next try after the backoff, instead of failing on a dropped connection.
    private func scheduleRetry(at i: Int) {
        let id = allRecords[i].id
        let attempt = (retries[id] ?? 0) + 1
        retries[id] = attempt
        holds[id] = Date.now.addingTimeInterval(TimeInterval(TransferPlan.retryDelay(attempt: attempt)))
        allRecords[i].phase = .waiting
        if attempt >= 2 { stalled.insert(id) }
    }

    private func clearRetry(_ id: String) {
        retries[id] = nil
        holds[id] = nil
        stalled.remove(id)
    }

    /// Ends every backoff now: the network came back or the user asked for another try.
    private func wake() {
        retries = [:]
        holds = [:]
        stalled = []
        if backingOff { worker?.cancel() }
        kick()
    }

    private func transfer(_ id: String, library: PlexLibrary, scope: DownloadScope, owner: UUID) async throws {
        guard var i = transferIndex(id, scope: scope, owner: owner), allRecords[i].phase.isActive else { return }
        var record = allRecords[i]
        let item = try PlexMetadata.fromSnapshot(Data(contentsOf: store.metadataFile(for: record)))
        guard item.media.indices.contains(record.mediaIndex), let part = item.media[record.mediaIndex].parts.first else { throw DownloadFailure.message("The saved media description is missing.") }
        var url: URL
        if record.quality != .original {
            if record.conversion == nil, record.streamFailed != true, try await stream(id, item: item, library: library, scope: scope, owner: owner) {
                return
            }
            if record.conversion == nil {
                guard let target = Self.target(of: record, media: item.media[record.mediaIndex]) else { throw DownloadFailure.message("The saved media description is missing.") }
                let queue = try await library.downloadQueue()
                try Task.checkCancellation()
                guard let queuedIndex = transferIndex(id, scope: scope, owner: owner), allRecords[queuedIndex].phase.isActive else { return }
                let queueItem = try await library.addToDownloadQueue(queue, ratingKey: id, mediaIndex: record.mediaIndex, target: target)
                try Task.checkCancellation()
                guard let current = transferIndex(id, scope: scope, owner: owner), allRecords[current].phase.isActive else { return }
                allRecords[current].conversion = .init(queue: queue, item: queueItem, target: target)
                allRecords[current].phase = .converting
                persist()
            }
            guard let conversionIndex = transferIndex(id, scope: scope, owner: owner), allRecords[conversionIndex].phase.isActive, let conversion = allRecords[conversionIndex].conversion else { return }
            while true {
                try Task.checkCancellation()
                let state = try await library.downloadQueueItem(conversion.queue, item: conversion.item)
                guard let current = transferIndex(id, scope: scope, owner: owner), allRecords[current].phase.isActive, !Task.isCancelled else { return }
                allRecords[current].conversion?.status = state.status
                allRecords[current].conversion?.progress = state.progress
                allRecords[current].conversion?.speed = state.speed
                persist()
                if state.status == .available { break }
                if state.status == .expired { try await library.restartDownloadQueueItem(conversion.queue, item: conversion.item) }
                if state.status == .error { throw DownloadFailure.message(state.error ?? "The server could not convert this title.") }
                try await Task.sleep(for: .seconds(5))
            }
            try Task.checkCancellation()
            guard let decisionIndex = transferIndex(id, scope: scope, owner: owner), allRecords[decisionIndex].phase.isActive else { return }
            let decision = try await library.downloadDecision(conversion.queue, item: conversion.item)
            try Task.checkCancellation()
            guard let writeIndex = transferIndex(id, scope: scope, owner: owner), allRecords[writeIndex].phase.isActive else { return }
            try decision.data.write(to: store.decisionFile(for: allRecords[writeIndex]), options: .atomic)
            url = try await library.downloadURL(queue: conversion.queue, item: conversion.item)
        } else {
            url = try await library.downloadURL(part: part)
        }
        while !Task.isCancelled {
            guard let current = transferIndex(id, scope: scope, owner: owner), allRecords[current].phase.isActive else { return }
            i = current
            record = allRecords[i]
            if let length = record.length, record.received.isComplete(length: length) {
                try finish(id: id, ext: record.quality == .original ? part.container ?? "mkv" : "mp4")
                return
            }
            let length = record.length ?? Int64.max / 2
            let slicePart = backgroundHandoff && background.isAvailable ? relativePart(for: record) : nil
            let size = slicePart == nil ? TransferPlan.foregroundChunk : TransferPlan.backgroundSlice
            guard let range = record.received.next(length: length, size: size) else { return }
            allRecords[i].phase = .downloading
            persist()
            let file = store.partialFile(for: record)
            if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else { throw DownloadFailure.message("Could not create the download file.") }
            }
            if let slicePart {
                // iOS starts the slice after the backoff, so a retry still happens while the app is suspended.
                let delay = max(0, holds[id]?.timeIntervalSinceNow ?? 0)
                background.start(.init(id: id, part: slicePart, lower: range.lowerBound, upper: range.upperBound), url: url, headers: library.authorizationHeaders(), cellular: settings.cellular, after: delay)
                return
            }
            let outcome = await fetcher.fetch(url, headers: library.authorizationHeaders(), range: range, into: file, id: id, cellular: settings.cellular)
            // The next try probes for an address that answers, e.g. away from home after the home one.
            if let error = outcome.error, TransferPlan.dropsAddress(error) { await library.connection.reportFailure(at: url) }
            guard let outcomeIndex = transferIndex(id, scope: scope, owner: owner) else { return }
            if case .whole = outcome.reply { allRecords[outcomeIndex].received = ByteSpans() }
            allRecords[outcomeIndex].received.insert(outcome.written)
            meter.commit(Int64(outcome.written.count), for: id)
            if !outcome.written.isEmpty { clearRetry(id) }
            switch outcome.reply {
            case .partial(let length): allRecords[outcomeIndex].length = length
            case .whole(let length): allRecords[outcomeIndex].length = length ?? (outcome.error == nil ? outcome.written.upperBound : nil)
            case .notReady(let delay): persist(); try await Task.sleep(for: .seconds(delay)); continue
            case .failed(let status): throw TransferStatusError(status: status)
            case nil: break
            }
            persist()
            try Task.checkCancellation()
            if let error = outcome.error { throw error }
            if outcome.written.isEmpty { throw DownloadFailure.message("The server returned no media bytes.") }
        }
    }

    private func finish(id: String, ext: String) throws {
        guard let i = index(id) else { return }
        let record = allRecords[i]
        let name = "media.\(ext.filter { $0.isLetter || $0.isNumber })"
        let destination = store.folder(for: record).appending(path: name)
        try FileManager.default.moveItem(at: store.partialFile(for: record), to: destination)
        allRecords[i].fileName = name
        if let stream = record.stream { allRecords[i].length = stream.bytes }
        allRecords[i].phase = .done
        allRecords[i].finishedAt = .now
        persist()
    }

    /// What a conversion asks for; a waiting download saved by an older version has only its tier.
    private static func target(of record: DownloadRecord, media: PlexMedia) -> DownloadTarget? {
        if let target = record.target { return target }
        guard record.quality != .original else { return nil }
        return DownloadQualityPlan(media: media, animated: false, hevc: false, originalPlays: false, map: nil).option(for: record.quality)?.target
    }

    /// A transcode session's segments and the playlist they are relative to.
    private struct StreamSession {
        var playlist: URL
        var segments: [HLSPlaylist.Segment]
    }

    /// The server converts the title while the phone saves its segments (`StreamedFile`), so the
    /// download starts at once. Each run, and each session the server dropped, starts a new session
    /// where the saved segments end. Returns false when the server will not stream the conversion,
    /// for the download queue to make it.
    private func stream(_ id: String, item: PlexMetadata, library: PlexLibrary, scope: DownloadScope, owner: UUID) async throws -> Bool {
        guard let i = transferIndex(id, scope: scope, owner: owner), allRecords[i].phase.isActive else { return true }
        let record = allRecords[i]
        let media = item.media[record.mediaIndex]
        // A transcode session plays one part.
        guard media.parts.count == 1, var target = Self.target(of: record, media: media) else { return refuseStream(id, library: library) }
        let file = store.partialFile(for: record)
        var stream = record.stream ?? DownloadRecord.Stream(session: UUID().uuidString)
        try StreamedFile.prepare(file, stream: &stream)
        let absorbed = try StreamedFile.absorb(into: file, stream: &stream)
        allRecords[i].stream = stream
        allRecords[i].phase = .downloading
        persist()
        // Pieces left after a gap belong to a session that ends now.
        for piece in absorbed + StreamedFile.pieces(of: file).map(\.url) { try? FileManager.default.removeItem(at: piece) }
        if stream.isComplete {
            try finishStream(id, session: stream.session, library: library)
            return true
        }
        // The first session asks decisions for the cap whose output comes closest to the target's
        // bitrate; the last decision describes the file offline.
        if !FileManager.default.fileExists(atPath: store.decisionFile(for: record).path(percentEncoded: false)) {
            var decisions: [Int: PlexMetadataSnapshot] = [:]
            let found: (cap: Int, answer: TranscodeLadder.Answer)
            do {
                found = try await TranscodeLadder.search(for: target) { cap in
                    var asked = target
                    asked.maxVideoBitrateKbps = cap
                    let decision = try await library.transcodeDecision(TranscodeRequest(download: item, mediaIndex: record.mediaIndex, target: asked, session: stream.session))
                    decisions[cap] = decision
                    return Self.answer(decision) ?? TranscodeLadder.Answer(videoKbps: target.videoKbps, height: target.height)
                }
            } catch let error where !(error is CancellationError) && !TransferPlan.isTransient(error) {
                return refuseStream(id, library: library)
            }
            try Task.checkCancellation()
            target.maxVideoBitrateKbps = found.cap
            try decisions[found.cap]?.data.write(to: store.decisionFile(for: record), options: .atomic)
        }
        guard var session = try await startSession(&stream, item: item, mediaIndex: record.mediaIndex, target: target, library: library) else {
            return refuseStream(id, library: library)
        }
        // Saves the stream, and with it the session that pausing or removing stops; false once the
        // download is paused, removed or taken over by another run, and this session is ended.
        func kept() -> Bool {
            guard let current = transferIndex(id, scope: scope, owner: owner), allRecords[current].phase.isActive else {
                Task { [name = stream.session] in try? await library.stopTranscode(session: name) }
                return false
            }
            allRecords[current].target = target
            allRecords[current].stream = stream
            persist()
            return true
        }
        guard kept() else { return true }
        while let next = HLSPlaylist.next(after: stream.saved, in: session.segments) {
            if backgroundHandoff && background.isAvailable, let current = index(id), let part = relativePart(for: allRecords[current]) {
                handOff(session, from: next, pieces: stream.pieces, id: id, part: part, target: target, library: library)
                return true
            }
            let segment = session.segments[next]
            guard let url = URL(string: segment.uri, relativeTo: session.playlist)?.absoluteURL else { return refuseStream(id, library: library) }
            let (data, status) = try await streamData(url, library: library)
            try Task.checkCancellation()
            if status == 404 || ((200..<300).contains(status) && StreamedFile.isPlaceholder(data.count)) {
                // The server dropped the session, or the segment lies before where it began.
                stream.restarts += 1
                guard stream.restarts <= Self.sessionRestarts,
                      let again = try await startSession(&stream, item: item, mediaIndex: record.mediaIndex, target: target, library: library) else {
                    return refuseStream(id, library: library)
                }
                session = again
            } else {
                guard (200..<300).contains(status) else { throw TransferStatusError(status: status) }
                try StreamedFile.append(data, ending: segment.end, to: file, stream: &stream)
                meter.commit(Int64(data.count), for: id)
                clearRetry(id)
            }
            guard kept() else { return true }
        }
        try finishStream(id, session: stream.session, library: library)
        return true
    }

    /// Starts the server's transcode where the saved segments end, under a new session; nil when the
    /// server will not stream it.
    private func startSession(
        _ stream: inout DownloadRecord.Stream, item: PlexMetadata, mediaIndex: Int, target: DownloadTarget, library: PlexLibrary
    ) async throws -> StreamSession? {
        let old = stream.session
        Task { try? await library.stopTranscode(session: old) }
        stream.session = UUID().uuidString
        stream.joining = stream.pieces > 0
        let request = TranscodeRequest(download: item, mediaIndex: mediaIndex, target: target, offset: stream.saved, session: stream.session)
        let master: URL
        do {
            master = try await library.transcodeURL(request)
        } catch let error where !(error is CancellationError) && !TransferPlan.isTransient(error) {
            return nil
        }
        let (masterData, masterStatus) = try await streamData(master, library: library)
        try Self.throwIfTransient(masterStatus)
        guard (200..<300).contains(masterStatus), let variant = HLSPlaylist.variant(in: String(decoding: masterData, as: UTF8.self)),
              let playlist = URL(string: variant, relativeTo: master)?.absoluteURL else { return nil }
        let (data, status) = try await streamData(playlist, library: library)
        try Self.throwIfTransient(status)
        guard (200..<300).contains(status), let segments = HLSPlaylist.segments(in: String(decoding: data, as: UTF8.self)) else { return nil }
        stream.end = segments.last?.end
        return StreamSession(playlist: playlist, segments: segments)
    }

    /// A playlist or segment of a streamed conversion, kept to Wi-Fi like the rest of the download.
    private func streamData(_ url: URL, library: PlexLibrary) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        for (name, value) in library.authorizationHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        request.allowsCellularAccess = settings.cellular
        do {
            let (data, response) = try await metadataSession.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            // The next try probes for an address that answers, e.g. away from home after the home one.
            if TransferPlan.dropsAddress(error) { await library.connection.reportFailure(at: url) }
            throw error
        }
    }

    private static func throwIfTransient(_ status: Int) throws {
        let error = TransferStatusError(status: status)
        if TransferPlan.isTransient(error) { throw error }
    }

    /// What a decision says the server will make: the picture's size class and the video's bitrate.
    private static func answer(_ decision: PlexMetadataSnapshot) -> TranscodeLadder.Answer? {
        guard let media = decision.item.media.first, let height = PictureClass.of(media),
              let kbps = media.parts.first?.videoStream?.bitrate else { return nil }
        return TranscodeLadder.Answer(videoKbps: kbps, height: height)
    }

    /// Hands the next segments to iOS, which fetches them one at a time while the app is suspended.
    private func handOff(_ session: StreamSession, from next: Int, pieces: Int, id: String, part: String, target: DownloadTarget, library: PlexLibrary) {
        let headers = library.authorizationHeaders()
        for (offset, segment) in session.segments[next...].prefix(Self.handoffSegments).enumerated() {
            guard let url = URL(string: segment.uri, relativeTo: session.playlist)?.absoluteURL else { return }
            let size = max(1, target.bytes(duration: Int(segment.duration * 1000)))
            let slice = BackgroundTransfer.Slice(id: id, part: part, lower: 0, upper: size, segment: .init(number: pieces + offset, end: segment.end))
            background.start(slice, url: url, headers: headers, cellular: settings.cellular)
        }
    }

    /// Ends the server's transcode and keeps the saved segments as the download's `media.ts`.
    private func finishStream(_ id: String, session: String, library: PlexLibrary) throws {
        Task { try? await library.stopTranscode(session: session) }
        try finish(id: id, ext: "ts")
    }

    /// The server will not stream this conversion: what the stream saved is dropped, and the download
    /// queue makes the conversion instead. Returns false for `transfer` to go on to the queue.
    private func refuseStream(_ id: String, library: PlexLibrary) -> Bool {
        guard let i = index(id) else { return false }
        if let session = allRecords[i].stream?.session { Task { try? await library.stopTranscode(session: session) } }
        let file = store.partialFile(for: allRecords[i])
        for piece in StreamedFile.pieces(of: file) { try? FileManager.default.removeItem(at: piece.url) }
        try? FileManager.default.removeItem(at: file)
        allRecords[i].stream = nil
        allRecords[i].streamFailed = true
        persist()
        return false
    }

    /// Ends a paused or removed download's transcode on the server, best effort.
    private func stopSession(of record: DownloadRecord) {
        guard let session = record.stream?.session, record.phase != .done, let library = libraries[record.scope.server] else { return }
        Task { try? await library.stopTranscode(session: session) }
    }

    /// Appends the segments iOS saved while the app was away; the download is done once all are in.
    private func absorbPieces(at i: Int) {
        guard var stream = allRecords[i].stream else { return }
        let id = allRecords[i].id
        let file = store.partialFile(for: allRecords[i])
        let before = stream.bytes
        do {
            try StreamedFile.prepare(file, stream: &stream)
            let done = try StreamedFile.absorb(into: file, stream: &stream)
            allRecords[i].stream = stream
            persist()
            for piece in done { try? FileManager.default.removeItem(at: piece) }
            meter.commit(max(0, stream.bytes - before), for: id)
            if stream.isComplete, let library = libraries[allRecords[i].scope.server] {
                try finishStream(id, session: stream.session, library: library)
            }
        } catch {
            allRecords[i].phase = .failed(error.localizedDescription)
        }
    }

    private func receivedBackground(_ result: BackgroundTransfer.Result) async {
        let slice: BackgroundTransfer.Slice
        switch result {
        case .saved(let value, _, _), .notReady(let value, _), .interrupted(let value, _), .failed(let value, _), .expired(let value), .stopped(let value):
            slice = value
        }
        if case .interrupted(_, let dropped?) = result, let record = allRecords.first(where: { $0.id == slice.id }), let library = libraries[record.scope.server] {
            await library.connection.reportFailure(at: dropped)
        }
        guard let i = allRecords.firstIndex(where: { $0.id == slice.id && relativePart(for: $0) == slice.part && $0.phase.isActive }) else { return }
        let id = allRecords[i].id
        switch result {
        case .saved(_, let written, let length):
            if slice.segment != nil {
                absorbPieces(at: i)
            } else {
                allRecords[i].received.insert(written)
                if let length { allRecords[i].length = length }
            }
            clearRetry(id)
        case .notReady(_, let delay):
            holds[id] = Date.now.addingTimeInterval(TimeInterval(delay))
        case .interrupted:
            scheduleRetry(at: i)
        case .failed(_, let message):
            allRecords[i].phase = .failed(message)
        case .expired, .stopped: break
        }
        persist()
        // The segments handed over after an expired one would fail too; the next run starts a new session.
        if case .expired = result { await background.cancel(part: slice.part) }
        kick()
    }

    /// The part file's path below Application Support, which is what a background slice carries: the
    /// app container's path can change between launches.
    private func relativePart(for record: DownloadRecord) -> String? {
        DownloadStore.relativePart(of: store.partialFile(for: record), under: BackgroundTransfer.supportDirectory)
    }

    private func enteredBackground() {
        flushWatch()
        guard activeCount > 0 else { return }
        if settings.keepAlive && playbackCount == 0 {
            keepAlive.start { [weak self] in self?.activeCount ?? 0 > 0 }
        } else { handoff() }
    }

    private func handoff() {
        backgroundHandoff = true
        worker?.cancel()
        kick()
    }

    private func foreground() {
        backgroundHandoff = false
        keepAlive.stop(restoringCategory: playbackCount > 0)
        // A slice iOS has not begun may wait for Wi-Fi or for an address that stopped answering; the app
        // fetches it now.
        Task { [background] in await background.cancelUnstarted() }
        kick()
    }

    private enum DownloadFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
