import Foundation
import Synchronization

/// Whose snapshot a response belongs to: one server, seen by one profile. Never the token, so a rotated
/// token or a different address of the same server keeps its snapshot.
public struct SnapshotScope: Hashable, Sendable {
    public let server: String
    public let profile: String

    public init(server: String, profile: String) {
        self.server = server
        self.profile = profile
    }
}

/// Raw Plex responses kept on disk, so a screen can show its last content before the server answers and
/// decode it with the same decoders as a live answer. One folder per scope, one file per request; a file
/// holds the request's key on its first line, then the body, so a hash collision cannot hand one
/// profile's response to another. Bounded per response, per scope and in total, and older than `maxAge`
/// is not served.
///
/// The calls do file input and output; call them off the main thread. Every operation takes one lock,
/// and `removeAll()` and `remove(profile:)` start a new epoch, so a write still in flight from before a
/// sign-out lands nowhere.
public final class SnapshotStore: Sendable {
    public struct Limits: Sendable, Equatable {
        public var entryBytes = 4 << 20
        public var scopeBytes = 12 << 20
        public var totalBytes = 48 << 20
        public var maxAge: TimeInterval = 30 * 86_400

        public init() {}
    }

    public struct Entry: Sendable {
        public let body: Data
        public let savedAt: Date
    }

    private let directory: URL
    private let limits: Limits
    private let clock: @Sendable () -> Date
    /// Counts removals.
    private let epochCounter = Atomic<Int>(0)
    /// Held for every file operation, so a removal and a write never interleave.
    private let files = Mutex<Void>(())

    public init(directory: URL, limits: Limits = Limits(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.clock = clock
    }

    /// What a snapshot made now must carry to be written. Read without the file lock, so it is cheap on the main thread.
    public var epoch: Int { epochCounter.load(ordering: .sequentiallyConsistent) }

    public func read(_ request: String, in scope: SnapshotScope) -> Entry? {
        let file = fileURL(request, in: scope)
        return files.withLock { _ in
            guard let data = try? Data(contentsOf: file),
                  let newline = data.firstIndex(of: 0x0A),
                  data[..<newline].elementsEqual(Self.header(request, in: scope).utf8),
                  let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            guard clock().timeIntervalSince(saved) <= limits.maxAge else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return Entry(body: Data(data[data.index(after: newline)...]), savedAt: saved)
        }
    }

    /// Keeps `body` as `request`'s snapshot unless a removal came after `epoch` was read, or the body is
    /// over the per-response bound.
    public func write(_ body: Data, for request: String, in scope: SnapshotScope, epoch: Int) {
        guard body.count <= limits.entryBytes else { return }
        var data = Data(Self.header(request, in: scope).utf8)
        data.append(0x0A)
        data.append(body)
        let folder = scopeURL(scope)
        files.withLock { _ in
            guard epochCounter.load(ordering: .sequentiallyConsistent) == epoch else { return }
            let fm = FileManager.default
            let file = folder.appending(path: Self.hash(request), directoryHint: .notDirectory)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                try fm.setAttributes([.modificationDate: clock()], ofItemAtPath: file.path(percentEncoded: false))
            } catch {
                return
            }
            trim(folder)
            trimTotal(keeping: folder)
        }
    }

