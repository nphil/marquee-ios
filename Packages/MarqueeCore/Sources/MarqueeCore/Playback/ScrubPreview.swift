import Foundation

/// The player's own scrub previews, for a title Plex has no BIF index for (DESIGN §8.6): one frame every
/// `interval` seconds, made from the file the phone is playing. Slots are numbered from the start of the title.
public enum ScrubPreviewPlan {
    public static let interval: TimeInterval = 10
    /// The longest side of a made frame, in pixels.
    public static let width = 240

    /// The slots a title of `duration` seconds holds; none for an unknown length.
    public static func slotCount(duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int((duration / interval).rounded(.down)) + 1
    }

    /// The slot nearest `time`, within the title.
    public static func slot(at time: TimeInterval, duration: TimeInterval) -> Int {
        let last = max(0, slotCount(duration: duration) - 1)
        guard time.isFinite else { return 0 }
        return min(last, max(0, Int((time / interval).rounded())))
    }

    /// Where a slot's frame is taken, kept inside the title.
    public static func time(of slot: Int, duration: TimeInterval) -> TimeInterval {
        min(TimeInterval(slot) * interval, max(0, duration - 1))
    }

    /// Every slot, nearest the playhead first and alternating ahead and behind: the order the background
    /// fill works in.
    public static func fillOrder(playhead: TimeInterval, duration: TimeInterval) -> [Int] {
        let count = slotCount(duration: duration)
        guard count > 0 else { return [] }
        let start = slot(at: playhead, duration: duration)
        var order = [start]
        order.reserveCapacity(count)
        var distance = 1
        while order.count < count {
            if start + distance < count { order.append(start + distance) }
            if start - distance >= 0 { order.append(start - distance) }
            distance += 1
        }
        return order
    }
}

/// When the background fill may run. A file already on the phone costs no data; a stream is read only on
/// unmetered Wi-Fi without Low Data Mode, and never while playback waits or the phone runs hot.
public struct ScrubPreviewFillPolicy: Sendable, Equatable {
    public var isLocalFile: Bool
    /// Wi-Fi or Ethernet, not a hotspot or cellular.
    public var isUnmeteredWiFi: Bool
    /// Low Data Mode, the system's Save Data.
    public var saveData: Bool
    public var isPlaying: Bool
    public var isStalled: Bool
    public var isThermalSerious: Bool

    public init(
        isLocalFile: Bool = false, isUnmeteredWiFi: Bool = false, saveData: Bool = false,
        isPlaying: Bool = false, isStalled: Bool = false, isThermalSerious: Bool = false
    ) {
        self.isLocalFile = isLocalFile
        self.isUnmeteredWiFi = isUnmeteredWiFi
        self.saveData = saveData
        self.isPlaying = isPlaying
        self.isStalled = isStalled
        self.isThermalSerious = isThermalSerious
    }

    public var allows: Bool {
        guard isPlaying, !isStalled, !isThermalSerious else { return false }
        return isLocalFile || (isUnmeteredWiFi && !saveData)
    }
}

/// Paces the frames made while a finger drags: the first of a scrub, or one after a pause, starts at once;
/// each next one waits out `quiet` since the last began, so a drag makes a frame per pause rather than one
/// per touch sample.
public struct ScrubPreviewPacer: Sendable {
    public static let quiet: Duration = .milliseconds(80)

    private var lastStart: ContinuousClock.Instant?

    public init() {}

    /// How long a frame asked for at `now` waits before it starts.
    public mutating func delay(at now: ContinuousClock.Instant) -> Duration {
        var wait = Duration.zero
        if let lastStart, now - lastStart < Self.quiet { wait = Self.quiet - (now - lastStart) }
        lastStart = now.advanced(by: wait)
        return wait
    }

    /// A scrub ended: the next one starts at once.
    public mutating func reset() {
        lastStart = nil
    }
}

/// The made frames on disk, as JPEG files `<directory>/<part id>/<slot>.jpg`, oldest evicted first once they
/// pass `cap` bytes. A frame is a few KB, so 20 MB holds hours of previews.
public actor ScrubPreviewDisk {
    public static let defaultCap = 20_000_000

    private struct Key: Hashable {
        let part: Int
        let slot: Int
    }

    private let directory: URL
    private let cap: Int
    /// Oldest first.
    private var order: [Key] = []
    private var sizes: [Key: Int] = [:]
    private var total = 0
    private var loaded = false

    public init(directory: URL, cap: Int = ScrubPreviewDisk.defaultCap) {
        self.directory = directory
        self.cap = cap
    }

    /// The bytes held.
    public var byteCount: Int {
        load()
        return total
    }

    /// The slots of a part that have a frame.
    public func slots(part: Int) -> Set<Int> {
        load()
        return Set(sizes.keys.lazy.filter { $0.part == part }.map(\.slot))
    }

    public func data(part: Int, slot: Int) -> Data? {
        load()
        guard sizes[Key(part: part, slot: slot)] != nil else { return nil }
        return try? Data(contentsOf: file(Key(part: part, slot: slot)))
    }

    public func store(_ data: Data, part: Int, slot: Int) {
        load()
        let key = Key(part: part, slot: slot)
        let url = file(key)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        if let old = sizes[key] {
            total -= old
            order.removeAll { $0 == key }
        }
        sizes[key] = data.count
        order.append(key)
        total += data.count
        while total > cap, !order.isEmpty {
            let oldest = order.removeFirst()
            total -= sizes.removeValue(forKey: oldest) ?? 0
            try? FileManager.default.removeItem(at: file(oldest))
        }
    }

    private func file(_ key: Key) -> URL {
        directory.appending(path: "\(key.part)/\(key.slot).jpg", directoryHint: .notDirectory)
    }

    /// Reads what an earlier run left, ordered by modification time.
    private func load() {
        guard !loaded else { return }
        loaded = true
        let manager = FileManager.default
        guard let parts = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        var found: [(key: Key, size: Int, modified: Date)] = []
        for name in parts {
            guard let part = Int(name),
                  let files = try? manager.contentsOfDirectory(atPath: directory.appending(path: name).path) else { continue }
            for file in files where file.hasSuffix(".jpg") {
                guard let slot = Int(file.dropLast(4)),
                      let attributes = try? manager.attributesOfItem(atPath: directory.appending(path: "\(name)/\(file)").path)
                else { continue }
                found.append((Key(part: part, slot: slot), (attributes[.size] as? Int) ?? 0, (attributes[.modificationDate] as? Date) ?? .distantPast))
            }
        }
        found.sort { ($0.modified, $0.key.part, $0.key.slot) < ($1.modified, $1.key.part, $1.key.slot) }
        for entry in found {
            order.append(entry.key)
            sizes[entry.key] = entry.size
            total += entry.size
        }
    }
}
