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

@MainActor @Observable
final class DownloadCenter {
    let store: DownloadStore
    var settings: DownloadSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
            if !settings.keepAlive { keepAlive.stop() }
        }
    }
    var error: String?
    var records: [DownloadRecord] { allRecords.filter { $0.scope == scope } }
    var activeCount: Int { records.filter { $0.phase.isActive }.count }

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
    @ObservationIgnored private var transferRecordID: String?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var backgroundObserver: (any NSObjectProtocol)?
    private var playbackCount = 0
    private var removing: Set<String> = []
    private var backgroundHandoff = false
    @ObservationIgnored private lazy var fetcher = RangeFetcher(meter: meter)
    @ObservationIgnored private lazy var background = BackgroundTransfer { [weak self] result in
        await self?.receivedBackground(result)
    }

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
        allRecords = store.loadIndex()
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(DownloadSettings.self, from: $0) } ?? DownloadSettings()
        keepAlive.onSurrender = { [weak self] in self?.handoff() }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foreground() }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enteredBackground() }
        }
        _ = background
    }

    func connect(library: PlexLibrary?, scope: DownloadScope?) {
        transferOwner = UUID()
        enqueueOwner = UUID()
        worker?.cancel()
        keepAlive.stop()
        self.library = library
        self.scope = scope
        kick()
        syncWatch()
    }

    func enqueue(item: PlexMetadata, quality: DownloadQuality, mediaIndex: Int) async {
        guard let library, let scope, !removing.contains(item.ratingKey), !records.contains(where: { $0.ratingKey == item.ratingKey }) else { return }
        let owner = enqueueOwner
        do {
            let snapshot = try await library.metadataSnapshot(item.ratingKey)
            guard self.scope == scope, enqueueOwner == owner, snapshot.item.media.indices.contains(mediaIndex) else { return }
            let media = snapshot.item.media[mediaIndex]
            guard !media.parts.isEmpty else { throw DownloadFailure.message("No media file is available.") }
            guard quality != .original || media.parts.count == 1 else { throw DownloadFailure.message("Original downloads with multiple parts are not supported. Choose a converted quality.") }
            let target: DownloadTarget?
            if case .converted(let preset) = quality { target = PresetTarget.target(for: preset, media: media) } else { target = nil }
            var record = DownloadRecord(item: snapshot.item, scope: scope, quality: quality, mediaIndex: mediaIndex, addedAt: .now, expectedLength: quality.estimatedBytes(media: media, target: target))
            let poster: Data?
            if let thumb = record.thumb { poster = try? await PlexFetch.data(thumb, library: library, session: .shared) }
            else { poster = nil }
            guard self.scope == scope, enqueueOwner == owner else { return }
            var subtitles: [(DownloadRecord.Subtitle, Data)] = []
            for stream in media.parts.flatMap(\.streams) where stream.kind == .subtitle {
                guard let key = stream.key else { continue }
                let data = try? await PlexFetch.data(key, library: library, session: .shared)
                guard self.scope == scope, enqueueOwner == owner else { return }
                guard let data else { continue }
                let ext = (stream.format ?? stream.codec ?? "srt").filter { $0.isLetter || $0.isNumber }
                subtitles.append((DownloadRecord.Subtitle(streamID: stream.id, fileName: "subtitle-\(stream.id).\(ext)"), data))
            }
            guard self.scope == scope, enqueueOwner == owner, !removing.contains(item.ratingKey), !records.contains(where: { $0.ratingKey == item.ratingKey }) else { return }
            try store.makeFolder(for: record)
            try snapshot.data.write(to: store.metadataFile(for: record), options: .atomic)
            if let poster { try? poster.write(to: store.posterFile(for: record), options: .atomic) }
            for (subtitle, data) in subtitles {
                try data.write(to: store.subtitleFile(for: record, subtitle), options: .atomic)
                record.subtitles.append(subtitle)
            }
            allRecords.append(record)
            persist()
            kick()
        } catch {
            if self.scope == scope, enqueueOwner == owner { self.error = error.localizedDescription }
        }
    }

    func pause(_ id: String) {
        guard let index = index(id), allRecords[index].phase.isActive else { return }
        let part = relativePart(for: allRecords[index])
        allRecords[index].phase = .paused
        persist()
        worker?.cancel()
        Task { await background.cancel(part: part) }
    }

    func resume(_ id: String) {
        guard let index = index(id), allRecords[index].phase != .done else { return }
        allRecords[index].phase = .waiting
        persist()
        kick()
    }

    func remove(_ id: String) {
        guard let index = index(id) else { return }
        if transferRecordID == id { transferOwner = UUID() }
        let record = allRecords.remove(at: index)
        removing.insert(id)
        worker?.cancel()
        persist()
        do { try store.remove(record) } catch { self.error = error.localizedDescription }
        Task {
            await background.cancel(part: relativePart(for: record))
            removing.remove(id)
            if let library, record.scope == scope, let conversion = record.conversion {
                try? await library.removeFromDownloadQueue(conversion.queue, item: conversion.item)
            }
            kick()
        }
    }

    func updateWatch(id: String, position: Int, duration: Int) {
        guard let index = index(id) else { return }
        if duration > 0 && Double(position) / Double(duration) >= 0.9 {
            if !allRecords[index].watch.finishedUnsynced { allRecords[index].watch.finished(at: .now, told: false) }
        } else {
            allRecords[index].watch.played(to: max(0, position), at: .now)
        }
        persist()
    }

    func setPlaybackActive(_ active: Bool) {
        playbackCount = max(0, playbackCount + (active ? 1 : -1))
        if playbackCount > 0 { keepAlive.stop(restoringCategory: true) }
        else if UIApplication.shared.applicationState == .background { enteredBackground() }
        if playbackCount == 0 { syncWatch() }
    }

    func eraseAll() {
        transferOwner = UUID()
        enqueueOwner = UUID()
        worker?.cancel()
        keepAlive.stop()
        let old = allRecords
        allRecords = []
        do { try store.eraseAll() } catch { self.error = error.localizedDescription }
        Task {
            for record in old { await background.cancel(part: relativePart(for: record)) }
        }
    }

    private func index(_ id: String) -> Int? { allRecords.firstIndex { $0.scope == scope && $0.id == id } }
    private func transferIndex(_ id: String, scope: DownloadScope, owner: UUID) -> Int? {
        guard self.scope == scope, transferOwner == owner else { return nil }
        return allRecords.firstIndex { $0.scope == scope && $0.id == id }
    }
    private func persist() {
        do { try store.saveIndex(allRecords) } catch { self.error = error.localizedDescription }
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
        let owner = transferOwner
        let running = await background.running()
        guard !Task.isCancelled, self.scope == scope, transferOwner == owner else { return false }
        guard let record = records.first(where: { record in record.phase.isActive && !running.contains(where: { $0.part == relativePart(for: record) }) }) else { return false }
        transferRecordID = record.id
        defer { if transferOwner == owner { transferRecordID = nil } }
        do { try await transfer(record.id, library: library, scope: scope, owner: owner) }
        catch is CancellationError { }
        catch {
            if !Task.isCancelled, let i = transferIndex(record.id, scope: scope, owner: owner), allRecords[i].phase.isActive {
                allRecords[i].phase = .failed(error.localizedDescription)
                persist()
            }
        }
        return true
    }

    private func transfer(_ id: String, library: PlexLibrary, scope: DownloadScope, owner: UUID) async throws {
        guard var i = transferIndex(id, scope: scope, owner: owner), allRecords[i].phase.isActive else { return }
        var record = allRecords[i]
        let item = try PlexMetadata.fromSnapshot(Data(contentsOf: store.metadataFile(for: record)))
        guard item.media.indices.contains(record.mediaIndex), let part = item.media[record.mediaIndex].parts.first else { throw DownloadFailure.message("The saved media description is missing.") }
        var url: URL
        if case .converted(let preset) = record.quality {
            if record.conversion == nil {
                let target = PresetTarget.target(for: preset, media: item.media[record.mediaIndex])
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
                try finish(id: id, part: part)
                return
            }
            let length = record.length ?? Int64.max / 2
            let size = backgroundHandoff && background.isAvailable ? TransferPlan.backgroundSlice : TransferPlan.foregroundChunk
            guard let range = record.received.next(length: length, size: size) else { return }
            allRecords[i].phase = .downloading
            persist()
            let file = store.partialFile(for: record)
            if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else { throw DownloadFailure.message("Could not create the download file.") }
            }
            if backgroundHandoff && background.isAvailable {
                background.start(.init(id: id, part: relativePart(for: record), lower: range.lowerBound, upper: range.upperBound), url: url, headers: library.authorizationHeaders(), cellular: settings.cellular)
                return
            }
            let outcome = await fetcher.fetch(url, headers: library.authorizationHeaders(), range: range, into: file, id: id, cellular: settings.cellular)
            guard let outcomeIndex = transferIndex(id, scope: scope, owner: owner) else { return }
            if case .whole = outcome.reply { allRecords[outcomeIndex].received = ByteSpans() }
            allRecords[outcomeIndex].received.insert(outcome.written)
            meter.commit(Int64(outcome.written.count), for: id)
            switch outcome.reply {
            case .partial(let length): allRecords[outcomeIndex].length = length
            case .whole(let length): allRecords[outcomeIndex].length = length ?? (outcome.error == nil ? outcome.written.upperBound : nil)
            case .notReady(let delay): persist(); try await Task.sleep(for: .seconds(delay)); continue
            case .failed(let status): throw DownloadFailure.message("The server answered \(status).")
            case nil: break
            }
            persist()
            try Task.checkCancellation()
            if let error = outcome.error { throw error }
            if outcome.written.isEmpty { throw DownloadFailure.message("The server returned no media bytes.") }
        }
    }

    private func finish(id: String, part: PlexPart) throws {
        guard let i = index(id) else { return }
        let record = allRecords[i]
        let ext = (record.quality == .original ? (part.container ?? "mkv") : "mp4").filter { $0.isLetter || $0.isNumber }
        let name = "media.\(ext)"
        let destination = store.folder(for: record).appending(path: name)
        try FileManager.default.moveItem(at: store.partialFile(for: record), to: destination)
        allRecords[i].fileName = name
        allRecords[i].phase = .done
        allRecords[i].finishedAt = .now
        persist()
    }

    private func receivedBackground(_ result: BackgroundTransfer.Result) async {
        let slice: BackgroundTransfer.Slice
        switch result {
        case .saved(let value, _, _), .notReady(let value), .failed(let value, _), .stopped(let value): slice = value
        }
        guard let i = allRecords.firstIndex(where: { $0.id == slice.id && relativePart(for: $0) == slice.part && $0.phase.isActive }) else { return }
        switch result {
        case .saved(_, let written, let length):
            allRecords[i].received.insert(written)
            if let length { allRecords[i].length = length }
        case .failed(_, let message):
            if allRecords[i].phase.isActive { allRecords[i].phase = .failed(message) }
        case .notReady, .stopped: break
        }
        persist()
        kick()
    }

    private func relativePart(for record: DownloadRecord) -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path(percentEncoded: false)
        let path = store.partialFile(for: record).path(percentEncoded: false)
        return String(path.dropFirst(support.count + 1))
    }

    private func enteredBackground() {
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
        kick()
    }

    private enum DownloadFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