    /// Sign-out and Delete All Local Data: everything.
    public func removeAll() {
        files.withLock { _ in
            epochCounter.add(1, ordering: .sequentiallyConsistent)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A profile switch: whatever the profile left behind, on every server.
    public func remove(profile: String) {
        files.withLock { _ in
            epochCounter.add(1, ordering: .sequentiallyConsistent)
            let prefix = Self.hash(profile) + "-"
            for folder in folders() where folder.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    // MARK: Files

    private func scopeURL(_ scope: SnapshotScope) -> URL {
        directory.appending(path: "\(Self.hash(scope.profile))-\(Self.hash(scope.server))", directoryHint: .isDirectory)
    }

    private func fileURL(_ request: String, in scope: SnapshotScope) -> URL {
        scopeURL(scope).appending(path: Self.hash(request), directoryHint: .notDirectory)
    }

    private static func header(_ request: String, in scope: SnapshotScope) -> String {
        "\(scope.profile)\u{1F}\(scope.server)\u{1F}\(request)"
    }

    private func folders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private struct Item {
        let url: URL
        let bytes: Int
        let modified: Date
    }

    private func items(in folder: URL) -> [Item] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Item(url: url, bytes: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Drops what is past `maxAge`, then the oldest files until the scope fits.
    private func trim(_ folder: URL) {
        let now = clock()
        var kept: [Item] = []
        for item in items(in: folder) {
            if now.timeIntervalSince(item.modified) > limits.maxAge {
                try? FileManager.default.removeItem(at: item.url)
            } else {
                kept.append(item)
            }
        }
        var total = kept.reduce(0) { $0 + $1.bytes }
        for item in kept.sorted(by: { $0.modified < $1.modified }) where total > limits.scopeBytes {
            try? FileManager.default.removeItem(at: item.url)
            total -= item.bytes
        }
    }

    /// Drops whole scopes, least recently written first, until the store fits. `keeping` is the one just written.
    private func trimTotal(keeping: URL) {
        var scopes: [(url: URL, bytes: Int, modified: Date)] = folders().map { folder in
            let files = items(in: folder)
            return (folder, files.reduce(0) { $0 + $1.bytes }, files.map(\.modified).max() ?? .distantPast)
        }
        var total = scopes.reduce(0) { $0 + $1.bytes }
        scopes.sort { $0.modified < $1.modified }
        for scope in scopes where total > limits.totalBytes && scope.url.lastPathComponent != keeping.lastPathComponent {
            try? FileManager.default.removeItem(at: scope.url)
            total -= scope.bytes
        }
    }

    /// FNV-1a over the UTF-8 bytes, as 16 hex digits: stable across launches, unlike `hashValue`.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// Thrown by a replaying snapshot for a request that was never recorded.
public struct SnapshotUnavailable: Error, Equatable {
    public init() {}
}

/// A snapshot store for one scope, in one of two modes. Recording lets a live request through, then
/// keeps its answer once it has decoded. Replaying answers from disk only and never touches the network,
/// so a screen's own loading code runs unchanged over the stored bytes.
public struct ResponseSnapshot: Sendable {
    public enum Mode: Sendable {
        case record, replay
    }

    public let store: SnapshotStore
    public let scope: SnapshotScope
    public let mode: Mode
    private let epoch: Int
    private let oldest: Oldest

    public init(store: SnapshotStore, scope: SnapshotScope, mode: Mode) {
        self.store = store
        self.scope = scope
        self.mode = mode
        epoch = store.epoch
        oldest = Oldest()
    }

    /// When the oldest response a replay used was saved: the snapshot's age.
    public var savedAt: Date? { oldest.date.withLock { $0 } }

    /// The key of one request: path, query and the paging headers, with any token left out.
    public static func requestKey(path: String, query: [URLQueryItem], headers: [String: String] = [:]) -> String {
        let items = query
            .filter { $0.name.lowercased() != "x-plex-token" }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
        var key = items.isEmpty ? path : path + "?" + items.joined(separator: "&")
        let start = headers[PlexHeader.containerStart], size = headers[PlexHeader.containerSize]
        if start != nil || size != nil { key += " #\(start ?? "")+\(size ?? "")" }
        return key
    }

    /// Replaying: decodes the stored body, or throws `SnapshotUnavailable`. Recording: sends, decodes,
    /// and hands the body to the store in the background.
    public func decoded<T>(
        _ request: String,
        fetch: () async throws -> Data,
        decode: (Data) throws -> T
    ) async throws -> T {
        switch mode {
        case .replay:
            guard let entry = await read(request) else { throw SnapshotUnavailable() }
            let value = try decode(entry.body)
            oldest.date.withLock { date in date = date.map { min($0, entry.savedAt) } ?? entry.savedAt }
            return value
        case .record:
            let body = try await fetch()
            let value = try decode(body)
            let (store, scope, epoch) = (store, scope, epoch)
            Task.detached(priority: .utility) {
                store.write(body, for: request, in: scope, epoch: epoch)
            }
            return value
        }
    }

    @concurrent
    private func read(_ request: String) async -> SnapshotStore.Entry? {
        store.read(request, in: scope)
    }

    private final class Oldest: Sendable {
        let date = Mutex<Date?>(nil)
    }
}
